# Where it runs, and checking it works

## Sherlock (Slurm)

Don't log in to a cluster or submit jobs unless the user asked you to; this
only says what goes in the job. One-time setup (check, don't redo): the logger and the wrapper on
Sherlock at `$HOME/soliton/logger` and `$HOME/soliton/monitor_solver.py`. If
missing, and the user has authorized Sherlock access, copy them from the
repository:
`rsync -a --exclude __pycache__ --exclude tests logger skills/codex/soliton/scripts/monitor_solver.py sherlock:soliton/`.

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
  "Things to check" in `references/other-programs.md`: the server then
  marks the stop itself.
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
  jobs: run it once when you check, never in a loop or `watch`.
- Give `total_steps` (or a simulation's `t_end`): the app then warns the
  user, once per job, when the run won't finish before its time limit.
- When a job ends, the app's Resources card suggests `--mem`, `-c`, `-G`
  and `--time` for next time. If the user passes those on, use them in the
  next job script for the same computation.

## Modal, cloud machines, containers

The logger needs Python and outgoing HTTPS to a server reachable from the
internet; the test server inside Sherlock is not. Add the logger to the
image (`pip install /path/to/logger`, or copy `logger/src/soliton` onto
`PYTHONPATH`), pass `SOLITON_SERVER`/`SOLITON_TOKEN` as a secret (Modal:
`modal.Secret.from_name("soliton")`), and point `SOLITON_DIR` at a
persistent volume so offline runs survive the container. The host is
detected (Modal, AWS, GCP, ...). If there is no public server, use
`SOLITON_MODE=offline` and `soliton sync` from somewhere that can reach one.

## Locally

`SOLITON_SERVER=http://127.0.0.1:8000` and the token from
`soliton-server --show-token`, set by the user in their shell. The logger
and the wrapper are in the Soliton repository (`logger/src` on
`PYTHONPATH`, and this skill's `scripts/monitor_solver.py`). Set `SOLITON_DIR`
explicitly (the default is `./soliton-runs` in the current directory) and
follow the project's own rules about where files may go. Outside Slurm and
containers, CPU and memory include the program only if `psutil` is
installed in the wrapper's Python; otherwise they cover the wrapper alone.

## Check it works

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
