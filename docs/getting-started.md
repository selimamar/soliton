# Getting started with Soliton

Soliton lets you follow your computations while they run: training runs,
simulations and solver jobs, on Sherlock, in the cloud or on your own
computer. You see their progress, curves, fields, the machine they use and
what they print, on your phone or computer, and you get an alert when one
finishes or crashes.

It has three parts:

- **The logger**, a small Python package that your computation calls (or
  that wraps it). It saves everything locally first, then uploads.
- **The server**, which keeps the runs.
- **The app**, which shows them.

```
your job + logger  ──►  server  ◄──  the app (phone, tablet, Mac, browser)
```

## 1. Open the app

From this repository, after the one-time setup in the
[README](../README.md#setting-up-everything-stays-in-this-folder):

```bash
source env.sh
tool/run_web.sh          # in a browser, at http://localhost:8787
```

`flutter run -d macos` opens it as a Mac app, and `flutter run` puts it on a
connected phone. With no server connected, the app is empty and says "Not
connected to a server". To look around first, turn on **Settings → Demo
data**: made-up runs to explore every screen.

## 2. Have a server

Pick the one that fits:

| Server | For | How |
|---|---|---|
| On your computer | Trying it; runs on your computer | `soliton-server` (address `http://127.0.0.1:8000`, token from `soliton-server --show-token`) |
| A test server on Sherlock | Sherlock jobs, followed from your computer | A job in Sherlock's `service` partition, reached through an SSH tunnel: [Sherlock guide](sherlock.md#a-server-on-sherlock-for-testing) |
| A public server | Everything, including your phone and Modal or cloud jobs | A small cloud machine with HTTPS: [server README](../server/README.md#putting-it-on-the-internet) |

The Sherlock test server in short: start it with
`sbatch $HOME/soliton-server/sherlock-server.sbatch` from
`$SCRATCH/soliton-server`. While it runs, `$HOME/soliton-server/env.sh` has
its address. From your computer, open a tunnel while you use the app
(`ssh -N -L 8100:NODE:PORT sherlock`, Ctrl-C when done), and use
`http://localhost:8100` as the address.

## 3. Connect the app

**Settings → Server** (or **Connect server** on the runs list): the
server's address and its token, and a name if you like. The app checks
them, remembers them, and shows the server's runs from then on, updating
live. Add more servers the same way (a lab server, the Sherlock test
server, one on your laptop): they're listed on that screen, and tapping one
shows its runs instead. Each keeps its own token; rename or remove them from
their menu. With two or more, **All servers** at the top of that list shows
every server's runs together, live: each run's host starts with its server's
name ("Lab · Sherlock"), and stopping, deleting or tagging a run goes to its
own server. A server that can't be reached is named above the list, and its
runs are left out until it's back. Advanced security (tokens) is per server:
pick one to manage it. The token is kept in
the Keychain (iPhone, iPad, Mac) or the Android Keystore, not with the other
settings; in a browser there is no secure place for it. On a Mac, a newly
built app may ask once to use the keychain.

**Optional, for more safety:** Settings → **Advanced security** →
**Separate token for jobs**. The server makes a second token, shown once,
for your job scripts and cluster files: it can only add and update runs and
data, not read your runs, change tags and notes or delete anything. Use it as
`SOLITON_TOKEN` on clusters and keep the main token on your own devices.
If the main token may have leaked, **New main token** there replaces it: the
old one stops working everywhere, and this device switches to the new one.

## 4. Make your computations report

### With a coding agent (the easy way)

Claude Code and Codex each have a `soliton` skill: whenever the agent
writes, edits or submits a training script, a simulation or a job (for
Sherlock, Modal or elsewhere), it adds the monitoring by itself, checks it
with a short run, and tells you the run's name. Just ask for the
computation, e.g. "run this solver on Sherlock with 4 nodes".

Install the skill once, on the computer where you use the agent (from this
repository):

```bash
ln -s "$PWD/skills/claude-code/soliton" ~/.claude/skills/soliton    # Claude Code
ln -s "$PWD/skills/codex/soliton" ~/.agents/skills/soliton          # Codex
```

[skills/README.md](../skills/README.md) has the details. For other agents,
copy the block at the end of [for-agents.md](for-agents.md) into your
project's `AGENTS.md`.

### By hand

Install the logger in the environment the computation uses
(`pip install ./logger`, no dependencies), or put `logger/src` on
`PYTHONPATH`. Then tell each machine where the server is, once:

```bash
soliton setup --server https://runs.example.com    # or: python3 -m soliton setup ...
```

It asks for the token without showing it, checks it with the server, and
saves both in `~/.soliton_env` (readable by you only); job scripts then
`source ~/.soliton_env`. Which token: the app has the server's main token
(step 3); for a cluster, make a job token in the app (Settings → Advanced
security → Separate token for jobs), copy it, and paste that. With the main
token it works too, but it can do everything.

**A training script:**

```python
import soliton

with soliton.init("resnet50-cifar", project="classification", config=hparams,
                  total_steps=50_000) as run:
    run.watch(model)                                  # PyTorch: layers, network diagram
    for step, (x, y) in enumerate(loader):
        ...
        run.log({"train/loss": loss, "optim/lr": lr}, step=step)
```

**A simulation in Python:**

```python
with soliton.simulate("kh-2048", project="turbulence", t_end=10,
                      setup={"grid": "2048 x 2048", "Re": 1e4}, monitor="energy") as sim:
    while t < 10:
        ...
        sim.log({"energy": E, "cfl": cfl}, t=t, dt=dt)
```

**Any other program** (a compiled solver, an MPI job): don't change it;
launch it through the wrapper, telling it which output files or lines hold
the values to follow:

```bash
python3 skills/claude-code/soliton/scripts/monitor_solver.py --name channel-re180 --t-end 50 \
    --table 'run/diagnostics.dat,t=2,energy=3,residual=5' \
    -- srun ./solver input.cfg
```

Here the solver appends a row to `run/diagnostics.dat` at each output time,
with the time in column 2 and the energy and residual in columns 3 and 5.
The wrapper can also read HDF5 tables and the progress lines the program
prints (`--help` explains).

**On Sherlock**, three lines in the job script matter:

```bash
#SBATCH --signal=B:TERM@60                 # so a time limit is reported
export SOLITON_DIR=$SCRATCH/soliton-runs   # the local copy, on scratch
exec python3 train.py                      # exec, for the same reason
```

Submit with `soliton sbatch` in place of `sbatch` (same options) to see the
job while it waits in the queue, and `soliton queue` to update what Slurm
says of waiting jobs (each starting Soliton job also does it once):

```bash
python3 -m soliton sbatch -p gpu -G 1 train.sbatch
python3 -m soliton queue
```

The [Sherlock guide](sherlock.md) has the rest (where the logger lives,
offline runs). The full logger API is in [logger/README.md](../logger/README.md).

## 5. What you see

- **Runs** (training), **Compute** (simulations), **Data** (datasets): the
  bar at the bottom, or the side on a wide screen. Each list has search and
  status filters (Queued, while some are; Live, Finished, Crashed).
- **A queued job** (from `soliton sbatch`): how long it has waited, why in
  plain words (Priority, Resources, a limit), when Slurm expects to start it
  ("Not estimated" until it's near the front), and what it asked for. It
  turns into the run when its script starts logging.
- **A run's page**: Overview (progress, time left, queue wait and time
  limit for Slurm jobs, cost estimate, hyperparameters, tags and notes, what
  it printed), Metrics, Layers, Fields and System (the machine and how busy
  it kept it).
- **Continued runs** (several jobs, from checkpoints): a Jobs card on the
  Overview lists each job (Slurm id, queue wait, run time, steps, how it
  ended), and the Metrics charts mark where each later job took over.
- **Reproduce**, on the System tab: the git commit, the files with
  uncommitted changes, the command, the job script and the packages, with a
  button that copies the command to rerun.
- **Resources**, on an ended Slurm job's Overview: memory, CPUs, GPUs and
  time it used against what it asked for, and the sbatch options to ask for
  next time (e.g. `--mem=16G -c 4 --time=03:00:00`, with a copy button), or a
  warning when it came close to a limit. Smaller requests start sooner.
- **A simulation's page**: simulated time and time left, Diagnostics (every
  value against simulated time, drift of conserved quantities, the CFL
  number with its limit), Fields, System. A blow-up is marked: "Diverged at
  t = ...".
- **Statuses**: Queued, Live, Finished, Crashed (with the reason: the
  error, "Diverged", "Stopped by its Slurm time limit", "Lost contact" when
  a job went silent for 10 minutes, or "Cancelled before it started").
- **Training health**: a warning at the top of a run's Overview when its
  loss turns NaN, its training loss climbs back up, or its gradient norm
  (log `optim/grad_norm`) blows up, with what usually helps.
- **Alerts** while the app is open, when a run finishes or crashes, when a
  live run, at its pace, won't finish before its Slurm time limit (once per
  job, while there's time to save a checkpoint), when training goes wrong,
  and when a queued Slurm job starts (after `soliton sbatch`, or a wait of
  10 minutes or more). Each can be turned off in Settings. Phone
  notifications when it's closed need ntfy on the server
  ([server README](../server/README.md)).

## 6. Everyday things

- **Compare runs**: pick up to six on the runs list (the pick button, or a
  long press) and open Compare: their curves together, and "Settings that
  differ", only the hyperparameters that changed between them.
- **Organize**: tag runs and write notes on their Overview; group the list
  by project, model, dataset, tag or host; order it by a metric.
- **The farm**: the egg button on the runs list shows the runs as a farm,
  finished runs as animals as big as their models, live runs as eggs that
  hatch when they finish. Pick an animal for each model family (a moose for
  your FNOs, say) in Settings → Farm, or from the farm's own settings
  button. The farm follows the clock and the seasons; set your hemisphere
  there, or keep it always day or always night.
- **Sweeps**: the grid button on the runs list shows a project's runs over
  two hyperparameters, or one metric against another.
- **Delete** runs, simulations or datasets from their page, or several at
  once after picking them.
- **Keep storage in check**: Settings → Storage shows how much space each
  run takes on the server. Thin out old ended runs there: they look the same
  in the app (each curve keeps 1,000 points, each field its latest snapshot)
  but take a fraction of the space. Then "Give back" returns it to the disk.
- **Right-size the next job**: copy the options from an ended job's
  Resources card into the next sbatch.
- **Stop a run cleanly**: the stop button on a live run's page. If its
  script checks `run.should_stop()` (the agent skills add it), it saves a
  checkpoint and ends as "Stopped from the app"; otherwise it is stopped as
  by scancel. Continue it later in a new job with `soliton sbatch --id`.
- **Analyse results, make figures**: in Python on your computer, with the
  server's main token, `soliton.runs(...)` reads runs back: every point of
  any metric, and a table of final and best values per run (see the
  [logger README](../logger/README.md#reading-runs-back-solitonruns)).
- **Offline runs** (no server, or it was unreachable) upload later:
  `soliton sync $SOLITON_DIR` (on Sherlock: `python3 -m soliton sync
  $SCRATCH/soliton-runs`, by hand on a login node).

## When something's off

| You see | Why, and what to do |
|---|---|
| The run isn't in the app | The job didn't have `SOLITON_SERVER`/`SOLITON_TOKEN`, or couldn't reach the server: the run is saved in `SOLITON_DIR`; `soliton sync` uploads it |
| "Lost contact" | The job stopped sending for 10 minutes: killed (out of memory, node failure) or lost its network. It turns live again if data arrives |
| Crashed at the time limit with no message, or only after 10 minutes | The job script runs `python` without `exec`, or lacks `--signal=B:TERM@60` |
| "The server rejected the token" | The token changed or was mistyped: Settings → Server |
| A continued run's job gets 403 with the job token | It can't find the run's key: run it with the same `SOLITON_DIR` as the first job (the key is in `<SOLITON_DIR>/<run id>/key`), or set `SOLITON_RUN_KEY` to that file's contents |
| "That's the job token" | The app needs the server's main token; the job token is for job scripts |
| A queued job doesn't move on | What Slurm says is as of `soliton sbatch`, the last `soliton queue`, or the last Soliton job that started: run `soliton queue`. The wait itself counts up by itself |
| "Asked to stop" stays | The script doesn't log often, or checks `run.should_stop()` rarely: it stops at its next check (or next log, for a script that never checks) |
| A training-health warning you don't believe | The checks are deliberately loose (10 times the lowest loss, back to the starting loss, a gradient norm 10 times its usual size for 5 logs in a row), but a loss that can rise on purpose (a curriculum, a restart) may still set one off. `SOLITON_HEALTH=0` turns them off for a job |
| No time-limit alert | It comes once the run has gone 10 minutes and 2% of the way, and only if it would miss the limit by more than 5 minutes; it needs `total_steps` (or a simulation's `t_end`) |
| The server won't start: "the database is at version N, newer than this server knows" | A newer server already upgraded that database: update the server (`git pull`, then restart it) |
| Reproduce says "Uncommitted changes" | The code wasn't committed when the run started, so its commit alone may not reproduce it: commit before long runs |
| The Mac app asks to use the keychain | Once after the app was rebuilt (it is signed without a developer team): Always Allow |
| Nothing updates | The tunnel to the Sherlock test server is closed, or its job ended: start them again |
