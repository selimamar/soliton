"""Slurm jobs still waiting in the queue, shown in the app before they start.

`soliton sbatch ...` submits a job as sbatch does and reports it to the
server as queued, with what Slurm says of it: why it waits (Priority,
Resources...), when Slurm expects to start it, and what it asked for. When
the job starts and its script calls soliton.init(), the new run takes its
place (the server matches the Slurm job id), or, with `--id`, the queued
run itself goes live (the script calling init(id=...) with that id).

`soliton queue` asks Slurm once about every job the server shows as queued
and updates them: still waiting (and why), or gone without starting
(cancelled, failed). It is one command, not a service: run it when you
check, so nothing keeps polling Slurm from a login node.
"""

from __future__ import annotations

import getpass
import os
import subprocess
import sys
from datetime import datetime, timezone, tzinfo
from typing import Callable, Dict, List, Mapping, Optional, Sequence, Tuple

OWN_OPTIONS = ("--name", "--project", "--id", "--server", "--token")

from ._system import _iso, _slurm_time
from ._util import RUN_ID, detect_host

# squeue's fields, in order: what `describe_job` reads.
SQUEUE_FIELDS = [
    ("%i", "jobId"), ("%j", "jobName"), ("%T", "state"), ("%r", "reason"),
    ("%V", "submitTime"), ("%S", "expectedStart"), ("%l", "timeLimit"),
    ("%P", "partition"), ("%C", "cpus"), ("%m", "memory"), ("%b", "gres"),
]
SQUEUE_FORMAT = "|".join(code for code, _ in SQUEUE_FIELDS)
_UNKNOWN = {"", "N/A", "n/a", "(null)", "None", "Unknown"}

Runner = Callable[..., "subprocess.CompletedProcess[str]"]


def submit(sbatch_args: Sequence[str], run: Runner = subprocess.run) -> Tuple[str, str]:
    """Runs sbatch; returns the job id and cluster ("" on a single cluster).
    Raises CalledProcessError (with sbatch's message) if sbatch refused."""
    result = run(["sbatch", "--parsable", *sbatch_args], capture_output=True, text=True)
    if result.returncode != 0:
        raise subprocess.CalledProcessError(result.returncode, "sbatch", result.stdout, result.stderr)
    last = (result.stdout or "").strip().splitlines()[-1:] or [""]
    job, _, cluster = last[0].strip().partition(";")
    if not job:
        raise subprocess.CalledProcessError(1, "sbatch", result.stdout, "sbatch printed no job id")
    return job, cluster


def queued_jobs(run: Runner = subprocess.run) -> Dict[str, Dict[str, str]]:
    """squeue's fields for each of your jobs, by job id (an array job by its
    own id). Raises OSError if squeue failed."""
    result = run(["squeue", "--me", "--noheader", "--format", SQUEUE_FORMAT],
                 capture_output=True, text=True)
    if result.returncode != 0:
        # Slurm before 20.11 has no --me.
        result = run(["squeue", "--user", getpass.getuser(), "--noheader", "--format",
                      SQUEUE_FORMAT], capture_output=True, text=True)
    if result.returncode != 0:
        raise OSError((result.stderr or "squeue failed").strip())
    return parse_squeue(result.stdout)


def parse_squeue(text: str) -> Dict[str, Dict[str, str]]:
    jobs: Dict[str, Dict[str, str]] = {}
    for line in text.splitlines():
        values = line.split("|")
        if len(values) != len(SQUEUE_FIELDS):
            continue
        fields = {name: value.strip() for (_, name), value in zip(SQUEUE_FIELDS, values)}
        job = base_job_id(fields["jobId"])
        # An array's pending tasks ("123_[4-10]") speak for the job.
        if job not in jobs or fields["state"] == "PENDING":
            jobs[job] = fields
    return jobs


def base_job_id(job: str) -> str:
    """"123" for "123", "123_4" or "123_[4-10]"."""
    return job.split("_", 1)[0].split(";", 1)[0]


def describe_job(fields: Dict[str, str], now: Optional[datetime] = None,
                 local: Optional[tzinfo] = None) -> Dict[str, str]:
    """What Slurm said of a job, as the app reads it (system.slurm): its
    times in UTC (squeue writes local times), what it asked for."""
    slurm: Dict[str, str] = {}
    for key in ("jobName", "state", "reason", "partition", "cpus", "timeLimit", "memory"):
        value = fields.get(key, "")
        if value not in _UNKNOWN:
            slurm[key] = value
    if "jobId" in fields:
        slurm["jobId"] = base_job_id(fields["jobId"])
    for key in ("submitTime", "expectedStart"):
        seconds = _slurm_time(fields.get(key), local)
        if seconds is not None:
            slurm[key] = _iso(seconds)
    gpus = gpu_count(fields.get("gres", ""))
    if gpus:
        slurm["gpus"] = str(gpus)
    slurm["queueCheckedAt"] = _iso((now or datetime.now(timezone.utc)).timestamp())
    return slurm


