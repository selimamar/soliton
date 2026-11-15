# Soliton

**[Getting started](docs/getting-started.md)** ·
[On Sherlock](docs/sherlock.md) ·
[For coding agents](docs/for-agents.md) ·
[Logger](logger/README.md) ·
[Server](server/README.md) ·
[Agent skills](skills/README.md)

Watch your deep learning training runs from your phone: loss curves,
hyperparameters, architecture, gradient norms and per-layer activation
statistics, updating live, with an alert when a run finishes, crashes or
starts to go wrong.

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

New here: [docs/getting-started.md](docs/getting-started.md), the app and
how to use it in a few minutes. Training on Stanford's Sherlock cluster:
[docs/sherlock.md](docs/sherlock.md). Coding agents: [docs/for-agents.md](docs/for-agents.md)
explains how Soliton works and how to add monitoring to any computation;
the `soliton` skills for Claude Code and Codex in [skills/](skills/README.md)
make agents do it by themselves (install instructions there). Programs that
aren't Python (compiled solvers, MPI jobs) report through the skills'
`scripts/monitor_solver.py` without being changed.

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

In the app: **Settings → Server** (or **Connect server** on the runs list), enter
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
- **Reproduce** (on the System tab): the git commit the run used (and which
  files had uncommitted changes), its command line and directory, the Slurm
  job script and the Python packages, with "Copy command to rerun". Compare
  shows the code version among the settings that differ.
- **Continued runs**: a run continued over several jobs from checkpoints
  shows each job (Slurm id, queue wait, run time, steps, how it ended) on its
  Overview, and its charts mark where each later job took over.
- **System**: each run's machine (GPUs, CPU, memory, software, Slurm job) and
  how busy it kept them: GPU use and memory per GPU, CPU, memory, GPU
  temperature and power, sampled by the logger every 15 seconds.
- **Job times** on a run's or simulation's Overview: how long its Slurm job
  waited in the queue, when it should finish at its current pace, and its
  time limit, with a warning when the limit comes first (and an alert, see
  Alerts).
