# Soliton for coding agents

How Soliton works, and how to make any computation you write or submit show
up in it. For Claude Code, the `soliton` skill
([skills/soliton/SKILL.md](../skills/soliton/SKILL.md)) holds the
step-by-step recipe and loads by itself; this page is the reference behind
it, and works for any agent (copy the block at the end into a project's
`AGENTS.md` or `CLAUDE.md`).

## What Soliton is

```
the computation + soliton logger  ──HTTP──►  soliton-server  ◄──HTTP/WebSocket──  Soliton app
(logger/, Python, stdlib only)              (server/, FastAPI)                     (lib/, Flutter)
```

- **The logger** (`import soliton`) runs inside the computation. It writes
  every record to a local file first (`$SOLITON_DIR/<run id>/events.jsonl`),
  then uploads in the background every 2 seconds, retrying when the server
  can't be reached. A slow or broken network never slows the computation or
  loses data. It also samples the machine (CPU, memory, GPUs) every 15
  seconds and captures what the script prints.
- **The server** stores runs (SQLite or PostgreSQL), pushes changes to the
  app over a WebSocket, and marks runs that went quiet as crashed.
- **The app** (phone, tablet, Mac, web) shows them live. It has three
  sections: **Runs** (training), **Compute** (simulations) and **Data**
  (datasets). It reads only what the server has: nothing appears unless the
  computation reports through the logger.

## What becomes what in the app

| In the computation | In the app |
|---|---|
| `soliton.init(name, project=, config=, train_samples=, val_samples=, loss=, total_steps=, total_epochs=, tags=, notes=)` | A card under **Runs**: name, project, host, tags, loss sparkline, progress. Overview: hyperparameters (samples and loss first), progress, time left, cost, tags and notes |
| `run.log({...}, step=, epoch=)` | **Metrics** tab: one chart per known name, the rest under "Other metrics"; log scale and step/epoch axis options |
| `run.watch(model)` (PyTorch) | **Layers** tab (activation histograms, dead units, gradient norms per layer) and the network diagram on the Overview |
| `run.log_field`, `log_rollout`, `capture_layers`, `log_eval`, `log_curve` | **Fields** tab: prediction, truth and error maps, rollouts, 3D views, worst validation samples, error against resolution or a parameter |
| `soliton.simulate(name, t_end=, setup=, monitor=, cfl_limit=)`, `sim.log({...}, t=, dt=)` | A card under **Compute**: simulated time, progress, time left. Diagnostics tab: every value against t, drift of conserved quantities, log scale for "residual"/"error" names, `cfl` against its limit |
| `sim.log_field(name, field)` | Fields tab, at the simulated time |
| `soliton.register_dataset(path)`, `init(datasets=[...])` | **Data**: size, samples, splits, arrays and ranges, previews, which run made it and which runs used it. Only the description is uploaded |
| Automatic: the machine | **System** tab: CPU model and cores, memory limit, GPUs, software versions, host ("Sherlock", "Modal", ...), Slurm job (id, partition, node). Usage every 15 s: CPU %, memory against the job's limit, GPU use, memory, temperature, power |
| Automatic: the Slurm job | Overview: queue wait, expected finish, time limit, and a warning when the limit comes first |
| Automatic: what the script prints | **Output** on the Overview (last 1,000 lines), first thing on a crashed run, with the traceback |

### Metric names

The app gives these their own charts: `train/loss`, `val/loss`,
`val/accuracy`, `optim/lr`, `optim/grad_norm`. Groups: `loss/<term>` (terms
of a composite loss), `val/rel_l2` and `val/rel_l2/<variable>`,
`perf/inference_s` and `perf/solver_s` (the speed-up). Names starting with
`system/` are the logger's own. For simulations, any names; the simulated
time is stored as `sim/t` and the time step as `sim/dt`. Values may be Python, NumPy or PyTorch scalars,
and NaN or infinity (shown as such).

### How a run ends

