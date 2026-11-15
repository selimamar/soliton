"""Pictures the script draws (`run.log_image`): a matplotlib figure, a PIL
image, an array, or a PNG or JPEG file, sent as PNG or JPEG.

Standard library only: arrays are written as PNG with zlib; a figure is
saved by matplotlib itself and a PIL image by PIL, both already loaded by
the script that made them.
"""

from __future__ import annotations

import base64
import io
import struct
import zlib
from pathlib import Path
from typing import Any, Optional, Tuple

MAX_SIDE = 1600  # Pixels: larger pictures are scaled down.
MAX_BYTES = 6 * 1024 * 1024  # After encoding; the server takes up to 8 MB.

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"


class ImageError(ValueError):
    """The picture can't be sent (unknown kind, or too big)."""


def encode(image: Any, max_side: int = MAX_SIDE) -> Tuple[bytes, str, int, int]:
    """(file bytes, "png" or "jpeg", width, height) for [image]."""
    if isinstance(image, (bytes, bytearray, memoryview)):
        data = bytes(image)
    elif isinstance(image, (str, Path)):
        data = Path(image).read_bytes()
    elif hasattr(image, "savefig"):  # A matplotlib figure.
        data = _figure(image, max_side)
    elif hasattr(image, "save") and hasattr(image, "mode") and hasattr(image, "size"):  # PIL.
        data = _pil(image, max_side)
    else:
        data = _array(image, max_side)
    if len(data) > MAX_BYTES:
        raise ImageError(f"{len(data) / 1e6:.1f} MB after encoding, more than "
                         f"{MAX_BYTES / 1e6:.0f} MB: draw it smaller")
    if data.startswith(PNG_MAGIC):
        width, height = struct.unpack(">II", data[16:24])
        return data, "png", width, height
    if data.startswith(JPEG_MAGIC):
        width, height = _jpeg_size(data)
        return data, "jpeg", width, height
    raise ImageError("only PNG and JPEG files can be logged as they are")


def to_event(name: str, image: Any, step: int, caption: Optional[str]) -> dict:
    data, kind, width, height = encode(image)
    event = {"type": "image", "step": step, "name": name, "format": kind,
             "width": width, "height": height, "data": base64.b64encode(data).decode()}
    if caption:
        event["caption"] = str(caption)[:500]
    return event


def _figure(figure: Any, max_side: int) -> bytes:
    width, height = figure.get_size_inches()
    dpi = min(float(figure.get_dpi()), max_side / max(width, height, 1e-9))
    buffer = io.BytesIO()
    figure.savefig(buffer, format="png", dpi=dpi, facecolor=figure.get_facecolor())
    return buffer.getvalue()


def _pil(picture: Any, max_side: int) -> bytes:
    if max(picture.size) > max_side:
        picture = picture.copy()
        picture.thumbnail((max_side, max_side))
    if picture.mode not in ("L", "LA", "RGB", "RGBA"):
        picture = picture.convert("RGBA" if "A" in picture.mode else "RGB")
    buffer = io.BytesIO()
    picture.save(buffer, format="PNG")
    return buffer.getvalue()


def _array(image: Any, max_side: int) -> bytes:
    """An array as PNG: (H, W) greyscale, (H, W, 3) RGB or (H, W, 4) RGBA,
    channels first too ((3, H, W), as PyTorch has them). Floats in [0, 1]
    are read as such, other floats stretched from their min to their max."""
    from ._fields import _numpy

    np = _numpy()
    if hasattr(image, "detach"):  # A PyTorch tensor.
        image = image.detach().cpu().numpy()
    try:
        array = np.asarray(image)
    except Exception:
        raise ImageError(f"can't log a {type(image).__name__} as an image: pass a matplotlib "
                         "figure, a PIL image, an array, or a PNG or JPEG file") from None
    if array.ndim == 3 and array.shape[0] in (1, 3, 4) and array.shape[-1] not in (1, 3, 4):
        array = np.moveaxis(array, 0, -1)
    if array.ndim == 3 and array.shape[-1] == 1:
        array = array[..., 0]
    if array.ndim not in (2, 3) or (array.ndim == 3 and array.shape[-1] not in (3, 4)):
        raise ImageError(f"an image array is (H, W), (H, W, 3) or (H, W, 4), not {array.shape}")
    if array.size == 0:
        raise ImageError("the image array is empty")
    stride = -(-max(array.shape[:2]) // max_side)
    if stride > 1:
        array = array[::stride, ::stride]
    array = _to_bytes(np, array)
    height, width = array.shape[:2]
    channels = 1 if array.ndim == 2 else array.shape[-1]
    color = {1: 0, 3: 2, 4: 6}[channels]
    rows = array.reshape(height, width * channels)
    raw = b"".join(b"\x00" + rows[i].tobytes() for i in range(height))
    return (PNG_MAGIC
            + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color, 0, 0, 0))
            + _chunk(b"IDAT", zlib.compress(raw, 6)) + _chunk(b"IEND", b""))


def _to_bytes(np: Any, array: Any) -> Any:
    if array.dtype == np.uint8:
        return np.ascontiguousarray(array)
    if array.dtype == bool:
        return array.astype(np.uint8) * 255
    values = array.astype(np.float64)
    finite = np.isfinite(values)
    if not finite.any():
        return np.zeros(array.shape, dtype=np.uint8)
    low, high = float(values[finite].min()), float(values[finite].max())
    if not (0 <= low and high <= 1):  # Not already in [0, 1]: stretch.
        values = (values - low) / (high - low) if high > low else values * 0
    values = np.where(finite, values, 0)
    return np.ascontiguousarray((np.clip(values, 0, 1) * 255 + 0.5).astype(np.uint8))


def _chunk(kind: bytes, body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def _jpeg_size(data: bytes) -> Tuple[int, int]:
    """(width, height) from a JPEG's frame header; (0, 0) if not found."""
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        i += 2 + length
    return 0, 0
