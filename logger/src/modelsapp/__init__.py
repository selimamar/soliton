"""ModelsApp training logger.

    import modelsapp

    run = modelsapp.init("resnet50-cifar", project="image-classification",
                         config=vars(args), train_samples=train_set,
                         val_samples=val_set, loss=criterion,
                         total_steps=50_000, total_epochs=100)
    run.watch(model, every=100)          # per-layer statistics, network diagram
    for step, (x, y) in enumerate(batches):
        loss = criterion(model(x), y)
        loss.backward()
        run.log({"train/loss": loss}, step=step, epoch=epoch)
        optimizer.step(); optimizer.zero_grad()
    run.finish()

Simulations (a PDE solve, any computation stepping through time) are
monitored the same way:

    sim = modelsapp.simulate("kelvin-helmholtz", t_end=10,
                             setup={"equation": "Navier-Stokes 2D", "Re": 1e4})
    while t < 10:
        ...
        sim.log({"energy": E, "cfl": cfl}, t=t, dt=dt)
    sim.finish()

The server and token come from MODELSAPP_SERVER and MODELSAPP_TOKEN. Without
a server, runs are saved locally (offline) and uploaded later with
`modelsapp sync`. See logger/README.md.
"""

from __future__ import annotations

from typing import Any, Iterable, Mapping, Optional

from ._run import Run
from ._simulation import Diverged, Simulation

__all__ = ["Diverged", "Run", "Simulation", "init", "simulate"]
__version__ = "0.1.0"


def init(
    name: str,
    *,
    project: str = "",
    config: Optional[Mapping[str, Any]] = None,
    train_samples: Any = None,
    val_samples: Any = None,
    loss: Any = None,
    pde: Optional[Mapping[str, Any]] = None,
    tags: Optional[Iterable[str]] = None,
    notes: str = "",
    system_metrics: bool = True,
    system_interval: float = 15,
    price_per_hour: Optional[float] = None,
    total_steps: int = 0,
    total_epochs: int = 0,
    host: Optional[str] = None,
    id: Optional[str] = None,
    server: Optional[str] = None,
    token: Optional[str] = None,
    mode: Optional[str] = None,
    dir: Optional[str] = None,
) -> Run:
    """Starts a run.

    name, project: shown in the app. config: hyperparameters (a dict, nested
    dicts and argparse namespaces work). train_samples, val_samples: how many
    samples are trained and validated on: a number, a dataset or a DataLoader
    (its dataset is counted). loss: the loss, e.g. the criterion module
    ("CrossEntropyLoss(label_smoothing=0.1)"), a function or a string.
    These three are listed first among the hyperparameters, then pde: what
    is solved, e.g. {"equation": "Navier-Stokes 2D", "viscosity": 1e-3,
    "resolution": "64 x 64"} (the app can group runs by PDE). tags, notes:
    to organise runs in the app (e.g. tags=["baseline"]); they only set the
    starting values, which are then edited in the app. system_metrics:
    sample GPU, memory and CPU usage every system_interval seconds (the
    machine, GPUs and Slurm job are recorded either way). price_per_hour:
    what the machine costs in US dollars per hour, for the app's cost
    estimate (default MODELSAPP_PRICE_PER_HOUR, else the app assumes a
    typical cloud price for the GPUs; 0 hides the estimate). total_steps,
    total_epochs: for the progress bar and time estimate. host: where it runs (default: detected,
    e.g. "Sherlock"). id: reuse an id to continue a run (default: new).
    server, token: default MODELSAPP_SERVER, MODELSAPP_TOKEN. mode: "online"
    (upload while training), "offline" (save only) or "disabled"; default
    MODELSAPP_MODE, else online if a server is set. dir: where runs are saved
    (default MODELSAPP_DIR, else ./modelsapp-runs).
    """
    return Run(
        name,
        project=project,
        config=config,
        train_samples=train_samples,
        val_samples=val_samples,
        loss=loss,
        pde=pde,
        tags=tags,
        notes=notes,
        system_metrics=system_metrics,
        system_interval=system_interval,
        price_per_hour=price_per_hour,
        total_steps=total_steps,
        total_epochs=total_epochs,
        host=host,
        id=id,
        server=server,
        token=token,
        mode=mode,
        dir=dir,
    )


def simulate(
    name: str,
    *,
    project: str = "",
    setup: Optional[Mapping[str, Any]] = None,
    t_end: Optional[float] = None,
    max_iterations: int = 0,
    monitor: Optional[str] = None,
    cfl_limit: Optional[float] = None,
    stop_on_divergence: bool = False,
    tags: Optional[Iterable[str]] = None,
    notes: str = "",
    system_metrics: bool = True,
    system_interval: float = 15,
    price_per_hour: Optional[float] = None,
    host: Optional[str] = None,
    id: Optional[str] = None,
    server: Optional[str] = None,
    token: Optional[str] = None,
    mode: Optional[str] = None,
    dir: Optional[str] = None,
) -> Simulation:
    """Starts monitoring a simulation, e.g. a PDE solve. It shows in the
    app's Compute section.

    setup: how it is set up, shown like hyperparameters: equation, method,
    grid, parameters, boundary and initial conditions (a dict, nested is
    fine). t_end: the simulated time it runs to, for the progress bar and
    the time left; for a steady solve, max_iterations instead. monitor: the
    logged value drawn on its card in the list, e.g. "energy". cfl_limit:
    drawn on the chart of a value named "cfl". The first NaN or infinity
    logged (a value or a field) ends it as diverged; stop_on_divergence
    also raises `modelsapp.Diverged` then, to stop the simulation itself.
    The other options are as for `init()`.
    """
    return Simulation(
        name,
        project=project,
        setup=setup,
        t_end=t_end,
        max_iterations=max_iterations,
        monitor=monitor,
        cfl_limit=cfl_limit,
        stop_on_divergence=stop_on_divergence,
        tags=tags,
        notes=notes,
        system_metrics=system_metrics,
        system_interval=system_interval,
        price_per_hour=price_per_hour,
        host=host,
        id=id,
        server=server,
        token=token,
        mode=mode,
        dir=dir,
    )
