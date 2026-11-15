---
name: soliton
description: "Add Soliton monitoring to a computation so it can be followed live in the Soliton app: training scripts (PyTorch or not), Python simulations and solvers, and any other program (compiled solvers, community codes, MPI jobs, shell pipelines) run through Slurm on Sherlock or another cluster, on Modal, a cloud machine or locally. Use whenever writing, editing, wrapping or submitting such a computation or its job script, even if the user doesn't mention Soliton, unless they say not to. Also use to read monitored runs back for analysis, figures or results tables (soliton.runs())."
---

# Soliton: make every computation show up in the app

Soliton shows training runs and simulations live on the user's phone and
computer. A computation shows up only if it reports through the `soliton`
Python logger. Your job: whenever you write, change or submit a computation,
add that reporting, the right way for its kind, without changing what it
computes.

The full reference is `docs/for-agents.md` in the Soliton repository
(GitHub: `selimamar/soliton`, or wherever the user keeps their copy); the
logger's API is in `logger/README.md` there. Read
them when something here isn't enough.

## Rules

- **Never write the token anywhere**: not in code, job scripts, configs,
  logs or chat. The server and token come from the environment
  (`SOLITON_SERVER`, `SOLITON_TOKEN`), which the user sets up. If they
  aren't set, the logger saves the run locally (offline); that's fine, don't
  work around it. `SOLITON_TOKEN` may be a job token that can add runs but
  not read them (the server answers 403 to reads); that's fine too, never ask
  for the main token to get around it.
- **No secrets on the command line or in job scripts.** The logger records
  both (and the git commit) so the user can rerun the run from the app; it
  hides values named like a token, password, secret or key, but keep secrets
  in the environment. Before a long job, suggest committing the code: the
  run then records a clean commit instead of "uncommitted changes".
- **Don't change the science.** Monitoring is added around the computation:
  same inputs, same numerics, same outputs. Don't catch exceptions to hide a
  crash, and don't replace NaN before logging it (the first NaN marks a
  simulation as diverged, which is what the user wants to see).
- **Keep it cheap.** Log scalars every few steps (aim for a few records per
  second at most), fields every few hundred steps. Logging a GPU tensor makes
  Python wait for the GPU: in fast loops, log every 10–50 steps.
- **Say what you added** in your reply: the run's name, where it reports
  (server or offline), and how the user can find it in the app.

## 1. Which kind of computation is it?

| It is | Use | App section |
|---|---|---|
| Training a model in Python | `soliton.init(...)`, `run.log(...)` (2a) | Runs |
| A Python simulation or solver (steps through time, or iterates to convergence) | `soliton.simulate(...)`, `sim.log(..., t=t)` (2b) | Compute |
| A program that isn't Python, or that you shouldn't edit (compiled solver, MPI launch, shell pipeline) | `scripts/monitor_solver.py` around its launch (2c) | Compute |
| Making data | `register_dataset(path)` after writing it (2d) | Data |

A parameter sweep or job array: one run per task, the parameters in the name
and in `config`/`setup`, the same `project`, a tag such as `sweep-<name>`.

## 2a. Training (Python)

```python
import soliton

with soliton.init(
    "fno-ns-64modes",                       # short: model-data-variant
    project="navier-stokes",                # what the model does; runs group by it
    config={"Optimizer": "AdamW", "Learning rate": 3e-4, "Batch size": 32, "Modes": 64},
    train_samples=train_set, val_samples=val_set,   # a number, a dataset or a DataLoader
    loss=criterion,                         # module, function or string
    total_steps=epochs * len(loader), total_epochs=epochs,   # progress and time left
    tags=["baseline"], notes="Why this run exists, in a sentence.",
) as run:
    run.watch(model, every=100)             # PyTorch: layer statistics, network diagram, model family
    for epoch in range(epochs):
        for x, y in loader:
            loss = criterion(model(x), y)
            optimizer.zero_grad(); loss.backward()
            if step % 20 == 0:
                run.log({"train/loss": loss, "optim/lr": sched.get_last_lr()[0]},
                        step=step, epoch=epoch)
            optimizer.step(); step += 1
        run.log({"val/loss": val_loss, "val/accuracy": val_acc}, step=step)
        if run.should_stop():               # the app's Stop button
            save_checkpoint(model, optimizer, step, run.id)
            break
```

- **Names with their own charts:** `train/loss`, `val/loss`, `val/accuracy`,
  `optim/lr`, `optim/grad_norm` (what `clip_grad_norm_` returns); loss terms
  as `loss/<term>`; field errors as `val/rel_l2` and `val/rel_l2/<variable>`;
  `perf/inference_s`, `perf/solver_s`. Anything else shows under "Other
  metrics".
