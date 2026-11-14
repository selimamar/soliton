# Instructions for a coding agent that writes your training code

If another agent writes or runs your training scripts, this tells it to report
every run to ModelsApp. Copy everything below the line into the instructions
file at the root of your training project: `CLAUDE.md` for Claude Code,
`AGENTS.md` for Codex and several other agents. You can also paste it into a
prompt. Replace `/path/to/ModelsAPP` with where this repository is on the
machine that trains (on Sherlock, your copy there).

Set `MODELSAPP_SERVER` and `MODELSAPP_TOKEN` yourself, in your shell or in
`~/.modelsapp_env` on Sherlock (see [sherlock.md](sherlock.md)), so the token
never appears in the agent's code.

---

## Experiment tracking: modelsapp

Every training script in this project reports to ModelsApp through the `modelsapp`
Python package, so I can follow runs on my phone.

**Install** once per Python environment: `pip install /path/to/ModelsAPP/logger`
(no dependencies). Full docs: /path/to/ModelsAPP/logger/README.md

**Server and token** come from the environment variables `MODELSAPP_SERVER` and
`MODELSAPP_TOKEN`, which I set. Never write the token into code, configs or logs,
and never print it. If they aren't set, the logger only saves runs locally; that's
fine, don't work around it.

**In every training script**
- Before training: `run = modelsapp.init(name, project=..., config=hparams,
  train_samples=train_set, val_samples=val_set, loss=criterion,
  total_steps=..., total_epochs=...)`. `name` is short and descriptive
  (model-dataset-variant). `config` holds all other hyperparameters as a dict.
  Always pass `train_samples` and `val_samples` (a number, a dataset or a
  DataLoader) and `loss` (the criterion module, a function or a string such
  as "CrossEntropyLoss + Dice"): they're listed first in the app.
- Use `project=` for what the model does (e.g. "image-classification") and
  `tags=[...]` for what makes this run different (e.g. ["baseline"],
  ["ablation", "no-dropout"]): I group runs by them in the app. Put the
  reason for the run in `notes=` (one or two sentences).
- PyTorch: `run.watch(model, every=100)` right after building the model.
  It also records the layers for the app's network diagram on the first
  forward pass. With DDP, only rank 0 calls init, watch and log.
- In the training loop, after `loss.backward()` and before `optimizer.zero_grad()`:
  `run.log({"train/loss": loss, "optim/lr": lr}, step=global_step, epoch=epoch)`.
  If you clip gradients, also log `"optim/grad_norm"`: the value `clip_grad_norm_` returns.
- After each evaluation: `run.log({"val/loss": ..., "val/accuracy": ...}, step=global_step)`.
- If the model predicts a field (a neural operator, a PDE surrogate), after each
  evaluation also log one fixed validation sample, one channel per name:
  `run.log_field("u", pred[0, 0], target[0, 0])`; for time-dependent problems a
  rollout, `run.log_rollout("u", pred_frames, true_frames, times=t)` (frames on
  axis 0); and once in a while the layers, with
  `with torch.no_grad(), run.capture_layers(model): model(x[:1])`. Pass the
  domain with `extent=` and `axes=`. Each evaluation, also log the whole
  validation set with `run.log_eval("u", preds, targets)` and
  `run.log({"val/rel_l2": err, "val/rel_l2/u": err_u, ...})`; name loss terms
  `loss/data`, `loss/pde`, ...; log `perf/inference_s` (and `perf/solver_s` if
  known) once. Pass `pde={...}` to `init()`. See logger/README.md, "Fields" and
  "Diagnostics".
- Use exactly these names for these quantities. Other names (e.g. `train/accuracy`)
  are fine and show under "Other metrics".
- `step` is the global optimizer step: keep it increasing across epochs, never
  reset it. When resuming from a checkpoint, save `run.id` in the checkpoint and
  pass `id=` it to `init` so the same run continues.
- Use `with modelsapp.init(...) as run:` or call `run.finish()` at the end. Don't
  catch exceptions just to hide a crash: a crashed run should show as crashed.
- If one step takes only a few milliseconds, log every 10-50 steps: logging a GPU
  tensor makes Python wait for the GPU.

- For a simulation that isn't training a model (a PDE solver):
  `sim = modelsapp.simulate(name, project=..., t_end=..., setup={...}, monitor="energy")`,
  then each step `sim.log({"energy": E, "cfl": cfl}, t=t, dt=dt)`, a field
  every few hundred steps with `sim.log_field("u", u)`, and `sim.finish()`
  (or `with sim:`). Don't replace NaN before logging it: the first NaN marks
  the simulation as diverged. See logger/README.md, "Simulations".

**Check it works** with a short run (a few hundred steps), then:
`curl -s -H "Authorization: Bearer $MODELSAPP_TOKEN" "$MODELSAPP_SERVER/api/runs"`
The new run should be in the list.

**On Sherlock**, in Slurm job scripts, before `python train.py`:
`source ~/.modelsapp_env` and `export MODELSAPP_DIR=$SCRATCH/modelsapp-runs`
