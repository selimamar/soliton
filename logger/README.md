# modelsapp (logger)

Sends your training metrics and per-layer statistics to a ModelsApp server,
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

## Use

```python
import modelsapp

run = modelsapp.init(
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

Or `with modelsapp.init(...) as run:`, which finishes (or marks the run as
crashed) for you. If you forget both, the run is still finished when the
script ends, or marked crashed with the exception when it dies.

Set the server and token in the environment (keep the token out of your code):

```bash
export MODELSAPP_SERVER=https://runs.example.com
export MODELSAPP_TOKEN=...            # modelsapp-server --show-token
```

If a coding agent writes your training code, give it
[docs/for-agents.md](../docs/for-agents.md): the same rules, written as
instructions for it.

### Metric names

The app gives these their own charts: `train/loss`, `val/loss`,
`val/accuracy`, `optim/lr` and `optim/grad_norm`. Anything else shows up under
"Other metrics". Values may be Python, NumPy or PyTorch scalars (tensors are
read with `.item()`), and may be NaN or infinite: that's what a diverging run
logs, and the app shows it. Names starting with `system/` are the logger's
own (below) and go to the System tab.

### System: what it trains on, and how busy it keeps it

When a run starts, it records the machine: GPUs (model, memory, driver),
CPU and the cores the job may use, memory (the job's Slurm limit, else the
machine's), Python, PyTorch, CUDA and cuDNN versions, the OS, the host name,
and the Slurm job (id, name, partition, nodes, cluster, array task).

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
the network (a filmstrip, input to output; tap a layer to see it large):

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

### All `init()` options

| Option | Default | |
|---|---|---|
| `name` | required | Shown in the app |
| `project` | `""` | Shown under the name; the app can group runs by it |
| `system_metrics`, `system_interval` | `True`, `15` | Sample GPU, memory and CPU use every `system_interval` seconds (see above) |
| `tags`, `notes` | none | To organise runs in the app, e.g. `tags=["baseline"]`, `notes="first try with AdamW"`. Only the starting values: they're then edited in the app, and the logger never overwrites them |
| `config` | none | Hyperparameters: a dict (nested is fine) or argparse namespace |
| `train_samples`, `val_samples` | none | How many samples are trained and validated on: a number, a dataset, or a DataLoader (its dataset is counted, not its batches) |
| `loss` | none | The loss: the criterion module (shown with the settings that differ from the defaults, e.g. `CrossEntropyLoss(label_smoothing=0.1)`), a function, or a string |
| `total_steps`, `total_epochs` | 0 | Progress bar, time left, epochs on the x-axis |
| `host` | detected | Where it runs: `MODELSAPP_HOST`, else the Slurm cluster (e.g. "Sherlock"), the platform (Modal, RunPod, Colab, Kaggle, SageMaker, AWS Batch), the cloud (AWS, GCP, Azure, DigitalOcean, Hetzner, Oracle Cloud, Vultr, Linode), Kubernetes, else the machine's name |
| `id` | new | Pass a previous run's id to continue it |
| `server`, `token` | `MODELSAPP_SERVER`, `MODELSAPP_TOKEN` | |
| `mode` | `MODELSAPP_MODE`, else `online` if a server is set | `online`, `offline` (save only) or `disabled` |
| `dir` | `MODELSAPP_DIR`, else `./modelsapp-runs` | Where runs are saved |

## Running elsewhere: Modal, cloud machines, containers

The logger only needs Python and outgoing HTTPS to the server, so jobs on
any of them report to the same server, next to your Sherlock runs. The server
must be reachable from the internet (not the test server inside Sherlock).
The host is detected (table above), and memory and CPU are measured against
the container's own limits.

On [Modal](https://modal.com/docs), keep the address and token in a secret
(`modal secret create modelsapp MODELSAPP_SERVER=https://... MODELSAPP_TOKEN=...`)
and add the logger to the image, roughly (check Modal's docs for the current
API):

```python
image = (
    modal.Image.debian_slim()
    .pip_install("torch")
    .add_local_dir("logger", "/opt/modelsapp-logger", copy=True)  # from this repository
    .run_commands("pip install /opt/modelsapp-logger")
)
app = modal.App("train", image=image)


@app.function(gpu="A100", secrets=[modal.Secret.from_name("modelsapp")], timeout=6 * 3600)
def train():
    import modelsapp

    with modelsapp.init("resnet50-modal", ...) as run:
        ...
```

A container's disk disappears with it, and with it the logger's local copy
of the run. That's fine while the server is reachable (everything is already
uploaded); as a fallback for when it isn't, point `MODELSAPP_DIR` at a
persistent volume (on Modal, a `modal.Volume`) and run `modelsapp sync` on it
later.

## Offline, and uploading later

Every run is saved to `modelsapp-runs/<run id>/events.jsonl` first. In
`online` mode a background thread uploads new records every 2 seconds and
retries with backoff when the server can't be reached. If something is
left when the run ends, it says so; upload it later with:

```bash
modelsapp sync                      # every run in ./modelsapp-runs
modelsapp sync path/to/run-folder   # one run
```

`sync` only sends what the server doesn't have yet, and the server ignores
duplicates, so running it twice is harmless. With `MODELSAPP_MODE=offline`,
nothing is uploaded during training. Use it where there's no internet, then
`sync` from a machine that has it.

## Stopped jobs

- An exception or Ctrl-C marks the run as crashed, with the error message.
- `SIGTERM` (a Slurm time limit, `scancel`) marks it as crashed with that
  reason, uploads for up to 15 seconds, and lets the signal end the process
  as usual. This applies only if your script doesn't handle `SIGTERM` itself.
- If the process is killed outright (`SIGKILL`, out of memory), the server
  marks the run as crashed ("lost contact") after 10 minutes of silence.

## Try it

`modelsapp demo` trains a small model on random data (needs PyTorch), so
you can watch a real run in the app. `modelsapp demo --crash-at 500` makes
the loss NaN at step 500 and crashes, to show what that looks like.

## Tests

```bash
source env.sh && pytest logger/tests
```

The tests in `test_with_server.py` run the logger against the real server
over HTTP.
