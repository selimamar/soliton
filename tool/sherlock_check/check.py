"""End-to-end check of Soliton on Sherlock: one small job per scenario,
reporting live to the test server, with known markers so the app's numbers
can be checked against what really happened.

    python3 check.py train      CPU training that finishes; registers a dataset
    python3 check.py crash      CPU training that raises an error
    python3 check.py timeout    simulation stopped by the job's time limit
    python3 check.py diverge    simulation that blows up (NaN)
    python3 check.py gpu        GPU training with field snapshots

Markers (all at known times, printed with UTC timestamps):
- train: all the job's cores for the first half of the steps, one core for
  the second half (CPU % should halve); +1 GiB RAM held from halfway.
- crash: +1.5 GiB RAM held from halfway, then a RuntimeError.
- gpu:   +2 GiB GPU memory held from halfway.

At the end (or just before the crash) each prints one line starting with
"TRUTH " holding what the process itself measured (CPU time, peak RSS,
steps, marker times), to compare with the app, sacct and seff.

Each scenario does about CHECK_MINUTES (default 10) of real work: Sherlock
asks for jobs of at least 10 minutes.
"""

import json
import math
import os
import resource
import sys
import time
from datetime import datetime, timezone

import numpy as np

import soliton

MINUTES = float(os.environ.get("CHECK_MINUTES", "10"))
CPUS = int(os.environ.get("SLURM_CPUS_PER_TASK", "1"))
GIB = 2**30
T0 = time.monotonic()
MARKS = {}


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def mark(name, message):
    MARKS[name] = now()
    print(f"[{MARKS[name]} +{time.monotonic() - T0:5.0f}s] {message}", flush=True)


def truth(run, **extra):
    usage = resource.getrusage(resource.RUSAGE_SELF)
    wall = time.monotonic() - T0
    cpu = usage.ru_utime + usage.ru_stime
    print("TRUTH " + json.dumps({
        "run": run.id, "job": os.environ.get("SLURM_JOB_ID"), "cpus": CPUS,
        "wall_s": round(wall, 1), "cpu_s": round(cpu, 1),
        "cpu_pct_of_job": round(100 * cpu / wall / CPUS, 1),
        "max_rss_gib": round(usage.ru_maxrss * 1024 / GIB, 3),  # ru_maxrss is KiB on Linux
        "marks": MARKS, **extra,
    }), flush=True)


def hold_ram(gib):
    block = np.ones(int(gib * GIB), dtype=np.uint8)  # np.ones touches every page
    return block


# Training -------------------------------------------------------------------

def make_data(n=4096, d=32, seed=0):
    rng = np.random.default_rng(seed)
    x = rng.standard_normal((n, d)).astype(np.float32)
    w = rng.standard_normal((d,)).astype(np.float32)
    y = (np.sin(x @ w / math.sqrt(d)) + 0.1 * x[:, 0] ** 2).astype(np.float32)[:, None]
    return x, y


