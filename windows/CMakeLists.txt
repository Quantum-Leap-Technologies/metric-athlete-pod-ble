cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "metric_athlete_pod_ble")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "metric_athlete_pod_ble_plugin")

add_library(${PLUGIN_NAME} SHARED
  "pod_connector_plugin.cpp"
  "pod_connector_plugin.h"
  "pod_ble_core.cpp"
  "pod_ble_core.h"
)

apply_standard_settings(${PLUGIN_NAME})

# C++20 required for standard coroutine support (co_await/co_return).
# Set per-target AFTER apply_standard_settings to override its C++17 default.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  CXX_VISIBILITY_PRESET hidden
)

# The host app's apply_standard_settings defines _HAS_EXCEPTIONS=0, but this
# plugin requires C++ exceptions for WinRT coroutines and error handling.
target_compile_definitions(${PLUGIN_NAME} PRIVATE _HAS_EXCEPTIONS=1)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  windowsapp
  kernel32
)

# List of absolute paths to libraries that should be bundled with the plugin
set(metric_athlete_pod_ble_bundled_libraries
  ""
  PARENT_SCOPE
)
