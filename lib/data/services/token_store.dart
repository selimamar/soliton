import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'settings_store.dart';

/// Where the server token is kept, apart from the other settings.
abstract interface class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> delete();
}

/// The app's [TokenStore]. `main()` overrides it with [SecureTokenStore];
/// otherwise (tests) the token lives in memory.
final tokenStoreProvider = Provider<TokenStore>((ref) => MemoryTokenStore());

/// The token saved on the device, as [loadServerToken] read it at startup.
/// Read once, so `connectionProvider` can build synchronously; connecting
/// and disconnecting change that provider's state, not this.
final savedTokenProvider = Provider<String?>((ref) => null);

/// Where older versions kept the token: in plain settings.
const legacyTokenKey = 'serverToken';

/// Reads the saved token, first moving it out of [settings] if an older
/// version left it there. If secure storage fails, a token still in the
/// settings is used as it is, and moved on a later launch.
///
/// Gives up after [timeout] (the app then starts without a login), so a
/// keyring that never answers (a Linux desktop without a secret service)
/// can't keep the window blank; a keychain prompt can be answered well
/// within it.
Future<String?> loadServerToken(
  TokenStore tokens,
  SettingsStore settings, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final legacy = settings.getString(legacyTokenKey);
  try {
    if (legacy != null) {
      await tokens.write(legacy).timeout(timeout);
      await settings.setString(legacyTokenKey, null);
      return legacy;
    }
    return await tokens.read().timeout(timeout);
  } catch (error) {
    debugPrint('Could not read the saved server token ($error).');
    return legacy;
  }
}

/// The platform's secure storage:
///
/// * iOS: the Keychain, readable after the first unlock, on this device
///   only (not synced to iCloud, not restored from backups to another one).
/// * Android: encrypted with a key held in the Android Keystore. The
///   encrypted file is also kept out of Auto Backup (`backup_rules.xml`,
///   `data_extraction_rules.xml`), since the key can't be restored with it.
/// * macOS: the login keychain. The app is ad-hoc signed, without a team,
///   so it can't use the data-protection keychain (that needs a
///   `keychain-access-groups` entitlement, which needs a team). A rebuilt
///   app has a new signature, so macOS may ask again to allow keychain
///   access.
/// * Web: NOT secure. The browser has no secure store; the token is
///   encrypted with a key kept next to it in localStorage, so any script on
///   the page can read both.
class SecureTokenStore implements TokenStore {
  const SecureTokenStore();

  static const _key = 'serverToken';

  static const _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      accountName: 'Soliton',
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(accountName: 'Soliton', usesDataProtectionKeychain: false),
    aOptions: AndroidOptions(),
  );

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.token]);

  /// The stored token (null if none). Tests read it directly.
  String? token;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> write(String token) async => this.token = token;

  @override
  Future<void> delete() async => token = null;
}
