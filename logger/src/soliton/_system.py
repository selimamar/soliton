"""What a run trains on, and how busy it keeps the machine.

Standard library only:

- GPUs through `nvidia-smi` (on every machine with an NVIDIA driver,
  including Sherlock's GPU nodes), limited to the job's GPUs.
- Memory and CPU through the cgroup that limits them: the whole Slurm job
  (DataLoader workers included; what Slurm enforces --mem on), or the
  container (Modal, Docker, Kubernetes: its memory limit and CPU quota).
  Elsewhere, through psutil if it's installed, else for this process only
  (/proc on Linux, `ps` on macOS).
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone, tzinfo
from pathlib import Path
from typing import Callable, Dict, List, Mapping, Optional

GB = 1024 ** 3

# Metric names: system/gpu.<i>.<field>, system/cpu, system/memory, system/memory_gb.
GPU_FIELDS = {
    "utilization.gpu": "utilization",  # %
    "memory.used": "memory_gb",        # MiB -> GB
    "temperature.gpu": "temperature",  # °C
    "power.draw": "power",             # W
}


# GPUs -----------------------------------------------------------------------


def run_nvidia_smi(fields: List[str], timeout: float = 5) -> Optional[str]:
    """CSV rows for every GPU, or None without nvidia-smi (or a working driver)."""
    exe = shutil.which("nvidia-smi")
    if exe is None:
        return None
    try:
        result = subprocess.run(
            [exe, f"--query-gpu={','.join(fields)}", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def parse_nvidia_smi(text: str, fields: List[str]) -> List[Dict[str, str]]:
    """Rows as dicts; values nvidia-smi doesn't know ("[N/A]") are left out."""
    rows = []
    for line in text.strip().splitlines():
        values = [v.strip() for v in line.split(",")]
        if len(values) != len(fields):
            continue
        rows.append({f: v for f, v in zip(fields, values) if v and not v.startswith("[")})
    return rows


def visible_gpus(gpus: List[Dict[str, str]], env: Mapping[str, str] = os.environ):
    """The job's GPUs, in CUDA's order. CUDA_VISIBLE_DEVICES holds indices or
    UUIDs; if it matches nothing (e.g. Slurm renumbered the job's GPUs while
    nvidia-smi shows physical numbers), every listed GPU is the job's."""
    wanted = env.get("CUDA_VISIBLE_DEVICES")
    if wanted is None:
        return gpus
    wanted = wanted.strip()
    if wanted in ("", "-1", "NoDevFiles"):
        return []
    picked = []
    for item in (w.strip() for w in wanted.split(",")):
        for gpu in gpus:
            if item == gpu.get("index") or (item.startswith("GPU-") and
                                            gpu.get("uuid", "").startswith(item)):
                picked.append(gpu)
                break
    return picked or gpus


def _number(text: Optional[str]) -> Optional[float]:
    try:
        return float(text) if text is not None else None
    except ValueError:
        return None


# Memory and CPU ---------------------------------------------------------------


