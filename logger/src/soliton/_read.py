"""Reading runs back from the server, for your own analysis and figures:

    import soliton

    runs = soliton.runs(project="operator-learning", tags=["final"])
    for run in runs:
        curve = run.metric("val/rel_l2")          # every point, not thinned out
        plt.plot(curve.steps, curve.values, label=run.name)
    runs.table(["val/rel_l2"]).to_pandas()        # one row per run

Reading needs the server's main token (the job token can only add runs), so
use it on the machine you analyse on, never in job scripts. Standard library
only; `to_pandas()` needs pandas.
"""

from __future__ import annotations

import csv
import fnmatch
import json
import math
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, Tuple, Union

from ._util import urlopen

PAGE = 20_000  # Points per request.

# A metric where higher is better, for "best": accuracy and the like, unless
# its name says it's a loss or an error.
_HIGHER = re.compile(r"acc|f1|auc|precision|recall|score|psnr|ssim|iou|r2|reward|return",
                     re.IGNORECASE)
_LOWER = re.compile(r"loss|err|l2|mse|mae|rmse|nll|perplexity|ppl|time|_s$", re.IGNORECASE)

_JOB_TOKEN = (
    "reading runs needs the server's main token, and SOLITON_TOKEN is the job token, which "
    "can only add runs. Use the main token where you analyse (e.g. pass token=... or set "
    "SOLITON_TOKEN in that shell), never in job scripts"
)


def higher_is_better(name: str) -> bool:
    """Whether a bigger value of metric [name] is better (accuracy, PSNR,
    reward); else smaller (losses, errors, times)."""
    return bool(_HIGHER.search(name)) and not _LOWER.search(name)


def _number(value: Any) -> float:
    if isinstance(value, str):
        return {"NaN": math.nan, "Infinity": math.inf, "-Infinity": -math.inf}.get(value, math.nan)
    return math.nan if value is None else float(value)


def _time(value: Any) -> Optional[datetime]:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


