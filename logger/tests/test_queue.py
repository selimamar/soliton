"""`soliton sbatch` and `soliton queue`, against a fake Slurm and server."""

import subprocess
from argparse import Namespace
from datetime import datetime, timedelta, timezone

import pytest

from soliton._queue import (
    SQUEUE_FORMAT, describe_job, ended_status, gpu_count, parse_squeue, refresh, sbatch_main,
    split_sbatch_args, submit,
)

PACIFIC = timezone(timedelta(hours=-8))
NOW = datetime(2026, 11, 14, 20, 0, tzinfo=timezone.utc)
# What squeue --me prints with SQUEUE_FORMAT: a pending job, a pending
# array (its running task too), and a running job.
SQUEUE = "\n".join([
    "52340117|fno-hires|PENDING|Priority|2026-11-14T10:05:12|N/A|1-00:00:00|gpu|8|64G|gres/gpu:1",
    "52340200_[2-10]|sweep|PENDING|Resources|2026-11-14T11:00:00|2026-11-14T13:30:00|2:00:00|normal|1|4000M|N/A",
    "52340200_1|sweep|RUNNING|None|2026-11-14T11:00:00|2026-11-14T11:01:00|2:00:00|normal|1|4000M|N/A",
    "52340300|other|RUNNING|None|2026-11-14T09:00:00|2026-11-14T09:02:00|4:00:00|normal|2|8G|N/A",
])


class FakeSlurm:
    def __init__(self, squeue=SQUEUE, sacct=None, sbatch="52340117\n", sbatch_code=0):
        self.squeue, self.sacct, self.sbatch, self.sbatch_code = squeue, sacct or {}, sbatch, sbatch_code
        self.calls = []

    def __call__(self, command, capture_output=True, text=True):
        self.calls.append(command)
        if command[0] == "sbatch":
            return subprocess.CompletedProcess(command, self.sbatch_code, self.sbatch,
                                               "sbatch: error: invalid partition\n")
        if command[0] == "squeue" and "--Format" in command:
            return subprocess.CompletedProcess(command, 0, "sherlock            \n", "")
        if command[0] == "squeue":
            assert command[-1] == SQUEUE_FORMAT
            return subprocess.CompletedProcess(command, 0, self.squeue, "")
        if command[0] == "sacct":
            job = command[command.index("--jobs") + 1]
            return subprocess.CompletedProcess(command, 0, self.sacct.get(job, ""), "")
        raise AssertionError(command)


class FakeServer:
    def __init__(self, runs=()):
        self.runs, self.puts, self.events = list(runs), [], []

    def get_runs(self, status=None):
        assert status == "queued", "a job token may only list queued runs"
        return self.runs

    def put_run(self, run_id, body, run_key=None):
        self.puts.append((run_id, body))

    def post_events(self, run_id, events, run_key=None):
        self.events.append((run_id, events))


def test_squeue_lines_by_job_with_an_arrays_pending_tasks_speaking_for_it():
    jobs = parse_squeue(SQUEUE)
    assert set(jobs) == {"52340117", "52340200", "52340300"}
    assert jobs["52340200"]["state"] == "PENDING"
    assert jobs["52340117"]["gres"] == "gres/gpu:1"


def test_what_slurm_says_of_a_job_in_utc_and_what_it_asked_for():
    slurm = describe_job(parse_squeue(SQUEUE)["52340117"], NOW, PACIFIC)
    assert slurm == {
        "jobId": "52340117", "jobName": "fno-hires", "state": "PENDING", "reason": "Priority",
        "partition": "gpu", "cpus": "8", "memory": "64G", "timeLimit": "1-00:00:00",
        "submitTime": "2026-11-14T18:05:12Z", "gpus": "1",
        "queueCheckedAt": "2026-11-14T20:00:00Z",
    }, "no expected start: Slurm hasn't worked one out (N/A)"
    array = describe_job(parse_squeue(SQUEUE)["52340200"], NOW, PACIFIC)
    assert array["expectedStart"] == "2026-11-14T21:30:00Z"
    assert array["jobId"] == "52340200"