- **Queued jobs**: submit with `soliton sbatch ...` (sbatch's own options)
  and the job shows as Queued while it waits: for how long, why (e.g.
  Priority, Resources, in plain words), when Slurm expects to start it, and
  what it asked for. When its script calls `soliton.init()`, the run takes
  its place. `soliton queue` updates what Slurm says of queued jobs, and ends
  those that left without starting (cancelled, failed); each starting
  Soliton job also refreshes them once.
- **Stop** on a live run's page: its script stops at its next
  `run.should_stop()` check, after saving a checkpoint, and the run ends
  "Stopped from the app" (a script that doesn't check is stopped as by
  scancel). No SSH or `scancel` needed.
- **Resources** on an ended Slurm job's Overview: memory, CPUs, GPUs, GPU
  memory and time it used against what it asked for, with the sbatch options
  to ask for next time (e.g. `--mem=16G -c 4 --time=03:00:00`, to copy) when
  it asked for far more than it needed, or a warning when it came close to a
  limit. Smaller requests usually start sooner.
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
  see only the settings that differ between them (the rest fold away), and
  see the fields they share side by side on one colour scale.

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
- **Several servers**: Settings → Server keeps a list (a lab server, the
  Sherlock test server, a local one), each with its own token; tap one to
  show its runs, or **All servers** to see every server's runs together,
  live, each marked with its server's name.
- **`soliton setup`**: once per machine or cluster, saves the server's address
  and a token where jobs read them (`~/.soliton_env`), asking for the token
  without showing it and checking it with the server first. Agents run it
  for you and ask you to paste the token from the app.
- **Advanced security** (Settings, optional): a separate token for jobs on
  clusters that can only add runs and update its own (each run has a key
  only its jobs hold), so a leaked job script or env file can't read your
  runs, touch the ones it didn't start, or delete anything; the main token
  stays on your devices. And **New main token**, if
  the main token may have leaked: the old one stops working everywhere. See
  the server README.
- **Chart options**: log scale (loss, learning rate, gradient norm), and
  steps or epochs on the x-axis. Saved, like all settings.
- **Training health**: the logger watches what a run logs and says when
  training goes wrong: a loss turns NaN or infinite, a training loss climbs
  back up (diverges), or the gradient norm blows up. Each shows at the top of
  the run's Overview, with what usually helps, and sends an alert, once per
  job. `init(stop_on_divergence=True)` also ends a run whose loss turned NaN.
- **Alerts** while the app is open when a run finishes or crashes, when a
  live run, at its pace, won't finish before its Slurm time limit (once per
  job, while there's still time to save a checkpoint), when training goes
  wrong (above), and when a queued Slurm job starts (one queued with
  `soliton sbatch`, or any that waited 10 minutes or more), so you can check
  its first minutes. Each can be turned off in Settings. For notifications
  when the app is closed, set up ntfy on the server: it sends all five.

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
      token_store.dart          the server token, in secure storage
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
docs/README.md                  index of the guides below
docs/getting-started.md         the app and how to use it, for people
docs/sherlock.md                using the logger on Sherlock
docs/for-agents.md              how Soliton works, for coding agents
skills/                         skills that make coding agents add monitoring
  claude-code/soliton/          for Claude Code
  codex/soliton/                for OpenAI Codex
  */scripts/monitor_solver.py   reports any program (a compiled solver) unchanged
tool/sherlock_check/            small Sherlock jobs that check the app's numbers
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
| `shared_preferences` | Saved settings and the server address |
| `flutter_secure_storage` | The server token, in the Keychain or Keystore |

Small visuals (sparklines, histograms) use plain `CustomPainter`s instead of a
chart library, which keeps lists fast.

The run detail tabs switch by tapping the tab bar, not by swiping: a swipe
would otherwise win over dragging a chart to read its values.

The server token is kept apart from the other settings, in the platform's
secure storage (`lib/data/services/token_store.dart`):

- **iOS:** the Keychain, readable after the first unlock and on this device
  only: not synced to iCloud, not restored to another device.
- **Android:** encrypted with a key in the Android Keystore. Auto Backup
  leaves the encrypted file out (`android/app/src/main/res/xml/`).
- **macOS:** the login keychain. The app is ad-hoc signed without a team,
  so it can't use the newer data-protection keychain. After a rebuild the app
  has a new signature, and macOS may ask again to allow keychain access.
- **Web: not secure.** Browsers have no secure store: the token is encrypted
  with a key kept beside it in localStorage, so anything that can run script
  on the page, or read the browser profile, can read it. It also only works
  over HTTPS or on localhost; elsewhere the token isn't saved, and the app
  asks for it again after a reload.

Older versions kept the token in the plain settings; the app moves it on the
first start and deletes the old copy. Disconnecting deletes it everywhere.

## Roadmap

1. ~~UI skeleton on demo data~~
2. ~~Python logger: PyTorch hooks for activations and gradients, batched uploads~~
3. ~~Server: FastAPI + Postgres, WebSocket for live updates~~
4. ~~`ApiRunRepository` in the app, live charts, login (server address + token)~~
5. ~~Notifications: in-app alerts, and push through ntfy~~
6. ~~Saved settings, log scale, step/epoch x-axis, compare runs~~
7. ~~The server token in the Keychain/Keystore~~
8. ~~Slurm: job times, queued jobs (`soliton sbatch`, `soliton queue`), the
   time-limit alert, Resources (right-sizing), continued runs over several jobs~~
9. ~~Control and safety: Stop from the app, a separate job token, rotating the
   main token, database migrations, deleting runs~~
10. ~~Several servers, and all of them in one list; the settings that differ
    in Compare; Reproduce (code version, command, job script)~~
11. ~~Training-health alerts (NaN or diverging loss, exploding gradients) and
    an alert when a queued job starts~~
12. Next ideas: reading runs back into Python for paper figures
    (`soliton.runs(project=...)` → metrics, settings, summaries), accounts for
    several people, native push (APNs/FCM), signing the Apple apps with a
    developer team
