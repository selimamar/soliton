"""System info and usage: GPUs (with a stand-in nvidia-smi), Slurm cgroups
(with stand-in files), and how a run records them. Standard library only."""

from __future__ import annotations

import os
import stat
import sys
import time

import pytest

from modelsapp._system import (
    SlurmCgroup,
    SystemMonitor,
    _cudnn,
    _job_level,
    parse_nvidia_smi,
    system_info,
    visible_gpus,
)
from test_logger import offline, records

pytestmark = pytest.mark.skipif(sys.platform == "win32", reason="POSIX shell stand-ins")

GPUS = [{"index": "0", "uuid": "GPU-aaaa"}, {"index": "1", "uuid": "GPU-bbbb"},
        {"index": "2", "uuid": "GPU-cccc"}]


@pytest.fixture
def fake_nvidia_smi(tmp_path, monkeypatch):
    """Two A100s, the second busy; answers both of the logger's queries."""
    script = tmp_path / "bin" / "nvidia-smi"
    script.parent.mkdir()
    script.write_text("""#!/bin/sh
case "$*" in
  *driver_version*)
    echo "0, GPU-aaaa, NVIDIA A100-SXM4-80GB, 81920, 550.54.15"
    echo "1, GPU-bbbb, NVIDIA A100-SXM4-80GB, 81920, 550.54.15" ;;
  *)
    echo "0, GPU-aaaa, 81920, 0, 1024, 34, [N/A]"
    echo "1, GPU-bbbb, 81920, 97, 61440, 71, 312.5" ;;
esac
""")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    monkeypatch.setenv("PATH", f"{script.parent}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.delenv("CUDA_VISIBLE_DEVICES", raising=False)
    return script


def test_nvidia_smi_output_is_read_and_unknown_values_dropped():
    fields = ["index", "utilization.gpu", "power.draw"]
    rows = parse_nvidia_smi("0, 87, [N/A]\n1, 3, 61.2\nnot a row\n", fields)
    assert rows == [{"index": "0", "utilization.gpu": "87"},
                    {"index": "1", "utilization.gpu": "3", "power.draw": "61.2"}]


def test_only_the_jobs_gpus_count():
    assert visible_gpus(GPUS, {}) == GPUS
    assert visible_gpus(GPUS, {"CUDA_VISIBLE_DEVICES": "2,0"}) == [GPUS[2], GPUS[0]], "CUDA's order"
    assert visible_gpus(GPUS, {"CUDA_VISIBLE_DEVICES": "GPU-bb"}) == [GPUS[1]]
    assert visible_gpus(GPUS, {"CUDA_VISIBLE_DEVICES": ""}) == []
    # Slurm renumbered the job's GPUs, nvidia-smi shows physical numbers.
    assert visible_gpus(GPUS[2:], {"CUDA_VISIBLE_DEVICES": "0"}) == GPUS[2:]


def test_gpu_usage_is_sampled(fake_nvidia_smi):
    values = SystemMonitor(lambda _: None, env={}).sample()
    assert values["system/gpu.1.utilization"] == 97
    assert values["system/gpu.1.memory_gb"] == 60
    assert values["system/gpu.1.memory"] == 75.0, "percent of the GPU's memory"
    assert values["system/gpu.1.temperature"] == 71
    assert values["system/gpu.1.power"] == 312.5
    assert "system/gpu.0.power" not in values, "[N/A] is left out"
    assert "system/memory_gb" in values


def test_without_nvidia_smi_there_are_no_gpu_values(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))
    values = SystemMonitor(lambda _: None, env={}).sample()
    assert not any(name.startswith("system/gpu") for name in values)


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def test_a_slurm_job_is_measured_through_its_cgroup_v2(tmp_path):
    job = "/system.slice/slurmstepd.scope/job_42"
    write(tmp_path / "proc/self/cgroup", f"0::{job}/step_0/user/task_0\n")
    cgroup = tmp_path / "sys/fs/cgroup"
    write(cgroup / "cgroup.controllers", "cpu memory\n")
    write(cgroup / job.lstrip("/") / "memory.current", str(10 * 2**30))
    write(cgroup / job.lstrip("/") / "memory.stat", f"anon 1\ninactive_file {2 * 2**30}\n")
    write(cgroup / job.lstrip("/") / "memory.max", str(32 * 2**30))
    write(cgroup / "system.slice/slurmstepd.scope/memory.max", "max")
    write(cgroup / job.lstrip("/") / "cpu.stat", "usage_usec 4500000\nuser_usec 1\n")

    found = SlurmCgroup.find({"SLURM_JOB_ID": "42"}, root=tmp_path)
    assert found is not None and found.v2
    assert found.memory_used() == 8 * 2**30, "minus file cache the kernel can drop"
    assert found.memory_limit() == 32 * 2**30
    assert found.cpu_seconds() == 4.5


