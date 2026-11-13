# Using ModelsApp with Sherlock

Train on Sherlock, watch on your phone. The logger runs inside your Slurm
job; the server runs somewhere else, since Sherlock can't host it (see
below).

```
Sherlock job + modelsapp logger  ──►  your server (public, HTTPS)  ◄──  ModelsApp
```

## 1. Put the server somewhere public

Sherlock's nodes "are not directly accessible from the outside"
([Concepts](https://www.sherlock.stanford.edu/docs/concepts/)), so they
can't host a server your phone could reach. Run `modelsapp-server` on a
small cloud VM or hosting platform instead, with HTTPS: see
[server/README.md](../server/README.md#putting-it-on-the-internet).

To try it out first, the server can run as a job inside Sherlock, and the app
on your computer reaches it through an SSH tunnel: see
[A server on Sherlock, for testing](#a-server-on-sherlock-for-testing).

## 2. Install the logger on Sherlock

On a login node, in the Python environment you train with (a venv, conda,
...), from a copy of this repository:

```bash
pip install ./logger
```

It has no dependencies of its own and needs Python 3.9 or newer.

Keep the server address and token in a private file, not in your scripts:

```bash
cat > ~/.modelsapp_env <<'EOF'
export MODELSAPP_SERVER=https://runs.example.com
export MODELSAPP_TOKEN=paste-the-token-here
EOF
chmod 600 ~/.modelsapp_env
```

## 3. Jobs can reach the internet

Tested on 2026-11-12 from a compute node in the `normal` partition: outgoing
HTTPS (and HTTP) connections work directly, with no proxy, so the logger can
upload while the job runs. Sherlock's own notes say compute nodes "may have
limited outbound network access", so check once that your server answers
from a compute node:

```bash
sh_dev                                    # an interactive session on a compute node
source ~/.modelsapp_env
curl -sS "$MODELSAPP_SERVER/api/health"   # {"status":"ok",...} means it works
```

Serve the API on the standard HTTPS port (443): only ports 443 and 80 were
tested. If a node ever can't connect, use offline mode (step 5).

## 4. A job script

```bash
#!/bin/bash
#SBATCH --job-name=resnet50
#SBATCH --partition=gpu
#SBATCH -G 1
#SBATCH --time=12:00:00
#SBATCH --output=%x-%j.out

source ~/.modelsapp_env                        # server and token
export MODELSAPP_DIR=$SCRATCH/modelsapp-runs   # where runs are saved first

python train.py                                # calls modelsapp.init(...), run.log(...)
```

Runs show "Sherlock" as their host (from Slurm's cluster name). The local
copy in `$SCRATCH` is only a buffer: the server keeps the run, and Sherlock
purges `$SCRATCH` files after 90 days without changes.

The run's System tab shows the node, its GPU, the job's cores and memory
limit, and GPU, memory and CPU use (of the whole job, DataLoader workers
included). Tested on 2026-11-12 on an RTX 2080 Ti node: the numbers matched
`nvidia-smi` and Slurm's own `seff` accounting.

**With Sherlock's PyTorch module** instead of your own environment:

```bash
ml math                        # the category first,
ml py-pytorch/2.10.0_py314     # then the module, in a separate command
export PYTHONPATH="$HOME/path/to/src${PYTHONPATH:+:$PYTHONPATH}"   # add to it, don't replace it
```

`ml math py-pytorch/...` in one command silently loads nothing, and
replacing `PYTHONPATH` hides the module's packages. PyTorch 2.10 doesn't
support the older GPUs in the `gpu` partition (TITAN Xp, P100), so ask for
a newer one with
`#SBATCH --constraint=GPU_CC:7.0|GPU_CC:7.5|GPU_CC:8.6|GPU_CC:8.9|GPU_CC:9.0`
(`sh_node_feat -p gpu` lists the features).

## 5. If a job can't reach your server

Run offline, then upload from a login node:

```bash
# in the job script
export MODELSAPP_MODE=offline
```

```bash
# on a login node, by hand, during or after the job
source ~/.modelsapp_env
modelsapp sync $SCRATCH/modelsapp-runs
```

`sync` sends only what's new, so running it again is harmless. Run it by hand:
Sherlock doesn't allow loops, `watch` or anything else that syncs
continuously on a login node. Between syncs more than 10 minutes apart, the
server shows the run as "lost contact"; the next sync brings it back to live.

## A server on Sherlock, for testing

Sherlock's public `service` partition is for lightweight servers
([Service jobs](https://www.sherlock.stanford.edu/docs/advanced-topics/service-jobs/)),
so `modelsapp-server` can run there as a job: training jobs send it data
live, and the app on your computer connects through an SSH tunnel while you
use it. Your phone can't reach it, and it stops at the job's time limit
(1 day in the script; the partition allows 2). Tested on 2026-11-12.

1. Copy the server over (from this repository, on your computer):

   ```bash
   rsync -a server/src server/deploy/requirements.txt server/deploy/sherlock-server.sbatch sherlock:modelsapp-server/
   ```

2. Start it (on a login node). The first job creates its Python environment
   in `$HOME/modelsapp-server/venv`, which takes a minute:

   ```bash
   mkdir -p $SCRATCH/modelsapp-server && cd $SCRATCH/modelsapp-server
   sbatch $HOME/modelsapp-server/sherlock-server.sbatch
   ```

   While it runs, `$HOME/modelsapp-server/env.sh` holds its address and token
   (readable by you only). The token itself is in `$HOME/modelsapp-server/token`
   and stays the same for every job.

3. In training job scripts, use it instead of `~/.modelsapp_env`:

   ```bash
   source $HOME/modelsapp-server/env.sh   # MODELSAPP_SERVER and MODELSAPP_TOKEN
   ```

4. Open a tunnel from your computer while you use the app, with the address
   from `env.sh` (e.g. `http://sh03-01n01.int:45678`), and close it (Ctrl-C)
   when you're done: Sherlock doesn't allow tunnels left running unattended.

   ```bash
   ssh -N -L 8100:NODE:PORT sherlock   # e.g. 8100:sh03-01n01.int:45678
   ```

5. In the app, Settings → Server: address `http://localhost:8100`, and the
   token (`ssh sherlock cat modelsapp-server/token`).

The database lives on the node's local disk while the server runs (SQLite
doesn't belong on a network filesystem) and is copied to
`$SCRATCH/modelsapp-server` when the job ends, for the next job to pick up.
A node failure loses what changed since that job started. Stop the server
with `scancel <job id>` (it saves the database first). Inside Sherlock the
token travels over plain HTTP on the cluster's network.

## When a job ends

- **Finishes:** shown as finished.
- **Python error** (e.g. CUDA out of memory): crashed, with the error.
- **Time limit or `scancel`:** Slurm sends SIGTERM. The logger marks the run
  as crashed ("Stopped by SIGTERM ...") and uploads for up to 15 seconds
  before the job ends (Slurm waits 30 seconds by default before it kills a
  job outright).
- **Killed outright** (out of memory, node failure): no chance to report. The
  server marks the run as crashed ("lost contact") after 10 minutes without
  data. If the run was offline, it shows whatever `sync` uploaded.

## What leaves Sherlock

Only what you log: metric values, hyperparameters, the model's layer names
and parameter counts, and per-layer summary statistics. Plus, from the
logger itself: the node's name, its GPU and CPU models, software versions,
the Slurm job's id, name and partition, and GPU, memory and CPU use every 15
seconds (turn the sampling off with `system_metrics=False`). No training data
or model weights. Run names and hyperparameters go to your server, so don't put
anything sensitive in them. Sherlock is approved for low- and moderate-risk
data only.
