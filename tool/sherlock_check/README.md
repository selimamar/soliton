# Checking Soliton on Sherlock with real jobs

Small Slurm jobs that report live to the test server
([docs/sherlock.md](../../docs/sherlock.md#a-server-on-sherlock-for-testing)),
each with markers at known times, so what the app shows can be checked
against what really happened: `nvidia-smi`, `sacct`/`seff`, and the
process's own measurements, which `check.py` prints on a line starting
with `TRUTH` at the end.

Each scenario does about 10 minutes of real work (`CHECK_MINUTES`):
Sherlock asks for jobs of at least 10 minutes.

| Scenario | Resources | What the app should show |
|---|---|---|
| `train` | 2 CPUs, 4 GB, 20 min | Finished. CPU 100% of 2 cores, then 50% from halfway; memory +1 GiB from halfway. A dataset in Data, "Used by 1 run" |
| `crash` | 1 CPU, 4 GB, 20 min | Crashed: "RuntimeError: Deliberate crash ...", with the traceback. Memory +1.5 GiB from halfway. No epoch or step total ("Step 2,390 · Epoch 341") |
| `timeout` | 1 CPU, 2 GB, **12 min** | In Compute. While live: "Slurm will stop it first". Then crashed: "Stopped by its Slurm time limit" |
| `diverge` | 1 CPU, 2 GB, 20 min | In Compute. Crashed: "Diverged at t = ...: energy is infinite", marked on the charts |
| `gpu` | 1 GPU, 2 CPUs, 8 GB, 20 min | Finished. GPU memory +2 GiB from halfway, matching `logs/nvsmi-<job>.csv`; 12 field snapshots |

## Running them

On your computer, from this repository (the server must already be
running, see the link above):

```bash
rsync -a --exclude __pycache__ --exclude tests logger tool/sherlock_check/check.py tool/sherlock_check/check.sbatch sherlock:soliton-appcheck/
```

On a Sherlock login node:

```bash
mkdir -p $SCRATCH/soliton-appcheck/logs && cd $SCRATCH/soliton-appcheck
S=$HOME/soliton-appcheck/check.sbatch
sbatch -J appcheck-train   -p normal -c 2 --mem=4G --time=00:20:00 $S train
sbatch -J appcheck-crash   -p normal -c 1 --mem=4G --time=00:20:00 $S crash
sbatch -J appcheck-timeout -p normal -c 1 --mem=2G --time=00:12:00 $S timeout
sbatch -J appcheck-diverge -p normal -c 1 --mem=2G --time=00:20:00 $S diverge
sbatch -J appcheck-gpu -p gpu -G 1 -c 2 --mem=8G --time=00:20:00 \
    "--constraint=GPU_CC:7.0|GPU_CC:7.5|GPU_CC:8.6|GPU_CC:8.9|GPU_CC:9.0" $S gpu
```

Add `--signal=B:TERM@60` to the `timeout` job to check the early warning
too: it then stops a minute before its limit.

Afterwards, compare with Slurm's own numbers:

```bash
sacct -j <job ids> -X -o JobID,JobName%18,State,Submit,Start,End,Elapsed,AllocCPUS
seff <job id>
grep -h '^TRUTH' logs/appcheck-*.out
```

Results of the 2026-11-14 run: CPU, memory and GPU readings matched
within about 2%, and job times matched `scontrol` to the second. The
app's memory reads lower than `seff`'s "Memory Utilized" (see
[docs/sherlock.md](../../docs/sherlock.md#4-a-job-script)).

Clean up when done: `rm -r $SCRATCH/soliton-appcheck/runs` (the server
keeps the runs) and delete the `appcheck-*` runs in the app.
