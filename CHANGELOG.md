## 1.1.0

### Fixed
* **Double-filtering bug:** FilterPipeline no longer applies Butterworth twice on already-filtered data.
* **LiveTelemetry bounds check:** Validates payload length before parsing to prevent index-out-of-range crashes.
* **Android buffer overflow cap:** Limits packet reassembly buffer to prevent unbounded memory growth.
* **Android race condition:** Synchronized access to shared packet queue between GATT callback and processing threads.
* **Android watchdog threshold:** Increased stall timeout from 2.5s to 5s to avoid false positives on slow connections.
* **Android Smart Peek buffer underread:** Reads full 128-byte header before timestamp comparison.
* **iOS/macOS timezone:** Parses pod timestamps as UTC instead of local time, fixing date-filter mismatches.
* **iOS/macOS race conditions:** Thread-safe access to shared state on `bleQueue`.
* **Fire-and-forget async:** Awaits all critical async operations in PodNotifier to prevent silent failures.
* **copyWith null sentinel:** PodState.copyWith correctly distinguishes between "not provided" and explicit null.
* **Butterworth NaN guard:** Returns input unchanged if filter produces NaN/Infinity values.
* **O(n) telemetry insert:** Replaced O(n) list insert with O(1) append for telemetry history.
* **Outlier rejection cascade:** Limits consecutive rejected points to prevent chain-reaction data loss.
* **Download retry:** Sends cancel command before retrying a failed download to reset pod state.

### Added
* **PodLogger:** Structured diagnostic logging with ring buffer (500 entries), severity levels (debug/info/warn/error), category filtering (`ble`, `sync`, `protocol`, `clock`), and optional external listener hook via `onLog`.
* **RSSI tracking:** `lastRssi` field in PodState for real-time BLE signal strength monitoring.
* **Clock drift detection:** `clockDriftMs` field in PodState comparing pod RTC against device clock.
* **Data deduplication:** Filters duplicate records by packetId+timestamp in `syncAllFiles`.
* **Comprehensive test suite:** 106 tests across 6 files covering filters, stats, protocol decoding, state management, and data processing.

### Removed
* **`kalman_gps_filter.dart`:** Dead code — simpler 2D Kalman filter was unused after full TrajectoryFilter pipeline was implemented.

## 1.0.0
* **Initial Release**
* implemented robust BLE connectivity with auto-reconnect and watchdog.
* Added native Android Foreground Service for reliable background downloads.
* Implemented 3-Stage Trajectory Filter:
    * Stage -1: Sanity Check (Gibberish removal).
    * Stage 0: Linear Interpolation (Packet loss repair).
    * Stage 1 & 2: Variance-tuned Kalman Filter + RTS Smoother.
