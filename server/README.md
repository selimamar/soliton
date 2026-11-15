# soliton-server

Stores the training runs that the `soliton` logger sends, and serves them
to the Soliton app, with live updates over a WebSocket.

FastAPI, SQLAlchemy, and SQLite or PostgreSQL. One process; no other services.

## Running it locally

From the project root (see the main README for `env.sh`):

```bash
source env.sh
soliton-server                  # http://127.0.0.1:8000, this computer only
soliton-server --show-token     # the token for the logger and the app
```

Without `SOLITON_TOKEN`, the server makes a random token on first start and
keeps it in `$SOLITON_DATA_DIR/token` (readable by you only). The database
is `$SOLITON_DATA_DIR/soliton.db` (SQLite). With `env.sh`, that folder is
`.data/` in the project.

To use the app on a phone on the same network, listen on all addresses and
use your computer's local IP in the app, e.g. `http://192.168.1.20:8000`:

```bash
soliton-server --host 0.0.0.0
```

## Settings

All from environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `SOLITON_TOKEN` | generated, in `token` | The API token (send as `Authorization: Bearer ...`) |
| `DATABASE_URL` or `SOLITON_DATABASE_URL` | SQLite in the data folder | e.g. `postgresql://user:pass@host/db` |
| `SOLITON_DATA_DIR` | `./soliton-data` | Where the SQLite database and token live |
| `SOLITON_LISTEN_HOST`, `PORT` | `127.0.0.1`, `8000` | Address and port (also `--host`, `--port`) |
| `SOLITON_STALE_MINUTES` | `10` | A live run silent this long is marked crashed ("lost contact"); one silent past its Slurm job's time limit is marked a minute after it ("Stopped by its Slurm time limit") |
| `SOLITON_CORS_ORIGINS` | `*` | Web origins allowed to call the API (comma-separated) |
| `SOLITON_NTFY_URL` | off | Push notifications, e.g. `https://ntfy.sh/<long-random-topic>` |
| `SOLITON_NTFY_TOKEN` | none | Access token for a protected ntfy topic |
| `SOLITON_NOTIFY_ON` | `finished,crashed,time-limit` | Which events send a push notification (`time-limit`: a live run that, at its pace, won't finish before its Slurm time limit; once per job) |

## Push notifications (ntfy)

[ntfy](https://ntfy.sh) delivers real push notifications to its free iOS and
Android apps, without an Apple or Google developer account:

1. Install the ntfy app on your phone and subscribe to a topic with a long,
   random name (anyone who knows a topic on the public server can read it).
2. Start the server with `SOLITON_NTFY_URL=https://ntfy.sh/<that-topic>`.

You get "resnet50 finished" or "resnet50 crashed: CUDA out of memory" with
the app closed. For privacy, run your own ntfy server and set
`SOLITON_NTFY_TOKEN`.

## Putting it on the internet

The logger on a cluster and the app on your phone both need to reach the
server, so it has to run somewhere public, with HTTPS. Two common ways:

- **A small cloud VM** (any provider): install uv, copy this repository,
  `uv sync --package soliton-server --extra postgres` (or keep SQLite), set
  `SOLITON_TOKEN` to a long random string, run
  `soliton-server --host 127.0.0.1`, and put [Caddy](https://caddyserver.com)
  in front for automatic HTTPS (`reverse_proxy 127.0.0.1:8000`; it forwards
  WebSockets as is).
- **A hosting platform** that runs Python apps: start command
  `soliton-server --host 0.0.0.0` (it reads `PORT`), and a managed
  PostgreSQL in `DATABASE_URL` (`postgres://` URLs are accepted). Set
  `SOLITON_TOKEN`; don't rely on the generated one, as the disk may not
  persist.

Run a single process: live updates are pushed from memory, so several
workers wouldn't see each other's changes. Tables are created on startup.
There are no migrations yet, so after an upgrade that changes an existing
table, start from a fresh database. (New tables, like `run_notes` for tags
and notes or `run_system` for what a run trains on, are added to an
existing database on startup.)

## A separate token for jobs (optional)

By default one token does everything, and it ends up in job scripts and env
files on clusters. Turn on **Settings → Advanced security → Separate token
for jobs** in the app and the server makes a second token, shown once in
the app, for jobs: it can create and update runs, send their events,
describe datasets and list queued jobs (`soliton queue`), and nothing else.
It can't read what was logged, change tags and notes, delete anything or
follow live updates. What it can do is what a logger does, so someone with a
leaked cluster file could still add runs, or overwrite a run's description
or mark it ended if they know its id (ids end in a random part), but not read
or delete your history. Put it in
place of `SOLITON_TOKEN` on your clusters and keep the main token on your
own devices. The server keeps only its SHA-256 hash (in the database, so
it survives restarts); "New job token" replaces it, and turning the setting
off makes jobs need the main token again.

## API

Every endpoint except `/api/health` needs `Authorization: Bearer <token>`:
the main token, or, where marked, the job token (refused with 403
elsewhere).
Field names and shapes are exactly what the app's models read (`fromJson` in
`lib/models/`). Non-finite numbers travel as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`.

| Method and path | What it does |
|---|---|
| `GET /api/health` | `{"status": "ok", "version": ...}`, public |
| `GET /api/session` | Checks the token; `jobToken`: whether a job token is set |
| `POST /api/job-token` | Makes a new job token (replacing any), `{"token": ...}`, shown this once |
| `DELETE /api/job-token` | Removes the job token |
| `GET /api/runs?status=` | All runs (or those with that status), newest first, each with a 60-point loss preview. Job token: `status=queued` only |
| `GET /api/runs/{id}` | One run (404 if unknown) |
| `PUT /api/runs/{id}` | Creates or updates a run's description (the logger does this). Job token too |
| `PATCH /api/runs/{id}` | Sets its `tags` and/or `notes` (the app does this; below) |
| `DELETE /api/runs/{id}` | Deletes a run and its data |
| `POST /api/runs/{id}/events` | A batch of events from the logger (below). Job token too |
| `GET /api/runs/{id}/metrics?maxPoints=1000` | Every metric, downsampled keeping spikes and NaN |
| `GET /api/runs/{id}/layers?maxPoints=500` | Per-layer statistics, in model order |
| `GET /api/runs/{id}/grad-norms` | Each layer's latest gradient norm |
| `GET /api/runs/{id}/fields` | The logged fields: each one's shape and steps, with error statistics |
| `GET /api/runs/{id}/fields/snapshot?name=u&step=1200` | One field snapshot (the latest without `step`) |
| `GET /api/runs/{id}/evals` | Validation-set summaries (`run.log_eval`), per name and step |
| `GET /api/runs/{id}/curves` | Curves (`run.log_curve`), per name and step |
| `GET /api/runs/{id}/output` | The last 1,000 lines the script printed: `{"lines": [...], "total": 52341}` |
| `GET /api/datasets` | Every dataset, most recently updated first, without previews |
| `GET /api/datasets/{id}` | One dataset, with its previews, `madeBy` and `usedBy` |
| `PUT /api/datasets/{id}` | Registers or updates a dataset (the logger does this). Job token too |
| `DELETE /api/datasets/{id}` | Forgets a dataset (the files are not touched) |
| `GET /api/metrics/latest?names=val/rel_l2,perf/inference_s` | For sweeps: `{run id: {metric: {latest, min}}}`, up to 20 names |
| `WS /api/live` | Live updates (below) |

**Events** (`POST .../events` with `{"events": [...]}`, up to 5000 per batch):

```json
{"type": "metrics", "step": 1200, "epoch": 3, "time": "2026-11-12T09:00:00Z",
 "values": {"train/loss": 0.41, "val/accuracy": "NaN"}}
{"type": "layers", "step": 1200, "layers": [{"layerName": "conv1",
 "activationMean": 0.1, "activationStd": 0.9, "gradNorm": 0.02, "deadFraction": 0.1,
 "activationHistogram": {"min": -2, "max": 3, "counts": [1, 5, 9], "zeroCount": 40}}]}
{"type": "field", "step": 1200, "name": "vorticity", "shape": [128, 128],
 "originalShape": [256, 256], "min": -3.1, "max": 2.8, "prediction": "<base64>",
 "target": "<base64>", "stats": {"relL2": 0.031, "rmse": 0.02, "maxError": 0.4}}
{"type": "field", "step": 1200, "name": "u", "shape": [64, 64], "frames": 20,
 "times": [0.1, 0.2, ...], "frameStats": {"relL2": [0.01, 0.012, ...]}, ...}
{"type": "field", "step": 1200, "name": "layers/blocks.0", "kind": "layer",
 "layer": "blocks.0", "position": 1, "reduction": "mean of 32 channels",
 "layerShape": [32, 64, 64], "shape": [64, 64], "target": null, ...}
{"type": "output", "start": 120, "lines": ["epoch 3: loss 0.41", "Traceback ..."]}
{"type": "status", "status": "crashed", "message": "RuntimeError: CUDA out of memory"}
{"type": "status", "status": "crashed", "diverged": true,
 "message": "Diverged at t = 0.83: energy is NaN"}
```

**Simulations** (`soliton.simulate`) are runs whose description has a
`simulation` entry: `{"tEnd": 10, "cflLimit": 1, "monitor": "energy"}`
(all optional). Their values are ordinary metrics, the simulated time the
metric `sim/t`. A run reads back with `simulation` set to that entry plus
`time` (the latest `sim/t`), `preview` (the monitored value, downsampled)
and `diverged`; training runs have `"simulation": null`. They're kept in
their own table, so older databases get them without a migration.

**Datasets** are described, not uploaded: `PUT /api/datasets/{id}` takes
`name`, `version`, `description`, `samples`, `splits`, `sampleShape`,
`sizeBytes`, `files`, `format`, `location`, `host`, `source`,
`fingerprint`, `system`, `madeBy` (a run id), `variables` (name,
description, unit, shape, dtype, min, max, mean, std) and up to 8
`previews` (1D or 2D, at most 96 points per axis, encoded like field
snapshots: `{"name", "shape", "min", "max", "data"}`). A run's description
may list `datasets` (ids) it trains on; they read back on the run, and on
each dataset as `usedBy`. A run may name a dataset before it is registered.
Dataset changes are pushed live as `{"type": "dataset", "event":
"updated", "datasetId": ...}`.

**Field snapshots** (`run.log_field`, `run.log_rollout` and
`run.capture_layers` in the logger): each frame a 1D, 2D or 3D array of at
most 512 points per axis, row by row (the last axis fastest), frames one
after the other; at most 16,777,216 values in all (about 43 MB of JSON). Each value is a
little-endian unsigned 16-bit code: 0 is `min`, 65534 is `max`, 65535 is
NaN. `target` (the true field, same shape and scale) may be `null`. `stats`
are computed by the logger on the full-resolution arrays. A rollout has
`frames` > 1, `times` (one per frame) and `frameStats` (e.g. `relL2` per
frame). A layer snapshot has `kind: "layer"`, is named `layers/<layer>`, and
has `layer`, `position` (its order in the model), `reduction` (e.g. "mean of
32 channels") and `layerShape` (the layer's output for one sample). A
snapshot is keyed by run, field name and step, like a metric point.
`GET .../fields` lists output fields by name, then layers in model order,
then worst samples (`kind: "worst"`, named `worst/<field>/<rank>`, with
`sample` and `worstOf`) and Fourier weights (`kind: "weights"`, named
`weights/<parameter>`). Optional: `extent` (`[[start, end], ...]` per axis),
`axes` (names) and `spectrum` (`{"k": [...], "prediction": [...], "target":
[...]}`).

**Validation sets and curves**:

```json
{"type": "eval", "step": 1200, "name": "u", "count": 200,
 "stats": {"median": 0.03, "p90": 0.07, "max": 0.21, "nonFinite": 0},
 "histogram": {"edges": [0.005, ...], "counts": [3, ...]},
 "worst": [{"rank": 1, "sample": 17, "relL2": 0.21}]}
{"type": "curve", "step": 1200, "name": "error vs resolution", "x": [64, 128, 256],
 "y": [0.03, 0.033, 0.036], "xLabel": "Resolution", "yLabel": "Relative L2",
 "trainRange": [64, 64]}
```

Both are keyed by run, name and step, so a resent one replaces itself.

**Tags and notes** (`PATCH /api/runs/{id}` with `{"tags": ["baseline"], "notes": "..."}`;
leave a field out to keep it): up to 20 tags of 1–40 characters (trimmed,
each once ignoring case) and a note of up to 10,000 characters. Every run
response includes `tags` and `notes`. The logger's `tags=` and `notes=` only
set them when the run is created, so it never overwrites edits made in the
app.

**System**: the logger's run description includes `system`, what the run
trains on (machine, GPUs, CPU, memory, software versions, Slurm job; up to
20,000 characters of JSON). It is returned with every run (`null` from an
older logger) and replaced whenever the logger sends a newer one. GPU,
memory and CPU use are ordinary metrics named `system/...`.

A point is keyed by run, metric and step, so a resent batch replaces itself:
the logger can retry freely. A run marked "lost contact" comes back to life
when newer data arrives.

**Live updates**: connect to `/api/live`, send `{"type": "auth", "token": "..."}`
first (browsers can't set WebSocket headers, and a token in the URL would end
up in logs), get `{"type": "ready"}`, then one message per change:

```json
{"type": "run", "event": "updated", "runId": "...", "name": "...", "status": "live",
 "statusMessage": null, "currentStep": 1200, "totalSteps": 50000}
```

`event` is `created`, `updated`, `finished`, `crashed`, `revived` or `deleted`.
The server sends `{"type": "ping"}` when idle, to keep proxies from closing
the connection. Interactive API docs are at `/docs` while the server runs.

## Tests

```bash
source env.sh && pytest server/tests
```

Each API test runs on SQLite and on PostgreSQL. PostgreSQL comes from the
`pgserver` package in `.venv`; if it can't start (on macOS this happens when
other apps hold all System V shared memory segments), those runs are skipped.
To use another PostgreSQL, set `SOLITON_TEST_POSTGRES_URL` (its tables are
dropped).
