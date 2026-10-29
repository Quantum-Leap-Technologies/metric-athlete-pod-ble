import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:metric_athlete_pod_ble/utils/pod_protocol_decoder.dart';

/// File list (ICD V3.6): [payload length][file count] then 36 bytes per file:
/// 32-byte name + uint32 size (little endian). The exact size is how the Android
/// download knows a file is complete (the stream has no packet-count header).
Uint8List _fileList(Map<String, int> files) {
  final data = Uint8List(2 + files.length * 36);
  data[0] = data.length - 1; // payload length
  data[1] = files.length;
  var i = 0;
  files.forEach((name, size) {
    final base = 2 + i * 36;
    final bytes = ascii.encode(name);
    for (var b = 0; b < bytes.length; b++) {
      data[base + b] = bytes[b];
    }
    ByteData.sublistView(data, base + 32, base + 36).setUint32(0, size, Endian.little);
    i++;
  });
  return data;
}

void main() {
  test('the file list payload carries the exact size of every file', () {
    final messages = <PodMessage>[];
    final handler = PodProtocolHandler(onMessageDecoded: messages.add);

    handler.handleMessage(
      0x02,
      _fileList({'20260606_104934_v01.bin': 16471040, '20260612_130252_v01.bin': 64000}),
    );

    expect(messages, hasLength(1));
    final payload = messages.first.payload as Map;
    expect(payload['fileSizes'], {
      '20260606_104934_v01.bin': 16471040,
      '20260612_130252_v01.bin': 64000,
    });
    // The display strings are unchanged (KB, one decimal).
    expect((payload['files'] as List).first, '20260606_104934_v01.bin (16085.0 KB)');
    expect(payload['storageUsedBytes'], 16471040 + 64000);
  });
}
