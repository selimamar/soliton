# soliton (logger)

Sends your training metrics and per-layer statistics to a Soliton server,
so you can follow the run on your phone.

- Standard library only (Python 3.9+). PyTorch is needed only for `run.watch()`.
- Saves everything to disk first and uploads in the background, so a slow or
  broken network never slows down or loses your training run.
- Marks the run as crashed, with the error, when your script dies.

## Install

Into the Python environment you train with:

```bash
pip install ./logger        # from a copy of this repository
```

Once the repository is on GitHub, `pip install "git+https://github.com/<you>/<repo>.git#subdirectory=logger"`
works too.

## Setting up a machine: `soliton setup`

Once per machine (a cluster's login node, your laptop):

```bash
soliton setup --server https://runs.example.com
```

It asks for the token without showing it, so it never lands on a command
line or in shell history, checks it with the server (and says whether it's
the main token or a job token), then writes `~/.soliton_env`, readable by
you only, keeping any other lines in it. Job scripts `source ~/.soliton_env`.
Nothing is saved if the server rejects the token or can't be reached
(`--no-check` saves anyway, e.g. on a machine that can't reach the server
but whose jobs can). A token piped in (`... | soliton setup`) is read from
standard input instead. For clusters, use the app's job token (Settings →
Advanced security).

## Use

```python
import soliton

run = soliton.init(
    "resnet50-cifar",                 # shown in the app
    project="image-classification",
    config={"Optimizer": "AdamW", "Learning rate": 3e-4, "Batch size": 256},
    train_samples=train_set,          # or a DataLoader, or a number
    val_samples=val_set,
    loss=criterion,                   # e.g. nn.CrossEntropyLoss(label_smoothing=0.1)
    total_steps=50_000,               # for the progress bar and time left
    total_epochs=100,
)
run.watch(model, every=100)           # layer statistics, network diagram

for epoch in range(100):
    for x, y in loader:
        loss = criterion(model(x), y)
        optimizer.zero_grad()
        loss.backward()
        run.log({"train/loss": loss, "optim/lr": scheduler.get_last_lr()[0]},
                step=step, epoch=epoch)   # after backward(): includes gradients
        optimizer.step()
        step += 1
    run.log({"val/loss": val_loss, "val/accuracy": val_acc}, step=step)

run.finish()
```

Or `with soliton.init(...) as run:`, which finishes (or marks the run as
crashed) for you. If you forget both, the run is still finished when the
script ends, or marked crashed with the exception when it dies.

Set the server and token in the environment (keep the token out of your code):

```bash
export SOLITON_SERVER=https://runs.example.com
export SOLITON_TOKEN=...            # soliton-server --show-token
```