class Cgroup:
    """The cgroup (v1 or v2) that limits this process: a Slurm job's, or a
    container's. Memory in use and its limit, CPU time of every process in
    it, and its CPU quota."""

    UNLIMITED = 1 << 60

    def __init__(self, memory_dir: Path, cpu_dir: Optional[Path], v2: bool,
                 kind: str = "slurm") -> None:
        self.memory_dir, self.cpu_dir, self.v2, self.kind = memory_dir, cpu_dir, v2, kind

    @classmethod
    def find(cls, env: Mapping[str, str] = os.environ, root: Path = Path("/")) -> Optional["Cgroup"]:
        """The Slurm job's cgroup, or a container's; None on an ordinary
        machine, where a cgroup spans unrelated processes (e.g. a login session)."""
        try:
            lines = (root / "proc/self/cgroup").read_text().splitlines()
        except OSError:
            return None
        job = env.get("SLURM_JOB_ID")
        base = root / "sys/fs/cgroup"
        paths = {}
        for line in lines:
            parts = line.split(":", 2)
            if len(parts) != 3:
                continue
            _, controllers, path = parts
            for controller in controllers.split(",") if controllers else [""]:
                paths[controller] = _job_level(path, job) if job else path
        found = None
        if "" in paths and (base / "cgroup.controllers").exists():  # v2
            directory = base / paths[""].lstrip("/")
            found = cls(directory, directory, v2=True)
            at_root = paths[""] == "/"
        elif "memory" in paths:  # v1
            memory = base / "memory" / paths["memory"].lstrip("/")
            cpu = None
            for name in ("cpu,cpuacct", "cpuacct,cpu", "cpuacct"):
                candidate = base / name / paths.get("cpuacct", "").lstrip("/")
                if "cpuacct" in paths and candidate.exists():
                    cpu = candidate
                    break
            found = cls(memory, cpu, v2=False) if memory.exists() else None
            at_root = paths["memory"] == "/"
        if found is None:
            return None
        if job:
            return found
        # Not Slurm: only a container's (a namespace root, or limited).
        if at_root or found.memory_limit() is not None or found.cpu_limit() is not None:
            found.kind = "container"
            return found
        return None

    def memory_used(self) -> Optional[int]:
        """The working set: what is in use, minus file cache the kernel can drop."""
        usage = _read_int(self.memory_dir / ("memory.current" if self.v2 else "memory.usage_in_bytes"))
        if usage is None:
            return None
        stat = _read_stat(self.memory_dir / "memory.stat")
        inactive = stat.get("inactive_file" if self.v2 else "total_inactive_file", 0)
        return max(usage - inactive, 0)

    def memory_limit(self) -> Optional[int]:
        """The tightest limit on the way up (None if unlimited)."""
        name = "memory.max" if self.v2 else "memory.limit_in_bytes"
        limits = [v for v in (_read_int(d / name) for d in self._upwards(self.memory_dir))
                  if v is not None and v < self.UNLIMITED]
        return min(limits) if limits else None

    def cpu_limit(self) -> Optional[float]:
        """Cores' worth of CPU quota, e.g. 2.0 for `docker run --cpus 2`; None
        without a quota (Slurm limits cores with CPU affinity instead)."""
        quotas = []
        if self.v2:
            for directory in self._upwards(self.memory_dir):
                try:
                    quota, period = (directory / "cpu.max").read_text().split()
                except (OSError, ValueError):
                    continue
                if quota != "max" and int(period) > 0:
                    quotas.append(int(quota) / int(period))
        elif self.cpu_dir is not None:
            quota = _read_int(self.cpu_dir / "cpu.cfs_quota_us")
            period = _read_int(self.cpu_dir / "cpu.cfs_period_us")
            if quota is not None and quota > 0 and period:
                quotas.append(quota / period)
        return min(quotas) if quotas else None

    def cpu_seconds(self) -> Optional[float]:
        if self.cpu_dir is None:
            return None
        if self.v2:
            usage = _read_stat(self.cpu_dir / "cpu.stat").get("usage_usec")
            return usage / 1e6 if usage is not None else None
        nanoseconds = _read_int(self.cpu_dir / "cpuacct.usage")
        return nanoseconds / 1e9 if nanoseconds is not None else None

    @staticmethod
    def _upwards(directory: Path, levels: int = 4):
        for _ in range(levels):
            yield directory
            if directory.name == "cgroup":  # The hierarchy's root.
                return
            directory = directory.parent


def _job_level(path: str, job: str) -> str:
    """/slurm/uid_1/job_42/step_0/task_0 -> /slurm/uid_1/job_42: the whole job."""
    parts = path.split("/")
    for i, part in enumerate(parts):
        if part == f"job_{job}":
            return "/".join(parts[: i + 1])
    return path


def _read_int(path: Path) -> Optional[int]:
    try:
        text = path.read_text().strip()
    except OSError:
        return None
    if text == "max":
        return Cgroup.UNLIMITED
    try:
        return int(text)
    except ValueError:
        return None


