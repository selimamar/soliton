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

umask 077                      # the database, its copies and the tokens: yours only
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

# Jobs get the job token, never the main one: it can only add and update
# runs (not read, delete or rotate anything). The one in $APP/job-token is
# kept while the server accepts it; otherwise a new one is made there.
"$PYTHON" - "$PORT" "$APP/job-token" <<'PY' || echo "warning: no job token; jobs get the main token"
import json, os, sys, time, urllib.error, urllib.request
base, path = f"http://127.0.0.1:{sys.argv[1]}/api", sys.argv[2]

def call(method, route, token):
    request = urllib.request.Request(base + route, method=method,
                                     headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.read()

for _ in range(120):  # The server starts in the background.
    try:
        urllib.request.urlopen(base + "/health", timeout=2)
        break
    except OSError:
        time.sleep(1)
else:
    sys.exit("the server didn't start")
try:
    saved = open(path).read().strip()
except FileNotFoundError:
    saved = ""
if saved:
    try:
        call("GET", "/runs?status=queued", saved)
        sys.exit(0)  # Still accepted.
    except urllib.error.HTTPError:
        pass
token = json.loads(call("POST", "/job-token", os.environ["SOLITON_TOKEN"]))["token"]
os.umask(0o077)
with open(path + ".new", "w") as file:
    file.write(token + "\n")
os.replace(path + ".new", path)
print(f"made a new job token in {path}")
PY
JOB_TOKEN="$SOLITON_TOKEN"
if [ -s "$APP/job-token" ]; then JOB_TOKEN="$(cat "$APP/job-token")"; fi

# Where training jobs send their data (holds the job token: readable by you only).
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
    # And a backup in $HOME, which Sherlock backs up and never purges
    # ($SCRATCH is neither): one per server job, the 10 latest kept.
    (umask 077; mkdir -p "$APP/backups") \
        && "$PYTHON" -c 'from soliton_server.cli import main; main()' --backup "$APP/backups/" \
        && ls -1t "$APP/backups"/soliton-*.db | tail -n +11 | xargs -r rm -f --
}
trap 'save; exit 0' USR1 TERM
wait "$SERVER"
save
