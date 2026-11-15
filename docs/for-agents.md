# Soliton for coding agents

How Soliton works, and how to make any computation you write or submit show
up in it. For Claude Code and Codex, the `soliton` skills
([skills/](../skills/README.md)) hold the step-by-step recipe and load by
themselves once installed; this page is the reference behind them, and
works for any agent (copy the block at the end into a project's `AGENTS.md`
or `CLAUDE.md`).

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
| `run.should_stop()` in the loop | The **Stop** button on a live run's page: it turns `True` within seconds; save a checkpoint and leave the loop, and the run ends "Stopped from the app" |
| `run.log({...}, step=, epoch=)` | **Metrics** tab: one chart per known name, the rest under "Other metrics"; log scale and step/epoch axis options |
| `run.watch(model)` (PyTorch) | **Layers** tab (activation histograms, dead units, gradient norms per layer) and the network diagram on the Overview; the model's class is its family, which the runs list groups by and the farm turns into an animal |
| `run.log_image(name, figure)` (a matplotlib figure, PIL image, array or PNG/JPEG file) | **Fields** tab: the picture, with a slider over the steps it was logged at; tap to zoom. For plots the app has no form for (phase portraits, confusion matrices, generated samples). Log every few hundred steps |
| `run.log_field`, `log_rollout`, `capture_layers`, `log_eval`, `log_curve` | **Fields** tab: prediction, truth and error maps, rollouts, 3D views, worst validation samples, error against resolution or a parameter |
| `soliton.simulate(name, t_end=, setup=, monitor=, cfl_limit=)`, `sim.log({...}, t=, dt=)` | A card under **Compute**: simulated time, progress, time left. Diagnostics tab: every value against t, drift of conserved quantities, log scale for "residual"/"error" names, `cfl` against its limit |
| `sim.log_field(name, field)` | Fields tab, at the simulated time |
| `soliton.register_dataset(path)`, `init(datasets=[...])` | **Data**: size, samples, splits, arrays and ranges, previews, which run made it and which runs used it. Only the description is uploaded |
| Automatic: the machine | **System** tab: CPU model and cores, memory limit, GPUs, software versions, host ("Sherlock", "Modal", ...), Slurm job (id, partition, node). Usage every 15 s: CPU %, memory against the job's limit, GPU use, memory, temperature, power |
| Automatic: training health | A warning on the Overview, and an alert, once per job, when a loss turns NaN or infinite, a training loss climbs back up, or `optim/grad_norm` blows up. `init(stop_on_divergence=True)` also ends the run when its loss turns NaN (raising `soliton.Diverged`). Off with `SOLITON_HEALTH=0` |
| Automatic: the Slurm job | Overview: queue wait, expected finish, time limit, and a warning when the limit comes first; an alert (and ntfy push) once per job when, at its pace, it won't finish in time, and when a job that waited (queued with `soliton sbatch`, or 10 minutes or more) starts. When it ends, **Resources**: memory, CPUs, GPUs and time used against what it asked for, with sbatch options for next time |
| `soliton sbatch <sbatch's options> job.sbatch` (in place of `sbatch`) | A **Queued** card while the job waits: how long, why, expected start, what it asked for. The run the job's script starts takes its place (matched by Slurm job id); with `--id <run id>`, that run itself shows as queued. `soliton queue` updates what Slurm says, and ends jobs that left without starting |
| Automatic: how to run it again | **System** tab, Reproduce: the git commit (and files with uncommitted changes), the command and directory, the Slurm job script, the packages; "Copy command to rerun". Secrets hidden. Compare shows the code version among the settings that differ |
| A run continued over several jobs (`init(id=...)`) | Overview: a **Jobs** card (each job's Slurm id, queue wait, run time, steps, how it ended); the Metrics charts mark where each later job took over |
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
| A training loss turns NaN or infinite | Still live, with a warning and an alert; with `stop_on_divergence=True`, crashed: "Diverged: train/loss is NaN at step N" (the script gets `soliton.Diverged`) |
| SIGTERM (Slurm time limit, `scancel`) | Crashed: "Stopped by its Slurm time limit" (or "by SIGTERM"). In a job script Python must get the signal: `exec python ...` and `#SBATCH --signal=B:TERM@60` |
| Killed outright (out of memory, node failure), or the signal never reached Python | Crashed by the server: "Stopped by its Slurm time limit" a minute after the limit, else "Lost contact" after 10 minutes of silence. It turns live again if data arrives |
| A later job continues it (`init(id=...)`, the wrapper's `--id`), e.g. from a checkpoint | Live again, whatever the earlier job ended with; its pace (time left, the time-limit alert) counts from where it resumed |
| The app's Stop button | Finished, "Stopped from the app at step N", once the script sees `run.should_stop()` and leaves its loop; a script that never checks it is ended as by scancel (crashed, "Stopped from the app") |
| A queued job (`soliton sbatch`) leaves the queue without starting | After `soliton queue`: crashed, with what `sacct` says ("Cancelled before it started.", no alert for a cancel; failed, out of memory...) |

## Where the data goes

The logger reads `SOLITON_SERVER` and `SOLITON_TOKEN` from the environment.
The user sets them; never write the token into code, scripts, configs or
logs. Without them the logger works offline: everything is saved under
`SOLITON_DIR` (default `./soliton-runs`), and `soliton sync` uploads it
later (it sends only what the server doesn't have, so running it twice is
harmless).

If a machine has no `~/.soliton_env` yet, set it up with the user: run
`python3 -m soliton setup --server <address>` in a terminal the user can type
in (for a cluster, over their SSH session), and ask them to paste the token
at its hidden prompt, from the app (Settings → Advanced security → Separate
token for jobs; or the server's main token). Never ask for the token in the
chat or put it on a command line. It checks the token and writes the file,
readable by them only.

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

`SOLITON_TOKEN` may be the server's main token or, if the user turned on
**Advanced security** in the app, the **job token**: it can create and update
runs, send their events, describe datasets and list queued jobs, and the
server answers 403 to everything else (listing or reading runs, deleting,
editing tags). That is by design: don't ask the user for the main token to
work around it; check uploads as in "Checking that it works" below. With the
job token, a run that exists changes only with its **run key**, which the
logger keeps in `$SOLITON_DIR/<run id>/key`: a job continuing a run
(`init(id=...)`) finds it when it uses the same `SOLITON_DIR` (keep it the
same across jobs, e.g. `$SCRATCH/soliton-runs`); otherwise set
`SOLITON_RUN_KEY` to that file's contents. Never pass the token on the
command line (`soliton --token` shows it in `ps`): use the environment.

| Variable | Default | |
|---|---|---|
| `SOLITON_SERVER`, `SOLITON_TOKEN` | none | Where to upload |
| `SOLITON_MODE` | `online` if a server is set | `online`, `offline` or `disabled` |
| `SOLITON_DIR` | `./soliton-runs` | The local copy. On a cluster, scratch space |
| `SOLITON_CAPTURE_OUTPUT` | `1` | `0`: don't send what the script prints |
| `SOLITON_PRICE_PER_HOUR` | estimated | `0` hides the cost estimate |
| `SOLITON_HOST` | detected | The host shown in the app |
| `SOLITON_REFRESH_QUEUE` | `1` | `0`: a starting Slurm job doesn't refresh the user's other queued jobs |
| `SOLITON_CAPTURE_CODE` | `1` | `0`: don't record the git commit, command line, job script and packages |

## Reading results back

For analysis or figures from runs already on the server (a results table,
curves for a paper, mean over seeds), use `soliton.runs()` rather than
scraping the app or calling the HTTP API by hand:

```python
import soliton                      # SOLITON_SERVER, and SOLITON_TOKEN = the main token

runs = soliton.runs(project="operator-learning", tags=["final"])   # newest first
for run in runs:
    curve = run.metric("val/rel_l2")                # every point logged, not thinned out
    plt.plot(curve.steps, curve.values, label=run.name)

table = runs.table(["val/rel_l2", "perf/inference_s"])   # one row per run
table.to_csv("results.csv")                              # or .to_pandas()
```

`run.config` has the settings, `run.summary[name]` a metric's count, first,
final, min and max (with steps), `soliton.get_run(id)` one run. A run with
`thinned_at` set was thinned out on the server (1,000 points per curve). It needs the
server's **main** token: the job token gets a `PermissionError` that says so.
Run it on the user's machine, never in a job script, and never ask for the
main token in the chat; if `SOLITON_TOKEN` there is the job token, ask the
user to run the analysis in a shell that has the main one.

Asked to back up the server's data, use `soliton-server --backup <folder>`
on the server's machine (safe while it runs; it never overwrites a file),
or point the user to Settings → Storage → Download a backup. Never copy
`soliton.db` with `cp` while the server runs (the copy can be broken), and
never put a backup anywhere others can read: it holds everything the runs
logged. See [Backups](../server/README.md#backups).

## Adding monitoring to a computation

1. **Training in Python:** `soliton.init` before training, `run.log` in the
   loop and after each evaluation, `run.watch(model)` for PyTorch, `with`
   or `run.finish()`. Give `total_steps` (progress, time left),
   `train_samples`, `val_samples` and `loss`. `step` is the global
   optimizer step and never resets; resuming from a checkpoint, save
   `run.id` in it and pass `id=` to `init`. With DDP, rank 0 only. Where the
   script can checkpoint, check `run.should_stop()` in the loop (save, then
   break), so the app's Stop button stops it cleanly.
2. **A Python simulation:** `soliton.simulate(name, t_end=..., setup={...},
   monitor=...)`, `sim.log({...}, t=t, dt=dt)` every few steps,
   `sim.log_field` every few hundred, `with sim:`. A steady solve gives
   `max_iterations=` and logs once per iteration.
3. **Any other program** (compiled solvers, community codes, MPI launches,
   shell pipelines): don't edit it. Launch it through
   [skills/claude-code/soliton/scripts/monitor_solver.py](../skills/claude-code/soliton/scripts/monitor_solver.py),
   which runs it unchanged, passes its output through, reads the values it
   writes (text tables of numbers, HDF5 tables, or progress lines it
   prints) and reports them as a simulation. It keeps the program's exit
   code, `--error` catches programs that exit 0 after an error, and `--id`
   continues the same run across jobs restarted from checkpoints. Find the
   real files and read their headers for column numbers; don't guess.
4. **Data:** `soliton.register_dataset(path, name=, version=, source=,
   splits=)`, passed to `init(datasets=[...])`; a run that writes data
   registers it with `run.register_dataset(path)`.
5. **Submitting to Slurm:** `soliton sbatch` (`python3 -m soliton sbatch`
   with the logger on `PYTHONPATH`) in place of `sbatch`: soliton's own
   options first (`--name`, `--project`, `--id`), then sbatch's, unchanged.
   It submits, prints sbatch's job id, and shows the job as Queued. A job
   continuing a run passes that run's id: `soliton sbatch --id <run id> ...`.
   `soliton queue` is one `squeue` call: run it when you check, never in a
   loop (on Sherlock, no polling from login nodes). Each Soliton job also
   refreshes the user's other queued jobs once as it starts.

The [skill](../skills/claude-code/soliton/SKILL.md) has a code example for each, job
script templates for Sherlock, Modal and cloud machines, and how to find
and choose what to watch in a program's output. The full API is in
[logger/README.md](../logger/README.md).

### Rules

- Don't change what the computation does. Don't catch exceptions to hide a
  crash; don't replace NaN before logging it.
- No secrets on the command line or in job scripts: the logger records both
  for Reproduce (it hides values named like a token, password, secret or key,
  but secrets belong in the environment). Suggest committing the code before
  a long job, so its run records a clean commit.
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
`/api/datasets`, `/api/runs?status=queued`, `/api/health` (no token).
Offline: the run's `events.jsonl` grows and ends with a `"status"` record.

With the job token those reads answer 403. Check the upload instead: in
`$SOLITON_DIR/<run id>/`, `upload.json`'s `offset` catches up with the size
of `events.jsonl` (bytes the server has), and the job's output shows no
`soliton:` upload errors. Then ask the user to look in the app.

## Block to copy into a project's AGENTS.md or CLAUDE.md

Replace `/path/to/soliton` with where the Soliton repository (or its
`logger` folder) is on the machine that runs the computation.

```markdown
## Monitoring: Soliton

Every computation in this project reports to Soliton, so I can follow it in
the Soliton app. Follow /path/to/soliton/docs/for-agents.md (Claude Code or
Codex: the `soliton` skill, from /path/to/soliton/skills). In short:

- Training scripts: `soliton.init(...)`, `run.log(...)`, `run.watch(model)`,
  and `if run.should_stop(): save a checkpoint; break` (the app's Stop button).
  Python simulations: `soliton.simulate(...)`, `sim.log(..., t=t)`. Other
  programs: launch them through `monitor_solver.py`. Data: `register_dataset`.
- The logger is at /path/to/soliton/logger: `pip install` it, or put
  `/path/to/soliton/logger/src` first on `PYTHONPATH`.
- Server and token come from `SOLITON_SERVER`/`SOLITON_TOKEN`, which I set.
  Never write the token anywhere. Without them runs are saved offline.
- Slurm job scripts: `#SBATCH --signal=B:TERM@60`, `SOLITON_DIR` on scratch,
  and `exec python ...` so a time limit is reported. Submit with
  `soliton sbatch` (sbatch's options) so the job shows while queued.
- `SOLITON_TOKEN` may be a job token that can't read runs (403): that's
  expected; check uploads in `$SOLITON_DIR/<run id>/upload.json`.
- Don't change what the computation does; check with a short run first.
- Training loops check `run.should_stop()` (the app's Stop button). No
  secrets on the command line or in job scripts (they're recorded).
```