def _read_stat(path: Path) -> Dict[str, int]:
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return {}
    stats = {}
    for line in lines:
        key, _, value = line.partition(" ")
        if value.strip().isdigit():
            stats[key] = int(value)
    return stats


def available_cores() -> int:
    """Cores this process may run on (Slurm's allocation on Linux)."""
    try:
        return max(len(os.sched_getaffinity(0)), 1)  # type: ignore[attr-defined]
    except AttributeError:
        return os.cpu_count() or 1


def total_memory() -> Optional[int]:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1]) * 1024
    except OSError:
        pass
    if sys.platform == "darwin":
        out = _command(["sysctl", "-n", "hw.memsize"])
        return int(out) if out and out.isdigit() else None
    return None


class _ProcessUsage:
    """Memory and CPU time of this process (and its children with psutil)."""

    def __init__(self) -> None:
        try:
            import psutil  # type: ignore[import-not-found]

            self._psutil = psutil.Process()
        except Exception:
            self._psutil = None

    def memory_used(self) -> Optional[int]:
        if self._psutil is not None:
            try:
                tree = [self._psutil, *self._psutil.children(recursive=True)]
                return sum(_safe(lambda p=p: p.memory_info().rss, 0) for p in tree)
            except Exception:
                pass
        try:
            for line in Path("/proc/self/status").read_text().splitlines():
                if line.startswith("VmRSS:"):
                    return int(line.split()[1]) * 1024
        except OSError:
            pass
        out = _command(["ps", "-o", "rss=", "-p", str(os.getpid())])
        return int(out) * 1024 if out and out.isdigit() else None

    def cpu_seconds(self) -> float:
        if self._psutil is not None:
            try:
                total = sum(self._psutil.cpu_times()[:4])  # Includes finished children.
                for child in self._psutil.children(recursive=True):
                    total += _safe(lambda c=child: sum(c.cpu_times()[:2]), 0.0)
                return total
            except Exception:
                pass
        times = os.times()
        return times.user + times.system + times.children_user + times.children_system


def _safe(get: Callable, default):
    try:
        return get()
    except Exception:  # The process ended meanwhile.
        return default


def _command(args: List[str]) -> Optional[str]:
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout.strip() if result.returncode == 0 else None


# Sampling ---------------------------------------------------------------------


class SystemMonitor(threading.Thread):
    """Every [interval] seconds, measures GPUs, memory and CPU and hands the
    values (named like "system/gpu.0.utilization") to [emit]."""

    def __init__(self, emit: Callable[[Dict[str, float]], None], interval: float = 15,
                 env: Mapping[str, str] = os.environ) -> None:
        super().__init__(name="soliton-system", daemon=True)
        self._emit = emit
        self._interval = interval
        self._env = env
        self._stopped = threading.Event()
        self._gpus = True  # Until nvidia-smi says otherwise.
        self._cgroup = Cgroup.find(env)
        self._process = _ProcessUsage()
        self._limit = self._cgroup.memory_limit() if self._cgroup else None
        self._total = self._limit or total_memory()
        self._cores = cores(self._cgroup)
        self._last_cpu: Optional[tuple] = None

    def run(self) -> None:
        while True:
            try:
                values = self.sample()  # The first has no CPU yet: it starts the clock.
            except Exception:  # Never let monitoring break a run.
                values = {}
            if values:
                self._emit(values)
            if self._stopped.wait(self._interval):
                return

    def stop(self) -> None:
        self._stopped.set()

    def sample(self) -> Dict[str, float]:
        values: Dict[str, float] = {}
        if self._gpus:
            self._sample_gpus(values)
        self._sample_memory_and_cpu(values)
        return values

    def _sample_gpus(self, values: Dict[str, float]) -> None:
        fields = ["index", "uuid", "memory.total", *GPU_FIELDS]
        text = run_nvidia_smi(fields)
        if text is None:
            self._gpus = False
            return
        for i, gpu in enumerate(visible_gpus(parse_nvidia_smi(text, fields), self._env)):
            for field, name in GPU_FIELDS.items():
                value = _number(gpu.get(field))
                if value is None:
                    continue
                if field == "memory.used":
                    total = _number(gpu.get("memory.total"))
                    if total:
                        values[f"system/gpu.{i}.memory"] = round(100 * value / total, 1)
                    value = value * 2 ** 20 / GB
                values[f"system/gpu.{i}.{name}"] = round(value, 2)

    def _sample_memory_and_cpu(self, values: Dict[str, float]) -> None:
        source = self._cgroup or self._process
        used = source.memory_used()
        if used is not None:
            values["system/memory_gb"] = round(used / GB, 2)
            if self._total:
                values["system/memory"] = round(100 * used / self._total, 1)
        cpu = source.cpu_seconds()
        now = time.monotonic()
        if cpu is not None:
            if self._last_cpu is not None:
                spent, elapsed = cpu - self._last_cpu[0], now - self._last_cpu[1]
                if elapsed > 0:
                    values["system/cpu"] = round(max(0.0, 100 * spent / elapsed / self._cores), 1)
            self._last_cpu = (cpu, now)