If a coding agent writes your training code, give it
[docs/for-agents.md](https://github.com/selimamar/soliton/blob/main/docs/for-agents.md): the same rules, written as
instructions for it.

### Metric names

The app gives these their own charts: `train/loss`, `val/loss`,
`val/accuracy`, `optim/lr` and `optim/grad_norm`. Groups of names share one
chart:

- `loss/<term>` (e.g. `loss/data`, `loss/pde`, `loss/bc`): the terms of a
  composite or physics-informed loss, so you see when one takes over.
- `val/rel_l2` and `val/rel_l2/<variable>` (e.g. `val/rel_l2/u`): the
  validation error overall and per variable. The Sweep screen compares runs
  on `val/rel_l2`.
- `perf/inference_s` and `perf/solver_s`: seconds per sample for the model
  and for the numerical solver it replaces. The Overview shows the speed-up;
  the Sweep screen plots error against cost.

Anything else shows up under "Other metrics". Values may be Python, NumPy or PyTorch scalars (tensors are
read with `.item()`), and may be NaN or infinite: that's what a diverging run
logs, and the app shows it. Names starting with `system/` are the logger's
own (below) and go to the System tab.

### Training health

The logger watches what you log and tells you when training goes wrong,
while there's still time to act:

- **NaN loss**: a loss (any name containing "loss") turns NaN or infinite.
- **Diverging loss**: a training loss climbs back up, to 10 times its lowest
  (smoothed) value and at least 5% of where it started (so the noise of a
  loss that is already tiny doesn't count), or back to where it started
  after having halved.
  Validation losses don't count: rising can be overfitting.
- **Exploding gradients**: a gradient norm (a name ending in `grad_norm`,
  e.g. `optim/grad_norm`, what `clip_grad_norm_` returns) stays more than 10
  times its usual size, or NaN, for 5 logs in a row. One-off spikes (clipped,
  or skipped by a gradient scaler) don't count.

Each is printed (`soliton: warning: train/loss is NaN at step 1,234`), shown
at the top of the run's Overview with what usually helps, and sent as an
alert (and through ntfy), once per kind and job. The run goes on: with
`init(stop_on_divergence=True)`, a NaN or infinite loss also ends it as
crashed ("Diverged: ...") and raises `soliton.Diverged`, to stop the script
before it spends more GPU hours. Simulations have their own divergence check
(below). `SOLITON_HEALTH=0` turns the checks off.

### System: what it trains on, and how busy it keeps it

When a run starts, it records the machine: GPUs (model, memory, driver),
CPU and the cores the job may use, memory (the job's Slurm limit, else the
machine's), Python, PyTorch, CUDA and cuDNN versions, the OS, the host name,
and the Slurm job (id, name, partition, nodes, cluster, array task, and
when it was submitted, started and will reach its time limit: one
`scontrol show job` when the run starts).

While it runs, every 15 seconds (`system_interval`), it samples:

| Metric | |
|---|---|
| `system/gpu.<i>.utilization` | GPU use, % |
| `system/gpu.<i>.memory_gb`, `system/gpu.<i>.memory` | GPU memory in use, GB and % |
| `system/gpu.<i>.temperature`, `system/gpu.<i>.power` | °C, W |
| `system/cpu` | CPU, % of the cores the job may use |
| `system/memory_gb`, `system/memory` | Memory in use, GB and % of the limit |

Samples are stored at the step training is at. GPUs come from `nvidia-smi`
(only the job's: it follows `CUDA_VISIBLE_DEVICES`). In a Slurm job, memory and
CPU are the whole job's (DataLoader workers included), read from its cgroup:
the memory is what Slurm's `--mem` limit applies to, so a run creeping towards
100% is about to be killed. In a container (Modal, Docker, Kubernetes) they
are the container's, measured against its memory limit and CPU quota (e.g.
`docker run --cpus 2` counts as 2 cores). Elsewhere they come from psutil if
it's installed, else they cover this process only. `system_metrics=False`
turns the sampling off (the machine is still recorded).

### `run.watch(model, every=100, layers=None, max_layers=64)`

Every `every`-th training forward pass, each watched layer's output is
summarised on its device: mean, standard deviation, a 32-bin histogram, the
share of exact zeros, and the share of dead units (channels or features that
are zero for the whole batch). At the next `run.log()`, the gradient norm of
each layer's own parameters is added. Other passes cost one counter increment;
evaluation passes (`model.eval()`) are ignored.

On the model's first forward pass after `watch()`, it also records which
layers run, in order, and the shape of each one's output. The app draws this
as a network diagram (a column of units per layer, connected to the next) in
the run's Overview. Large models are drawn by block (e.g. ResNet's `layer1`,
or "blocks.0–11 ×12" for a transformer). Skip connections aren't shown.

By default it watches every module that holds parameters itself (Conv,
Linear, norms, embeddings), spread over the model if there are more than
`max_layers`. Pass `layers=["encoder.0", "head"]`, or a function
`(name, module) -> bool`, to choose. The architecture tree with parameter
counts is sent along.

With DistributedDataParallel, log from rank 0 only.

### Fields: `run.log_field`, `run.log_rollout`, `run.capture_layers`

For neural operators and other models that predict a field (a PDE solution
on a grid). The app's **Fields** tab shows the prediction next to the true
field and their difference, with a slider through the logged steps and the
relative L2 error over training.

```python
if step % 500 == 0:                          # e.g. at each validation
    with torch.no_grad():
        pred = model(val_a[:1])              # The same sample each time.
    run.log_field("vorticity", pred[0, ..., 0], val_u[0, ..., 0], step=step)
```

**`run.log_field(name, prediction, target=None, step=None, max_size=None)`**
logs one snapshot. Arrays are NumPy arrays or PyTorch tensors (any device),
**1D, 2D or 3D** once dimensions of size 1 are dropped: log one sample and
one channel; for several variables, one name each (`"u"`, `"v"`, `"p"`).
2D fields show as heatmaps, 1D as lines, and 3D in a **3D view** you turn
by dragging (pinch, or Ctrl/⌘ + scroll, to zoom), with prediction, truth and error
turning together. It draws the field as a see-through volume (values far
from zero, or from the bottom of the range, show most), as a maximum
projection, or as isosurfaces at a level you set (at plus and minus the
level for a signed field). It renders on the device, so 3D views are
coarser while turning and sharpen when you let go. Switch to **Slices** to
cut the field along an axis instead (by default across the shortest axis,
e.g. time in an FNO-3D's (x, y, t) output). 3D rollouts play in either
view.

**`run.log_rollout(name, prediction, target=None, step=None, times=None,
time_axis=0, max_size=None, max_frames=64)`** logs a field over time, e.g.
an autoregressive rollout of shape `[frames, x, y]` (`time_axis` says which
axis counts frames; `times` gives each frame's time). The app plays it, shows
the relative L2 error frame by frame (how error builds up along the rollout),
and draws 1D rollouts as space-time maps. At most `max_frames` frames are
kept, evenly spread, always the first and the last.

```python
traj = rollout(model, val_u[:1, 0], steps=20)          # [20, 1, 64, 64]
run.log_rollout("u", traj[:, 0], val_u[0, 1:21], step=step, times=t[1:21])
```

**`with run.capture_layers(model, step=None, layers=None, channel_axis=None,
reduce="mean", max_size=64):`** records what each layer outputs during the
forward pass in the block, so the app can show the field as it goes through
the network (a filmstrip, input to output; tap a layer to see it large, and a
3D layer output in the same 3D view as 3D fields, or in slices):

```python
with torch.no_grad(), run.capture_layers(model, step=step):
    model(val_a[:1])
```

- Only the first sample, and each layer's first call, are kept.
- `layers`: module names, or a function `(name, module) -> bool`. Default:
  the model's top-level modules, with `ModuleList` and `Sequential` opened
  one level (for an FNO: lifting, each block, projection).
- Each output's channels are averaged (`reduce="norm"`: their L2 norm) to
  leave a 1D to 3D field. The channel axis is guessed: the first or last axis
  of a sample, whichever differs from the spatial axes between them (so
  `[32, 64, 64]` and `[64, 64, 32]` both work). Say it with
  `channel_axis=0` (channels-first) or `-1` (channels-last), counted without
  the batch axis.

All three:

- Errors (relative L2, RMSE, largest pointwise error) are computed on the
  full arrays, ignoring NaN. The snapshot itself is averaged down to at most
  `max_size` points per axis (default 128, 64 for layers; up to 512) and
  `max_points` values in all, all frames together (default 4M, up to 16M),
  and sent as 16-bit values: about 90 KB for 128 × 128 with its target,
  11 MB per array for 4M values. The app loads a whole snapshot to show it,
  so very large ones are slow on a phone.
- `step` defaults to the latest step logged, so a field logged right after
  `run.log(..., step=step)` lands on the same step.
- Snapshots are much larger than metrics: log them every few hundred steps,
  not every step. They need NumPy.
- `extent=[(x0, x1), (y0, y1)]` and `axes=["y", "x"]` (one per array axis, in
  order) give the domain: the app shows coordinates instead of grid indices,
  and names the 3D view's axes.
- `log_field` and `log_rollout` also send the **energy spectrum** (radially
  averaged, on the full grid; a rollout's last frame) of the prediction and
  the target, and a rollout sends per frame the **mean, mean square and
  minimum** of both, for the app's conservation checks (mass, energy,
  positivity).

### Diagnostics: `run.log_eval`, `run.log_curve`, `run.log_fourier_weights`

**`run.log_eval(name, predictions, targets, step=None, worst=4, sample_axis=0,
max_size=64, extent=None, axes=None)`**: the whole validation set, one sample
per entry along `sample_axis`. The relative L2 error of every sample is
computed on the full arrays; only a summary (a 24-bin histogram, the median,
90th percentile and worst) and the `worst` samples (as field snapshots, so
the app can show them in full) are sent. A sample with no finite values
counts as worst.

```python
with torch.no_grad():
    pred = torch.cat([model(a) for a, _ in val_loader])     # [N, 1, 64, 64]
run.log_eval("u", pred[:, 0], val_u[:, 0], step=step)
```

**`run.log_curve(name, x, y, step=None, x_label="", y_label="Relative L2",
train_range=None)`**: a curve measured at one step. For **resolution
invariance**, evaluate at several grids; for **generalization**, across a PDE
parameter, with `train_range` the values seen in training (the app shades
it):

```python
run.log_curve("error vs resolution", [64, 128, 256], errors, x_label="Resolution",
              train_range=(64, 64))
run.log_curve("error vs viscosity", nus, errors, x_label="Viscosity",
              train_range=(5e-4, 2e-3))
```

**`run.log_fourier_weights(model, step=None, max_size=64)`**: for every complex
parameter with 3 or more axes (FNO-style spectral weights, in × out ×
modes...), |w| averaged over the channels, as a map over the modes. Weights
still large at the highest kept mode suggest more modes would help.

### Pictures: `run.log_image`

**`run.log_image(name, image, step=None, *, caption=None)`** logs a picture
the script drew, for plots the app has no form for: a phase portrait, a
confusion matrix, samples from a generative model, a custom diagnostic. It
shows on the run's Fields tab, one card per name, with a slider over the
steps it was logged at; tapping it opens it large to zoom in.

```python
import matplotlib
matplotlib.use("Agg")                     # no window on a cluster
import matplotlib.pyplot as plt

if step % 500 == 0:
    fig, ax = plt.subplots(figsize=(5, 4))
    ax.plot(trajectory[:, 0], trajectory[:, 1])
    run.log_image("phase portrait", fig, caption=f"epoch {epoch}")
    plt.close(fig)
```

`image` is a matplotlib figure, a PIL image, an array (`(H, W)` greyscale,
`(H, W, 3)` RGB or `(H, W, 4)` RGBA, channels first too as PyTorch has them;
floats in [0, 1] are read as such, others stretched from their min to their
max), or a PNG or JPEG file (a path, or its bytes). Pictures larger than 1600
pixels are scaled down, and each is sent once, so log every few hundred
steps, not every step: a picture is typically 20 to 200 KB on the server.
`step` defaults to the latest step logged. A picture that can't be sent
(an unknown kind, or over 6 MB) is skipped with a warning, so training goes
on. Arrays need NumPy; figures and PIL images are saved by the library that
made them. Thinning a run (Settings → Storage) keeps each picture's latest
step.

### Simulations: `soliton.simulate`

A simulation (a PDE solve, or any computation that steps through time or
iterates to convergence) is monitored like a training run, with no model
involved. It shows in the app's **Compute** section, apart from the training
runs: where it is in simulated time, its values against time, its fields,
the machine and its cost.

```python
import soliton

sim = soliton.simulate(
    "kelvin-helmholtz-2048", project="turbulence", t_end=10,
    setup={"equation": "Incompressible Navier-Stokes", "method": "Fourier spectral",
           "grid": "2048 x 2048", "Re": 1e4},
    monitor="enstrophy", cfl_limit=1.0)
with sim:
    while t < 10:
        ...                                       # advance the solver
        sim.log({"energy": E, "enstrophy": Z, "cfl": cfl}, t=t, dt=dt)
        if step % 500 == 0:
            sim.log_field("vorticity", w, extent=[(0, 1), (0, 1)], axes=["y", "x"])
```

- `sim.log(values, t=..., dt=...)`: values at simulated time `t` (stored as
  the metrics `sim/t` and `sim/dt`). The app charts each value against `t`,
  with how far it drifted since the start (for conserved quantities), names
  containing "residual" or "error" on a log scale, and `cfl` with
  `cfl_limit`. The step counts up by itself; pass `step=` to set it.
- A steady solve logs no `t`: pass `max_iterations=` instead of `t_end`,
  and log once per iteration, e.g. `sim.log({"residual": r})`. Its charts
  and snapshots go by iteration.
- `sim.log_curve(name, x, y, x_label=..., y_label=...)`: a result against a
  parameter, e.g. drag against Reynolds number over a parameter study,
  charted on the Diagnostics tab.
- `sim.log_field(name, field)`: a 1D, 2D or 3D snapshot at the latest step,
  shown at its simulated time; `sim.log_rollout(...)` logs several times at
  once. Same sizes, `extent` and `axes` as `run.log_field`.
- **Divergence**: the first NaN or infinity (in a value or a field) ends the
  simulation as crashed, marked "Diverged at t = 0.83: energy is NaN", with
  the bad value recorded. Later calls do nothing. With
  `stop_on_divergence=True`, it also raises `soliton.Diverged`, to stop the
  solver instead of letting it run on.
- `setup`: how it's set up, shown on its Overview (equation, method, grid,
  parameters, boundary and initial conditions; nested dicts are fine).
  `monitor`: the value drawn on its card in the list. The other options
  (`project`, `tags`, `notes`, `system_metrics`, `capture_output`, `capture_code`, `price_per_hour`, `host`,
  `id`, `server`, `token`, `mode`, `dir`) are as for `init()`.

Solvers that aren't in Python can still report, unchanged: launch them
through [skills/claude-code/soliton/scripts/monitor_solver.py](https://github.com/selimamar/soliton/blob/main/skills/claude-code/soliton/scripts/monitor_solver.py),
which reads what the solver writes (text tables of numbers, HDF5 tables) or
prints, and calls `sim.log` for it. Its `--help` has the details.

### Datasets: `soliton.register_dataset`, `soliton data`

The app's **Data** section lists the datasets you have: how big they are,
where they live, what's in them, what made them, and which runs trained on
them. Only their description is uploaded, never the data.

```python
import soliton

ds = soliton.register_dataset(
    "/scratch/users/me/ns2d/v3.h5", name="ns2d-vorticity", version="v3",
    source="Simulated", splits={"train": 8000, "val": 1000, "test": 1000},
    variables=[{"name": "u", "description": "vorticity"}])

run = soliton.init("fno-ns", datasets=[ds])     # listed under the dataset
```

- From a path, the logger reads the size, the number of files, the format
  and a fingerprint (from the files' names, sizes and dates: it changes
  when they do). For NumPy (`.npy`, `.npz`), HDF5, NetCDF, MAT and Zarr
  files it also reads each array's shape and type, the range, mean and
  spread over the first 64 samples, and four small sample previews (a
  sample's trailing axes beyond two are cut at their last index, e.g. the
  last time step). Only headers and those first samples are read, so a
  terabyte file is as quick as a small one. HDF5, NetCDF 4 and MAT v7.3
  need `h5py`; Zarr needs `zarr`; older MAT files need SciPy.
- What you pass wins over what is read: `name` (default: the file's name)
  and `version` make the id (`ns2d-vorticity-v3`); `samples`, `splits`,
  `sample_shape`, `variables` and `previews` (arrays, one per sample) add
  to or replace it. `source` says how it was obtained.
- `init(datasets=[...])` takes registered datasets, dataset ids, or paths
  (registered on the way). Registering the same dataset again updates it.
- A run or simulation that writes a dataset registers it with
  `run.register_dataset(path, ...)` (or `sim.register_dataset`): the app
  then shows what made it and on which machine.
- Without a server (or if it's unreachable), datasets are saved to
  `$SOLITON_DIR/datasets` and uploaded by `soliton sync`.

From a shell, without writing Python:

```bash
soliton data add /scratch/users/me/ns2d/v3.h5 --version v3 --source Simulated
soliton data scan $SCRATCH/data          # each data file or folder of them in there
```

### All `init()` options

| Option | Default | |
|---|---|---|
| `name` | required | Shown in the app |
| `project` | `""` | Shown under the name; the app can group runs by it |
| `system_metrics`, `system_interval` | `True`, `15` | Sample GPU, memory and CPU use every `system_interval` seconds (see above) |
| `capture_output` | `SOLITON_CAPTURE_OUTPUT`, else `True` | Send what the script prints (see Output, below) |
| `capture_code` | `SOLITON_CAPTURE_CODE`, else `True` | Record what it takes to run it again: git commit and changed files, command line, job script, packages (see Reproducing a run, below) |
| `price_per_hour` | `SOLITON_PRICE_PER_HOUR`, else estimated | What the machine costs in US dollars per hour (all its GPUs), for the app's rounded cost estimate. Without it, the app assumes a typical on-demand cloud price for the GPUs (e.g. about $4/h per H100, $2.50 per A100, $0.80 per L4) or $0.05 per CPU core. `0` hides the estimate (e.g. a cluster you don't pay by the hour for) |
| `stop_on_divergence` | `False` | When a loss turns NaN or infinite, end the run as crashed and raise `soliton.Diverged` (see Training health); otherwise it only warns |
| `tags`, `notes` | none | To organise runs in the app, e.g. `tags=["baseline"]`, `notes="first try with AdamW"`. Only the starting values: they're then edited in the app, and the logger never overwrites them |
| `config` | none | Hyperparameters: a dict (nested is fine) or argparse namespace |
| `train_samples`, `val_samples` | none | How many samples are trained and validated on: a number, a dataset, or a DataLoader (its dataset is counted, not its batches) |
| `loss` | none | The loss: the criterion module (shown with the settings that differ from the defaults, e.g. `CrossEntropyLoss(label_smoothing=0.1)`), a function, or a string |
| `datasets` | none | What it trains on: datasets from `register_dataset()`, dataset ids, or paths (registered on the way). The app lists the run under each one |
| `pde` | none | What is solved, listed right after the data and loss: `{"equation": "Navier-Stokes 2D", "viscosity": 1e-3, "domain": "[0, 1]² periodic", "resolution": "64 × 64"}` (nested is fine). The equation becomes the `PDE` hyperparameter, which the app can group runs by |
| `total_steps`, `total_epochs` | 0 | Progress bar, time left, epochs on the x-axis |
| `host` | detected | Where it runs: `SOLITON_HOST`, else the Slurm cluster (e.g. "Sherlock"), the platform (Modal, RunPod, Colab, Kaggle, SageMaker, AWS Batch), the cloud (AWS, GCP, Azure, DigitalOcean, Hetzner, Oracle Cloud, Vultr, Linode), Kubernetes, else the machine's name |
| `id` | new | Pass a previous run's id to continue it, e.g. in a job restarted from a checkpoint (save `run.id` in the checkpoint); a run that had ended turns live again. The app lists each job that ran it and marks where each took over on its charts; its time left counts from where it resumed |
| `server`, `token` | `SOLITON_SERVER`, `SOLITON_TOKEN` | |
| `mode` | `SOLITON_MODE`, else `online` if a server is set | `online`, `offline` (save only) or `disabled` |
| `dir` | `SOLITON_DIR`, else `./soliton-runs` | Where runs are saved |

## Reading runs back: `soliton.runs()`

For your own analysis and figures, read runs back from the server in Python
(a notebook, a script on your computer):

```python
import soliton                      # SOLITON_SERVER, and SOLITON_TOKEN = the main token

runs = soliton.runs(project="operator-learning", tags=["final"])   # newest first
for run in runs:
    curve = run.metric("val/rel_l2")                # every point logged, not thinned out
    plt.plot(curve.steps, curve.values, label=run.name)

table = runs.table(["val/rel_l2", "perf/inference_s"])   # one row per run
table.to_csv("results.csv")                              # or .to_pandas()
```

- **`soliton.runs(project=None, *, tags=None, status=None, host=None,
  name=None)`**: the server's runs and simulations, newest first. `tags`:
  runs with all of them; `status`: one or several of `live`, `finished`,
  `crashed`, `queued`; `name`: a pattern such as `"fno-*"`. Pick one with
  `runs["fno-w32"]` (name or id). `soliton.get_run(id)` reads one by its id.
- **A run** has `id`, `name`, `project`, `host`, `status`,
  `status_message`, `started_at`, `ended_at` (datetimes), `current_step`,
  `total_steps`, `config` (its settings, as the app shows them), `tags`,
  `notes`, `system`, `jobs`, `health` and `simulation`.
- **`run.metric(name)`**: every value logged, at full resolution (the app's
  charts are thinned out to about 1,000 points), as a `Curve` with `steps`
  and `values` (NaN and infinity as floats); `.to_pandas()` for a Series.
  A simulation's simulated time is the metric `sim/t`.
- **`run.summary`**: for each metric, `count`, `first`, `final`, `min`,
  `max` (over finite values) with their steps, and `best`: the max for
  accuracy-like names (accuracy, F1, AUC, PSNR, SSIM, IoU, reward), else the
  min. `run.metrics` lists the names.
- **`runs.table(metrics)`**: one row per run: what describes it, its
  settings, and for each metric its final value, best and step of the best.
  `.to_csv(path)` or `.to_pandas()` (pandas isn't required otherwise).

A run thinned out on the server to save space (Settings → Storage) has
`thinned_at` set and keeps `thinned_to` points per curve (1,000), so
`run.metric()` returns those, not every point it logged.

It needs the server's **main token**, the one the app uses: the job token can
only add runs, and gets a `PermissionError` saying so. Keep the main token
on the machine you analyse on, never in job scripts. Metrics come a page of
20,000 points at a time, so even long runs read back whole.

## Running elsewhere: Modal, cloud machines, containers

The logger only needs Python and outgoing HTTPS to the server, so jobs on
any of them report to the same server, next to your Sherlock runs. The server
must be reachable from the internet (not the test server inside Sherlock).
The host is detected (table above), and memory and CPU are measured against
the container's own limits.

On [Modal](https://modal.com/docs), keep the address and token in a secret
(`modal secret create soliton SOLITON_SERVER=https://... SOLITON_TOKEN=...`)
and add the logger to the image, roughly (check Modal's docs for the current
API):

```python
image = (
    modal.Image.debian_slim()
    .pip_install("torch")
    .add_local_dir("logger", "/opt/soliton-logger", copy=True)  # from this repository
    .run_commands("pip install /opt/soliton-logger")
)
app = modal.App("train", image=image)


@app.function(gpu="A100", secrets=[modal.Secret.from_name("soliton")], timeout=6 * 3600)
def train():
    import soliton

    with soliton.init("resnet50-modal", ...) as run:
        ...
```

A container's disk disappears with it, and with it the logger's local copy
of the run. That's fine while the server is reachable (everything is already
uploaded); as a fallback for when it isn't, point `SOLITON_DIR` at a
persistent volume (on Modal, a `modal.Volume`) and run `soliton sync` on it
later.

## Offline, and uploading later

Every run is saved to `soliton-runs/<run id>/events.jsonl` first. In
`online` mode a background thread uploads new records every 2 seconds and
retries with backoff when the server can't be reached. If something is
left when the run ends, it says so; upload it later with:

Without installing (the logger on `PYTHONPATH`, e.g. on a cluster),
`python3 -m soliton` is the same command.

```bash
soliton sync                      # every run in ./soliton-runs
soliton sync path/to/run-folder   # one run
```

`sync` only sends what the server doesn't have yet, and the server ignores
duplicates, so running it twice is harmless. With `SOLITON_MODE=offline`,
nothing is uploaded during training. Use it where there's no internet, then
`sync` from a machine that has it.

A server older than the logger may not take its newer records (training
health warnings, pictures). Then the logger says so once and sends the rest
without them, so the run's metrics still arrive; update the server to keep
those too.

## Reproducing a run

When a run starts, the logger records what it takes to run it again, shown
on the run's System tab under Reproduce (with a button that copies the
command): the git commit of the script's repository, its branch and remote,
and which files had uncommitted changes (never the diff itself); the command
line and working directory; the Slurm job script (`scontrol write
batch_script`); and the installed Python packages. Values that look like
secrets are replaced by `***`: options and variables named like a token,
password, secret or key (`HF_TOKEN=`, `--api-key x`, `OPENAI_KEY=`,
`GITHUB_PAT=`, `SOLITON_NTFY_URL=`), credentials in URLs
(`postgres://user:***@host`), and Authorization headers. It is a guess: a
secret that looks like any other word gets through, so keep secrets in the
environment, not in scripts. Turn it off with `init(capture_code=False)` or
`SOLITON_CAPTURE_CODE=0`.

## The run key

When a run starts, the logger makes a random key for it, keeps it in the
run's folder (`soliton-runs/<id>/key`, readable by you only) and sends it
with every upload. With a job token (the app's Settings → Advanced
security), the server lets only requests carrying it change that run, so a
leaked job token can't touch runs it didn't start. A job continuing a run
(`init(id=...)`) from the same folder finds the key there; from another
directory or machine, copy that file, or set `SOLITON_RUN_KEY` to its
contents. With the main token, the key isn't needed.

The logger never follows a redirect (uploading, `soliton setup`,
`soliton.runs()`): it would send the token wherever one points, another
host or plain http included. A server that redirects (say an `http://`
address a proxy sends to `https://`) gets an error naming where it points:
use that address instead.

## Output

What the script prints (`print`, logging, warnings, its errors) is sent with
the run every 30 seconds, and shown on its Overview: for a crashed run, the
end of the output with the traceback, first thing. It still goes where it
went too (the terminal, Slurm's `.out` file). The server keeps the last 1,000
lines. Progress bars keep only their last frame, colours are removed, and a
line is cut at 1,000 characters.
Secret-looking values in it are hidden the same way as in the job script.

Only Python's own output is seen: what a C library or a subprocess writes
straight to the terminal isn't. Turn it off with `capture_output=False` or
`SOLITON_CAPTURE_OUTPUT=0`, e.g. when the script prints things that shouldn't
leave the machine.

## Stopping from the app: `run.should_stop()`

A live run's page in the app has a Stop button. The logger hears of it on
its next upload (every few seconds while the run logs), and
`run.should_stop()` turns `True`: save a checkpoint and leave the loop, and
the run ends as finished, "Stopped from the app at step N".

```python
for step in range(start, total_steps):
    ...
    run.log({"train/loss": loss}, step=step)
    if run.should_stop():
        save_checkpoint(model, optimizer, step, run.id)
        break
```

Simulations have it too (`sim.should_stop()`). A script that never calls it
is stopped as by `scancel` instead: the logger sends its own process
`SIGTERM` (see below), and the run ends as crashed, "Stopped from the app".

## Stopped jobs

- An exception or Ctrl-C marks the run as crashed, with the error message.
- `SIGTERM` (a Slurm time limit, `scancel`) marks it as crashed with that
  reason ("Stopped by its Slurm time limit" when the job's limit is at most
  5 minutes away), uploads for up to 15 seconds, and lets the signal end the
  process as usual. This applies only if your script doesn't handle
  `SIGTERM` itself. In a Slurm job script, start Python with
  `exec python ...`: Slurm signals the job script, and a Python started as
  its child never gets the signal. `#SBATCH --signal=B:TERM@60` sends it a
  minute before the limit, leaving time to upload.
- If the process is killed outright (`SIGKILL`, out of memory), the server
  marks the run as crashed: "Stopped by its Slurm time limit" a minute after
  the job's limit, otherwise "lost contact" after 10 minutes of silence.

## Queued jobs: `soliton sbatch`, `soliton queue`

Submit with `soliton sbatch` in place of `sbatch` (soliton's options first,
then sbatch's, unchanged) and the job shows in the app as Queued while it
waits, with how long, why, when Slurm expects to start it, and what it asked
for:

```bash
soliton sbatch --name fno-hires -p gpu -G 1 --time=1-00:00:00 train.sbatch
soliton queue      # later: update what Slurm says of every queued job
```

When the job starts and its script calls `soliton.init()`, the new run takes
the queued one's place (the server matches the Slurm job id). For a job
continuing a run (`init(id=...)`), pass that id: `soliton sbatch --id
fno-hires-3fa9c1 ...` shows that run as queued until it goes on.

`soliton queue` asks `squeue` once about all of your jobs, updates the queued
ones, and ends those that left the queue without starting, with what `sacct`
says (cancelled, failed). It doesn't keep running: run it when you check.
Slurm often has no start estimate ("Not estimated") until a job nears the
front of the queue. When the job starts, the app (and ntfy) says so: "fno-hires
started after 2 h 15 min in the queue". Any Slurm job that waited 10 minutes
or more gets that alert too, `soliton sbatch` or not.

Jobs also refresh the queue themselves: as a Slurm job starts logging, its
logger does what `soliton queue` does once, in the background, for your other
queued jobs (not its own, which its run replaces; in an array, only the first
task). So while you have jobs starting, the queue stays fresh with nothing
polling Slurm from a login node. `SOLITON_REFRESH_QUEUE=0` turns it off.

## Try it

`soliton demo` trains a small model on random data (needs PyTorch), so
you can watch a real run in the app. `soliton demo --crash-at 500` makes
the loss NaN at step 500 and crashes, to show what that looks like.

## Tests

```bash
source env.sh && pytest logger/tests
```

The tests in `test_with_server.py` run the logger against the real server
over HTTP.
