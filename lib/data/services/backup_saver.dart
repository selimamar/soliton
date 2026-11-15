import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:ui' show Rect;

import 'backup_saver_io.dart' if (dart.library.js_interop) 'backup_saver_web.dart' as platform;

/// Puts a downloaded backup (Settings → Storage → Download a backup) where
/// the person can keep it:
///
/// - Mac: the Downloads folder.
/// - iPhone and iPad: the share sheet (Save to Files, AirDrop…), from a copy
///   in the app's own temporary folder, removed after.
/// - Android: its "Save to…" screen (Downloads, Drive…), from such a copy
///   too (MainActivity.kt). Not the share sheet: it would keep another copy
///   in the app's cache until the next share.
/// - Web: the browser's download.
///
/// A backup holds everything the server stores, so it is never left
/// anywhere else, and a stopped download leaves no partial file.
abstract class BackupSaver {
  const BackupSaver();

  /// Where a backup goes, to say before downloading, e.g. "your Downloads
  /// folder".
  String get destination;

  /// Saves [bytes] as [fileName]; returns what to tell the person (e.g.
  /// "Saved to Downloads as …"), or null when they saw it go (share sheet).
  /// [origin]: where the share sheet points (iPad).
  Future<String?> save(String fileName, Stream<List<int>> bytes, {Rect? origin});
}

final backupSaverProvider = Provider<BackupSaver>((ref) => platform.saver);
