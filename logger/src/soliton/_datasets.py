"""Datasets: what training data (or simulation output) exists, where it
lives and what is in it. Only the description travels to the server: sizes,
shapes, variable ranges, a few small sample previews. The data stays where
it is.

    ds = soliton.register_dataset("/scratch/me/ns2d/v3.h5", name="ns2d-vorticity",
                                    version="v3", source="Simulated",
                                    splits={"train": 8000, "val": 1000, "test": 1000})
    run = soliton.init("fno", datasets=[ds])     # the run trains on it

Files are read for their headers only (HDF5, NetCDF and MAT v7.3 need h5py;
Zarr needs zarr; .npy and .npz need NumPy). The ranges and previews come
from the first few samples, so a terabyte file is as quick as a small one.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import sys
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence

from ._util import RUN_ID, detect_host, dumps, encode_floats, open_private, private_dir, slugify, to_float

# File formats read for their contents, by suffix.
FORMATS = {
    ".npy": "NumPy", ".npz": "NumPy (npz)", ".h5": "HDF5", ".hdf5": "HDF5", ".hdf": "HDF5",
    ".nc": "NetCDF", ".nc4": "NetCDF", ".mat": "MAT", ".zarr": "Zarr",
}
# Also counted as data in a folder, but not opened.
OTHER_FORMATS = {".pt": "PyTorch", ".pth": "PyTorch", ".csv": "CSV", ".parquet": "Parquet",
                 ".vtk": "VTK", ".vtu": "VTK", ".tfrecord": "TFRecord", ".bin": "Binary"}
SAMPLED = 64  # Samples read for ranges and statistics.
PREVIEWS = 4  # Sample previews sent.
PREVIEW_SIZE = 64  # Points per axis of a preview.


@dataclass
class Dataset:
    """A registered dataset: pass it (or its [id]) to `init(datasets=[...])`."""

    id: str
    name: str
    description: dict = field(repr=False)


def dataset_id(name: str, version: str = "") -> str:
    """"ns2d-vorticity-v3": readable, and the same every time it's registered."""
    text = slugify(f"{name}-{version}" if version else name)
    if not RUN_ID.match(text):
        raise ValueError(f"cannot make an id from {name!r}")
    return text


def describe(
    path: Optional[os.PathLike] = None,
    *,
    name: Optional[str] = None,
    version: str = "",
    description: str = "",
    samples: Optional[int] = None,
    splits: Optional[Mapping[str, int]] = None,
    sample_shape: Optional[Sequence[int]] = None,
    variables: Optional[Sequence[Mapping[str, Any]]] = None,
    source: str = "",
    previews: Optional[Sequence[Any]] = None,
    made_by: Optional[str] = None,
    system: Optional[dict] = None,
    host: Optional[str] = None,
) -> Dataset:
    """A dataset's description: what is given, plus what [path] says
    about itself (size, files, format, fingerprint, variables, samples,
    previews). What is given wins over what is read."""
    info: dict = {}
    read: dict = {}
    if path is not None:
        location = Path(path).expanduser().resolve()
        if not location.exists():
            raise FileNotFoundError(f"no such file or folder: {location}")
        read = inspect(location)
        info["location"] = str(location)
        if name is None:
            name = location.stem if location.is_file() else location.name
    if not name:
        raise ValueError("a dataset needs a name (or a path to take it from)")
    info["name"] = str(name)[:200]
    info.update({k: v for k, v in read.items() if k != "previewArrays"})
    if version:
        info["version"] = str(version)[:60]
    if description:
        info["description"] = str(description)[:2000]
    if source:
        info["source"] = str(source)[:200]
    if samples is not None:
        info["samples"] = int(samples)
    if splits:
        info["splits"] = {str(k)[:40]: int(v) for k, v in list(splits.items())[:10]}
        info.setdefault("samples", sum(info["splits"].values()))
    if sample_shape is not None:
        info["sampleShape"] = [int(n) for n in sample_shape]
    if variables is not None:
        info["variables"] = [_variable(v) for v in variables][:50]
    if made_by:
        info["madeBy"] = str(made_by)
    if system:
        info["system"] = system
    info["host"] = host or detect_host()
    arrays = list(previews) if previews is not None else read.get("previewArrays", [])
    info["previews"] = [p for p in (_preview(a, f"sample {i}") for i, a in
                                    enumerate(arrays[:PREVIEWS])) if p]
    return Dataset(id=dataset_id(info["name"], version), name=info["name"],
                   description=encode_floats(info))