def test_gpus_from_squeue():
    assert gpu_count("gres/gpu:2") == 2
    assert gpu_count("gpu:a100:4") == 4
    assert gpu_count("gres:gpu:1,gres/shard:2") == 1
    assert gpu_count("N/A") == 0


def test_soliton_options_come_first_and_the_rest_goes_to_sbatch():
    own, rest = split_sbatch_args(["--name", "fno", "--project=ops", "-p", "gpu", "job.sh", "--name", "x"])
    assert own == {"name": "fno", "project": "ops"}
    assert rest == ["-p", "gpu", "job.sh", "--name", "x"]
    assert split_sbatch_args(["--id", "r1", "--", "--name", "job.sh"]) == ({"id": "r1"}, ["--name", "job.sh"])
    with pytest.raises(ValueError):
        split_sbatch_args(["--name"])


def test_submit_reads_sbatchs_job_id_and_cluster():
    assert submit(["job.sh"], FakeSlurm(sbatch="123;sherlock\n")) == ("123", "sherlock")
    with pytest.raises(subprocess.CalledProcessError):
        submit(["job.sh"], FakeSlurm(sbatch_code=1))


def args(**given):
    return Namespace(**{"sbatch_args": ["-p", "gpu", "job.sh"], "name": None, "project": None,
                        "id": None, **given})


def test_sbatch_submits_then_shows_the_job_as_queued():
    slurm, server, said = FakeSlurm(), FakeServer(), []
    assert sbatch_main(args(), server, slurm, said.append) == 0
    assert slurm.calls[0] == ["sbatch", "--parsable", "-p", "gpu", "job.sh"]
    assert said[0] == "Submitted batch job 52340117"
    [(run_id, body)] = server.puts
    assert run_id == "queued-52340117"
    assert body["queued"] is True and body["name"] == "fno-hires"
    assert body["startedAt"] == body["system"]["slurm"]["submitTime"]
    assert body["system"]["slurm"]["reason"] == "Priority"
    assert body["system"]["slurm"]["cluster"] == "sherlock"
    assert body["host"] == "Sherlock", "as the job's logger names it, not the login node"


def test_sbatch_with_a_run_id_queues_that_run(tmp_path, monkeypatch):
    monkeypatch.setenv("SOLITON_DIR", str(tmp_path))
    server = FakeServer()
    sent = []
    server.put_run = lambda run_id, body, run_key=None: sent.append((run_id, run_key))
    sbatch_main(args(id="fno-hires-a1b2c3"), server, FakeSlurm(), lambda _: None)
    # With the key the job's logger will find in the run's folder.
    key = (tmp_path / "fno-hires-a1b2c3" / "key").read_text().strip()
    assert sent == [("fno-hires-a1b2c3", key)] and len(key) >= 30


def test_a_refused_job_reports_nothing_and_a_missing_server_still_submits(capsys):
    server = FakeServer()
    assert sbatch_main(args(), server, FakeSlurm(sbatch_code=1), lambda _: None) == 1
    assert server.puts == []
    assert "invalid partition" in capsys.readouterr().err
    assert sbatch_main(args(), None, FakeSlurm(), lambda _: None) == 0


def queued(run_id, job, host="Sherlock", **slurm):
    return {"id": run_id, "name": run_id, "project": "", "host": host, "status": "queued",
            "startedAt": "2026-11-14T18:05:12Z", "system": {"slurm": {"jobId": job, **slurm}}}


