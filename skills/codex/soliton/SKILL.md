---
name: soliton
description: Add Soliton monitoring to computations so they can be followed live in the Soliton app. Use when writing, editing, wrapping or submitting a training script, a simulation or solver run, or a job script (Slurm/Sherlock, Modal, cloud, local), even if Soliton isn't mentioned. Not for unrelated code or analysis-only scripts.
---

# Soliton monitoring

Soliton shows training runs and simulations live in its app (phone,
computer, browser). A computation appears only if it reports through the
`soliton` Python logger. When you write, change or submit a computation,
add that reporting in the way that fits it, without changing what it
computes.

## Rules

1. Never write the server token anywhere: not in code, job scripts,
   configs, logs or your replies. Server and token come from the
   environment (`SOLITON_SERVER`, `SOLITON_TOKEN`), set by the user. If
   they're missing, the logger saves the run locally (offline): that's
   fine, don't work around it. `SOLITON_TOKEN` may be a job token that can
   add runs but not read them (403 on reads): fine too; never ask for the
   main token to get around it. If a cluster has no `~/.soliton_env`, have
   the user run `python3 -m soliton setup --server <address>` in their own
   terminal and paste the token at its hidden prompt, never in the chat
   (see references/where-it-runs.md). No secrets on the command line or in job
   scripts either: the logger records both (and the git commit) for rerunning
   from the app, hiding only values named like a token, password or key.
2. Don't change the science: same inputs, numerics and outputs. Don't catch
   exceptions to hide a crash. Don't replace NaN before logging it (the
   first NaN marks a simulation as diverged).
3. Keep logging cheap: scalars a few times per second at most, fields every
   few hundred steps; in fast GPU loops, log every 10–50 steps.
4. Don't log in to a cluster, submit jobs or contact a server unless the
   user asked for it. If the sandbox blocks network access (a check with
   `curl`, a copy with `rsync`), ask for approval; don't work around it.

## Steps

1. **Identify the kind of computation** and read the matching reference:

   | It is | Add | Reference |
   |---|---|---|
   | Training a model in Python | `soliton.init(...)`, `run.log(...)`, `run.watch(model)` | `references/recipes.md` |
   | A Python simulation or solver | `soliton.simulate(...)`, `sim.log(..., t=t)` | `references/recipes.md` |
   | Any other program (compiled solver, community code, MPI launch, shell pipeline) | launch it through `scripts/monitor_solver.py`, unchanged | `references/other-programs.md` |
   | Making or using a dataset | `soliton.register_dataset(path)` | `references/recipes.md` |

   A sweep or job array is one run per task: parameters in the name and in
   `config`/`setup`, one `project`, a tag such as `sweep-<name>`.

2. **Add the monitoring.** Short, descriptive names (`model-data-variant`);
   `project` for what it's about; `tags` for what makes this run different;
   `notes` for why it exists. Give the total (`total_steps`, `t_end`) when
   known, so the app shows progress and time left.

3. **Set up where it runs** (`references/where-it-runs.md`): the logger on
   `PYTHONPATH` or installed, `SOLITON_DIR` for the local copy, the
   server's environment. In Slurm job scripts: `#SBATCH --signal=B:TERM@60`
   and `exec python ...` when Python is the script's last command, so a
   time limit is reported. Submit with `soliton sbatch` (sbatch's options)
   so the job shows as Queued while it waits.

4. **Check it works** with a short version first (a few hundred steps, a
   coarse grid, a short time limit): the run is listed by the server
   (`curl -s -H "Authorization: Bearer $SOLITON_TOKEN" "$SOLITON_SERVER/api/runs"`;
   a 403 means a job token: check `$SOLITON_DIR/<run id>/upload.json`
   instead), or offline, `$SOLITON_DIR/<run id>/events.jsonl` grows and ends
   with a `"status"` record.

5. **Report back:** the run's name, where it reports (server or offline),
   and the app section it appears in (Runs, Compute or Data).

## Inputs and outputs

- Input: the computation (script, program or job) and where it will run.
- Output: the computation with monitoring added (or wrapped), its job
  script updated, a short test run, and a one-paragraph summary for the
  user.

## Resources

- `scripts/monitor_solver.py`: the wrapper for programs that aren't Python.
  `python3 scripts/monitor_solver.py --help` explains every option.
- The Soliton repository has the full reference (`docs/for-agents.md`) and
  the logger's API (`logger/README.md`), for anything these files don't
  cover.
