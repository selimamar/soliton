"""`modelsapp demo`: a small real training run, to try the app.

An MLP learns to imitate a random "teacher" network, so the loss really
falls and the layer statistics are real.
"""

from __future__ import annotations

import math
import time
from typing import Optional

import modelsapp


def train(steps: int = 3000, delay: float = 0.02, crash_at: Optional[int] = None,
          name: str = "demo-mlp") -> None:
    """[crash_at]: make the loss NaN from this step on, and stop with an error
    5 steps later, to see how a crash looks."""
    try:
        import torch
        from torch import nn
    except ImportError:
        raise SystemExit("modelsapp demo needs PyTorch: pip install torch") from None

    torch.manual_seed(0)
    features, classes, batch, steps_per_epoch = 32, 10, 128, 100
    teacher = nn.Sequential(nn.Linear(features, 64), nn.Tanh(), nn.Linear(64, classes))
    model = nn.Sequential(
        nn.Linear(features, 128), nn.ReLU(),
        nn.Linear(128, 128), nn.ReLU(),
        nn.Linear(128, 64), nn.ReLU(),
        nn.Linear(64, classes),
    )
    config = {"Optimizer": "AdamW", "Learning rate": 3e-3, "Batch size": batch,
              "Schedule": "cosine", "Weight decay": 0.01}
    optimizer = torch.optim.AdamW(model.parameters(), lr=config["Learning rate"], weight_decay=0.01)
    loss_fn = nn.CrossEntropyLoss()

    def data(n):
        x = torch.randn(n, features)
        with torch.no_grad():
            y = teacher(x).argmax(dim=1)
        return x, y

    val_x, val_y = data(2048)
    with modelsapp.init(name, project="demos", config=config, total_steps=steps,
                        total_epochs=math.ceil(steps / steps_per_epoch)) as run:
        run.watch(model, every=50)
        for step in range(steps):
            lr = config["Learning rate"] * 0.5 * (1 + math.cos(math.pi * step / steps))
            if step == crash_at:
                with torch.no_grad():  # Simulate a blow-up: from here on, the loss is NaN.
                    model[2].weight[0, 0] = float("inf")
            for group in optimizer.param_groups:
                group["lr"] = lr
            x, y = data(batch)
            loss = loss_fn(model(x), y)
            optimizer.zero_grad()
            loss.backward()
            grad_norm = torch.nn.utils.clip_grad_norm_(model.parameters(), float("inf"))
            metrics = {"train/loss": loss, "optim/lr": lr, "optim/grad_norm": grad_norm}
            if step % 100 == 0 or step == steps - 1:
                model.eval()
                with torch.no_grad():
                    logits = model(val_x)
                    metrics["val/loss"] = loss_fn(logits, val_y)
                    metrics["val/accuracy"] = (logits.argmax(1) == val_y).float().mean()
                model.train()
            run.log(metrics, step=step, epoch=step // steps_per_epoch)
            optimizer.step()
            if crash_at is not None and step >= crash_at + 5 and not math.isfinite(loss.item()):
                raise FloatingPointError(f"Loss became NaN at step {crash_at}")
            if delay:
                time.sleep(delay)
