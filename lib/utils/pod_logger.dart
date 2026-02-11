import 'package:flutter/foundation.dart';

/// Severity levels for diagnostic logging.
enum LogLevel { debug, info, warn, error }

/// A diagnostic event captured by the plugin.
class PodLogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final String category;
  final String message;
  final String? detail;

  PodLogEntry({
    required this.level,
    required this.category,
    required this.message,
    this.detail,
  }) : timestamp = DateTime.now();

  @override
  String toString() =>
      '[${timestamp.toIso8601String()}] ${level.name.toUpperCase()} [$category] $message${detail != null ? ' | $detail' : ''}';
}

/// Structured diagnostic logger for the Pod BLE plugin.
///
/// Maintains a ring buffer of recent log entries and optionally forwards
/// them to an external listener (e.g., Crashlytics, Sentry, or a UI console).
///
/// Usage:
/// ```dart
/// PodLogger.info('ble', 'Connected to device', detail: 'AA:BB:CC:DD');
/// PodLogger.warn('sync', 'Poor data quality', detail: 'health=42%');
/// ```
class PodLogger {
  PodLogger._();

  static const int _maxEntries = 500;
  static final List<PodLogEntry> _entries = [];

  /// Optional external listener for production telemetry.
  /// Set this to forward logs to Crashlytics, Sentry, or custom analytics.
  static void Function(PodLogEntry entry)? onLog;

  static void _log(LogLevel level, String category, String message, {String? detail}) {
    final entry = PodLogEntry(level: level, category: category, message: message, detail: detail);

    // Ring buffer
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeAt(0);
    }

    // Debug console output (only in debug mode)
    if (kDebugMode) {
      debugPrint(entry.toString());
    }

    // External listener
    onLog?.call(entry);
  }

  static void debug(String category, String message, {String? detail}) =>
      _log(LogLevel.debug, category, message, detail: detail);

  static void info(String category, String message, {String? detail}) =>
      _log(LogLevel.info, category, message, detail: detail);

  static void warn(String category, String message, {String? detail}) =>
      _log(LogLevel.warn, category, message, detail: detail);

  static void error(String category, String message, {String? detail}) =>
      _log(LogLevel.error, category, message, detail: detail);

  /// Returns a snapshot of the recent log entries.
  static List<PodLogEntry> get entries => List.unmodifiable(_entries);

  /// Returns entries filtered by category.
  static List<PodLogEntry> entriesForCategory(String category) =>
      _entries.where((e) => e.category == category).toList();

  /// Returns entries at or above the given severity level.
  static List<PodLogEntry> entriesAtLevel(LogLevel minLevel) =>
      _entries.where((e) => e.level.index >= minLevel.index).toList();

  /// Clears all stored entries.
  static void clear() => _entries.clear();
}
