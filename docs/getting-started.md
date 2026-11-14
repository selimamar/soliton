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
server's address and its token. The app checks them, remembers them, and
shows the server's runs from then on, updating live.

## 4. Make your computations report

### With a coding agent (the easy way)

Claude Code has a `soliton` skill: whenever it writes, edits or submits a
training script, a simulation or a job (for Sherlock, Modal or elsewhere),
it adds the monitoring by itself, checks it with a short run, and tells you
the run's name. Just ask for the computation, e.g. "run this solver on
Sherlock with 4 nodes". For other agents (Codex, ...), copy the block at the
end of [for-agents.md](for-agents.md) into your project's `AGENTS.md`.

Install the skill once, on the computer where you use Claude Code:

```bash
ln -s "$PWD/skills/soliton" ~/.claude/skills/soliton     # from this repository
```

### By hand

Install the logger in the environment the computation uses
(`pip install ./logger`, no dependencies), or put `logger/src` on
`PYTHONPATH`. Set the server in the environment, never in code:

```bash
export SOLITON_SERVER=https://runs.example.com
export SOLITON_TOKEN=...
```

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
python3 skills/soliton/scripts/monitor_solver.py --name channel-re180 --t-end 50 \
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

The [Sherlock guide](sherlock.md) has the rest (where the logger lives,
offline runs). The full logger API is in [logger/README.md](../logger/README.md).

## 5. What you see

- **Runs** (training), **Compute** (simulations), **Data** (datasets): the
  bar at the bottom, or the side on a wide screen. Each list has search and
  status filters (Live, Finished, Crashed).
- **A run's page**: Overview (progress, time left, queue wait and time
  limit for Slurm jobs, cost estimate, hyperparameters, tags and notes, what
  it printed), Metrics, Layers, Fields and System (the machine and how busy
  it kept it).
- **A simulation's page**: simulated time and time left, Diagnostics (every
  value against simulated time, drift of conserved quantities, the CFL
  number with its limit), Fields, System. A blow-up is marked: "Diverged at
  t = ...".
- **Statuses**: Live, Finished, Crashed (with the reason: the error,
  "Diverged", "Stopped by its Slurm time limit", or "Lost contact" when a
  job went silent for 10 minutes).
- **Alerts** while the app is open, when a run finishes or crashes. Phone
  notifications when it's closed need ntfy on the server
  ([server README](../server/README.md)).

## 6. Everyday things

- **Compare runs**: pick up to six on the runs list (the pick button, or a
  long press) and open Compare.
- **Organize**: tag runs and write notes on their Overview; group the list
  by project, model, dataset, tag or host; order it by a metric.
- **Sweeps**: the grid button on the runs list shows a project's runs over
  two hyperparameters, or one metric against another.
- **Delete** runs, simulations or datasets from their page, or several at
  once after picking them.
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
| Nothing updates | The tunnel to the Sherlock test server is closed, or its job ended: start them again |
