# Soliton

Watch your deep learning training runs from your phone: loss curves,
hyperparameters, architecture, gradient norms and per-layer activation
statistics, updating live, with an alert when a run finishes or crashes.

It has three parts:

```
your training script                 your server                    your phone
  + soliton logger   --HTTPS-->   soliton-server   <--HTTPS--   Soliton (Flutter)
  (logger/, Python)                 (server/, FastAPI)   WebSocket  (lib/, iOS/Android/web)
```

- **Logger** (`logger/`): `pip install`-able, standard library only. Hooks into
  PyTorch for per-layer statistics, saves everything locally first and uploads
  in the background, so a network outage (or a cluster without internet)
  loses nothing. See [logger/README.md](logger/README.md).
- **Server** (`server/`): FastAPI with SQLite (local) or PostgreSQL. Stores
  runs, pushes changes over a WebSocket, marks silent runs as crashed and can
  send phone notifications through ntfy. See [server/README.md](server/README.md).
- **App** (`lib/`): shows your server's runs once you connect it. Made-up demo
  runs are off by default (**Settings → Demo data** turns them on while no
  server is connected).

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
`~/Development/flutter`, set `SOLITON_FLUTTER` first. To remove everything,
delete `.venv`, `.cache` and `.data`.

## Trying it all on one computer

Three terminals, each after `source env.sh`:

```bash
soliton-server                          # 1. the server, at http://127.0.0.1:8000
```

```bash
export SOLITON_SERVER=http://127.0.0.1:8000
export SOLITON_TOKEN=$(soliton-server --show-token)
soliton demo                            # 2. a small real training run (PyTorch)
```

```bash
tool/run_web.sh                           # 3. the app, at http://localhost:8787
```

In the app: **Settings → Data source** (or **Connect server** on the runs list), enter
`http://127.0.0.1:8000` and the token. The demo run appears and updates live.
`soliton demo --crash-at 500` shows what a crash looks like.

## The app

```bash
tool/run_web.sh           # in a browser (no Chrome needed; URLs like /runs/gpt-tiny)
flutter run               # on a connected phone or an open simulator
flutter run -d macos      # as a Mac app
flutter test              # unit and widget tests
flutter analyze           # lints
```

It runs on Android phones and tablets, iPhone and iPad (one iOS app for
both, in every orientation and in iPad Split View), macOS and the web.
Building for iOS, iPadOS and macOS needs Xcode only: plugins come in through
Swift Package Manager (set in `pubspec.yaml`), so CocoaPods isn't used and
`flutter doctor`'s note that it's missing can be ignored. For Android: Android
Studio (or the Android SDK and a JDK). `flutter doctor` says what's missing.

What it does:

- **Runs list** with status filters, live progress and a loss sparkline per run.
- **Organizing**: group the list by project, model, dataset, tag or host
  (folding groups away), tag runs (e.g. `baseline`, `best`) and leave a
  note on each. Tags and notes are saved on the server, so every device
  sees them; the logger can set the first ones.
- **System**: each run's machine (GPUs, CPU, memory, software, Slurm job) and
  how busy it kept them: GPU use and memory per GPU, CPU, memory, GPU
  temperature and power, sampled by the logger every 15 seconds.
- **Job times** on a run's or simulation's Overview: how long its Slurm job
  waited in the queue, when it should finish at its current pace, and its
  time limit, with a warning when the limit comes first.
- **Compute**: simulations (a PDE solve, or any computation stepping
  through time), monitored like runs from `soliton.simulate()`, in their
  own section (the bar at the bottom, or the side on a wide screen):
  progress in simulated time and the time left, an alert and a marked
  chart when one diverges (NaN or infinity), every logged value against
  simulated time (conservation drift, residuals on a log scale, the CFL
  number with its limit, the time step), results against a parameter
  (`sim.log_curve`), the same field views as runs (2D, 3D, rollouts), the
  setup, the machine and its cost. Steady solves go by iteration instead
  of simulated time.
- **Data**: the datasets you have, registered with
  `soliton.register_dataset(path)` or `soliton data scan FOLDER`: size,
  samples and splits, where they're stored, the arrays in them with their
  ranges, a few sample previews, what made them (a simulation, on which
  machine) and which runs trained on them. Only the description reaches
  the server, never the data.
- **Cost**: roughly what a run has cost and, while it runs, will cost in
  all: run time × the machine's price per hour, rounded (e.g. "≈ $38").
  The price is the run's own (`price_per_hour=`) or a typical cloud price
  for its GPUs. On the Overview, in Compare, and as a Sweep axis.
