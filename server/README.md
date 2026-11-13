# modelsapp-server

Stores the training runs that the `modelsapp` logger sends, and serves them
to the ModelsApp app, with live updates over a WebSocket.

FastAPI, SQLAlchemy, and SQLite or PostgreSQL. One process; no other services.

## Running it locally

From the project root (see the main README for `env.sh`):

```bash
source env.sh
modelsapp-server                  # http://127.0.0.1:8000, this computer only
modelsapp-server --show-token     # the token for the logger and the app
```

Without `MODELSAPP_TOKEN`, the server makes a random token on first start and
keeps it in `$MODELSAPP_DATA_DIR/token` (readable by you only). The database
is `$MODELSAPP_DATA_DIR/modelsapp.db` (SQLite). With `env.sh`, that folder is
`.data/` in the project.

To use the app on a phone on the same network, listen on all addresses and
use your computer's local IP in the app, e.g. `http://192.168.1.20:8000`:

```bash
modelsapp-server --host 0.0.0.0
```

## Settings

All from environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `MODELSAPP_TOKEN` | generated, in `token` | The API token (send as `Authorization: Bearer ...`) |
| `DATABASE_URL` or `MODELSAPP_DATABASE_URL` | SQLite in the data folder | e.g. `postgresql://user:pass@host/db` |
| `MODELSAPP_DATA_DIR` | `./modelsapp-data` | Where the SQLite database and token live |
| `MODELSAPP_LISTEN_HOST`, `PORT` | `127.0.0.1`, `8000` | Address and port (also `--host`, `--port`) |
| `MODELSAPP_STALE_MINUTES` | `10` | A live run silent this long is marked crashed ("lost contact") |
| `MODELSAPP_CORS_ORIGINS` | `*` | Web origins allowed to call the API (comma-separated) |
| `MODELSAPP_NTFY_URL` | off | Push notifications, e.g. `https://ntfy.sh/<long-random-topic>` |
| `MODELSAPP_NTFY_TOKEN` | none | Access token for a protected ntfy topic |
| `MODELSAPP_NOTIFY_ON` | `finished,crashed` | Which events send a push notification |

## Push notifications (ntfy)

[ntfy](https://ntfy.sh) delivers real push notifications to its free iOS and
Android apps, without an Apple or Google developer account:

1. Install the ntfy app on your phone and subscribe to a topic with a long,
   random name (anyone who knows a topic on the public server can read it).
2. Start the server with `MODELSAPP_NTFY_URL=https://ntfy.sh/<that-topic>`.

You get "resnet50 finished" or "resnet50 crashed: CUDA out of memory" with
the app closed. For privacy, run your own ntfy server and set
`MODELSAPP_NTFY_TOKEN`.

## Putting it on the internet

The logger on a cluster and the app on your phone both need to reach the
server, so it has to run somewhere public, with HTTPS. Two common ways:

- **A small cloud VM** (any provider): install uv, copy this repository,
  `uv sync --package modelsapp-server --extra postgres` (or keep SQLite), set
  `MODELSAPP_TOKEN` to a long random string, run
  `modelsapp-server --host 127.0.0.1`, and put [Caddy](https://caddyserver.com)
  in front for automatic HTTPS (`reverse_proxy 127.0.0.1:8000`; it forwards
  WebSockets as is).
- **A hosting platform** that runs Python apps: start command
  `modelsapp-server --host 0.0.0.0` (it reads `PORT`), and a managed
  PostgreSQL in `DATABASE_URL` (`postgres://` URLs are accepted). Set
  `MODELSAPP_TOKEN`; don't rely on the generated one, as the disk may not
  persist.

Run a single process: live updates are pushed from memory, so several
workers wouldn't see each other's changes. Tables are created on startup.
There are no migrations yet, so after an upgrade that changes an existing
table, start from a fresh database. (New tables, like `run_notes` for tags
and notes or `run_system` for what a run trains on, are added to an
existing database on startup.)

## API

Every endpoint except `/api/health` needs `Authorization: Bearer <token>`.
Field names and shapes are exactly what the app's models read (`fromJson` in
`lib/models/`). Non-finite numbers travel as the strings `"NaN"`,
`"Infinity"` and `"-Infinity"`.

| Method and path | What it does |
|---|---|
| `GET /api/health` | `{"status": "ok", "version": ...}`, public |
| `GET /api/session` | Checks the token |
| `GET /api/runs` | All runs, newest first, each with a 60-point loss preview |
| `GET /api/runs/{id}` | One run (404 if unknown) |
| `PUT /api/runs/{id}` | Creates or updates a run's description (the logger does this) |
| `PATCH /api/runs/{id}` | Sets its `tags` and/or `notes` (the app does this; below) |
| `DELETE /api/runs/{id}` | Deletes a run and its data |
| `POST /api/runs/{id}/events` | A batch of events from the logger (below) |
| `GET /api/runs/{id}/metrics?maxPoints=1000` | Every metric, downsampled keeping spikes and NaN |
| `GET /api/runs/{id}/layers?maxPoints=500` | Per-layer statistics, in model order |
| `GET /api/runs/{id}/grad-norms` | Each layer's latest gradient norm |
| `GET /api/runs/{id}/fields` | The logged fields: each one's shape and steps, with error statistics |
| `GET /api/runs/{id}/fields/snapshot?name=u&step=1200` | One field snapshot (the latest without `step`) |
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
{"type": "status", "status": "crashed", "message": "RuntimeError: CUDA out of memory"}
```

**Field snapshots** (`run.log_field(...)` in the logger): a 1D or 2D array
of at most 512 points per axis, row by row, each point a little-endian
unsigned 16-bit code: 0 is `min`, 65534 is `max`, 65535 is NaN. `target`
(the true field, same shape and scale) may be `null`. `stats` are computed
by the logger on the full-resolution arrays. A snapshot is keyed by run,
field name and step, like a metric point.

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
To use another PostgreSQL, set `MODELSAPP_TEST_POSTGRES_URL` (its tables are
dropped).