- **Training health** comes free from those names: the logger warns (in
  the app, with an alert) when a loss turns NaN, a training loss climbs back
  up, or `optim/grad_norm` blows up. So log the gradient norm when the
  script clips gradients. For long or costly runs, suggest
  `init(stop_on_divergence=True)`: a NaN loss then ends the run and raises
  `soliton.Diverged` (save nothing after it); don't add it unasked to a script
  that handles NaN itself (e.g. a gradient scaler).
- `step` is the global optimizer step: it never resets. Resuming from a
  checkpoint: save `run.id` in the checkpoint and pass `id=` to `init`.
  The app then shows the run's jobs (one per restart) and marks where each
  took over; submit the continuing job with `soliton sbatch --id <run id>`.
  Keep `SOLITON_DIR` the same for every job of a run: the run's key
  (`$SOLITON_DIR/<run id>/key`) is there, and with a job token a run only
  accepts updates carrying it (else set `SOLITON_RUN_KEY` to the file's
  contents).
- `run.should_stop()` turns `True` when the user presses Stop in the app:
  check it where the script can save a checkpoint (the end of an epoch, or
  every N steps) and leave the loop. Use the script's own checkpoint code;
  if it has none, just `break`. A script that never checks is ended as by
  scancel.
- Always give `total_steps` when it's known: without it there's no progress
  bar or time left.
- DDP: only rank 0 calls `init`, `watch` and `log`.
- Models that predict a field (neural operators, PDE surrogates): after each
  evaluation `run.log_field("u", pred[0, 0], target[0, 0], extent=..., axes=...)`,
  `run.log_eval("u", preds, targets)`, and `pde={...}` in `init`. See
  "Fields" and "Diagnostics" in `logger/README.md`.
- A plot the script already draws for itself (a phase portrait, a confusion
  matrix, generated samples): also `run.log_image("name", fig)` every few
  hundred steps (matplotlib figure, PIL image, array or PNG file), then
  `plt.close(fig)`. Use `matplotlib.use("Agg")` on a cluster. Not for
  curves over training: those are `run.log` metrics.

## 2b. A Python simulation

```python
sim = soliton.simulate(
    "kh-2048-re1e4", project="turbulence", t_end=10.0,     # or max_iterations= for a steady solve
    setup={"equation": "Incompressible Navier-Stokes", "method": "Fourier spectral",
           "grid": "2048 x 2048", "Re": 1e4},
    monitor="enstrophy", cfl_limit=1.0)
with sim:
    while t < t_end:
        ...                                                   # the solver's own step
        if step % 50 == 0:
            sim.log({"energy": E, "enstrophy": Z, "cfl": cfl}, t=t, dt=dt)
        if step % 2000 == 0:
            sim.log_field("vorticity", w, extent=[(0, 1), (0, 1)], axes=["y", "x"])
```

Names containing "residual" or "error" are drawn on a log scale; a value
named `cfl` is drawn with `cfl_limit`. Conserved quantities (mass, energy)
show how far they drifted. Pass `stop_on_divergence=True` to stop the solver
at the first NaN (it raises `soliton.Diverged`).
`sim.should_stop()` is the app's Stop button, as for training: check it where
the solver can write a restart file, then leave the loop.

## 2c. Any other program: `scripts/monitor_solver.py`

For a program that isn't Python, or that you shouldn't edit (a compiled
solver in C++, Fortran or Julia, a community code, an MPI launch, a shell
pipeline), don't touch it. Launch it through the wrapper, which runs it
unchanged, passes its output through, reads the numbers it writes, and
reports a simulation:

```bash
python3 monitor_solver.py --name NAME --project PROJECT --t-end T_END \
    --setup "grid=256^3" --setup "input=run.cfg" \
    --table 'GLOB,t=COL,name=COL,...' \
    --h5 'FILE,dataset=NAME,t=COL,name=COL,...' \
    --stdout 'REGEX with (?P<t>...) and (?P<name>...) groups' \
    --error 'REGEX for fatal lines' \
    -- THE ORIGINAL LAUNCH COMMAND (e.g. srun ./solver run.cfg)
```

`python3 monitor_solver.py --help` has every option, how specs are parsed
and how rows from several sources are merged: read it. The program's exit
code is kept (the wrapper exits with it), so job states, dependencies and
any script logic after the launch behave as before. The wrapper sees stdout
and stderr. It runs once, outside the MPI launcher: put it in front of
`srun`/`mpirun`, not inside.

