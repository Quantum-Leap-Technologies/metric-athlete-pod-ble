#include "pod_ble_core.h"

#include <winrt/Windows.Security.Cryptography.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <sstream>
#include <iomanip>

namespace pod_connector {

// UUID constants matching the Pod firmware
const winrt::guid PodBLECore::SERVICE_UUID{0x761993FB, 0xAD28, 0x4438,
    {0xA7, 0xB0, 0x6A, 0xB3, 0xF2, 0xE0, 0x38, 0x16}};
const winrt::guid PodBLECore::NOTIFY_CHAR_UUID{0x5E0C4072, 0xEE4D, 0x450D,
    {0x90, 0xA5, 0xA1, 0xFE, 0xFD, 0xB8, 0x46, 0x92}};
const winrt::guid PodBLECore::WRITE_CHAR_UUID{0xFB4A9352, 0x9BCD, 0x4CC6,
    {0x80, 0xE4, 0xAE, 0x37, 0xD1, 0x6F, 0xFB, 0xF1}};

PodBLECore::PodBLECore() {}

PodBLECore::~PodBLECore() {
    alive_->store(false);
    StopWatchdog();
    Disconnect();
    AllowSleep();
}

void PodBLECore::SetCallbacks(StatusCallback status, ScanCallback scan, PayloadCallback payload) {
    on_status_ = std::move(status);
    on_scan_ = std::move(scan);
    on_payload_ = std::move(payload);
}

// MARK: - Scanning

void PodBLECore::StartScan() {
    watcher_ = BluetoothLEAdvertisementWatcher();
    watcher_.ScanningMode(BluetoothLEScanningMode::Active);

    watcher_.Received([this](auto const& watcher, auto const& args) {
        OnAdvertisementReceived(watcher, args);
    });

    watcher_.Start();

    if (on_status_) on_status_("Scanning...");

    // Auto-stop after 15 seconds
    std::thread([this, alive = alive_]() {
        std::this_thread::sleep_for(std::chrono::seconds(15));
        if (alive->load()) StopScan();
    }).detach();
}

void PodBLECore::StopScan() {
    if (watcher_ != nullptr) {
        try {
            watcher_.Stop();
        } catch (...) {}
        watcher_ = nullptr;
    }
}

void PodBLECore::OnAdvertisementReceived(
    BluetoothLEAdvertisementWatcher const&,
    BluetoothLEAdvertisementReceivedEventArgs const& args) {

    auto adv = args.Advertisement();
    auto localName = winrt::to_string(adv.LocalName());

    // Filter for POD devices
    std::string upperName = localName;
    std::transform(upperName.begin(), upperName.end(), upperName.begin(),
        [](unsigned char c) -> char { return static_cast<char>(std::toupper(c)); });
    if (upperName.find("POD") != 0) return;

    // Format BLE address as string
    uint64_t addr = args.BluetoothAddress();
    std::ostringstream ss;
    ss << std::hex << std::setfill('0');
    for (int i = 5; i >= 0; i--) {
        ss << std::setw(2) << ((addr >> (i * 8)) & 0xFF);
        if (i > 0) ss << ":";
    }

    if (on_scan_) {
        on_scan_(localName, ss.str(), args.RawSignalStrengthInDBm());
    }
}

// MARK: - Connection

void PodBLECore::Connect(const std::string& deviceAddress) {
    StopScan();
    if (on_status_) on_status_("Connecting...");

    // Parse address string back to uint64
    uint64_t addr = 0;
    std::istringstream ss(deviceAddress);
    std::string byte_str;
    while (std::getline(ss, byte_str, ':')) {
        addr = (addr << 8) | std::stoul(byte_str, nullptr, 16);
    }

    ConnectAsync(addr);
}

winrt::fire_and_forget PodBLECore::ConnectAsync(uint64_t address) {
    try {
        device_ = co_await BluetoothLEDevice::FromBluetoothAddressAsync(address);
        if (device_ == nullptr) {
            if (on_status_) on_status_("Device Not Found");
            co_return;
        }

        PreventSleep();

        auto servicesResult = co_await device_.GetGattServicesForUuidAsync(SERVICE_UUID);
        if (servicesResult.Status() != GattCommunicationStatus::Success ||
            servicesResult.Services().Size() == 0) {
            if (on_status_) on_status_("Service Not Found");
            co_return;
        }

        auto service = servicesResult.Services().GetAt(0);

        // Get Notify Characteristic
        auto notifyResult = co_await service.GetCharacteristicsForUuidAsync(NOTIFY_CHAR_UUID);
        if (notifyResult.Status() == GattCommunicationStatus::Success &&
            notifyResult.Characteristics().Size() > 0) {
            notify_char_ = notifyResult.Characteristics().GetAt(0);

            // Enable notifications
            auto status = co_await notify_char_.WriteClientCharacteristicConfigurationDescriptorAsync(
                GattClientCharacteristicConfigurationDescriptorValue::Notify);

            if (status == GattCommunicationStatus::Success) {
                notify_char_.ValueChanged([this](auto const&, GattValueChangedEventArgs const& args) {
                    auto reader = DataReader::FromBuffer(args.CharacteristicValue());
                    reader.ByteOrder(ByteOrder::LittleEndian);
                    std::vector<uint8_t> data(reader.UnconsumedBufferLength());
                    reader.ReadBytes(data);

                    {
                        std::lock_guard<std::mutex> lock(mtx_);
                        last_packet_time_ = std::chrono::steady_clock::now();
                    }

                    if (total_expected_packets_ > 0 || received_packet_count_ == 0) {
                        ProcessPacket(data);
                    } else {
                        if (on_payload_) on_payload_(data);
                    }
                });
            }
        }

        // Get Write Characteristic
        auto writeResult = co_await service.GetCharacteristicsForUuidAsync(WRITE_CHAR_UUID);
        if (writeResult.Status() == GattCommunicationStatus::Success &&
            writeResult.Characteristics().Size() > 0) {
            write_char_ = writeResult.Characteristics().GetAt(0);
        }

        if (on_status_) on_status_("Connected");

        // Clear leftover buffers on Pod
        std::this_thread::sleep_for(std::chrono::seconds(1));
        WriteCommand({0x08});

    } catch (const winrt::hresult_error&) {
        if (on_status_) on_status_("Connection Error");
    }
}

void PodBLECore::Disconnect() {
    StopWatchdog();
    AllowSleep();

    notify_char_ = nullptr;
    write_char_ = nullptr;

    if (device_ != nullptr) {
        device_.Close();
        device_ = nullptr;
    }

    ResetDownloadState();
    if (on_status_) on_status_("Disconnected");
}

// MARK: - Write

winrt::fire_and_forget PodBLECore::WriteCommand(const std::vector<uint8_t>& data) {
    if (write_char_ == nullptr) co_return;

    try {
        DataWriter writer;
        writer.ByteOrder(ByteOrder::LittleEndian);
        writer.WriteBytes(data);
        auto buffer = writer.DetachBuffer();

        co_await write_char_.WriteValueAsync(buffer, GattWriteOption::WriteWithResponse);
    } catch (...) {}
}

// MARK: - Download

void PodBLECore::DownloadFile(const std::string& filename, int64_t start, int64_t end,
                               int totalFiles, int currentIndex) {
    StopWatchdog();
    ResetDownloadState();

    filter_start_ = start;
    filter_end_ = end;
    is_filtering_ = (start > 0 || end > 0);

    // Construct command: 0x06 + 0x20 + [32 bytes filename]
    std::string cleanName = filename;
    auto parenPos = cleanName.find('(');
    if (parenPos != std::string::npos) {
        cleanName = cleanName.substr(0, parenPos);
    }
    // Trim trailing spaces
    cleanName.erase(cleanName.find_last_not_of(' ') + 1);

    std::vector<uint8_t> command(34, 0);
    command[0] = 0x06;
    command[1] = 0x20;
    size_t copyLen = std::min(cleanName.size(), size_t(32));
    std::memcpy(command.data() + 2, cleanName.data(), copyLen);

    WriteCommand(command);

    last_packet_time_ = std::chrono::steady_clock::now();
    StartWatchdog();
}

void PodBLECore::CancelDownload() {
    StopWatchdog();
    WriteCommand({0x08});
    ResetDownloadState();

    // Send skip signal
    std::thread([this, alive = alive_]() {
        std::this_thread::sleep_for(std::chrono::milliseconds(600));
        if (alive->load() && on_payload_) on_payload_({0xDA});
    }).detach();
}

// MARK: - Packet Reassembly

void PodBLECore::ProcessPacket(const std::vector<uint8_t>& packet) {
    if (packet.size() < 5) return;

    if (actual_packet_size_ == 0) {
        actual_packet_size_ = static_cast<int>(packet.size());
    }

    if (received_packet_count_ == 0) {
        if (packet.size() < 9) return;

        current_message_type_ = packet[0];

        // Read total expected packets (bytes 5-8, little endian)
        total_expected_packets_ = static_cast<int>(
            packet[5] | (packet[6] << 8) | (packet[7] << 16) | (packet[8] << 24));

        int safeSize = std::max(actual_packet_size_, 64);
        int estimatedSize = total_expected_packets_ * (safeSize - 5) + 2048;
        payload_buffer_.clear();
        payload_buffer_.reserve(estimatedSize);

        payload_buffer_.push_back(current_message_type_);

        if (packet.size() > 9) {
            payload_buffer_.insert(payload_buffer_.end(), packet.begin() + 9, packet.end());
        }
        received_packet_count_ = 1;

    } else {
        if (packet.size() > 5) {
            payload_buffer_.insert(payload_buffer_.end(), packet.begin() + 5, packet.end());
        }
        received_packet_count_++;
    }

    // Smart Peek
    if (is_filtering_ && current_message_type_ == 0x03 && !is_smart_peek_done_ &&
        payload_buffer_.size() >= 129) {
        PerformSmartPeek();
        is_smart_peek_done_ = true;
    }

    // Completion check
    if (total_expected_packets_ > 0 && received_packet_count_ >= total_expected_packets_) {
        std::thread([this, alive = alive_]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (alive->load()) FinishMessage();
        }).detach();
    }
}