def inspect(path: Path) -> dict:
    """What a file or folder says about itself, without reading it all."""
    files = [path] if path.is_file() else _data_files(path)
    info: dict = {
        "sizeBytes": _size(path),
        "files": len(files) if path.is_dir() else 1,
        "fingerprint": _fingerprint(path, files),
    }
    suffix = path.suffix.lower()
    info["format"] = FORMATS.get(suffix) or OTHER_FORMATS.get(suffix) or _folder_format(files)
    # The biggest readable file stands for a folder of them.
    readable = [f for f in files if f.suffix.lower() in FORMATS]
    if path.suffix.lower() == ".zarr" or path.is_file():
        readable = [path]
    if readable:
        target = max(readable, key=_size)
        try:
            info.update(_read(target))
        except Exception as error:  # A file we can't read is still a dataset.
            print(f"soliton: {target.name}: contents not read ({error})", file=sys.stderr)
    return info


def _read(path: Path) -> dict:
    arrays = _arrays(path)
    if not arrays:
        return {}
    # The main array: the one with the most values.
    main = max(arrays, key=lambda a: math.prod(a[1]))
    name, shape, dtype, get = main
    variables = []
    for vname, vshape, vdtype, vget in arrays[:50]:
        variable = {"name": vname, "shape": list(vshape), "dtype": vdtype}
        if vget is not None and vshape and math.prod(vshape) > 0:
            variable.update(_stats(vget, vshape))
        variables.append(variable)
    info: dict = {"variables": variables}
    if len(shape) >= 2:
        info["samples"] = int(shape[0])
        info["sampleShape"] = [int(n) for n in shape[1:]]
    if get is not None and len(shape) >= 2:
        info["previewArrays"] = [get(i) for i in range(min(PREVIEWS, shape[0]))]
    return info


def _arrays(path: Path) -> list:
    """(name, shape, dtype, get(i) -> sample i or None) for each array."""
    suffix = path.suffix.lower()
    if suffix == ".npy":
        import numpy as np
        array = np.load(path, mmap_mode="r")
        return [(path.stem, array.shape, str(array.dtype), lambda i: np.asarray(array[i]))]
    if suffix == ".npz":
        return _npz(path)
    if suffix in (".h5", ".hdf5", ".hdf", ".nc", ".nc4") or (suffix == ".mat" and _is_hdf5(path)):
        return _hdf5(path)
    if suffix == ".mat":
        from scipy.io import whosmat  # MAT v5 and older: names and shapes only.
        return [(n, tuple(s), t, None) for n, s, t in whosmat(str(path)) if not n.startswith("__")]
    if suffix == ".zarr":
        import zarr
        root = zarr.open(str(path), mode="r")
        items = root.arrays() if hasattr(root, "arrays") else []
        return [(n, a.shape, str(a.dtype), (lambda a: lambda i: a[i])(a)) for n, a in items] or (
            [(path.stem, root.shape, str(root.dtype), lambda i: root[i])]
            if hasattr(root, "shape") else [])
    return []


def _npz(path: Path) -> list:
    import numpy as np
    from numpy.lib import format as npy

    arrays = []
    with zipfile.ZipFile(path) as archive:
        for entry in archive.namelist():
            if not entry.endswith(".npy"):
                continue
            with archive.open(entry) as handle:
                version = npy.read_magic(handle)
                read = npy.read_array_header_1_0 if version == (1, 0) else npy.read_array_header_2_0
                shape, _, dtype = read(handle)
            arrays.append([entry[:-4], shape, str(dtype), None])
    if path.stat().st_size < 512 * 2**20:  # Small enough to load for ranges and previews.
        loaded = np.load(path)
        for item in arrays:
            item[3] = (lambda key: lambda i: loaded[key][i])(item[0])
    return [tuple(a) for a in arrays]


def _hdf5(path: Path) -> list:
    import h5py

    handle = h5py.File(path, "r")
    arrays = []

    def visit(name, node):
        if isinstance(node, h5py.Dataset) and node.shape:
            arrays.append((name, node.shape, str(node.dtype), lambda i, n=node: n[i]))

    handle.visititems(visit)
    return arrays


def _is_hdf5(path: Path) -> bool:
    with open(path, "rb") as handle:
        return handle.read(8) == b"\x89HDF\r\n\x1a\n" or (handle.seek(512) and
                                                       handle.read(8) == b"\x89HDF\r\n\x1a\n")


