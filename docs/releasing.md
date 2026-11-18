# Releasing Soliton

How Soliton gets from this repository to people's computers and phones: a
checklist for the first public release on the Mac and Android, what each
later release takes, and what Windows and Linux would need.

The plan in short:

- **License:** MIT.
- **Mac:** an unsigned app, installed and updated with Homebrew from our own
  tap. There is no Apple Developer account, so the app isn't notarised.
- **Android:** an APK attached to each GitHub Release (not Google Play, for
  now).
- **iPhone and iPad:** later. Handing the app out smoothly needs the Apple
  Developer Program ($99/yr: TestFlight and the App Store). The free routes
  are the web version added to the Home Screen, or sideloading with
  SideStore or AltStore, which stops the app opening after 7 days unless it
  is refreshed.

## 1. Before going public

- [x] Add an MIT `LICENSE` file (copied into `logger/` and `server/` for
      their packages). The bundled fonts keep their own licences
      (`assets/fonts/OFL-*.txt`).
- [x] Check the whole history once more for anything personal or secret:
      paths on this computer, emails, tokens, keys.
- [x] [Getting started](getting-started.md) installs the app from a release
      (Homebrew, or the APK) first, and from this repository otherwise.
- [ ] Publish the logger and the server to PyPI (section 5), so that
      `pip install soliton` and `pip install soliton-server` work.
- [x] Make the repository public: Settings → General → Danger Zone →
      Change visibility.

## 2. Android: an APK on GitHub Releases

- [ ] Create a release signing key, once, and **back it up**. Android only
      installs an update signed with the same key as the version already on
      the phone, so losing the key means people have to uninstall and lose
      their settings to get updates:

      ```bash
      keytool -genkey -v -keystore ~/soliton-release.jks -keyalg RSA -keysize 4096 -validity 10000 -alias soliton
      ```

- [x] The release build uses that key when it can find it
      (`android/app/build.gradle.kts`), and Flutter's debug key otherwise.
      On your computer, put its location and passwords in
      `android/key.properties` (git ignores it, and any `.jks`):

      ```properties
      storeFile=/Users/you/soliton-release.jks
      storePassword=…
      keyAlias=soliton
      keyPassword=…
      ```

      `cd android && ./gradlew :app:signingReport` shows which key the
      `release` variant uses.
- [ ] Build `Soliton-x.y.z.apk` and attach it to the release: either by
      hand (`flutter build apk --release`, then
      `build/app/outputs/flutter-apk/app-release.apk`), or by the release
      workflow, once the key and its passwords are repository secrets
      (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
      `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`; see
      `.github/workflows/release.yml`).

People install it by downloading the APK on their phone and allowing
"install unknown apps" for their browser or file manager once. A newer APK
installs over the old one and keeps their settings.

## 3. Mac: Homebrew, from our own tap

