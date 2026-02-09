#pragma once

#include <flutter/method_channel.h>
#include <flutter/event_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/encodable_value.h>

#include "pod_ble_core.h"

#include <memory>
#include <string>

namespace pod_connector {

class PodConnectorPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

    PodConnectorPlugin(flutter::PluginRegistrarWindows* registrar);
    virtual ~PodConnectorPlugin();

    // Disallow copy and assign
    PodConnectorPlugin(const PodConnectorPlugin&) = delete;
    PodConnectorPlugin& operator=(const PodConnectorPlugin&) = delete;

private:
    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& method_call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    std::unique_ptr<PodBLECore> ble_core_;

    // Event sinks
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> status_sink_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> scan_sink_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> payload_sink_;
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
