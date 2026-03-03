#include "pod_connector_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace pod_connector {

namespace {
// Flutter's StandardMethodCodec encodes Dart int as either int32_t or int64_t
// depending on the value's magnitude. This helper extracts either variant safely.
int GetIntFromEncodableValue(const flutter::EncodableValue& value, int fallback) {
    if (auto* i32 = std::get_if<int32_t>(&value)) return static_cast<int>(*i32);
    if (auto* i64 = std::get_if<int64_t>(&value)) return static_cast<int>(*i64);
    return fallback;
}
}  // namespace

// static
void PodConnectorPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<PodConnectorPlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
}

PodConnectorPlugin::PodConnectorPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {

    // Capture HWND for dispatching BLE callbacks back to the platform thread.
    // BLE events fire on WinRT thread-pool threads, but Flutter requires all
    // EventSink calls on the platform (UI) thread.
    auto view = registrar->GetView();
    if (view) {
        window_handle_ = FlutterDesktopViewGetHWND(view);
    }

    // Register a window proc delegate to handle our custom callback message.
    proc_delegate_id_ = registrar->RegisterTopLevelWindowProcDelegate(
        [this](HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
            return HandleWindowMessage(hwnd, msg, wparam, lparam);
        });

    // Method Channel
    auto method_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "com.example.pod_connector/methods",
        &flutter::StandardMethodCodec::GetInstance());

    method_channel->SetMethodCallHandler(
        [this](const auto& call, auto result) {
            HandleMethodCall(call, std::move(result));
        });

    // Status Event Channel
    auto status_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        registrar->messenger(), "com.example.pod_connector/status",
        &flutter::StandardMethodCodec::GetInstance());

    status_channel->SetStreamHandler(
        std::make_unique<StreamHandler<void>>(
            [this](auto sink) { status_sink_ = std::move(sink); },
            [this](auto) { status_sink_.reset(); }));

    // Scan Event Channel
    auto scan_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        registrar->messenger(), "com.example.pod_connector/scan",
        &flutter::StandardMethodCodec::GetInstance());

    scan_channel->SetStreamHandler(
        std::make_unique<StreamHandler<void>>(
            [this](auto sink) { scan_sink_ = std::move(sink); },
            [this](auto) { scan_sink_.reset(); }));

    // Payload Event Channel
    auto payload_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        registrar->messenger(), "com.example.pod_connector/payload",
        &flutter::StandardMethodCodec::GetInstance());

    payload_channel->SetStreamHandler(
        std::make_unique<StreamHandler<void>>(
            [this](auto sink) { payload_sink_ = std::move(sink); },
            [this](auto) { payload_sink_.reset(); }));

    // Initialize BLE Core
    ble_core_ = std::make_unique<PodBLECore>();
    ble_core_->SetCallbacks(
        // Status callback — dispatched to platform thread
        [this](const std::string& status) {
            PostToMainThread([this, status]() {
                if (status_sink_) {
                    status_sink_->Success(flutter::EncodableValue(status));
                }
            });
        },
        // Scan callback — dispatched to platform thread
        [this](const std::string& name, const std::string& id, int rssi) {
            PostToMainThread([this, name, id, rssi]() {
                if (scan_sink_) {
                    flutter::EncodableMap device_map;
                    device_map[flutter::EncodableValue("name")] = flutter::EncodableValue(name);
                    device_map[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
                    device_map[flutter::EncodableValue("rssi")] = flutter::EncodableValue(rssi);
                    scan_sink_->Success(flutter::EncodableValue(device_map));
                }
            });
        },
        // Payload callback — dispatched to platform thread
        [this](const std::vector<uint8_t>& data) {
            PostToMainThread([this, data]() {
                if (payload_sink_) {
                    payload_sink_->Success(flutter::EncodableValue(data));
                }
            });
        });
}

PodConnectorPlugin::~PodConnectorPlugin() {
    if (registrar_ && proc_delegate_id_ >= 0) {
        registrar_->UnregisterTopLevelWindowProcDelegate(proc_delegate_id_);
    }
}

void PodConnectorPlugin::PostToMainThread(std::function<void()> callback) {
    if (window_handle_ == nullptr) {
        // No window handle (headless?) — call directly as fallback
        callback();
        return;
    }
    auto* fn = new std::function<void()>(std::move(callback));
    if (!PostMessage(window_handle_, kCallbackMessage,
                     reinterpret_cast<WPARAM>(fn), 0)) {
        delete fn;
    }
}

std::optional<LRESULT> PodConnectorPlugin::HandleWindowMessage(
    HWND /*hwnd*/, UINT message, WPARAM wparam, LPARAM /*lparam*/) {
    if (message == kCallbackMessage) {
        auto* fn = reinterpret_cast<std::function<void()>*>(wparam);
        if (fn) {
            (*fn)();
            delete fn;
        }
        return 0;
    }
    return std::nullopt;
}

void PodConnectorPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

    const auto& method = method_call.method_name();

    if (method == "startScan") {
        ble_core_->StartScan();
        result->Success();
    } else if (method == "stopScan") {
        ble_core_->StopScan();
        result->Success();
    } else if (method == "connect") {
        auto* args = std::get_if<std::string>(method_call.arguments());
        if (args) {
            ble_core_->Connect(*args);
            result->Success();
        } else {
            result->Error("INVALID_ARG", "Device ID required");
        }
    } else if (method == "disconnect") {
        ble_core_->Disconnect();
        result->Success();
    } else if (method == "writeCommand") {
        auto* bytes = std::get_if<std::vector<uint8_t>>(method_call.arguments());
        if (bytes) {
            ble_core_->WriteCommand(*bytes);
            result->Success();
        } else {
            result->Error("INVALID_ARG", "Byte array required");
        }
    } else if (method == "downloadFile") {
        auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
        if (args) {
            auto filename_it = args->find(flutter::EncodableValue("filename"));
            auto start_it = args->find(flutter::EncodableValue("filterStart"));
            auto end_it = args->find(flutter::EncodableValue("filterEnd"));
            auto total_it = args->find(flutter::EncodableValue("totalFiles"));
            auto index_it = args->find(flutter::EncodableValue("currentIndex"));

            std::string filename;
            if (filename_it != args->end()) {
                filename = std::get<std::string>(filename_it->second);
            }

            int64_t start = 0, end = 0;
            int totalFiles = 1, currentIndex = 1;

            if (start_it != args->end()) start = std::get<int64_t>(start_it->second);
            if (end_it != args->end()) end = std::get<int64_t>(end_it->second);
            if (total_it != args->end()) totalFiles = GetIntFromEncodableValue(total_it->second, 1);
            if (index_it != args->end()) currentIndex = GetIntFromEncodableValue(index_it->second, 1);

            ble_core_->DownloadFile(filename, start, end, totalFiles, currentIndex);
            result->Success();
        } else {
            result->Error("INVALID_ARG", "Download arguments required");
        }
    } else if (method == "cancelDownload") {
        ble_core_->CancelDownload();
        result->Success();
    } else if (method == "requestBatteryExemption") {
        // No-op on Windows
        result->Success();
    } else {
        result->NotImplemented();
    }
}

} // namespace pod_connector

// C-style registration function
void PodConnectorPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
    pod_connector::PodConnectorPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
