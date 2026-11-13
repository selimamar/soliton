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
logs, and the app shows it.

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

### All `init()` options

| Option | Default | |
|---|---|---|
| `name` | required | Shown in the app |
| `project` | `""` | Shown under the name; the app can group runs by it |
| `tags`, `notes` | none | To organise runs in the app, e.g. `tags=["baseline"]`, `notes="first try with AdamW"`. Only the starting values: they're then edited in the app, and the logger never overwrites them |
| `config` | none | Hyperparameters: a dict (nested is fine) or argparse namespace |
| `train_samples`, `val_samples` | none | How many samples are trained and validated on: a number, a dataset, or a DataLoader (its dataset is counted, not its batches) |
| `loss` | none | The loss: the criterion module (shown with the settings that differ from the defaults, e.g. `CrossEntropyLoss(label_smoothing=0.1)`), a function, or a string |
| `total_steps`, `total_epochs` | 0 | Progress bar, time left, epochs on the x-axis |
| `host` | detected | Where it runs: `MODELSAPP_HOST`, else the Slurm cluster (e.g. "Sherlock"), else the host name |
| `id` | new | Pass a previous run's id to continue it |
| `server`, `token` | `MODELSAPP_SERVER`, `MODELSAPP_TOKEN` | |
| `mode` | `MODELSAPP_MODE`, else `online` if a server is set | `online`, `offline` (save only) or `disabled` |
| `dir` | `MODELSAPP_DIR`, else `./modelsapp-runs` | Where runs are saved |

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