### Find out what the program writes

Don't guess file names or column numbers. Look at an earlier run's output
directory, or run a very short version (a few steps, a coarse grid), and
find the files that grow while it runs, one row per output time:

- **Text tables** (`.dat`, `.txt`, `.csv` with spaces, `.tsv`, or a code's
  own extension): read the comment lines at the top (`#`): they often
  number the columns ("# 1:iteration 2:level ... 9:time 10:value"). The
  time is often *not* column 1, and many codes write one small file per
  quantity (a minimum, a maximum, a norm): use one `--table` each. Columns
  in the spec are **1-based**, as such headers number them.
- **HDF5 files** (`.h5`): list them with `h5ls -r FILE`, or in Python
  `h5py.File(FILE).visit(print)` and the dataset's `.dtype.names` and
  `.attrs`. A table is a 2D dataset (one row per time) whose columns are
  named in an attribute (often `Legend`) or a compound dataset with named
  fields. Use the names in the spec: `t=time,error=error_l2`.
- **Output lines**: progress lines such as `it=120 t=3.42 dt=1e-3` or
  `Time = 3.42`; match them with `--stdout` and named groups.
- **Restarts** write into new numbered directories (`out-0000/`,
  `out-0001/`, ...) or append to the same files: use a glob that matches all
  of them (`out-*/name.dat`, for tables and HDF5 alike). A "current"
  directory symlinked to one of them is fine (files are read once), and rows
  at or before the last logged time are skipped.
- Files that only appear later (after an event, or at the first output) are
  waited for; a spec for them can be there from the start. Files that stop
  growing (a quantity only defined for part of the run) don't hold the
  others back.
- **Compare how each file prints the time.** If one prints it with fewer
  digits (e.g. `0.964` where another has `0.963692...`), pass
  `--time-tolerance` (half its last digit: `0.0005` for 3 decimals), so
  values from both land in one record, which `--derive` across files needs.

### Choose what to watch

Keep it to a handful of values that show progress and health:

- **the simulated time** (always). Give `--t-end` when the run has a final
  time: read it from the input or parameter file, at job time if the file is
  generated (`--t-end "$(awk ... input.par)"`). A run that ends on an event
  instead (a condition, not a time) has no `--t-end`: no progress bar, the
  values still show;
- **error, residual or constraint norms**: name them so the name contains
  "error" or "residual" (e.g. `constraint_error`), which the app draws on a
  log scale. They grow when a run goes wrong;
- **conserved quantities** (mass, energy, momentum, charge): every value's
  card says how far it moved since the start;
- **extremes of key fields** (a minimum that collapses, a maximum that
  blows up) and the time step or CFL number (`cfl`, with `--cfl-limit`):
  early warnings;
- one or two quantities of physical interest, computed with `--derive`
  when the program writes only the parts (e.g. a distance from two
  positions: `'separation=hypot(x1-x2, y1-y2)'`).