# What it runs on ----------------------------------------------------------------


def cores(cgroup: Optional[Cgroup]) -> float:
    """Cores' worth of CPU the run may use: a container's quota, else the
    cores it may run on (a Slurm job's allocation)."""
    quota = cgroup.cpu_limit() if cgroup is not None else None
    return min(quota, available_cores()) if quota else float(available_cores())


def system_info(env: Mapping[str, str] = os.environ, root: Path = Path("/")) -> dict:
    """The machine, software and Slurm job, as the app shows them."""
    cgroup = Cgroup.find(env, root)
    allowed = cores(cgroup)
    info: dict = {
        "hostname": socket.gethostname(),
        "os": _os_name(),
        "python": platform.python_version(),
        "cpu": _cpu_model(),
        "cpuCores": int(allowed) if allowed == int(allowed) else round(allowed, 1),
    }
    memory = (cgroup.memory_limit() if cgroup else None) or total_memory()
    if memory:
        info["memoryGb"] = round(memory / GB, 1)
    fields = ["index", "uuid", "name", "memory.total", "driver_version"]
    text = run_nvidia_smi(fields)
    if text is not None:
        gpus = visible_gpus(parse_nvidia_smi(text, fields), env)
        info["gpus"] = [
            {"name": g.get("name", "GPU"), "memoryGb": round((_number(g.get("memory.total")) or 0) / 1024, 1)}
            for g in gpus
        ]
        if gpus and gpus[0].get("driver_version"):
            info["gpuDriver"] = gpus[0]["driver_version"]
    info.update(framework_versions())
    slurm = {
        key: env[var]
        for key, var in (
            ("jobId", "SLURM_JOB_ID"), ("jobName", "SLURM_JOB_NAME"),
            ("partition", "SLURM_JOB_PARTITION"), ("nodes", "SLURM_JOB_NODELIST"),
            ("cluster", "SLURM_CLUSTER_NAME"), ("arrayJobId", "SLURM_ARRAY_JOB_ID"),
            ("arrayTaskId", "SLURM_ARRAY_TASK_ID"),
        )
        if env.get(var)
    }
    if slurm:
        slurm.update(slurm_times(env))
        info["slurm"] = slurm
    return info


# Slurm job times ------------------------------------------------------------

_NO_TIME = {"", "Unknown", "None", "N/A", "(null)"}
_A_YEAR = 365 * 24 * 3600  # A time limit further than this is no limit.


