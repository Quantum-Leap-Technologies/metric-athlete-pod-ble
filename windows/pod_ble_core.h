#pragma once

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Storage.Streams.h>

#include <functional>
#include <mutex>
#include <vector>
#include <string>
#include <chrono>
#include <thread>
#include <atomic>
#include <cstdint>

namespace pod_connector {

using namespace winrt;
using namespace Windows::Devices::Bluetooth;
using namespace Windows::Devices::Bluetooth::Advertisement;
using namespace Windows::Devices::Bluetooth::GenericAttributeProfile;
using namespace Windows::Storage::Streams;

/// Callback types for BLE events.
using StatusCallback = std::function<void(const std::string&)>;
using ScanCallback = std::function<void(const std::string& name, const std::string& id, int rssi)>;
using PayloadCallback = std::function<void(const std::vector<uint8_t>&)>;

/// Pure C++ class encapsulating WinRT BLE logic for Pod device communication.
class PodBLECore {
public:
    PodBLECore();
    ~PodBLECore();

    void SetCallbacks(StatusCallback status, ScanCallback scan, PayloadCallback payload);

    void StartScan();
    void StopScan();
    void Connect(const std::string& deviceAddress);
    void Disconnect();
    void WriteCommand(const std::vector<uint8_t>& data);
    void DownloadFile(const std::string& filename, int64_t start, int64_t end,
                      int totalFiles, int currentIndex);
    void CancelDownload();

private:
    // UUIDs
    static const winrt::guid SERVICE_UUID;
    static const winrt::guid NOTIFY_CHAR_UUID;
    static const winrt::guid WRITE_CHAR_UUID;

    // Callbacks
    StatusCallback on_status_;
    ScanCallback on_scan_;
    PayloadCallback on_payload_;

    // BLE objects
    BluetoothLEAdvertisementWatcher watcher_{nullptr};
    BluetoothLEDevice device_{nullptr};
    GattCharacteristic write_char_{nullptr};
    GattCharacteristic notify_char_{nullptr};

    // Packet reassembly
    std::vector<uint8_t> payload_buffer_;
    int received_packet_count_ = 0;
    int total_expected_packets_ = 0;
    int actual_packet_size_ = 0;
    uint8_t current_message_type_ = 0;

    // Smart Peek
    int64_t filter_start_ = 0;
    int64_t filter_end_ = 0;
    bool is_filtering_ = false;
    bool is_smart_peek_done_ = false;

    // Watchdog
    std::atomic<bool> watchdog_running_{false};
    std::thread watchdog_thread_;
    std::chrono::steady_clock::time_point last_packet_time_;
    std::mutex mtx_;

    // Sleep prevention
    void PreventSleep();
    void AllowSleep();

    // Internal
    void ProcessPacket(const std::vector<uint8_t>& packet);
    void PerformSmartPeek();
    void FinishMessage();
    void ResetDownloadState();
    void StartWatchdog();
    void StopWatchdog();
    int64_t SnapToStandardInterval(int64_t raw);

    // Async helpers
    winrt::fire_and_forget ConnectAsync(uint64_t address);
    void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher const& watcher,
                                  BluetoothLEAdvertisementReceivedEventArgs const& args);
};

} // namespace pod_connector