def test_a_slurm_job_is_measured_through_its_cgroup_v1(tmp_path):
    job = "/slurm/uid_1000/job_7"
    write(tmp_path / "proc/self/cgroup",
          f"5:memory:{job}/step_batch/task_0\n3:cpu,cpuacct:{job}/step_batch/task_0\n")
    cgroup = tmp_path / "sys/fs/cgroup"
    write(cgroup / "memory" / job.lstrip("/") / "memory.usage_in_bytes", str(5 * 2**30))
    write(cgroup / "memory" / job.lstrip("/") / "memory.stat", f"total_inactive_file {2**30}\n")
    write(cgroup / "memory" / job.lstrip("/") / "memory.limit_in_bytes", str(16 * 2**30))
    write(cgroup / "memory/slurm/memory.limit_in_bytes", "9223372036854771712")
    write(cgroup / "cpu,cpuacct" / job.lstrip("/") / "cpuacct.usage", "2500000000")

    found = SlurmCgroup.find({"SLURM_JOB_ID": "7"}, root=tmp_path)
    assert found is not None and not found.v2
    assert found.memory_used() == 4 * 2**30
    assert found.memory_limit() == 16 * 2**30
    assert found.cpu_seconds() == 2.5


def test_outside_slurm_there_is_no_cgroup(tmp_path):
    assert SlurmCgroup.find({}, root=tmp_path) is None
    assert _job_level("/slurm/uid_1/job_9/step_0", "9") == "/slurm/uid_1/job_9"


def test_the_machine_gpus_and_slurm_job_are_described(fake_nvidia_smi):
    info = system_info({"SLURM_JOB_ID": "12345678", "SLURM_JOB_PARTITION": "gpu",
                        "SLURM_JOB_NAME": "resnet50", "SLURM_CLUSTER_NAME": "sherlock",
                        "CUDA_VISIBLE_DEVICES": "1"})
    assert info["gpus"] == [{"name": "NVIDIA A100-SXM4-80GB", "memoryGb": 80.0}]
    assert info["gpuDriver"] == "550.54.15"
    assert info["slurm"] == {"jobId": "12345678", "jobName": "resnet50", "partition": "gpu",
                             "cluster": "sherlock"}
    assert info["cpuCores"] >= 1 and info["python"] and info["os"] and info["hostname"]


def test_cudnn_versions_read_like_people_write_them():
    assert _cudnn(90100) == "9.1.0"
    assert _cudnn(8902) == "8.9.2"


def system_events(run):
    return [r for r in records(run)
            if r["type"] == "metrics" and any(k.startswith("system/") for k in r["values"])]


def wait_for(condition, seconds=5.0):
    deadline = time.monotonic() + seconds
    while not condition():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(0.05)


def test_a_run_records_usage_at_the_step_it_is_at(tmp_path, fake_nvidia_smi):
    run = offline(tmp_path, system_metrics=True, system_interval=1)
    assert records(run)[0]["system"]["gpus"][0]["name"] == "NVIDIA A100-SXM4-80GB"
    wait_for(lambda: system_events(run))  # The first sample, right away.
    run.log({"train/loss": 1.0}, step=12, epoch=2)
    time.sleep(1.5)
    run.finish()
    events = system_events(run)
    assert events, "sampled while running"
    assert events[0]["step"] == 0, "the first sample comes before any step"
    later = events[-1]
    assert (later["step"], later["epoch"]) == (12, 2)
    assert later["values"]["system/gpu.1.utilization"] == 97
    assert records(run)[-1]["type"] == "status", "nothing after the run ends"


def test_usage_monitoring_can_be_turned_off(tmp_path):
    run = offline(tmp_path, system_metrics=False)
    run.log({"train/loss": 1.0}, step=0)
    run.finish()
    assert system_events(run) == []
    assert records(run)[0]["system"]["python"], "the machine is still described"
    with pytest.raises(ValueError, match="system_interval"):
        offline(tmp_path, name="x", system_interval=0.1)