def slurm_times(env: Mapping[str, str] = os.environ,
                scontrol: Optional[Callable[[str], Optional[str]]] = None,
                local: Optional[tzinfo] = None) -> Dict[str, str]:
    """When the job was submitted and started, and when its time limit
    stops it, as UTC times ("2026-11-14T18:23:45Z"): `submitTime`,
    `startTime`, `timeLimitAt`, whichever Slurm says. Asks `scontrol` once
    (the submit time is in no environment variable); never raises."""
    job = env.get("SLURM_JOB_ID")
    if not job:
        return {}
    fields = parse_scontrol((scontrol or run_scontrol)(job) or "")
    submitted = _slurm_time(fields.get("SubmitTime"), local)
    started = _epoch(env.get("SLURM_JOB_START_TIME")) or _slurm_time(fields.get("StartTime"), local)
    ends = _epoch(env.get("SLURM_JOB_END_TIME")) or _slurm_time(fields.get("EndTime"), local)
    if fields.get("TimeLimit") == "UNLIMITED" or (ends and started and ends - started > _A_YEAR):
        ends = None
    times = {"submitTime": submitted, "startTime": started, "timeLimitAt": ends}
    return {key: _iso(value) for key, value in times.items() if value}


def run_scontrol(job: str, timeout: float = 5) -> Optional[str]:
    """`scontrol show job -o <job>`: the job on one line, or None."""
    exe = shutil.which("scontrol")
    if exe is None:
        return None
    try:
        result = subprocess.run([exe, "show", "job", "-o", job],
                                capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None
    return result.stdout if result.returncode == 0 else None


def parse_scontrol(text: str) -> Dict[str, str]:
    """"JobId=42 SubmitTime=2026-11-14T10:23:45 ..." as a dict."""
    return dict(re.findall(r"(?:^|\s)(\w+)=(\S*)", text))


def _slurm_time(text: Optional[str], local: Optional[tzinfo]) -> Optional[float]:
    """Slurm's local time ("2026-11-14T10:23:45") as a Unix time."""
    if text is None or text in _NO_TIME:
        return None
    try:
        moment = datetime.strptime(text, "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None
    # Naive: the machine's time zone, Slurm's too.
    return (moment.replace(tzinfo=local) if local else moment.astimezone()).timestamp()


def _epoch(text: Optional[str]) -> Optional[float]:
    try:
        value = float(text) if text else 0
    except ValueError:
        return None
    return value if value > 0 else None


def _iso(seconds: float) -> str:
    return datetime.fromtimestamp(seconds, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def framework_versions() -> dict:
    """PyTorch, CUDA and cuDNN versions, if PyTorch is already imported
    (importing it here would slow down scripts that don't use it)."""
    torch = sys.modules.get("torch")
    if torch is None:
        return {}
    versions = {"torch": str(getattr(torch, "__version__", "")).split("+")[0]}
    try:
        if torch.version.cuda:
            versions["cuda"] = str(torch.version.cuda)
        cudnn = torch.backends.cudnn.version() if torch.backends.cudnn.is_available() else None
        if cudnn:
            versions["cudnn"] = _cudnn(int(cudnn))
    except Exception:
        pass
    return versions


def _cudnn(version: int) -> str:
    """90100 -> "9.1.0" (cuDNN 9 and later); 8902 -> "8.9.2" (before)."""
    if version >= 10000:
        return f"{version // 10000}.{version % 10000 // 100}.{version % 100}"
    return f"{version // 1000}.{version % 1000 // 100}.{version % 100}"


def _os_name() -> str:
    if sys.platform == "darwin":
        return f"macOS {platform.mac_ver()[0]}".strip()
    try:
        text = Path("/etc/os-release").read_text()
        match = re.search(r'^PRETTY_NAME="?([^"\n]+)"?', text, re.M)
        if match:
            return f"{match.group(1)} ({platform.system()} {platform.release().split('-')[0]})"
    except OSError:
        pass
    return f"{platform.system()} {platform.release()}"


def _cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    if sys.platform == "darwin":
        out = _command(["sysctl", "-n", "machdep.cpu.brand_string"])
        if out:
            return out
    return platform.processor() or platform.machine()
