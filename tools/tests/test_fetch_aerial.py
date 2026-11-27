import json

import numpy as np
import pytest
from PIL import Image
from pyproj import Transformer

import fetch_aerial as fa

CRS = "EPSG:6676"
ORIGIN = (42400.25, -129299.75)
SIZE = (400.0, 300.0)


def tile_color(x, y):
    """タイルごとに、見分けがつく単色 (番号から決める)。"""
    return (x * 37 % 251, y * 53 % 251, (x + y) * 11 % 251)


def solid_fetch(z, x, y):
    assert z == fa.ZOOM
    return Image.new("RGB", (fa.TILE_SIZE, fa.TILE_SIZE), tile_color(x, y))


def expected_color(east, north):
    """測量座標の 1 点が、どのタイルに入るか (独立に、地図の式で求める)。"""
    lon, lat = Transformer.from_crs(CRS, "EPSG:4326", always_xy=True).transform(east, north)
    tx, ty = fa.tile_position(lon, lat)
    return tile_color(int(np.floor(tx)), int(np.floor(ty)))


def test_output_size_is_half_meter_per_pixel():
    image = fa.render(ORIGIN, SIZE, CRS, solid_fetch)
    assert image.size == (800, 600)


def test_corners_and_center_come_from_the_right_tiles():
    image = fa.render(ORIGIN, SIZE, CRS, solid_fetch)
    width, height = image.size
    # 上が北、左が西。角のピクセルの中心 (端から 0.25 m 内側) の、測量座標で確かめる
    probes = {
        "北西": ((2, 2), (ORIGIN[0] + 1.0, ORIGIN[1] + SIZE[1] - 1.0)),
        "北東": ((width - 3, 2), (ORIGIN[0] + SIZE[0] - 1.0, ORIGIN[1] + SIZE[1] - 1.0)),
        "南西": ((2, height - 3), (ORIGIN[0] + 1.0, ORIGIN[1] + 1.0)),
        "南東": ((width - 3, height - 3), (ORIGIN[0] + SIZE[0] - 1.0, ORIGIN[1] + 1.0)),
        "中央": ((width // 2, height // 2), (ORIGIN[0] + SIZE[0] / 2, ORIGIN[1] + SIZE[1] / 2)),
    }
    checked = 0
    for name, (pixel, survey) in probes.items():
        assert image.getpixel(pixel) == expected_color(*survey), name
        checked += 1
    assert checked == 5


def test_the_range_really_crosses_several_tiles():
    # 前のテストが、1 枚のタイルだけで通ってしまわないように
    image = fa.render(ORIGIN, SIZE, CRS, solid_fetch)
    assert len(set(image.getdata())) > 3


def test_gradient_is_smooth_not_blocky():
    # 横に明るくなる画像: 補間で、隣の画素との差が小さい (半画素ずれや、段差がない)
    def gradient_fetch(z, x, y):
        row = np.tile(np.arange(fa.TILE_SIZE, dtype=np.uint8), (fa.TILE_SIZE, 1))
        return Image.fromarray(np.stack([row] * 3, axis=-1))

    image = np.asarray(fa.render(ORIGIN, (50.0, 50.0), CRS, gradient_fetch), dtype=int)
    interior = np.abs(np.diff(image[..., 0], axis=0)).max()
    assert interior <= 2  # 縦には、ほぼ変わらない (ゆがんだ重ね方だと、縦にも変わる)


def test_rejects_huge_range():
    with pytest.raises(ValueError):
        fa.render(ORIGIN, (5000.0, 300.0), CRS, solid_fetch)


def test_sidecar_extent_reads_size_in_glb_axis_order():
    sidecar = {"origin": [1.0, 2.0, 3.0], "size": [400.0, 65.0, 300.0], "crs": CRS}
    assert fa.sidecar_extent(sidecar) == ((1.0, 2.0), (400.0, 300.0), CRS)


@pytest.mark.parametrize("sidecar", [{}, {"origin": [1, 2, 3], "size": [4, 5, 6]}, {"origin": [1, 2], "size": [4, 5, 6], "crs": CRS}])
def test_sidecar_extent_rejects_incomplete(sidecar):
    with pytest.raises(ValueError):
        fa.sidecar_extent(sidecar)


def test_build_writes_jpg_next_to_json_and_keeps_existing(tmp_path):
    (tmp_path / "a.json").write_text(json.dumps({"origin": [*ORIGIN, 0], "size": [40.0, 5.0, 30.0], "crs": CRS}))
    (tmp_path / "broken.json").write_text(json.dumps({"origin": [*ORIGIN, 0]}))
    written = fa.build(tmp_path, solid_fetch)
    assert [path.name for path in written] == ["a.jpg"]
    assert Image.open(tmp_path / "a.jpg").size == (80, 60)
    assert not (tmp_path / "broken.jpg").exists()
    assert fa.build(tmp_path, solid_fetch) == []  # 2 回目は、作り直さない
    assert [p.name for p in fa.build(tmp_path, solid_fetch, force=True)] == ["a.jpg"]
