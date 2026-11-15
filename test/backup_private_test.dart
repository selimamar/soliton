@TestOn('mac-os || linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soliton/data/services/backup_saver_io.dart';

void main() {
  test('a saved backup is readable by you only', () {
    final folder = Directory.systemTemp.createTempSync('soliton-private-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final file = File('${folder.path}/soliton – my server.db')..writeAsStringSync('x');
    Process.runSync('chmod', ['644', file.path]);
    makePrivate(file.path);
    expect(file.statSync().mode & 0x1FF, 0x180, reason: 'rw------- (0600)');
  });
}
