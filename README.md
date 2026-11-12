# ModelsApp

A Flutter app (iOS and Android) for watching your deep learning training runs:
loss curves, hyperparameters, architecture, gradient norms and per-layer
activation statistics.

**Status: first draft.** The app runs on generated demo data. The Python
logger and the backend server come next (see the roadmap below).

## Running it

Requires Flutter 3.47 or newer (Dart 3.13), the first version `material_ui`
supports (`flutter --version`).

The iOS, Android and web folders were generated with the command below.
Run it again to add a platform: `flutter create` only adds missing files, so
it won't touch the code here.

```bash
flutter create --project-name models_app --org io.github.selimamar --platforms ios,android,web .
flutter pub get
```

Then run:

```bash
flutter run -d chrome     # quickest way to look at the UI (URLs like /runs/gpt-tiny)
flutter run               # on a connected phone or an open simulator
flutter test              # unit and widget tests
flutter analyze           # lints
```

## Code layout

```
lib/
  main.dart                     entry point
  app/
    app.dart                    MaterialApp, theme mode, router
    constants.dart              app name and version
    routes.dart                 AppRoutes: paths to navigate to
    router.dart                 the route tree (/, /runs/:runId, /settings, not found)
    theme.dart                  Material 3 theme, chart colours, status colours
  models/                       immutable data classes with ==, fromJson, toJson
    run.dart                    a training run (status, progress, hyperparameters)
    layer_info.dart             architecture tree node
    metric_series.dart          time series + well-known metric names
    layer_stats.dart            per-layer stats + histogram
    model_helpers.dart          equality helpers, NaN-safe JSON numbers
  data/
    run_repository.dart         interface the UI reads data through
    providers.dart              Riverpod providers (the UI's entry point to data)
    mock/                       demo data: generated curves and architectures
  features/                     one folder per screen
    not_found/                  shown for unknown URLs
    runs_list/                  home screen + run card
    run_detail/                 Overview, Metrics and Layers tabs + their widgets
    settings/                   settings screen + settings state
  shared/
    formatters.dart             23.5M, 3h 12m, 0.412, axis tick labels, ...
    axis_scale.dart             round chart axis bounds and tick spacing
    clock.dart                  clockProvider: keeps elapsed times moving
    widgets/                    reusable UI: cards, charts, sparkline, histogram
test/                           formatter unit tests + widget smoke tests
```

### How data flows

```
Screen  --watch-->  Riverpod provider  --calls-->  RunRepository  -->  MockRunRepository (today)
                                                                 -->  ApiRunRepository  (later)
```

Screens never create data themselves. To connect a real server, write a new
`RunRepository` implementation and change the one line in
`lib/data/providers.dart`. Keep the HTTP/WebSocket code in a service class
under `data/services/` and have the repository map responses with the models'
`fromJson` constructors. NaN and infinity travel as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`, since JSON has no such numbers.

Data providers retry a failed request 3 times, then show an error with a
Retry button. An unknown run id is never retried (`RunNotFoundException`).

### Common changes

- **Add a chart for a new metric:** add its name to `MetricKeys` in
  `models/metric_series.dart`, then add a `LineChartCard` in
  `features/run_detail/tabs/metrics_tab.dart`. Metrics without a dedicated
  chart already show up under "Other metrics".
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

Small visuals (sparklines, histograms) use plain `CustomPainter`s instead of a
chart library, which keeps lists fast.

The run detail tabs switch by tapping the tab bar, not by swiping: a swipe
would otherwise win over dragging a chart to read its values.

## Roadmap

1. ~~UI skeleton on demo data~~ (this draft)
2. Python logger (`pip install`): PyTorch hooks for activations and gradients,
   sending metrics in batches
3. Backend: FastAPI + Postgres, WebSocket for live updates
4. `ApiRunRepository` in the app, live charts, login
5. Push notifications (run finished or crashed)
6. Persist settings, log-scale toggle, step/epoch x-axis, compare runs