void PodBLECore::PerformSmartPeek() {
    if (payload_buffer_.size() < 129) return;

    // Extract date from header (offset 1 to skip message type byte)
    uint16_t yr = payload_buffer_[5] | (payload_buffer_[6] << 8);
    uint8_t mon = payload_buffer_[7];
    uint8_t day = payload_buffer_[8];
    uint8_t hr = payload_buffer_[9];
    uint8_t min = payload_buffer_[10];
    uint8_t sec = payload_buffer_[11];

    // Convert to epoch ms (simplified)
    struct tm tm_val = {};
    tm_val.tm_year = yr - 1900;
    tm_val.tm_mon = mon - 1;
    tm_val.tm_mday = day;
    tm_val.tm_hour = hr;
    tm_val.tm_min = min;
    tm_val.tm_sec = sec;
    int64_t startTimeMs = static_cast<int64_t>(mktime(&tm_val)) * 1000;

    // Estimate duration
    uint32_t t1 = payload_buffer_[1] | (payload_buffer_[2] << 8) |
                  (payload_buffer_[3] << 16) | (payload_buffer_[4] << 24);
    uint32_t t2 = payload_buffer_[65] | (payload_buffer_[66] << 8) |
                  (payload_buffer_[67] << 16) | (payload_buffer_[68] << 24);
    int64_t interval = SnapToStandardInterval(static_cast<int64_t>(t2 - t1));
    int64_t ppp = std::max(actual_packet_size_ - 5, 59);
    int64_t dur = (static_cast<int64_t>(total_expected_packets_) * ppp / 64) * interval;

    if ((filter_end_ > 0 && startTimeMs > filter_end_) ||
        (filter_start_ > 0 && (startTimeMs + dur) < filter_start_)) {
        CancelDownload();
    }
}

