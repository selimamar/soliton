# ModelsApp

Watch your deep learning training runs from your phone: loss curves,
hyperparameters, architecture, gradient norms and per-layer activation
statistics, updating live, with an alert when a run finishes or crashes.

It has three parts:

```
your training script                 your server                    your phone
  + modelsapp logger   --HTTPS-->   modelsapp-server   <--HTTPS--   ModelsApp (Flutter)
  (logger/, Python)                 (server/, FastAPI)   WebSocket  (lib/, iOS/Android/web)
```

- **Logger** (`logger/`): `pip install`-able, standard library only. Hooks into
  PyTorch for per-layer statistics, saves everything locally first and uploads
  in the background, so a network outage (or a cluster without internet)
  loses nothing. See [logger/README.md](logger/README.md).
- **Server** (`server/`): FastAPI with SQLite (local) or PostgreSQL. Stores
  runs, pushes changes over a WebSocket, marks silent runs as crashed and can
  send phone notifications through ntfy. See [server/README.md](server/README.md).
- **App** (`lib/`): shows demo data until you connect it to your server.

Training on Stanford's Sherlock cluster: see [docs/sherlock.md](docs/sherlock.md).
If a coding agent writes your training code, give it the instructions in
[docs/for-agents.md](docs/for-agents.md).

## Setting up (everything stays in this folder)

