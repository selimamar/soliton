import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The current time, refreshed every [Clock.tick].
///
/// Widgets that show elapsed or remaining time watch this, so the values keep
/// moving on screen. Tests can override it with a fixed time.
final clockProvider = NotifierProvider<Clock, DateTime>(Clock.new);

class Clock extends Notifier<DateTime> {
  static const tick = Duration(seconds: 10);

  @override
  DateTime build() {
    final timer = Timer.periodic(tick, (_) => state = DateTime.now());
    ref.onDispose(timer.cancel);
    return DateTime.now();
  }
}