def train(crash=False):
    import torch
    from torch import nn

    data_dir = os.path.join(os.environ.get("SCRATCH", "."), "soliton-appcheck", "data")
    datasets = []
    x, y = make_data()
    if not crash:
        os.makedirs(data_dir, exist_ok=True)
        path = os.path.join(data_dir, "appcheck-regression-v1.npz")
        np.savez(path, x=x, y=y)
        datasets = [soliton.register_dataset(
            path, name="appcheck-regression", version="v1", source="Synthetic",
            splits={"train": 3584, "val": 512},
            description="y = sin(x.w/sqrt(32)) + 0.1 x0^2, x ~ N(0, 1)^32 (app check)")]
    xt, yt = torch.from_numpy(x[:3584]), torch.from_numpy(y[:3584])
    xv, yv = torch.from_numpy(x[3584:]), torch.from_numpy(y[3584:])

    torch.manual_seed(0)
    model = nn.Sequential(nn.Linear(32, 768), nn.GELU(), nn.Linear(768, 768), nn.GELU(),
                          nn.Linear(768, 768), nn.GELU(), nn.Linear(768, 1))
    criterion = nn.MSELoss()
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)
    batch = 512
    per_epoch = math.ceil(len(xt) / batch)

    def one_step(i):
        j = (i % per_epoch) * batch
        loss = criterion(model(xt[j:j + batch]), yt[j:j + batch])
        optimizer.zero_grad()
        loss.backward()
        return loss

    # Calibrate: a step's time on all cores and on one, so that each half
    # takes MINUTES / 2.
    def timed(threads, n=40):
        torch.set_num_threads(threads)
        start = time.monotonic()
        for i in range(n):
            one_step(i)
            optimizer.step()
        return (time.monotonic() - start) / n
    fast, slow = timed(CPUS), timed(1)
    half_s = MINUTES * 60 / 2
    switch = int(half_s / fast)
    total = switch + int(half_s / slow)
    if crash:
        total = int(total * 1.5)  # never reached: it crashes at MINUTES
    print(f"calibrated: {fast * 1e3:.1f} ms/step on {CPUS} cores, {slow * 1e3:.1f} ms on 1; "
          f"{switch} + {total - switch} steps", flush=True)

    run = soliton.init(
        "appcheck-crash" if crash else "appcheck-train", project="sherlock-app-check",
        config={"Optimizer": "AdamW", "Learning rate": 1e-3, "Schedule": "cosine",
                "Batch size": batch, "Width": 768, "Depth": 3, "Threads": f"{CPUS} then 1"},
        train_samples=len(xt), val_samples=len(xv), loss=criterion, datasets=datasets,
        total_steps=0 if crash else total, total_epochs=0 if crash else math.ceil(total / per_epoch),
        tags=["app-check", "crash" if crash else "finishes"],
        notes=("Raises a RuntimeError after %g min. +1.5 GiB RAM from halfway." % MINUTES) if crash
        else (f"{CPUS} cores for the first {switch} steps, then 1 core (CPU % halves). "
              "+1 GiB RAM from halfway."),
    )
    log_every = max(10, total // 3000)
    val_every = max(200, total // 100)
    run.watch(model, every=max(50, total // 200))
    torch.set_num_threads(CPUS)
    mark("start", f"training started, run {run.id}")
    held = None
    step = 0
    while step < total:
        elapsed = time.monotonic() - T0
        if not crash and step == switch:
            torch.set_num_threads(1)
            held = hold_ram(1.0)
            mark("half", "switched to 1 thread, holding 1 GiB more RAM")
        if crash and held is None and elapsed > MINUTES * 30:
            held = hold_ram(1.5)
            mark("half", "holding 1.5 GiB more RAM")
        if crash and elapsed > MINUTES * 60:
            mark("crash", f"crashing at step {step}")
            truth(run, steps=step, expected="crashed with RuntimeError")
            raise RuntimeError(f"Deliberate crash at step {step} (Soliton app check)")
        loss = one_step(step)
        lr = 1e-3 * 0.5 * (1 + math.cos(math.pi * step / total))
        for group in optimizer.param_groups:
            group["lr"] = lr
        metrics = {}
        if step % log_every == 0:
            norm = torch.nn.utils.clip_grad_norm_(model.parameters(), float("inf"))
            metrics.update({"train/loss": loss, "optim/lr": lr, "optim/grad_norm": norm})
        if step % val_every == 0:
            with torch.no_grad():
                pred = model(xv)
                val = criterion(pred, yv).item()
                rel = (torch.linalg.norm(pred - yv) / torch.linalg.norm(yv)).item()
            metrics.update({"val/loss": val, "val/rel_l2": rel})
        if metrics:
            run.log(metrics, step=step, epoch=step // per_epoch)
        if step % 1000 == 0:
            print(f"step {step}/{total} loss {loss.item():.4f}", flush=True)
        optimizer.step()
        step += 1
    mark("end", f"finished {step} steps")
    truth(run, steps=step, switch=switch, expected="finished")
    run.finish()


# Simulations ----------------------------------------------------------------

def laplacian(u, dx):
    return (np.roll(u, 1, 0) + np.roll(u, -1, 0) + np.roll(u, 1, 1) + np.roll(u, -1, 1) - 4 * u) / dx**2


def simulation(diverge=False):
    n = 256
    dx = 1.0 / n
    nu = 1e-4
    c = np.array([1.0, 0.5])  # advection velocity
    xs = (np.arange(n) + 0.5) * dx
    X, Y = np.meshgrid(xs, xs, indexing="ij")
    u = np.exp(-((X - 0.3) ** 2 + (Y - 0.5) ** 2) / 0.005) + 0.5 * np.exp(-((X - 0.7) ** 2 + (Y - 0.4) ** 2) / 0.01)
    dt = 0.2 * dx / np.abs(c).max()

    def advance(u, dt):
        # Upwind advection (c > 0) + diffusion, explicit, periodic.
        ux = (u - np.roll(u, 1, 0)) / dx
        uy = (u - np.roll(u, 1, 1)) / dx
        return u + dt * (-c[0] * ux - c[1] * uy + nu * laplacian(u, dx))

    # Calibrate steps per second.
    start, k = time.monotonic(), 0
    while time.monotonic() - start < 5:
        advance(u, dt)
        k += 1
    rate = k / (time.monotonic() - start)
    # timeout: enough simulated time for about twice the job's limit. diverge:
    # out of reach (the 5 s estimate can be well off), so dt starts growing
    # at MINUTES, before the end.
    t_end = dt * rate * MINUTES * 60 * (3.0 if diverge else 2.5)
    print(f"calibrated: {rate:.0f} steps/s, t_end {t_end:.3f}", flush=True)

    sim = soliton.simulate(
        "appcheck-diverge" if diverge else "appcheck-timeout", project="sherlock-app-check",
        t_end=t_end, monitor="energy", cfl_limit=1.0, stop_on_divergence=True,
        setup={"equation": "Advection-diffusion", "method": "Upwind + central, explicit Euler",
               "grid": f"{n} x {n}", "viscosity": nu, "velocity": "(1, 0.5)",
               "boundary": "periodic"},
        tags=["app-check", "diverges" if diverge else "time-limit"],
        notes=("Stable for %g min, then dt grows 2%% per step until it blows up." % MINUTES) if diverge
        else "Needs about 2.5x the job's time limit: Slurm stops it (SIGTERM).",
    )
    mass0 = u.sum() * dx * dx
    t, step = 0.0, 0
    last_field = 0.0
    log_every = max(20, int(rate / 2))  # about two records per second
    mark("start", f"simulation started, {sim.id}")
    with sim, np.errstate(over="ignore", invalid="ignore"):
        while t < t_end:
            elapsed = time.monotonic() - T0
            if diverge and elapsed > MINUTES * 60:
                if "grow" not in MARKS:
                    mark("grow", f"dt starts growing at t = {t:.4f}")
                dt *= 1.02
            new = advance(u, dt)
            change = np.abs(new - u).max() / dt
            u = new
            t += dt
            step += 1
            if step % log_every == 0 or (diverge and "grow" in MARKS):
                cfl = dt * np.abs(c).sum() / dx
                sim.log({"energy": float((u**2).mean()), "mass": float(u.sum() * dx * dx),
                             "mass error": abs(float(u.sum() * dx * dx) - mass0),
                             "max": float(u.max()), "cfl": cfl, "residual": float(change)},
                            t=t, dt=dt)
            if time.monotonic() - last_field > 30:
                last_field = time.monotonic()
                sim.log_field("u", u, extent=[(0, 1), (0, 1)], axes=["x", "y"])
    mark("end", f"simulation ended at t = {t:.4f}, step {step}")
    truth(sim, steps=step, t=t)


def diverge():
    try:
        simulation(diverge=True)
    except soliton.Diverged as error:
        mark("diverged", f"stopped: {error}")
        print("TRUTH " + json.dumps({"marks": MARKS, "expected": "diverged"}), flush=True)


# GPU ------------------------------------------------------------------------

def gpu():
    import torch
    from torch import nn

    device = "cuda"
    n = 64

    def smooth(a):
        k = torch.fft.rfft2(a)
        kx = torch.fft.fftfreq(n, device=device)[:, None]
        ky = torch.fft.rfftfreq(n, device=device)[None, :]
        return torch.fft.irfft2(k * torch.exp(-200 * (kx**2 + ky**2)), s=(n, n))

    gen = torch.Generator(device=device).manual_seed(0)
    val_a = torch.randn(64, 1, n, n, device=device, generator=gen)
    val_u = smooth(val_a)
    model = nn.Sequential(
        nn.Conv2d(1, 64, 5, padding=2), nn.GELU(), nn.Conv2d(64, 64, 5, padding=2), nn.GELU(),
        nn.Conv2d(64, 64, 5, padding=2), nn.GELU(), nn.Conv2d(64, 1, 5, padding=2),
    ).to(device)
    criterion = nn.MSELoss()
    optimizer = torch.optim.AdamW(model.parameters(), lr=1e-3)

    def one_step():
        a = torch.randn(128, 1, n, n, device=device)
        loss = criterion(model(a), smooth(a))
        optimizer.zero_grad()
        loss.backward()
        optimizer.step()
        return loss
    for _ in range(20):
        one_step()
    torch.cuda.synchronize()
    start = time.monotonic()
    for _ in range(50):
        one_step()
    torch.cuda.synchronize()
    per = (time.monotonic() - start) / 50
    total = int(MINUTES * 60 / per)
    print(f"calibrated: {per * 1e3:.1f} ms/step, {total} steps on {torch.cuda.get_device_name(0)}",
          flush=True)

    run = soliton.init(
        "appcheck-gpu", project="sherlock-app-check",
        config={"Optimizer": "AdamW", "Learning rate": 1e-3, "Batch size": 128, "Width": 64},
        train_samples=total * 128, val_samples=64, loss=criterion, total_steps=total,
        pde={"equation": "Gaussian smoothing (operator learning toy)", "resolution": f"{n} x {n}"},
        tags=["app-check", "gpu"], notes="+2 GiB GPU memory held from halfway.",
    )
    run.watch(model, every=100)
    mark("start", f"training started, run {run.id}")
    held = None
    for step in range(total):
        if held is None and step >= total // 2:
            held = torch.ones(2 * GIB, dtype=torch.uint8, device=device)
            mark("half", "holding 2 GiB more GPU memory")
        loss = one_step()
        if step % 20 == 0:
            run.log({"train/loss": loss}, step=step)
        if step % 500 == 0:
            with torch.no_grad():
                pred = model(val_a)
                rel = (torch.linalg.norm(pred - val_u) / torch.linalg.norm(val_u)).item()
            run.log({"val/rel_l2": rel}, step=step)
            run.log_field("u", pred[0, 0], val_u[0, 0], step=step, extent=[(0, 1), (0, 1)])
    torch.cuda.synchronize()
    mark("end", f"finished {total} steps")
    truth(run, steps=total, gpu_mem_allocated_gib=round(torch.cuda.memory_allocated() / GIB, 2),
          gpu_mem_reserved_gib=round(torch.cuda.memory_reserved() / GIB, 2))
    run.finish()


if __name__ == "__main__":
    scenario = sys.argv[1]
    print(f"{scenario} on {os.uname().nodename}, job {os.environ.get('SLURM_JOB_ID')}, "
          f"{CPUS} CPUs, {MINUTES:g} min", flush=True)
    {"train": train, "crash": lambda: train(crash=True), "timeout": simulation,
     "diverge": diverge, "gpu": gpu}[scenario]()
