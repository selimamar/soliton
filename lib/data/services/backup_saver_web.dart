import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'dart:ui' show Rect;

import 'backup_saver.dart';

const BackupSaver saver = _WebBackupSaver();

/// In a browser: the backup is gathered in memory, then handed to the
/// browser as a download.
class _WebBackupSaver extends BackupSaver {
  const _WebBackupSaver();

  @override
  String get destination => 'your browser downloads it';

  @override
  Future<String?> save(String fileName, Stream<List<int>> bytes, {Rect? origin}) async {
    final buffer = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      buffer.add(chunk);
    }
    final blob = _Blob(
      [buffer.takeBytes().toJS].toJS,
      _BlobOptions(type: 'application/vnd.sqlite3'),
    );
    final url = _createObjectUrl(blob);
    final link = _document.createElement('a')
      ..href = url
      ..download = fileName;
    _document.body.appendChild(link);
    link.click();
    link.remove();
    // Freed once the browser has had time to start the download.
    Timer(const Duration(minutes: 1), () => _revokeObjectUrl(url));
    return 'Downloaded $fileName.';
  }
}

@JS('URL.createObjectURL')
external String _createObjectUrl(_Blob blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSUint8Array> parts, _BlobOptions options);
}

extension type _BlobOptions._(JSObject _) implements JSObject {
  external factory _BlobOptions({String type});
}

@JS('document')
external _Document get _document;

extension type _Document._(JSObject _) implements JSObject {
  external _Element createElement(String tag);
  external _Element get body;
}

extension type _Element._(JSObject _) implements JSObject {
  external set href(String value);
  external set download(String value);
  external void click();
  external void remove();
  external JSObject appendChild(_Element child);
}