void PodBLECore::FinishMessage() {
    StopWatchdog();

    std::vector<uint8_t> data;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        data = std::move(payload_buffer_);
    }

    if (on_payload_) on_payload_(data);

    received_packet_count_ = 0;
    total_expected_packets_ = 0;
    payload_buffer_.clear();
}

// MARK: - Watchdog

void PodBLECore::StartWatchdog() {
    StopWatchdog();
    watchdog_running_ = true;

    watchdog_thread_ = std::thread([this]() {
        while (watchdog_running_) {
            std::this_thread::sleep_for(std::chrono::seconds(1));

            std::chrono::steady_clock::time_point lpt;
            {
                std::lock_guard<std::mutex> lock(mtx_);
                lpt = last_packet_time_;
            }

            auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - lpt).count();

            // Hard timeout (60s)
            if (total_expected_packets_ > 0 && elapsed > 60000) {
                FinishMessage();
                return;
            }

            // Stuck at 99%
            if (total_expected_packets_ > 0 && elapsed > 2500) {
                double progress = static_cast<double>(received_packet_count_) /
                                  static_cast<double>(total_expected_packets_);
                if (progress > 0.98) {
                    FinishMessage();
                    return;
                }
            }
        }
    });
}

void PodBLECore::StopWatchdog() {
    watchdog_running_ = false;
    if (watchdog_thread_.joinable()) {
        watchdog_thread_.join();
    }
}

// MARK: - Helpers

void PodBLECore::ResetDownloadState() {
    received_packet_count_ = 0;
    total_expected_packets_ = 0;
    actual_packet_size_ = 0;
    is_smart_peek_done_ = false;
    payload_buffer_.clear();
}

int64_t PodBLECore::SnapToStandardInterval(int64_t raw) {
    const int64_t targets[] = {100, 200, 300, 400, 500, 600, 700, 800, 900, 1000};
    int64_t closest = 1000;
    int64_t minDiff = INT64_MAX;
    for (auto t : targets) {
        int64_t d = std::abs(raw - t);
        if (d < minDiff) {
            minDiff = d;
            closest = t;
        }
    }
    return closest;
}

void PodBLECore::PreventSleep() {
    SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
}

void PodBLECore::AllowSleep() {
    SetThreadExecutionState(ES_CONTINUOUS);
}

} // namespace pod_connector
