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

Offline: `$SOLITON_DIR/<run id>/events.jsonl` grows, and ends with a
`"status"` record. Then submit the real job. Tell the user the run's name
and which app section it appears in (Runs, Compute or Data).