`--monitor` (drawn on the run's card) must be one of the names you log.
If the program writes none of the useful values, adding output-only lines
to its input (more diagnostics, no change to the numerics) can help, but
ask the user first: it's their input file.

### Things to check

- **What do its exit codes mean?** Look at how earlier runs ended (the
  job's log, `sacct`). Some programs print an error and still exit 0: add
  `--error` with a pattern for their fatal lines (e.g. `'^ERROR|FATAL'`,
  as they actually appear). Some exit with a special code when they stop on
  purpose to continue in a new job (after writing a checkpoint near the
  wall-time limit): pass it as `--continue-code`, so the run doesn't show
  as crashed.
- **Does the run continue across several jobs** (restarts from
  checkpoints, chained jobs)? Give `--id` a fixed id from the first job on
  (e.g. the simulation's name; letters, digits, `.`, `_`, `-`, so turn `/`
  into `-`) and the same `SOLITON_DIR` in every job: the jobs appear as one
  run, continuing where the last one stopped, live again even if a job
  ended it as finished.
- **Is the job script generated by a tool** (a workflow manager or a
  templating system that writes and submits it)? Wrap the program's launch
  line in the template or run script the tool fills in, not the tool
  itself; keep the tool's own options and anything after the launch line.
  Prefer overriding a template in the user's own configuration to editing
  the tool's files. Mind the template language: find out which characters
  it substitutes (e.g. `@NAME@` in some tools, `{{ }}` and `{% %}` in
  Jinja) and escape them, or keep them out of your regular expressions, as
  that language requires. Characters it leaves alone, such as a shell's
  `$( )` in most templates, need nothing.
- **Is the wrapper the job script itself?** If it runs inside a tool's run
  script, after `time`, or code after it must still run, don't `exec` it.
  Slurm's early warning (`--signal=B:TERM@60`) then can't reach it; that's
  fine: the server marks the run "Stopped by its Slurm time limit" a minute
  after the limit.
- **Does the job's Python have h5py** (for `--h5`)? Check with
  `python3 -c 'import h5py'` in the same environment. On a cluster, look
  for a module (`ml spider h5py`) or use a Python environment that has it.
  Always prepend to `PYTHONPATH`: some codes' own launchers set it, and
  replacing it drops the logger or their packages.
- **How much does it write?** Each read logs at most `--max-rows` rows (200,
  evenly spread), output lines included; the default `--interval` is 15 s.

## 2d. Data

```python
ds = soliton.register_dataset(path, name="ns2d", version="v3", source="Simulated",
                              splits={"train": 8000, "val": 1000})
run = soliton.init(..., datasets=[ds])        # or a path
```

A run that writes data registers it with `run.register_dataset(path)` (or
`sim.`), so the app shows what made it. From a shell:
`python3 -m soliton data add PATH --version v1 --source Simulated`.

## 3. Where it runs

### Sherlock (Slurm)

Use the `sherlock` skill for cluster access; this skill only says what goes
in the job. One-time setup (check, don't redo): the logger and the wrapper on
Sherlock at `$HOME/soliton/logger` and `$HOME/soliton/monitor_solver.py`. If
missing, and the user has authorized Sherlock access, copy them from the
repository:
`rsync -a --exclude __pycache__ --exclude tests logger skills/claude-code/soliton/scripts/monitor_solver.py sherlock:soliton/`.

The server's address and token live in `~/.soliton_env` on the cluster. If
it's missing, set it up with the user: in a terminal they can type in (their
SSH session), run `python3 -m soliton setup --server <address>` (logger on
`PYTHONPATH`) and ask them to paste the token at its hidden prompt, from the
app (Settings → Advanced security → Separate token for jobs). Never ask for
the token in the chat. It checks the token, then writes the file privately.

In the job script:

```bash
#SBATCH --time=...
#SBATCH --signal=B:TERM@60              # 60 s warning before the time limit

ml python/3.12.1                        # any Python >= 3.9; or the env the job already uses
export PYTHONPATH="$HOME/soliton/logger/src${PYTHONPATH:+:$PYTHONPATH}"   # prepend, never replace
export SOLITON_DIR="$SCRATCH/soliton-runs"                               # local copy first
if [ -f "$HOME/soliton-server/env.sh" ]; then source "$HOME/soliton-server/env.sh"   # test server job
elif [ -f "$HOME/.soliton_env" ]; then source "$HOME/.soliton_env"                   # a public server
else export SOLITON_MODE=offline; fi

exec python3 train.py                    # exec: Python must be the job script to get SIGTERM
```

- When Python (or the wrapper) *is* the job script's last command, `exec`
  and `--signal=B:TERM@60` let a run stopped by the time limit say so
  itself. With the wrapper: `exec python3 $HOME/soliton/monitor_solver.py
  ... -- srun ./solver ...`. When it isn't (it runs inside a tool's run
  script, or the script does more after it), leave `exec` out, as in
  "Things to check" above: the server then marks the stop itself.
- Sherlock's compute nodes reach the internet and the test server, so runs
  report live. Offline runs (or if the server was down) upload later from a
  login node, by hand: `python3 -m soliton sync $SCRATCH/soliton-runs` (with
  `PYTHONPATH` set and the server's env sourced). Never in a loop.
- System metrics (CPU, memory against `--mem`, GPUs) are the whole job's,
  read from its cgroup: nothing to add.
- Job arrays: `name=f"sweep-{os.environ['SLURM_ARRAY_TASK_ID']}"` or the
  parameter values.
- Submit with `soliton sbatch` in place of `sbatch`, from a login node
  with `PYTHONPATH` set and the server's env sourced: soliton's options
  first, then sbatch's, unchanged (`python3 -m soliton sbatch --name
  fno-hires -p gpu -G 1 train.sbatch`). The job shows as Queued in the app
  while it waits, and the run its script starts takes its place. A job
  continuing a run passes that run's id first: `soliton sbatch --id <run
  id> ...`. `python3 -m soliton queue` updates what Slurm says of queued
  jobs: run it once when you check, never in a loop or `watch`. Each
  Soliton job also refreshes the other queued jobs once as it starts.
- Give `total_steps` (or a simulation's `t_end`): the app then warns the
  user, once per job, when the run won't finish before its time limit. It
  also tells them when a queued job starts, so there's no need to poll
  `squeue` for that.
- Plots drawn in the job (`run.log_image`): Sherlock's module needs its
  category first, `ml viz`, then `ml py-matplotlib/3.10.3_py312` (it brings
  Python 3.12 and NumPy); call `matplotlib.use("Agg")` before pyplot.
- When a job ends, the app's Resources card suggests `--mem`, `-c`, `-G`
  and `--time` for next time. If the user passes those on, use them in the
  next job script for the same computation.

### Modal, cloud machines, containers

The logger needs Python and outgoing HTTPS to a server reachable from the
internet; the test server inside Sherlock is not. Add the logger to the
image (`pip install /path/to/logger`, or copy `logger/src/soliton` onto
`PYTHONPATH`), pass `SOLITON_SERVER`/`SOLITON_TOKEN` as a secret (Modal:
`modal.Secret.from_name("soliton")`), and point `SOLITON_DIR` at a
persistent volume so offline runs survive the container. The host is
detected (Modal, AWS, GCP, ...). If there is no public server, use
`SOLITON_MODE=offline` and `soliton sync` from somewhere that can reach one.

### Locally

`SOLITON_SERVER=http://127.0.0.1:8000` and the token from
`soliton-server --show-token`, set by the user in their shell. The logger
and the wrapper are in the Soliton repository (`logger/src` on
`PYTHONPATH`, `skills/claude-code/soliton/scripts/monitor_solver.py`). Set `SOLITON_DIR`
explicitly (the default is `./soliton-runs` in the current directory) and
follow the project's own rules about where files may go. Outside Slurm and
containers, CPU and memory include the program only if `psutil` is
installed in the wrapper's Python; otherwise they cover the wrapper alone.

## 4. Check it works

Run a very short version first (a few hundred steps, a tiny grid, or the
real job with a short time limit) and check that the run arrived:

```bash
curl -s -H "Authorization: Bearer $SOLITON_TOKEN" "$SOLITON_SERVER/api/runs" | python3 -m json.tool | grep '"name"'
```

A 403 ("This is the job token") means `SOLITON_TOKEN` is the user's job
token (the app's Advanced security), which can add runs but not read them.
That's intended: don't ask for the main token. Check the upload instead: in
`$SOLITON_DIR/<run id>/`, `upload.json`'s `offset` reaches the size of
`events.jsonl`, and the job's output has no `soliton:` upload errors.

Offline: `$SOLITON_DIR/<run id>/events.jsonl` grows, and ends with a
`"status"` record. Then submit the real job, on a Slurm cluster with
`soliton sbatch <sbatch's options> job.sbatch` (in place of `sbatch`, with
`SOLITON_SERVER`/`SOLITON_TOKEN` set) so it shows as Queued while it waits;
for a job continuing a run, add `--id <run id>` before sbatch's options. Tell
the user the run's name and which app section it appears in (Runs, Compute
or Data).

## 5. Reading results back

Reading results back (analysis, figures, a results table, mean over seeds):
use `soliton.runs()` in Python on the user's machine, not the HTTP API by
hand and not screenshots of the app:

```python
import soliton                      # SOLITON_SERVER, and SOLITON_TOKEN = the main token

runs = soliton.runs(project="operator-learning", tags=["final"])   # newest first
for run in runs:
    curve = run.metric("val/rel_l2")                # every point logged, not thinned out
    plt.plot(curve.steps, curve.values, label=run.name)

table = runs.table(["val/rel_l2", "perf/inference_s"])   # one row per run
table.to_csv("results.csv")                              # or .to_pandas()
```

`run.config` holds the settings, `run.summary[name]` the first, final, min,
max and best of a metric, `soliton.get_run(id)` one run. A run with `thinned_at`
set was thinned out on the server (1,000 points per curve): say so if a
figure needs every point. It needs the main
token (the job token raises a `PermissionError` that says so): never put the
main token in a job script or ask for it in the chat; if the shell has the
job token, ask the user to run it where the main token is set.

Asked to back up the runs, use `soliton-server --backup <folder>` on the
server's machine (safe while the server runs, never overwrites a file), or
point the user to Settings → Storage → Download a backup; never `cp` the
live `soliton.db`, and keep the copy private (it holds everything logged).
