#pragma once

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include "pod_ble_core.h"

#include <functional>
#include <list>
#include <memory>
#include <mutex>
#include <optional>
#include <string>

namespace pod_connector {

class PodConnectorPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar,
                                      FlutterDesktopPluginRegistrarRef raw_registrar);

    PodConnectorPlugin(flutter::PluginRegistrarWindows* registrar,
                       FlutterDesktopPluginRegistrarRef raw_registrar);
    virtual ~PodConnectorPlugin();

    // Disallow copy and assign
    PodConnectorPlugin(const PodConnectorPlugin&) = delete;
    PodConnectorPlugin& operator=(const PodConnectorPlugin&) = delete;

private:
    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& method_call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    std::unique_ptr<PodBLECore> ble_core_;

    // Lifetime guard: checked by BLE callbacks before using sinks
    std::shared_ptr<std::atomic<bool>> alive_ = std::make_shared<std::atomic<bool>>(true);

    // Event sinks
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> status_sink_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> scan_sink_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> payload_sink_;

    // Platform thread dispatch: BLE callbacks fire on WinRT background threads,
    // but Flutter requires EventSink calls on the platform (UI) thread.
    HWND window_handle_ = nullptr;
    int proc_delegate_id_ = -1;
    flutter::PluginRegistrarWindows* registrar_ = nullptr;
    static constexpr UINT kCallbackMessage = WM_APP + 0x504F; // "PO" for Pod

    // Mutex-protected callback queue (swap-under-lock pattern).
    // Eliminates heap-allocated std::function* passed via WPARAM.
    std::mutex callback_mutex_;
    std::list<std::function<void()>> queued_callbacks_;

    void PostToMainThread(std::function<void()> callback);
    std::optional<LRESULT> HandleWindowMessage(
        HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
};

// Stream handler template
template <typename T>
class StreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
public:
    using SinkSetter = std::function<void(std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>)>;

    StreamHandler(SinkSetter setter, SinkSetter clearer)
        : setter_(std::move(setter)), clearer_(std::move(clearer)) {}

protected:
    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
    OnListenInternal(const flutter::EncodableValue* arguments,
                     std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events) override {
        setter_(std::move(events));
        return nullptr;
    }

    std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
    OnCancelInternal(const flutter::EncodableValue* arguments) override {
        clearer_(nullptr);
        return nullptr;
    }

private:
    SinkSetter setter_;
    SinkSetter clearer_;
};

} // namespace pod_connector

// C-style export for Flutter plugin registration
extern "C" {
    __declspec(dllexport) void PodConnectorPluginCApiRegisterWithRegistrar(
        FlutterDesktopPluginRegistrarRef registrar);
}