def test_soliton_queue_updates_waiting_jobs_and_ends_the_ones_that_left():
    server = FakeServer([
        queued("waiting", "52340117", reason="None"),
        queued("cancelled", "52339999"),
        queued("unknown", "52339998"),
        queued("elsewhere", "52339997", cluster="farmshare"),
        {**queued("live", "52340300"), "status": "live"},
    ])
    slurm = FakeSlurm(sacct={"52339999": "sherlock|CANCELLED by 12345\n",
                             "52339997": "sherlock|COMPLETED\n"})
    said = []
    assert refresh(server, slurm, now=NOW, say=said.append) == 4
    [(run_id, body)] = server.puts
    assert run_id == "waiting" and body["queued"] is True
    assert body["system"]["slurm"]["reason"] == "Priority"
    assert server.events == [
        ("cancelled", [{"type": "status", "status": "crashed", "message": "Cancelled before it started.",
                        "notify": False}]),
    ]
    assert sum("not a job of this cluster's" in line for line in said) == 2, "unknown, elsewhere"
    assert len([c for c in slurm.calls if c[0] == "squeue"]) == 1, "one squeue for all"


def test_a_job_squeue_still_lists_as_cancelled_ends():
    """squeue keeps an ended job for a few minutes after scancel."""
    server = FakeServer([queued("cancelled", "52340400")])
    slurm = FakeSlurm(
        squeue="52340400|x|CANCELLED|None|2026-11-14T10:05:12|N/A|5:00|normal|1|1G|N/A",
        sacct={"52340400": "sherlock|CANCELLED by 12345\n"},
    )
    refresh(server, slurm, now=NOW, say=lambda _: None)
    assert server.puts == []
    assert server.events[0][1][0]["message"] == "Cancelled before it started."


def test_older_slurm_without_squeue_me():
    class OldSlurm(FakeSlurm):
        def __call__(self, command, capture_output=True, text=True):
            if command[:2] == ["squeue", "--me"]:
                self.calls.append(command)
                return subprocess.CompletedProcess(command, 1, "", "squeue: unrecognized option '--me'")
            return super().__call__(command)

    slurm = OldSlurm()
    from soliton._queue import queued_jobs
    assert "52340117" in queued_jobs(slurm)
    assert slurm.calls[-1][:2] == ["squeue", "--user"]


def test_how_jobs_that_left_the_queue_end():
    assert ended_status("CANCELLED+")[0] == "crashed"
    assert ended_status("COMPLETED")[0] == "finished"
    assert ended_status("RUNNING") is None
    assert ended_status(None) is None


def test_a_starting_job_refreshes_the_queue_but_not_its_own_job():
    from soliton._queue import refresh_at_job_start

    server = FakeServer([queued("waiting", "52340117"), queued("mine", "52340300")])
    assert refresh_at_job_start(server, {"SLURM_JOB_ID": "52340300"}, FakeSlurm()) is True
    assert [run_id for run_id, _ in server.puts] == ["waiting"], "its own run takes its place"
    assert server.puts[0][1]["updateOnly"] is True


def test_only_the_first_task_of_an_array_refreshes_and_it_can_be_turned_off():
    from soliton._queue import refresh_at_job_start

    server = FakeServer([queued("waiting", "52340117")])
    array = {"SLURM_JOB_ID": "9", "SLURM_ARRAY_JOB_ID": "8", "SLURM_ARRAY_TASK_ID": "3",
             "SLURM_ARRAY_TASK_MIN": "1"}
    assert refresh_at_job_start(server, array, FakeSlurm()) is False
    assert refresh_at_job_start(server, {"SLURM_JOB_ID": "9", "SOLITON_REFRESH_QUEUE": "0"},
                                FakeSlurm()) is False
    assert refresh_at_job_start(server, {}, FakeSlurm()) is False
    assert server.puts == []


def test_a_queued_run_that_was_replaced_meanwhile_is_skipped():
    class Replaced(FakeServer):
        def put_run(self, run_id, body, run_key=None):
            raise LookupError("gone")

    server = Replaced([queued("waiting", "52340117"), queued("cancelled", "52339999")])
    slurm = FakeSlurm(sacct={"52339999": "sherlock|CANCELLED by 1\n"})
    assert refresh(server, slurm, now=NOW, say=lambda _: None) == 2
    assert server.events[0][0] == "cancelled", "the others still go on"
