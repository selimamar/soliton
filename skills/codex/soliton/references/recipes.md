# Recipes: training, Python simulations, data

Code to add for each kind of Python computation. Read the part you need.

## Training (Python)

```python
import soliton

with soliton.init(
    "fno-ns-64modes",                       # short: model-data-variant
    project="navier-stokes",                # what the model does; runs group by it
    config={"Optimizer": "AdamW", "Learning rate": 3e-4, "Batch size": 32, "Modes": 64},
    train_samples=train_set, val_samples=val_set,   # a number, a dataset or a DataLoader
    loss=criterion,                         # module, function or string
    total_steps=epochs * len(loader), total_epochs=epochs,   # progress and time left
    tags=["baseline"], notes="Why this run exists, in a sentence.",
) as run:
    run.watch(model, every=100)             # PyTorch: layer statistics, network diagram
    for epoch in range(epochs):
        for x, y in loader:
            loss = criterion(model(x), y)
            optimizer.zero_grad(); loss.backward()
            if step % 20 == 0:
                run.log({"train/loss": loss, "optim/lr": sched.get_last_lr()[0]},
                        step=step, epoch=epoch)
            optimizer.step(); step += 1
        run.log({"val/loss": val_loss, "val/accuracy": val_acc}, step=step)
        if run.should_stop():               # the app's Stop button
            save_checkpoint(model, optimizer, step, run.id)
            break
```

- **Names with their own charts:** `train/loss`, `val/loss`, `val/accuracy`,
  `optim/lr`, `optim/grad_norm` (what `clip_grad_norm_` returns); loss terms
  as `loss/<term>`; field errors as `val/rel_l2` and `val/rel_l2/<variable>`;
  `perf/inference_s`, `perf/solver_s`. Anything else shows under "Other
  metrics".
- `step` is the global optimizer step: it never resets. Resuming from a
  checkpoint: save `run.id` in the checkpoint and pass `id=` to `init`.
- `run.should_stop()` turns `True` when the user presses Stop in the app:
  check it where the script can save a checkpoint (the end of an epoch, or
  every N steps) and leave the loop. Use the script's own checkpoint code;
  if it has none, just `break`. A script that never checks is ended as by
  scancel.
- Always give `total_steps` when it's known: without it there's no progress
  bar or time left.
- DDP: only rank 0 calls `init`, `watch` and `log`.
- Models that predict a field (neural operators, PDE surrogates): after each
  evaluation `run.log_field("u", pred[0, 0], target[0, 0], extent=..., axes=...)`,
  `run.log_eval("u", preds, targets)`, and `pde={...}` in `init`. See
  "Fields" and "Diagnostics" in `logger/README.md`.

## A Python simulation

```python
sim = soliton.simulate(
    "kh-2048-re1e4", project="turbulence", t_end=10.0,     # or max_iterations= for a steady solve
    setup={"equation": "Incompressible Navier-Stokes", "method": "Fourier spectral",
           "grid": "2048 x 2048", "Re": 1e4},
    monitor="enstrophy", cfl_limit=1.0)
with sim:
    while t < t_end:
        ...                                                   # the solver's own step
        if step % 50 == 0:
            sim.log({"energy": E, "enstrophy": Z, "cfl": cfl}, t=t, dt=dt)
        if step % 2000 == 0:
            sim.log_field("vorticity", w, extent=[(0, 1), (0, 1)], axes=["y", "x"])
```

Names containing "residual" or "error" are drawn on a log scale; a value
named `cfl` is drawn with `cfl_limit`. Conserved quantities (mass, energy)
show how far they drifted. Pass `stop_on_divergence=True` to stop the solver
at the first NaN (it raises `soliton.Diverged`).
`sim.should_stop()` is the app's Stop button, as for training: check it where
the solver can write a restart file, then leave the loop.

## Data

```python
ds = soliton.register_dataset(path, name="ns2d", version="v3", source="Simulated",
                              splits={"train": 8000, "val": 1000})
run = soliton.init(..., datasets=[ds])        # or a path
```

A run that writes data registers it with `run.register_dataset(path)` (or
`sim.`), so the app shows what made it. From a shell:
`python3 -m soliton data add PATH --version v1 --source Simulated`.
