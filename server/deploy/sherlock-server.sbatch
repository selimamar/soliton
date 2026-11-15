#!/bin/bash
# A Soliton server for testing, in Sherlock's service partition (meant for
# lightweight servers). Training jobs reach it at the address it writes to
# $HOME/soliton-server/env.sh; the app reaches it through an SSH tunnel.
# Ends at its time limit and does not restart itself. Setup and use: see
# docs/sherlock.md ("A server on Sherlock, for testing"). Submit from
# $SCRATCH/soliton-server (the log goes there).
#SBATCH --job-name=soliton-server
#SBATCH --partition=service
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=1-00:00:00
#SBATCH --signal=B:USR1@120
#SBATCH --output=%x-%j.out

ml purge
ml python/3.12.1 || exit 1     # see `ml spider python`

APP="$HOME/soliton-server"          # code, environment, token
DATA="$SCRATCH/soliton-server"      # the database, between jobs
WORK="$L_SCRATCH_JOB/soliton"       # node-local while running: SQLite doesn't belong on a network filesystem
mkdir -p "$DATA" "$WORK"
export PIP_CACHE_DIR="$SCRATCH/.cache/pip"

if [ ! -x "$APP/venv/bin/python" ]; then
    echo "creating the environment in $APP/venv"
    python3 -m venv "$APP/venv" && "$APP/venv/bin/pip" install --quiet -r "$APP/requirements.txt" || exit 1
fi
PYTHON="$APP/venv/bin/python"

# One token for every job: made once, readable by you only.
if [ ! -s "$APP/token" ]; then
    (umask 077; "$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))' > "$APP/token")
fi
export SOLITON_TOKEN="$(cat "$APP/token")"
export SOLITON_DATA_DIR="$WORK"
export PYTHONPATH="$APP/src"

if [ -f "$DATA/soliton.db" ]; then
    cp "$DATA/soliton.db" "$WORK/soliton.db"
fi

PORT=$("$PYTHON" -c 'import socket; s = socket.socket(); s.bind(("", 0)); print(s.getsockname()[1])')
HOST=$(hostname)
"$PYTHON" -c 'from soliton_server.cli import main; main()' --host 0.0.0.0 --port "$PORT" &
SERVER=$!

# Where training jobs send their data (holds a token: readable by you only).
# With a job token (the app's Settings → Advanced security) saved in
# $APP/job-token, jobs get that one instead of the main token.
JOB_TOKEN="$SOLITON_TOKEN"
if [ -s "$APP/job-token" ]; then JOB_TOKEN="$(cat "$APP/job-token")"; fi
(umask 077; printf 'export SOLITON_SERVER=http://%s:%s\nexport SOLITON_TOKEN=%s\n' \
    "$HOST" "$PORT" "$JOB_TOKEN" > "$APP/env.sh")
echo "server on $HOST:$PORT (job $SLURM_JOB_ID); address in $APP/env.sh"

save() {
    kill "$SERVER" 2>/dev/null
    wait "$SERVER" 2>/dev/null
    rm -f "$APP/env.sh"
    "$PYTHON" -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("PRAGMA wal_checkpoint(TRUNCATE)"); c.close()' \
        "$WORK/soliton.db" && cp "$WORK/soliton.db" "$DATA/soliton.db.new" \
        && mv "$DATA/soliton.db.new" "$DATA/soliton.db" && echo "database saved to $DATA"
}
trap 'save; exit 0' USR1 TERM
wait "$SERVER"
save
