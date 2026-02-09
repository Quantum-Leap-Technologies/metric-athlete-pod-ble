///Helper class used to store the [filePath] of a file and the [start] and [end] time used for filtering and selection.
class UsbFileBounds {
  final DateTime start;
  final DateTime end;
  final String filePath;

  UsbFileBounds({
    required this.start,
    required this.end,
    required this.filePath,
  });
}