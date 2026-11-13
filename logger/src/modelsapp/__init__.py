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

The server and token come from MODELSAPP_SERVER and MODELSAPP_TOKEN. Without
a server, runs are saved locally (offline) and uploaded later with
`modelsapp sync`. See logger/README.md.
"""

from __future__ import annotations

from typing import Any, Iterable, Mapping, Optional

from ._run import Run

__all__ = ["Run", "init"]
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
    machine, GPUs and Slurm job are recorded either way). total_steps,
    total_epochs: for the
    progress bar and time estimate. host: where it runs (default: detected,
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
        total_steps=total_steps,
        total_epochs=total_epochs,
        host=host,
        id=id,
        server=server,
        token=token,
        mode=mode,
        dir=dir,
    )
