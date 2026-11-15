import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:share_plus/share_plus.dart';

import 'backup_saver.dart';

const BackupSaver saver = _IoBackupSaver();

class _IoBackupSaver extends BackupSaver {
  const _IoBackupSaver();

  static bool get _shares => Platform.isIOS || Platform.isAndroid;

  /// Android's "Save to…" screen (MainActivity.kt).
  static const _android = MethodChannel('soliton/save_file');

  @override
  String get destination =>
      _shares ? "you'll choose where it goes" : 'it goes to your Downloads folder';

  @override
  Future<String?> save(String fileName, Stream<List<int>> bytes, {Rect? origin}) async {
    if (Platform.isAndroid) return _saveOnAndroid(fileName, bytes);
    if (_shares) return _share(fileName, bytes, origin);
    final downloads = _downloads();
    if (!downloads.existsSync()) throw const FileSystemException('No Downloads folder');
    final target = _unused(downloads, fileName);
    final part = File('${downloads.path}/.${target.uri.pathSegments.last}.part');
    try {
      await _write(part, bytes);
      await part.rename(target.path);
    } catch (_) {
      if (part.existsSync()) await part.delete();
      rethrow;
    }
    return 'Saved to Downloads as ${target.uri.pathSegments.last}.';
  }

  /// A copy in the app's own temporary folder (private to the app), copied
  /// by Android to where the person picks, then removed. The share sheet
  /// would keep another copy in the app's cache until the next share.
  Future<String?> _saveOnAndroid(String fileName, Stream<List<int>> bytes) async {
    final folder = await Directory.systemTemp.createTemp('soliton-backup-');
    try {
      final file = File('${folder.path}/$fileName');
      await _write(file, bytes);
      final saved = await _android.invokeMethod<String>('save', {
        'path': file.path,
        'name': fileName,
        'mimeType': 'application/vnd.sqlite3',
      });
      if (saved == null) return 'Backup not saved.';
      return saved.isEmpty ? 'Backup saved.' : 'Saved as $saved.';
    } finally {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // The system cleans its temporary folder by itself.
      }
    }
  }

  /// A copy in the app's own temporary folder (private to the app), shared,
  /// then removed.
  Future<String?> _share(String fileName, Stream<List<int>> bytes, Rect? origin) async {
    final folder = await Directory.systemTemp.createTemp('soliton-backup-');
    try {
      final file = File('${folder.path}/$fileName');
      await _write(file, bytes);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/vnd.sqlite3', name: fileName)],
          sharePositionOrigin: origin,
        ),
      );
      return null;
    } finally {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // The system cleans its temporary folder by itself.
      }
    }
  }

  static Future<void> _write(File file, Stream<List<int>> bytes) async {
    final sink = file.openWrite();
    try {
      await sink.addStream(bytes);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  /// The Downloads folder. In the Mac app's sandbox, Downloads inside its
  /// container leads to the real one (the downloads entitlement).
  static Directory _downloads() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return Directory('$home/Downloads');
  }

  /// [fileName] in [folder], or "name (2).db" and so on if it's taken: a
  /// backup never replaces a file.
  static File _unused(Directory folder, String fileName) {
    final dot = fileName.lastIndexOf('.');
    final (stem, extension) = dot > 0
        ? (fileName.substring(0, dot), fileName.substring(dot))
        : (fileName, '');
    var file = File('${folder.path}/$fileName');
    for (var n = 2; file.existsSync() || Link(file.path).existsSync(); n++) {
      file = File('${folder.path}/$stem ($n)$extension');
    }
    return file;
  }
}
