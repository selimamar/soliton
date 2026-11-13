import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Key-value storage for settings that survive a restart.
///
/// Reads are synchronous (from memory), so providers can use saved values
/// in `build`. Writes are saved in the background.
abstract interface class SettingsStore {
  String? getString(String key);
  bool? getBool(String key);
  Future<void> setString(String key, String? value);
  Future<void> setBool(String key, bool value);
}

/// The app's [SettingsStore]. `main()` overrides it with saved settings;
/// otherwise (tests, or if loading failed) settings live in memory.
final settingsStoreProvider = Provider<SettingsStore>((ref) => MemorySettingsStore());

/// A setting saved on the device: its value, plus [set] to change it.
///
///     final darkProvider = NotifierProvider<Setting<bool>, bool>(
///       () => Setting.boolean('dark', false),
///     );
class Setting<T> extends Notifier<T> {
  Setting(this._key, this._initial, {required this.read, required this.write});

  static Setting<bool> boolean(String key, bool initial) => Setting<bool>(
    key,
    initial,
    read: (store, key) => store.getBool(key),
    write: (store, key, value) => store.setBool(key, value),
  );

  /// An enum, saved by name (so reordering the enum is safe).
  static Setting<E> choice<E extends Enum>(String key, E initial, List<E> values) => Setting<E>(
    key,
    initial,
    read: (store, key) => values.asNameMap()[store.getString(key)],
    write: (store, key, value) => store.setString(key, value.name),
  );

  final String _key;
  final T _initial;
  final T? Function(SettingsStore store, String key) read;
  final Future<void> Function(SettingsStore store, String key, T value) write;

  @override
  T build() => read(ref.watch(settingsStoreProvider), _key) ?? _initial;

  void set(T value) {
    state = value;
    // Saving can't meaningfully fail; the value is in memory either way.
    write(ref.read(settingsStoreProvider), _key, value).ignore();
  }
}

/// Settings saved on the device: NSUserDefaults on iOS, SharedPreferences
/// on Android, localStorage on the web.
class SharedPreferencesStore implements SettingsStore {
  SharedPreferencesStore._(this._prefs);

  final SharedPreferencesWithCache _prefs;

  static Future<SharedPreferencesStore> load() async => SharedPreferencesStore._(
    await SharedPreferencesWithCache.create(
      cacheOptions: const SharedPreferencesWithCacheOptions(),
    ),
  );

  @override
  String? getString(String key) => _prefs.getString(key);

  @override
  bool? getBool(String key) => _prefs.getBool(key);

  @override
  Future<void> setString(String key, String? value) =>
      value == null ? _prefs.remove(key) : _prefs.setString(key, value);

  @override
  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);
}

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([Map<String, Object>? values]) : _values = {...?values};

  final Map<String, Object> _values;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  Future<void> setString(String key, String? value) async =>
      value == null ? _values.remove(key) : _values[key] = value;

  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;
}