def _stats(get, shape) -> dict:
    """Range, mean and spread over the first few samples."""
    import numpy as np

    try:
        if len(shape) >= 2:
            values = np.stack([np.asarray(get(i), dtype=np.float64)
                               for i in range(min(SAMPLED, shape[0]))])
        else:
            values = np.asarray([get(i) for i in range(min(4096, shape[0]))], dtype=np.float64)
    except (TypeError, ValueError):  # Not numbers (strings, records).
        return {}
    finite = values[np.isfinite(values)]
    if finite.size == 0:
        return {"min": math.nan, "max": math.nan}
    return {"min": float(finite.min()), "max": float(finite.max()),
            "mean": float(finite.mean()), "std": float(finite.std())}


def _preview(array: Any, label: str) -> Optional[dict]:
    """A sample as a small 1D or 2D map: trailing axes beyond two are cut at
    their last index (e.g. the last time step), then averaged down."""
    import numpy as np

    from ._fields import quantize, shrink, to_array

    try:
        values = to_array(array, "preview")
    except TypeError:
        return None
    values = values.squeeze()
    while values.ndim > 2:
        values = values[..., -1]
    if values.ndim == 0 or values.size == 0:
        return None
    values = shrink(values, PREVIEW_SIZE)
    finite = values[np.isfinite(values)]
    low, high = (float(finite.min()), float(finite.max())) if finite.size else (0.0, 0.0)
    return {"name": label, "shape": list(values.shape), "min": low, "max": high,
            "data": quantize(values, low, high)}


def _variable(value: Mapping[str, Any]) -> dict:
    variable = {"name": str(value["name"])[:200]}
    for key in ("description", "unit", "dtype"):
        if value.get(key):
            variable[key] = str(value[key])
    for key in ("min", "max", "mean", "std"):
        number = to_float(value.get(key))
        if number is not None:
            variable[key] = number
    if value.get("shape") is not None:
        variable["shape"] = [int(n) for n in value["shape"]]
    return variable


def _data_files(folder: Path) -> List[Path]:
    known = set(FORMATS) | set(OTHER_FORMATS)
    found = []
    for root, dirs, names in os.walk(folder):
        here = Path(root)
        for d in list(dirs):
            if d.lower().endswith(".zarr"):
                found.append(here / d)
                dirs.remove(d)
        found.extend(here / n for n in names if Path(n).suffix.lower() in known)
    return sorted(found)


def _folder_format(files: Sequence[Path]) -> str:
    counts: Dict[str, int] = {}
    for f in files:
        kind = FORMATS.get(f.suffix.lower()) or OTHER_FORMATS.get(f.suffix.lower())
        if kind:
            counts[kind] = counts.get(kind, 0) + 1
    return max(counts, key=counts.get) if counts else ""


def _size(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def _fingerprint(path: Path, files: Iterable[Path]) -> str:
    """Changes when the files do: their names, sizes and modification times."""
    digest = hashlib.sha1()
    entries = [path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()]
    for p in sorted(entries):
        stat = p.stat()
        digest.update(f"{p.relative_to(path.parent)}|{stat.st_size}|{int(stat.st_mtime)}\n".encode())
    return digest.hexdigest()[:16]


def upload(dataset: Dataset, server: Optional[str], token: Optional[str],
           directory: Optional[os.PathLike] = None) -> bool:
    """Sends [dataset] to the server; without one (or if it's unreachable),
    saves it to [directory]/datasets for `soliton sync`. True if sent."""
    from ._upload import ApiClient, RetryLater

    if server and token:
        try:
            ApiClient(server, token).put_dataset(dataset.id, dataset.description)
            return True
        except RetryLater as error:
            print(f"soliton: server unreachable ({error}); saving dataset {dataset.id}",
                  file=sys.stderr)
    folder = Path(directory or os.environ.get("SOLITON_DIR") or "soliton-runs") / "datasets"
    private_dir(folder)
    with open_private(folder / f"{dataset.id}.json", "w") as file:
        file.write(dumps(dataset.description))
    print(f"soliton: saved dataset {dataset.id} to {folder}; upload it with `soliton sync`",
          file=sys.stderr)
    return False


def saved_datasets(folder: Path) -> List[tuple]:
    """(id, description, file) for each dataset saved in [folder]/datasets."""
    found = []
    for file in sorted((folder / "datasets").glob("*.json")):
        found.append((file.stem, json.loads(file.read_text()), file))
    return found
