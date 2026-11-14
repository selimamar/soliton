#!/bin/bash
# One scenario of check.py, reporting live to the Soliton test server job
# (server/deploy/sherlock-server.sbatch). Resources go on the command line,
# per scenario (see README.md next to this file, with what the app should show):
#   sbatch -J appcheck-train -c 2 --mem=4G --time=00:20:00 check.sbatch train
# Submit from $SCRATCH/soliton-appcheck (logs go to logs/).
#SBATCH --output=logs/%x-%j.out

SCENARIO="$1"
ml purge
# The category first, then the module: in one command the module isn't found.
ml math
ml py-pytorch/2.10.0_py314 || exit 1

# Prepend: the PyTorch module put its packages on PYTHONPATH.
export PYTHONPATH="$HOME/soliton-appcheck/logger/src${PYTHONPATH:+:$PYTHONPATH}"
export SOLITON_DIR="$SCRATCH/soliton-appcheck/runs"
source "$HOME/soliton-server/env.sh" || { echo "the server job isn't running"; exit 1; }

echo "== $SCENARIO: node $(hostname), job $SLURM_JOB_ID, CPUs $SLURM_CPUS_PER_TASK, GPUs ${CUDA_VISIBLE_DEVICES:-none}, $(date -u +%FT%TZ)"
if [ -z "$CUDA_VISIBLE_DEVICES" ]; then
    # exec: Python becomes the batch shell, so `--signal=B:TERM@60` reaches it.
    exec python3 "$HOME/soliton-appcheck/check.py" "$SCENARIO"
else
    # Ground truth for the GPU readings, every 15 s like the logger.
    nvidia-smi --query-gpu=timestamp,index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \
        --format=csv -l 15 > "logs/nvsmi-$SLURM_JOB_ID.csv" &
    SAMPLER=$!
fi
python3 "$HOME/soliton-appcheck/check.py" "$SCENARIO"
STATUS=$?
[ -n "$SAMPLER" ] && kill "$SAMPLER"
echo "== exit $STATUS, $(date -u +%FT%TZ)"
exit $STATUS