- **Run detail**: Overview (progress; tags and notes; hyperparameters, led
  by the number of training and validation samples and the loss; a network
  diagram and the module tree), Metrics (loss, accuracy, learning rate,
  gradient norms, any other metric), Layers (activation histograms, dead
  units, gradient norms per layer), Fields and System (below).
- **Fields**, for neural operators and other models that predict a field:
  the prediction, the true field and their difference as heatmaps or lines
  at any logged step; rollouts played over time with their error frame by
  frame; 3D fields (and 3D rollouts) in a 3D view you can turn, as a volume,
  a maximum projection or isosurfaces, or in slices; and the field through
  each layer of the model (in 3D too, for a 3D model). Also: the energy
  spectrum, conservation checks along a rollout, the error over the whole
  validation set with its worst samples, error against resolution or a PDE
  parameter, and the learned Fourier weights. Maps show the run's domain
  coordinates; charts and maps export as PNG images.
- **Sweep**: a project's runs as a grid over two hyperparameters (e.g.
  Fourier modes × width) or a scatter of two metrics (error against cost).
- **Live updates**: charts and the list refresh as the server receives data.
- **Compare**: pick up to six runs on the runs list to overlay their curves,
  and see the fields they share side by side on one colour scale.
- **Output**: the end of what a run's script printed, on its Overview; for
  a crashed run, first thing, with the traceback, folded away until the
  arrow on the card shows it (for every crashed run, until hidden again).
  Open it to read or copy
  all of it (the server keeps the last 1,000 lines). Off with
  `SOLITON_CAPTURE_OUTPUT=0`.
- **Search** at the top of Runs, Compute and Data: every word typed must
  appear somewhere in the name, project, host, tags, notes, model, dataset
  or PDE (for datasets: name, source, host, format, path, description).
  The status counts and Data's totals follow the search.
- **Delete** what clutters a section: from a run's, simulation's or
  dataset's page, or several at once by picking them in the list (a long
  press, or the pick button). The app asks first. Deleting a run removes
  everything it logged from the server; a run that is still running comes
  back with what it logs next. Deleting a dataset only forgets its
  description: the files aren't touched.
- **Chart options**: log scale (loss, learning rate, gradient norm), and
  steps or epochs on the x-axis. Saved, like all settings.
- **Alerts** while the app is open when a run finishes or crashes. For
  notifications when it is closed, set up ntfy on the server.

Phones need `https://` for a server on the internet. Plain `http://` works for
a server on your own network (debug builds on Android, any build on iOS,
iPadOS and macOS). iOS, iPadOS and macOS ask once for permission to use the
local network.

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
    empty_run_repository.dart   ... with nothing (not connected, demo data off)
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
    compute/                    simulations: list, Overview, Diagnostics
    data/                       datasets: list and a dataset's page
    settings/                   settings screen, server login screen
    not_found/                  shown for unknown URLs
  shared/
    formatters.dart             23.5M, 3h 12m, 0.412, axis tick labels, ...
    axis_scale.dart             round axis ticks, linear and logarithmic
    chart_settings.dart         log scale, steps/epochs
    clock.dart                  clockProvider: keeps elapsed times moving
    widgets/                    cards, charts, chart options, sparkline, histogram
test/                           unit, widget, accessibility and server tests
logger/                         the Python logger (package `soliton`)
server/                         the server (package `soliton-server`)
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
server when you're connected, otherwise demo data (or nothing, with the
**Demo data** setting off, the default); everything refetches
when that changes. NaN and infinity travel as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`, since JSON has no such numbers.

Data providers retry a failed request 3 times, then show an error with a
Retry button. An unknown run or a rejected token is never retried.

`test/server_contract_test.dart` checks the app against a real server:

```bash
SOLITON_TEST_SERVER=http://127.0.0.1:8000 \
SOLITON_TEST_TOKEN=$(soliton-server --show-token) \
flutter test test/server_contract_test.dart
```

### Common changes

- **Add a chart for a new metric:** add its name to `MetricKeys` in
  `models/metric_series.dart`, then add a `LineChartCard` in
  `features/run_detail/tabs/metrics_tab.dart`. Metrics without a dedicated
  chart already show up under "Other metrics".
- **Add a setting:** a `NotifierProvider` with `Setting.boolean(...)` or
  `Setting.choice(...)` (see `features/settings/settings_providers.dart`);
  it is saved automatically. Settings that choose where data comes from
  (the server login, demo data) live in `data/providers.dart` instead.
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
