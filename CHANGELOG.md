## 1.0.0
* **Initial Release**
* implemented robust BLE connectivity with auto-reconnect and watchdog.
* Added native Android Foreground Service for reliable background downloads.
* Implemented 3-Stage Trajectory Filter:
    * Stage -1: Sanity Check (Gibberish removal).
    * Stage 0: Linear Interpolation (Packet loss repair).
    * Stage 1 & 2: Variance-tuned Kalman Filter + RTS Smoother.