def gpu_count(gres: str) -> int:
    """GPUs from squeue's %b: "gres/gpu:2", "gpu:a100:2", "gres:gpu:1"; 0 if none."""
    total = 0
    for item in gres.split(","):
        parts = [p for p in item.replace("gres/", "").replace("gres:", "").split(":") if p]
        if parts and parts[0] == "gpu":
            count = parts[-1].split("(")[0]
            total += int(count) if count.isdigit() else 1
    return total


def queued_run(slurm: Dict[str, str], name: str, project: str = "",
               host: Optional[str] = None) -> dict:
    """The run the server shows while the job waits."""
    return {
        "name": name,
        "project": project,
        "host": host or detect_host(),
        "startedAt": slurm.get("submitTime"),
        "queued": True,
        "system": {"slurm": slurm},
    }


def run_id_for(job: str, given: Optional[str]) -> str:
    run_id = given or f"queued-{job}"
    if not RUN_ID.match(run_id):
        raise ValueError(f"invalid run id {run_id!r}: letters, digits, '.', '_' and '-' only")
    return run_id


# States in which a job may still start (or has, and its script soon logs).
WAITING_STATES = {"PENDING", "CONFIGURING", "RUNNING", "SUSPENDED", "REQUEUED",
                  "REQUEUE_HOLD", "REQUEUE_FED", "RESIZING", "SIGNALING", "STAGE_OUT"}

# Jobs gone from the queue: what sacct says became of them.
_ENDED = {
    "COMPLETED": ("finished", "The job finished without a run taking over: did its script call "
                              "soliton.init()?"),
    "CANCELLED": ("crashed", "Cancelled before it started."),
    "FAILED": ("crashed", "The job failed before its script started a run."),
    "TIMEOUT": ("crashed", "The job reached its time limit before its script started a run."),
    "OUT_OF_MEMORY": ("crashed", "The job ran out of memory before its script started a run."),
    "NODE_FAIL": ("crashed", "Its node failed before its script started a run."),
    "PREEMPTED": ("crashed", "Preempted before its script started a run."),
    "BOOT_FAIL": ("crashed", "Its node failed to boot."),
    "DEADLINE": ("crashed", "It missed its deadline (--deadline) and was cancelled."),
}


def job_state(job: str, run: Runner = subprocess.run) -> Tuple[Optional[str], Optional[str]]:
    """sacct's cluster and state of a job (e.g. ("sherlock", "CANCELLED by
    123")); (None, None) if this cluster's sacct doesn't know it."""
    result = run(["sacct", "--noheader", "--parsable2", "--allocations", "--jobs", job,
                  "--format", "Cluster,State"], capture_output=True, text=True)
    if result.returncode != 0:
        return None, None
    for line in result.stdout.splitlines():
        cluster, _, state = line.strip().partition("|")
        if state:
            return cluster or None, state
    return None, None


def job_cluster(job: str, run: Runner = subprocess.run) -> Optional[str]:
    """The cluster a job was submitted to, e.g. "sherlock" (from the job's
    own record: login nodes don't set SLURM_CLUSTER_NAME)."""
    try:
        result = run(["squeue", "--noheader", "--jobs", job, "--Format", "Cluster"],
                     capture_output=True, text=True)
    except OSError:
        return None
    cluster = (result.stdout or "").strip().split()[:1] if result.returncode == 0 else []
    return cluster[0] if cluster else job_state(job, run)[0]


def cluster_host(cluster: Optional[str]) -> str:
    """The host the app shows, as the job's logger will name it: its Slurm
    cluster ("Sherlock"), unless SOLITON_HOST says otherwise."""
    if os.environ.get("SOLITON_HOST"):
        return os.environ["SOLITON_HOST"]
    return cluster.capitalize() if cluster else detect_host()


def ended_status(state: Optional[str]) -> Optional[Tuple[str, str]]:
    """(status, message) for a job that left the queue as [state], or None
    while it may still start (or sacct doesn't know)."""
    if state is None:
        return None
    return _ENDED.get(state.split()[0].rstrip("+"))


def refresh(client, run: Runner = subprocess.run, now: Optional[datetime] = None,
            say: Callable[[str], None] = print, skip: Sequence[str] = ()) -> int:
    """`soliton queue`: updates every run the server shows as queued from
    one squeue call (your jobs on this cluster); a job no longer there ends
    as sacct says, if it was this cluster's. Jobs in [skip] are left alone.
    Returns how many it looked at."""
    waiting = [r for r in client.get_runs(status="queued")
               if r.get("status") == "queued"
               and ((r.get("system") or {}).get("slurm") or {}).get("jobId")
               and base_job_id(r["system"]["slurm"]["jobId"]) not in skip]
    if not waiting:
        say("soliton: no queued jobs on the server")
        return 0
    jobs = queued_jobs(run)
    for r in waiting:
        try:
            _refresh_one(client, r, jobs, run, now, say)
        except LookupError:
            pass  # Gone meanwhile: its job started and its run took its place.
    return len(waiting)