class _Reader:
    def __init__(self, server: Optional[str], token: Optional[str], timeout: float = 60) -> None:
        server = server or os.environ.get("SOLITON_SERVER")
        token = token or os.environ.get("SOLITON_TOKEN")
        if not server or not token:
            raise ValueError("reading runs needs a server and its main token: set SOLITON_SERVER "
                             "and SOLITON_TOKEN, or pass server=... and token=...")
        self.server = server.rstrip("/")
        self._token = token
        self._timeout = timeout

    def get(self, path: str, params: Optional[Dict[str, Any]] = None) -> Any:
        url = self.server + path + ("?" + urllib.parse.urlencode(params) if params else "")
        request = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self._token}", "User-Agent": "soliton-logger"})
        try:
            with urlopen(request, timeout=self._timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            detail = _detail(error)
            if error.code == 401:
                raise PermissionError(f"the server at {self.server} rejected the token") from None
            if error.code == 403 and "job token" in detail.lower():
                raise PermissionError(_JOB_TOKEN) from None
            if error.code == 404 and detail == "Not Found":
                # No such route, rather than no such run.
                raise RuntimeError(f"the server at {self.server} is older than this logger and "
                                   "can't be read from yet: update it (git pull, then restart "
                                   "it)") from None
            if error.code == 404:
                raise LookupError(detail or f"not found on {self.server}") from None
            raise RuntimeError(f"HTTP {error.code} from {self.server}: {detail}") from None
        except (urllib.error.URLError, OSError) as error:
            reason = getattr(error, "reason", error)
            raise ConnectionError(f"can't reach {self.server}: {reason}") from None


def _detail(error: urllib.error.HTTPError) -> str:
    try:
        body = json.loads(error.read())
        return str(body.get("detail", "")) if isinstance(body, dict) else ""
    except (ValueError, OSError):
        return ""


@dataclass(frozen=True)
class Curve:
    """Every logged value of one metric of one run, in step order. NaN and
    infinity come back as floats."""

    name: str
    steps: List[int]
    values: List[float]

    def __len__(self) -> int:
        return len(self.steps)

    def __iter__(self) -> Iterator[Tuple[int, float]]:
        return iter(zip(self.steps, self.values))

    def to_pandas(self):
        """A pandas Series indexed by step."""
        import pandas as pd

        return pd.Series(self.values, index=pd.Index(self.steps, name="step"), name=self.name)


@dataclass(frozen=True)
class Summary:
    """One metric of one run at a glance. min and max are over finite values
    (None if it never had one); final may be NaN (a diverged run)."""

    name: str
    count: int
    first: float
    first_step: int
    final: float
    final_step: int
    min: Optional[float]
    min_step: Optional[int]
    max: Optional[float]
    max_step: Optional[int]

    @property
    def best(self) -> Optional[float]:
        """The max for accuracy-like names, else the min (see higher_is_better)."""
        return self.max if higher_is_better(self.name) else self.min

    @property
    def best_step(self) -> Optional[int]:
        return self.max_step if higher_is_better(self.name) else self.min_step


class StoredRun:
    """A run as the server has it. Its metrics are fetched when first asked
    for, then kept."""

    def __init__(self, data: Dict[str, Any], reader: _Reader) -> None:
        self._reader = reader
        self.data = data
        self.id: str = data["id"]
        self.name: str = data["name"]
        self.project: str = data.get("project", "")
        self.host: str = data.get("host", "")
        self.status: str = data["status"]
        self.status_message: Optional[str] = data.get("statusMessage")
        self.started_at = _time(data.get("startedAt"))
        self.ended_at = _time(data.get("endedAt"))
        self.current_step: int = data.get("currentStep", 0)
        self.total_steps: int = data.get("totalSteps", 0)
        self.config: Dict[str, str] = dict(data.get("hyperparameters") or {})
        self.tags: List[str] = list(data.get("tags") or [])
        self.notes: str = data.get("notes", "")
        self.system: Optional[dict] = data.get("system")
        self.jobs: List[dict] = list(data.get("jobs") or [])
        self.health: List[dict] = list(data.get("health") or [])
        self.simulation: Optional[dict] = data.get("simulation")
        # Thinned out on the server to save space: when, and to how many
        # points per curve (its metrics then aren't every point logged).
        self.thinned_at = _time(data.get("thinnedAt"))
        self.thinned_to: Optional[int] = data.get("thinnedTo")
        self._curves: Dict[str, Curve] = {}
        self._summary: Optional[Dict[str, Summary]] = None

    def __repr__(self) -> str:
        return f"<StoredRun {self.id} {self.status} step {self.current_step:,}>"

    @property
    def summary(self) -> Dict[str, Summary]:
        """Each metric the run logged: count, first, final, min and max."""
        if self._summary is None:
            raw = self._reader.get(f"/api/runs/{_quote(self.id)}/metrics/summary")
            self._summary = {
                name: Summary(
                    name=name, count=e["count"], first=_number(e["first"]),
                    first_step=e["firstStep"], final=_number(e["final"]),
                    final_step=e["finalStep"],
                    min=None if e["min"] is None else _number(e["min"]), min_step=e["minStep"],
                    max=None if e["max"] is None else _number(e["max"]), max_step=e["maxStep"],
                )
                for name, e in raw.items()
            }
        return self._summary

    @property
    def metrics(self) -> List[str]:
        """The names of the metrics it logged."""
        return sorted(self.summary)

    def metric(self, name: str) -> Curve:
        """Every value of metric [name] (e.g. "val/rel_l2"), at full
        resolution; empty if the run never logged it."""
        if name not in self._curves:
            steps: List[int] = []
            values: List[float] = []
            after: Optional[int] = -1
            while after is not None:
                page = self._reader.get(f"/api/runs/{_quote(self.id)}/metrics/points",
                                        {"name": name, "after": after, "limit": PAGE})
                steps += page["steps"]
                values += [_number(v) for v in page["values"]]
                after = page["next"]
            self._curves[name] = Curve(name, steps, values)
        return self._curves[name]

    def row(self, metrics: Sequence[str] = ()) -> Dict[str, Any]:
        """One row of `Runs.table()`."""
        row: Dict[str, Any] = {
            "id": self.id, "name": self.name, "project": self.project, "host": self.host,
            "status": self.status, "started_at": self.started_at, "ended_at": self.ended_at,
            "step": self.current_step, **self.config,
        }
        for name in metrics:
            entry = self.summary.get(name)
            row[name] = None if entry is None else entry.final
            row[f"{name} best"] = None if entry is None else entry.best
            row[f"{name} best step"] = None if entry is None else entry.best_step
        return row


class Table(list):
    """Rows (dicts) with the same columns, from `Runs.table()`."""

    @property
    def columns(self) -> List[str]:
        return list(dict.fromkeys(key for row in self for key in row))

    def to_pandas(self):
        """A pandas DataFrame, indexed by run id."""
        import pandas as pd

        return pd.DataFrame(list(self), columns=self.columns).set_index("id")

    def to_csv(self, path: Union[str, "os.PathLike[str]"]) -> None:
        with open(path, "w", newline="") as file:
            writer = csv.DictWriter(file, fieldnames=self.columns)
            writer.writeheader()
            writer.writerows(self)


class Runs(list):
    """Runs from `soliton.runs()`, newest first: a list of StoredRun."""

    def table(self, metrics: Union[str, Iterable[str]] = ()) -> Table:
        """One row per run: what describes it (name, project, status, ...),
        its settings, and for each of [metrics] its final value, its best
        (lowest; highest for accuracy-like names) and the step of that best."""
        names = [metrics] if isinstance(metrics, str) else list(metrics)
        return Table(run.row(names) for run in self)

    def to_pandas(self):
        """`table()` as a pandas DataFrame."""
        return self.table().to_pandas()

    def __getitem__(self, key):
        if isinstance(key, str):  # By id or name.
            for run in self:
                if key in (run.id, run.name):
                    return run
            raise KeyError(key)
        result = super().__getitem__(key)
        return Runs(result) if isinstance(key, slice) else result


def runs(project: Optional[str] = None, *, tags: Optional[Iterable[str]] = None,
         status: Union[None, str, Iterable[str]] = None, host: Optional[str] = None,
         name: Optional[str] = None, server: Optional[str] = None,
         token: Optional[str] = None) -> Runs:
    """The server's runs (and simulations), newest first, for your own
    analysis and figures.

    project, host: exact. tags: runs with all of them. status: "live",
    "finished", "crashed", "queued", or several. name: a pattern, e.g.
    "fno-*". server, token: default SOLITON_SERVER, SOLITON_TOKEN; reading
    needs the main token (the job token can only add runs).
    """
    reader = _Reader(server, token)
    wanted_tags = set(tags or ())
    statuses = {status} if isinstance(status, str) else set(status or ())
    found = Runs()
    for data in reader.get("/api/runs"):
        if project is not None and data.get("project") != project:
            continue
        if host is not None and data.get("host") != host:
            continue
        if statuses and data.get("status") not in statuses:
            continue
        if wanted_tags and not wanted_tags <= set(data.get("tags") or ()):
            continue
        if name is not None and not fnmatch.fnmatchcase(data.get("name", ""), name):
            continue
        found.append(StoredRun(data, reader))
    return found


def get_run(run_id: str, *, server: Optional[str] = None,
            token: Optional[str] = None) -> StoredRun:
    """One run by its id (as the app shows it under the run's name, or
    `run.id` in the script). Raises LookupError if there's none."""
    reader = _Reader(server, token)
    return StoredRun(reader.get(f"/api/runs/{_quote(run_id)}"), reader)


def _quote(run_id: str) -> str:
    return urllib.parse.quote(run_id, safe="")