- [x] The release workflow (`.github/workflows/release.yml`): pushing a tag
      such as `v0.3.0` builds `Soliton.app` on GitHub's Macs, zips it and
      attaches `Soliton-0.3.0.zip` to a GitHub Release (with the APK, when
      the Android key is set up). It runs for the first time on the first
      tag, so check its log then (the repository's Actions tab).
- [x] Create the tap: an empty repository named `selimamar/homebrew-tap`.
- [x] Copy [packaging/homebrew/soliton.rb](../packaging/homebrew/soliton.rb)
      into it as `Casks/soliton.rb`, with the first release's version and
      checksum (`shasum -a 256 Soliton-0.3.0.zip`), then check it with
      `brew audit --cask selimamar/tap/soliton`.
- [ ] So that the release workflow updates the cask's `version` and
      `sha256` itself, store a `TAP_TOKEN` secret in this repository: a
      fine-grained token with Contents: Read and write on
      `selimamar/homebrew-tap` only. Without it, the workflow prints the new
      checksum for you to paste in.
- [ ] Optional: a `soliton-server` formula in the same tap, so that a Mac can
      run the server with `brew install selimamar/tap/soliton-server` and
      keep it running with `brew services start soliton-server`. Easiest
      once the server is on PyPI.

The release build is ad-hoc signed, sandboxed, and only asks for what it
uses (network connections out, and the Downloads folder for backups), and it
runs on Apple silicon and Intel Macs with macOS 12 or later. Two things
people will see, because it isn't signed by an Apple developer:

- **The first launch is blocked** until they choose Open Anyway (the cask
  says how).
- **Each update asks once for the keychain.** The server token is in the
  login keychain, and macOS ties keychain access to the app's signature,
  which changes with every build: after an update macOS asks whether
  Soliton may read it, and Always Allow settles it until the next update.
  Signing every release with the same certificate would remove this; a
  free self-signed certificate is enough for the keychain, though not for
  Gatekeeper.

People install and update it with:

```bash
brew trust --cask selimamar/tap/soliton    # once: Homebrew asks you to trust it
brew install --cask selimamar/tap/soliton
brew upgrade
```

Homebrew's main cask collection, where `brew install --cask soliton` would
work without the tap, doesn't take apps that fail macOS's Gatekeeper check:
since 1 September 2026 such casks are disabled. It also asks for a notable
project (at least 75 stars, 30 forks and 30 watchers on GitHub). Both need
the Apple Developer Program first. See
[Acceptable Casks](https://docs.brew.sh/Acceptable-Casks).

## 4. Every release after the first

1. Raise `version` in `pubspec.yaml` (`0.3.0+3` now: the part after `+` is
   the build number, which must go up for Android to accept the update),
   and `appVersion` in `lib/app/constants.dart` to match (the version
   Settings shows; `test/app_version_test.dart` fails until they agree).
2. Commit, then tag and push, e.g. `git tag v0.3.1 && git push origin main v0.3.1`.
3. The workflow builds the Mac zip, publishes the release and updates the
   cask. Attach the APK, unless the workflow builds it too.

## 5. The Python packages on PyPI

Both packages build and install cleanly (`uv build --package soliton`,
`uv build --package soliton-server`), with the license, links and
descriptions PyPI shows. To publish:

1. Make an account on [pypi.org](https://pypi.org), with two-factor
   authentication (PyPI requires it).
2. Check that `soliton` and `soliton-server` are still free.
3. Build both into `dist/` and upload them with `uv publish` (it asks for a
   PyPI API token), or set up trusted publishing from a GitHub workflow,
   which needs no token.

Raise `version` in `logger/pyproject.toml` or `server/pyproject.toml` before
each upload: PyPI never accepts the same version twice.

## 6. Windows and Linux

The app itself is close to ready: every plugin it uses supports both, and
the code already handles them (backups go to the Downloads folder, and are
made readable by you only on Linux as on the Mac). What's missing is setup
and packaging:

| | Windows | Linux |
|---|---|---|
| Add the platform | `flutter create --platforms=windows .` | `flutter create --platforms=linux .` |
| Built on | Windows only: GitHub's free Windows machines, so no PC is needed | Linux only: GitHub's free Ubuntu machines |
| Build tools | Visual Studio with C++ (already on GitHub's machines) | GTK 3, CMake, Ninja, and `libsecret` for the server token |
| The server token | Windows Credential Manager | The desktop's keyring (GNOME Keyring or KWallet); very minimal setups may lack one |
| Simplest download | A `.zip` on the release | A `.tar.gz` on the release |
| Nicer install | An installer (Inno Setup, free) or MSIX | AppImage (one file that runs anywhere), or a `.deb` |
| Package managers | Scoop (our own "bucket", like the tap) or winget (Microsoft's catalogue): both free | Flathub (reviewed, builds from source): free |
| Unsigned | SmartScreen warns once ("More info → Run anyway"); a code-signing certificate removes it (Azure Trusted Signing, about $10/month) | No warning: Linux doesn't require signing |

Both should be tried once on a real machine before the first release.
Homebrew casks are Mac-only, but Homebrew on Linux can install the
`soliton-server` formula.