def _refresh_one(client, r: dict, jobs: Dict[str, Dict[str, str]], run: Runner,
                 now: Optional[datetime], say: Callable[[str], None]) -> None:
    """Updates one queued run, or ends it if its job left the queue."""
    slurm = dict(r["system"]["slurm"])
    job = base_job_id(slurm["jobId"])
    # squeue lists an ended job for a few minutes more (CANCELLED,
    # COMPLETING...): sacct says how it ended.
    if job in jobs and jobs[job]["state"] in WAITING_STATES:
        slurm.update(describe_job(jobs[job], now))
        client.put_run(r["id"], {**queued_run(slurm, r["name"], r.get("project", ""),
                                              r.get("host")),
                                 "startedAt": slurm.get("submitTime") or r.get("startedAt"),
                                 "updateOnly": True})
        reason = f" ({slurm['reason']})" if slurm.get("reason") else ""
        say(f"{r['name']} (job {job}): {slurm.get('state', 'PENDING').lower()}{reason}")
        return
    cluster, state = job_state(job, run)
    if cluster is None or (slurm.get("cluster") and slurm["cluster"] != cluster):
        say(f"{r['name']} (job {job}): not a job of this cluster's, left as it is")
        return
    ended = ended_status(state)
    if ended is None:
        say(f"{r['name']} (job {job}): not in the queue, and sacct says {state}")
        return
    status, message = ended
    event = {"type": "status", "status": status, "message": message}
    if state and state.startswith("CANCELLED"):
        event["notify"] = False  # You cancelled it: nothing to alert you about.
    client.post_events(r["id"], [event])
    say(f"{r['name']} (job {job}): {message}")


def refresh_at_job_start(client, env: Mapping[str, str] = os.environ,
                         run: Runner = subprocess.run) -> bool:
    """A job's logger refreshing the queue as the job starts (see
    `_refresh_queue_once`): its own job is skipped (its run takes its
    place), and in an array only the first task does it. Returns whether
    it did."""
    if not env.get("SLURM_JOB_ID") or env.get("SOLITON_REFRESH_QUEUE", "").strip() == "0":
        return False
    task, first = env.get("SLURM_ARRAY_TASK_ID"), env.get("SLURM_ARRAY_TASK_MIN")
    if task is not None and first is not None and task != first:
        return False
    own = {base_job_id(env[key]) for key in ("SLURM_JOB_ID", "SLURM_ARRAY_JOB_ID") if env.get(key)}
    refresh(client, run, say=lambda _: None, skip=sorted(own))
    return True


def sbatch_main(args, client_or_none, run: Runner = subprocess.run,
                say: Callable[[str], None] = print) -> int:
    """`soliton sbatch`: submits, then reports the job as queued."""
    try:
        job, cluster = submit(args.sbatch_args, run)
    except subprocess.CalledProcessError as error:
        sys.stderr.write(error.stderr or "")
        return error.returncode or 1
    except FileNotFoundError:
        print("soliton: sbatch not found: run this where you submit Slurm jobs", file=sys.stderr)
        return 1
    say(f"Submitted batch job {job}" + (f" on cluster {cluster}" if cluster else ""))
    if client_or_none is None:
        print("soliton: not reported as queued: set SOLITON_SERVER and SOLITON_TOKEN",
              file=sys.stderr)
        return 0
    try:
        fields = queued_jobs(run).get(job, {"jobId": job})
    except OSError:
        fields = {"jobId": job}
    slurm = describe_job(fields)
    slurm["jobId"] = job
    cluster = cluster or job_cluster(job, run)
    if cluster:
        slurm["cluster"] = cluster
    name = args.name or slurm.get("jobName") or f"job {job}"
    try:
        run_id = run_id_for(job, args.id)
        # With --id, the job continues that run from here: the key its
        # logger will find (and send) in the run's folder.
        key = run_key_for(run_id) if args.id else None
        client_or_none.put_run(run_id, queued_run(slurm, name, args.project or "",
                                                  cluster_host(cluster)), key)
    except Exception as error:  # The job is submitted either way.
        print(f"soliton: job {job} is submitted, but not shown as queued: {error}", file=sys.stderr)
        return 0
    say(f"soliton: {name} shows as queued in the app (run {run_id}); `soliton queue` updates it")
    return 0



def run_key_for(run_id: str) -> str:
    """The key of run [run_id], as a job run from this directory finds it."""
    from pathlib import Path

    from ._upload import RunFiles

    return RunFiles(Path(os.environ.get("SOLITON_DIR") or "soliton-runs") / run_id).run_key()


def split_sbatch_args(argv: List[str]) -> Tuple[Dict[str, str], List[str]]:
    """soliton's own options (before anything else), and the rest for
    sbatch: `soliton sbatch --name x -p gpu job.sh --name y` passes
    `-p gpu job.sh --name y` on (the job script's own arguments included).
    A `--` ends soliton's options."""
    own: Dict[str, str] = {}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            i += 1
            break
        key, eq, value = arg.partition("=")
        if key not in OWN_OPTIONS:
            break
        if not eq:
            if i + 1 >= len(argv):
                raise ValueError(f"{key} needs a value")
            value = argv[i + 1]
            i += 1
        own[key[2:]] = value
        i += 1
    return own, argv[i:]
