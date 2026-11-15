from __future__ import annotations

import base64
import struct
import zlib

import pytest

import soliton
from soliton._images import ImageError, encode

from test_logger import offline, records
from test_with_server import TOKEN, LiveServer, database_url  # noqa: F401  (a fixture)

np = pytest.importorskip("numpy")


def decode_png(data: bytes):
    """(width, height, color type, pixel rows) of a PNG this logger wrote."""
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    i, idat, header = 8, b"", None
    while i < len(data):
        length = struct.unpack(">I", data[i:i + 4])[0]
        kind, body = data[i + 4:i + 8], data[i + 8:i + 8 + length]
        crc = struct.unpack(">I", data[i + 8 + length:i + 12 + length])[0]
        assert crc == zlib.crc32(kind + body) & 0xFFFFFFFF, kind
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        i += 12 + length
    width, height, _, color = header[:4]
    channels = {0: 1, 2: 3, 6: 4}[color]
    raw = zlib.decompress(idat)
    stride = 1 + width * channels
    rows = [raw[r * stride + 1:(r + 1) * stride] for r in range(height)]
    assert all(raw[r * stride] == 0 for r in range(height)), "no filter"
    return width, height, color, rows


def test_a_greyscale_array_becomes_a_png():
    data, kind, width, height = encode(np.array([[0.0, 0.5], [1.0, 0.25], [0.75, 0.0]]))
    assert (kind, width, height) == ("png", 2, 3)
    w, h, color, rows = decode_png(data)
    assert (w, h, color) == (2, 3, 0)
    assert rows == [bytes([0, 128]), bytes([255, 64]), bytes([191, 0])]


def test_floats_outside_0_1_are_stretched_and_nan_is_black():
    _, _, _, rows = decode_png(encode(np.array([[-2.0, 0.0], [2.0, np.nan]]))[0])
    assert rows == [bytes([0, 128]), bytes([255, 0])]


def test_rgb_rgba_channels_first_and_bool():
    rgb = np.zeros((4, 5, 3), dtype=np.uint8)
    rgb[..., 0] = 255
    assert decode_png(encode(rgb)[0])[:3] == (5, 4, 2)
    assert decode_png(encode(np.zeros((4, 5, 4), dtype=np.uint8))[0])[2] == 6
    chw = np.zeros((3, 4, 5), dtype=np.uint8)
    assert decode_png(encode(chw)[0])[:3] == (5, 4, 2), "channels first, as PyTorch has them"
    assert decode_png(encode(np.eye(3, dtype=bool))[0])[3][0] == bytes([255, 0, 0])


def test_a_big_array_is_scaled_down():
    data, _, width, height = encode(np.zeros((4000, 2000), dtype=np.uint8))
    assert (width, height) == (667, 1334)
    assert decode_png(data)[:2] == (667, 1334)


def test_png_and_jpeg_files_go_as_they_are(tmp_path):
    data = encode(np.zeros((3, 7), dtype=np.uint8))[0]
    path = tmp_path / "plot.png"
    path.write_bytes(data)
    assert encode(path) == (data, "png", 7, 3)
    assert encode(str(path))[0] == data
    # A JPEG header with a frame (SOF0) segment: 640 x 480.
    jpeg = (b"\xff\xd8\xff\xe0" + struct.pack(">H", 16) + b"JFIF\x00" + b"\x00" * 9
            + b"\xff\xc0" + struct.pack(">HBHH", 17, 8, 480, 640) + b"\x00" * 12 + b"\xff\xd9")
    assert encode(jpeg)[1:] == ("jpeg", 640, 480)


def test_what_cant_be_an_image_says_why():
    with pytest.raises(ImageError, match="only PNG and JPEG"):
        encode(b"GIF89a....")
    with pytest.raises(ImageError, match=r"\(H, W\)"):
        encode(np.zeros((2, 3, 4, 5)))


def test_a_matplotlib_figure(tmp_path):
    matplotlib = pytest.importorskip("matplotlib")
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    figure, axes = plt.subplots(figsize=(8, 4), dpi=300)
    axes.plot([0, 1], [0, 1])
    data, kind, width, height = encode(figure)
    plt.close(figure)
    assert kind == "png" and max(width, height) <= 1600 and width == 2 * height


def test_a_pil_image():
    Image = pytest.importorskip("PIL.Image")
    data, kind, width, height = encode(Image.new("RGB", (3000, 1000)))
    assert (kind, width, height) == ("png", 1600, 533)


def test_a_run_logs_images_at_its_latest_step(tmp_path):
    run = offline(tmp_path)
    run.log({"train/loss": 1.0}, step=40)
    run.log_image("phase portrait", np.zeros((2, 2)), caption="epoch 1")
    run.log_image("samples", np.ones((2, 2)), step=50)
    run.finish()
    images = [r for r in records(run) if r["type"] == "image"]
    assert [(r["name"], r["step"], r.get("caption")) for r in images] == [
        ("phase portrait", 40, "epoch 1"), ("samples", 50, None)]
    assert images[0]["format"] == "png" and (images[0]["width"], images[0]["height"]) == (2, 2)
    assert decode_png(base64.b64decode(images[0]["data"]))[:2] == (2, 2)


def test_a_bad_picture_is_skipped_with_a_warning(tmp_path):
    run = offline(tmp_path)
    with pytest.warns(UserWarning, match="skipping image 'x'"):
        run.log_image("x", object())
    run.finish()
    assert [r for r in records(run) if r["type"] == "image"] == []


def test_images_reach_the_server(tmp_path, database_url):  # noqa: F811
    with LiveServer(database_url) as server:
        run = soliton.init("tiny", server=server.url, token=TOKEN, dir=str(tmp_path),
                           system_metrics=False)
        picture = np.linspace(0, 1, 12).reshape(3, 4)
        run.log_image("ramp", picture, step=7, caption="a ramp")
        run.finish()
        assert server.get(f"/api/runs/{run.id}/images") == [
            {"name": "ramp", "steps": [{"step": 7, "width": 4, "height": 3, "caption": "a ramp"}]}]
        stored = server.get(f"/api/runs/{run.id}/images/snapshot?name=ramp")
        assert base64.b64decode(stored["data"]) == encode(picture)[0]
