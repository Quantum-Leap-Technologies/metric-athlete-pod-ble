import 'dart:async';
import 'package:flutter/foundation.dart';

/// Serial execution queue for BLE commands.
///
/// Prevents overlapping writeCommand/downloadFile/cancelDownload calls
/// that can cause E_FAIL on the WinRT BLE stack and similar issues
/// on other platforms.
class BleCommandQueue {
  final _queue = <_QueuedCommand>[];
  bool _processing = false;

  /// Enqueue a BLE command for serial execution.
  ///
  /// Returns a Future that completes when the command finishes
  /// (or fails with a timeout error).
  Future<void> enqueue(
    Future<void> Function() command, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<void>();
    _queue.add(_QueuedCommand(command, completer, timeout));
    _processNext();
    return completer.future;
  }

  /// Cancel all pending commands without affecting the currently running one.
  void clear() {
    for (final cmd in _queue) {
      if (!cmd.completer.isCompleted) {
        cmd.completer.completeError('Queue cleared');
      }
    }
    _queue.clear();
  }

  Future<void> _processNext() async {
    if (_processing || _queue.isEmpty) return;
    _processing = true;

    while (_queue.isNotEmpty) {
      final cmd = _queue.removeAt(0);
      if (cmd.completer.isCompleted) continue;

      try {
        await cmd.command().timeout(cmd.timeout);
        if (!cmd.completer.isCompleted) {
          cmd.completer.complete();
        }
      } on TimeoutException {
        if (!cmd.completer.isCompleted) {
          cmd.completer.completeError('BLE command timed out');
        }
        debugPrint('[BleCommandQueue] Command timed out after ${cmd.timeout}');
      } catch (e) {
        if (!cmd.completer.isCompleted) {
          cmd.completer.completeError(e);
        }
      }
    }

    _processing = false;
  }
}

class _QueuedCommand {
  final Future<void> Function() command;
  final Completer<void> completer;
  final Duration timeout;

  _QueuedCommand(this.command, this.completer, this.timeout);
}