The project keeps its own Python, packages and caches inside this folder;
nothing is installed system-wide. You need [uv](https://docs.astral.sh/uv/)
and the Flutter SDK (3.47 or newer).

```bash
source env.sh                 # in every new terminal
uv sync --all-packages        # Python 3.12 + logger + server + test tools, into .venv
flutter pub get               # Dart packages, into .cache/pub
```

`env.sh` points uv, pip, pub and temporary files at `.cache/` and puts `.venv`
and Flutter on the `PATH`. If your Flutter SDK isn't at
`~/Development/flutter`, set `MODELSAPP_FLUTTER` first. To remove everything,
delete `.venv`, `.cache` and `.data`.

## Trying it all on one computer

Three terminals, each after `source env.sh`:

```bash
modelsapp-server                          # 1. the server, at http://127.0.0.1:8000
```

```bash
export MODELSAPP_SERVER=http://127.0.0.1:8000
export MODELSAPP_TOKEN=$(modelsapp-server --show-token)
modelsapp demo                            # 2. a small real training run (PyTorch)
```

```bash
tool/run_web.sh                           # 3. the app, at http://localhost:8787
```

In the app: **Settings → Data source** (or **Connect** on the demo banner), enter
`http://127.0.0.1:8000` and the token. The demo run appears and updates live.
`modelsapp demo --crash-at 500` shows what a crash looks like.

## The app

```bash
tool/run_web.sh           # in a browser (no Chrome needed; URLs like /runs/gpt-tiny)
flutter run               # on a connected phone or an open simulator
flutter test              # unit and widget tests
flutter analyze           # lints
```

What it does:

- **Runs list** with status filters, live progress and a loss sparkline per run.
- **Organizing**: group the list by project, model, dataset, tag or host
  (folding groups away), tag runs (e.g. `baseline`, `best`) and leave a
  note on each. Tags and notes are saved on the server, so every device
  sees them; the logger can set the first ones.
- **Run detail**: Overview (progress; tags and notes; hyperparameters, led by the number of
  training and validation samples and the loss; a network diagram and the
  module tree), Metrics
  (loss, accuracy, learning rate, gradient norms, any other metric) and
  Layers (activation histograms, dead units, gradient norms per layer).
- **Live updates**: charts and the list refresh as the server receives data.
- **Compare**: pick up to six runs on the runs list to overlay their curves.
- **Chart options**: log scale (loss, learning rate, gradient norm), and
  steps or epochs on the x-axis. Saved, like all settings.
- **Alerts** while the app is open when a run finishes or crashes. For
  notifications when it is closed, set up ntfy on the server.

Phones need `https://` for a server on the internet. Plain `http://` works for
a server on your own network (debug builds on Android, any build on iOS).

### Code layout

```
lib/
  main.dart                     entry point; loads saved settings first
  app/
    app.dart                    MaterialApp, theme mode, router
    constants.dart              app name and version
    routes.dart                 AppRoutes: paths to navigate to
    router.dart                 the route tree (/, /runs/:id, /compare, /settings, ...)
    run_alert_listener.dart     in-app alerts; keeps live updates connected
    theme.dart                  Material 3 theme, chart colours, status colours
  models/                       immutable data classes with ==, fromJson, toJson
  data/
    run_repository.dart         interface the UI reads data through
    api_run_repository.dart     ... implemented with the server's API
    mock/                       ... implemented with generated demo data
    providers.dart              Riverpod providers: the server login, which
                                repository to use, and the data itself
    services/
      api_client.dart           HTTP to the server, with typed errors
      server_connection.dart    server address + token
      live_updates.dart         WebSocket: refreshes what changed, raises alerts
      settings_store.dart       saved settings (SharedPreferences) + Setting<T>
  features/                     one folder per screen
    runs_list/                  home screen, run card, picking runs to compare
    run_detail/                 Overview, Metrics and Layers tabs + their widgets
    compare/                    runs side by side
    settings/                   settings screen, server login screen
    not_found/                  shown for unknown URLs
  shared/
    formatters.dart             23.5M, 3h 12m, 0.412, axis tick labels, ...
    axis_scale.dart             round axis ticks, linear and logarithmic
    chart_settings.dart         log scale, steps/epochs
    clock.dart                  clockProvider: keeps elapsed times moving
    widgets/                    cards, charts, chart options, sparkline, histogram
test/                           unit, widget, accessibility and server tests
logger/                         the Python logger (package `modelsapp`)
server/                         the server (package `modelsapp-server`)
docs/sherlock.md                using the logger on Sherlock
docs/for-agents.md              instructions to give a coding agent
env.sh, pyproject.toml, uv.lock the project environment
```

### How data flows

```
Screen --watch--> Riverpod provider --calls--> RunRepository --> ApiRunRepository --> server
                        ^                                    \-> MockRunRepository (not connected)
                        |
          live_updates.dart invalidates what the server says changed
```

Screens never create data themselves. `runRepositoryProvider` picks the
server when you're connected and demo data otherwise; everything refetches
when that changes. NaN and infinity travel as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`, since JSON has no such numbers.

Data providers retry a failed request 3 times, then show an error with a
Retry button. An unknown run or a rejected token is never retried.

`test/server_contract_test.dart` checks the app against a real server:

```bash
MODELSAPP_TEST_SERVER=http://127.0.0.1:8000 \
MODELSAPP_TEST_TOKEN=$(modelsapp-server --show-token) \
flutter test test/server_contract_test.dart
```

### Common changes

- **Add a chart for a new metric:** add its name to `MetricKeys` in
  `models/metric_series.dart`, then add a `LineChartCard` in
  `features/run_detail/tabs/metrics_tab.dart`. Metrics without a dedicated
  chart already show up under "Other metrics".
- **Add a setting:** a `NotifierProvider` with `Setting.boolean(...)` or
  `Setting.choice(...)` (see `features/settings/settings_providers.dart`);
  it is saved automatically.
- **Change colours:** `app/theme.dart` (seed colour and `ChartColors`).
- **Add a screen:** create a folder under `features/`, register its route in
  `app/router.dart` and add its path to `app/routes.dart`.
- **Bump the version:** change `version:` in `pubspec.yaml` and `appVersion`
  in `app/constants.dart` (a test checks they match).

## Packages

| Package | Used for |
|---|---|
| `material_ui` | Material widgets (replaces the deprecated `package:flutter/material.dart`) |
| `fl_chart` | Line and bar charts with touch tooltips |
| `flutter_riverpod` | State management and data providers |
| `go_router` | Navigation |
| `http` | Requests to the server |
| `web_socket_channel` | Live updates |
| `shared_preferences` | Saved settings and the server login |

Small visuals (sparklines, histograms) use plain `CustomPainter`s instead of a
chart library, which keeps lists fast.

The run detail tabs switch by tapping the tab bar, not by swiping: a swipe
would otherwise win over dragging a chart to read its values.

The server token is saved in the app's normal storage (not the iOS Keychain or
Android Keystore). Anyone with access to the unlocked phone's app data could
read it.

## Roadmap

1. ~~UI skeleton on demo data~~
2. ~~Python logger: PyTorch hooks for activations and gradients, batched uploads~~
3. ~~Server: FastAPI + Postgres, WebSocket for live updates~~
4. ~~`ApiRunRepository` in the app, live charts, login (server address + token)~~
5. ~~Notifications: in-app alerts, and push through ntfy~~
6. ~~Saved settings, log scale, step/epoch x-axis, compare runs~~
7. Next ideas: the token in the Keychain/Keystore, native push (APNs/FCM),
   accounts for several people, database migrations, deleting runs from the app