| What happens | Status in the app |
|---|---|
| `run.finish()`, or the `with` block or script ends normally | Finished |
| An exception | Crashed, with the error and the traceback |
| A simulation logs NaN or infinity | Crashed: "Diverged at t = ...: energy is NaN", marked on its charts |
| SIGTERM (Slurm time limit, `scancel`) | Crashed: "Stopped by its Slurm time limit" (or "by SIGTERM"). In a job script Python must get the signal: `exec python ...` and `#SBATCH --signal=B:TERM@60` |
| Killed outright (out of memory, node failure), or the signal never reached Python | Crashed by the server: "Stopped by its Slurm time limit" a minute after the limit, else "Lost contact" after 10 minutes of silence. It turns live again if data arrives |
| A later job continues it (`init(id=...)`, the wrapper's `--id`), e.g. from a checkpoint | Live again, whatever the earlier job ended with |

## Where the data goes

The logger reads `SOLITON_SERVER` and `SOLITON_TOKEN` from the environment.
The user sets them; never write the token into code, scripts, configs or
logs. Without them the logger works offline: everything is saved under
`SOLITON_DIR` (default `./soliton-runs`), and `soliton sync` uploads it
later (it sends only what the server doesn't have, so running it twice is
harmless).

Where the server is depends on the user's setup:

- **A public server** (HTTPS, e.g. a small cloud VM): reachable from
  everywhere, including Modal and cloud machines. Its address and token are
  in `~/.soliton_env` on machines that use it.
- **The test server on Sherlock**: a job in the `service` partition
  ([sherlock.md](sherlock.md#a-server-on-sherlock-for-testing)). While it
  runs, `$HOME/soliton-server/env.sh` holds its address and token. Only
  Sherlock's own nodes reach it; the user's app connects through an SSH
  tunnel.
- **A local server**: `soliton-server` on the user's computer, for runs on
  that computer.

| Variable | Default | |
|---|---|---|
| `SOLITON_SERVER`, `SOLITON_TOKEN` | none | Where to upload |
| `SOLITON_MODE` | `online` if a server is set | `online`, `offline` or `disabled` |
| `SOLITON_DIR` | `./soliton-runs` | The local copy. On a cluster, scratch space |
| `SOLITON_CAPTURE_OUTPUT` | `1` | `0`: don't send what the script prints |
| `SOLITON_PRICE_PER_HOUR` | estimated | `0` hides the cost estimate |
| `SOLITON_HOST` | detected | The host shown in the app |

## Adding monitoring to a computation

1. **Training in Python:** `soliton.init` before training, `run.log` in the
   loop and after each evaluation, `run.watch(model)` for PyTorch, `with`
   or `run.finish()`. Give `total_steps` (progress, time left),
   `train_samples`, `val_samples` and `loss`. `step` is the global
   optimizer step and never resets; resuming from a checkpoint, save
   `run.id` in it and pass `id=` to `init`. With DDP, rank 0 only.
2. **A Python simulation:** `soliton.simulate(name, t_end=..., setup={...},
   monitor=...)`, `sim.log({...}, t=t, dt=dt)` every few steps,
   `sim.log_field` every few hundred, `with sim:`. A steady solve gives
   `max_iterations=` and logs once per iteration.
3. **Any other program** (compiled solvers, community codes, MPI launches,
   shell pipelines): don't edit it. Launch it through
   [skills/soliton/scripts/monitor_solver.py](../skills/soliton/scripts/monitor_solver.py),
   which runs it unchanged, passes its output through, reads the values it
   writes (text tables of numbers, HDF5 tables, or progress lines it
   prints) and reports them as a simulation. It keeps the program's exit
   code, `--error` catches programs that exit 0 after an error, and `--id`
   continues the same run across jobs restarted from checkpoints. Find the
   real files and read their headers for column numbers; don't guess.
4. **Data:** `soliton.register_dataset(path, name=, version=, source=,
   splits=)`, passed to `init(datasets=[...])`; a run that writes data
   registers it with `run.register_dataset(path)`.

The [skill](../skills/soliton/SKILL.md) has a code example for each, job
script templates for Sherlock, Modal and cloud machines, and how to find
and choose what to watch in a program's output. The full API is in
[logger/README.md](../logger/README.md).

### Rules

- Don't change what the computation does. Don't catch exceptions to hide a
  crash; don't replace NaN before logging it.
- Log scalars a few times per second at most, fields every few hundred
  steps. In fast GPU loops log every 10–50 steps (logging a GPU tensor waits
  for the GPU).
- Short, descriptive names (`model-data-variant`); `project` for what it is
  about (runs group by it); `tags` for what makes this run different;
  `notes` for why it exists.
- Check with a short run before the real one.

## Checking that it works

```bash
curl -s -H "Authorization: Bearer $SOLITON_TOKEN" "$SOLITON_SERVER/api/runs"   # the run is listed
curl -s -H "Authorization: Bearer $SOLITON_TOKEN" "$SOLITON_SERVER/api/runs/<id>/metrics"
```

Other endpoints: `/api/runs/<id>/output`, `/fields`, `/layers`,
`/api/datasets`, `/api/health` (no token). Offline: the run's
`events.jsonl` grows and ends with a `"status"` record.

## Block to copy into a project's AGENTS.md or CLAUDE.md

Replace `/path/to/soliton` with where the Soliton repository (or its
`logger` folder) is on the machine that runs the computation.

```markdown
## Monitoring: Soliton

Every computation in this project reports to Soliton, so I can follow it in
the Soliton app. Follow /path/to/soliton/docs/for-agents.md (Claude Code: the
`soliton` skill). In short:

- Training scripts: `soliton.init(...)`, `run.log(...)`, `run.watch(model)`.
  Python simulations: `soliton.simulate(...)`, `sim.log(..., t=t)`. Other
  programs: launch them through `monitor_solver.py`. Data: `register_dataset`.
- The logger is at /path/to/soliton/logger: `pip install` it, or put
  `/path/to/soliton/logger/src` first on `PYTHONPATH`.
- Server and token come from `SOLITON_SERVER`/`SOLITON_TOKEN`, which I set.
  Never write the token anywhere. Without them runs are saved offline.
- Slurm job scripts: `#SBATCH --signal=B:TERM@60`, `SOLITON_DIR` on scratch,
  and `exec python ...` so a time limit is reported.
- Don't change what the computation does; check with a short run first.
```
