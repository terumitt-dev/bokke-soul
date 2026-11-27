"""変換した地形 (GLB の隣の .json) ごとに、航空写真を切り出して、同じ名前の .jpg にする。

写真は、国土地理院の地理院タイル「全国最新写真 (シームレス)」。地形メッシュの範囲 (.json の origin と size) に、そのまま重なる
(東西、南北とも、1 ピクセルが 0.5 m。上が北)。ゲームは、実行中に写真を取りに行かず、この .jpg を読む。

使い方:
    python tools/fetch_aerial.py data/processed

取ったタイルは、data/cache/gsi-seamlessphoto/ にためる (同じタイルを何度も取りに行かない)。
出典: 国土地理院 (地理院タイル)。https://maps.gsi.go.jp/development/ichiran.html
"""

import argparse
import io
import json
import math
import urllib.request
from collections.abc import Callable
from pathlib import Path

import numpy as np
from PIL import Image
from pyproj import Transformer

ZOOM = 18  # 提供されている最大のズーム (1 ピクセルは、この地域で約 0.5 m)
TILE_SIZE = 256
METERS_PER_PIXEL = 0.5  # 出力の細かさ
URL = "https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg"
CACHE = Path(__file__).resolve().parent.parent / "data" / "cache" / "gsi-seamlessphoto"
MAX_PIXELS = 4096  # 1 辺の上限 (想定外に大きな範囲で、メモリを使い切らない)

Fetch = Callable[[int, int, int], Image.Image]


def tile_position(lon: np.ndarray | float, lat: np.ndarray | float, zoom: int = ZOOM) -> tuple:
    """経度、緯度から、タイル番号 (小数。整数部がタイル、小数部がタイルの中の位置) を求める。"""
    n = 2**zoom
    x = (np.asarray(lon) + 180.0) / 360.0 * n
    y = (1.0 - np.arcsinh(np.tan(np.radians(lat))) / math.pi) / 2.0 * n
    return x, y


def download(z: int, x: int, y: int, cache: Path = CACHE) -> Image.Image:
    """タイルを 1 枚取る。取ったものは、cache にためる。"""
    path = cache / str(z) / str(x) / f"{y}.jpg"
    if path.exists():
        return Image.open(path).convert("RGB")
    request = urllib.request.Request(URL.format(z=z, x=x, y=y), headers={"User-Agent": "bokke-soul/fetch_aerial"})
    data = urllib.request.urlopen(request, timeout=30).read()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return Image.open(io.BytesIO(data)).convert("RGB")


def render(origin: tuple[float, float], size: tuple[float, float], crs: str, fetch: Fetch = download) -> Image.Image:
    """測量座標の範囲 (origin = 西南の角の 東, 北。size = 東西, 南北の長さ) の写真を作る。上が北。"""
    width = max(1, round(size[0] / METERS_PER_PIXEL))
    height = max(1, round(size[1] / METERS_PER_PIXEL))
    if width > MAX_PIXELS or height > MAX_PIXELS:
        raise ValueError(f"範囲が大きすぎます: {size[0]:.0f} x {size[1]:.0f} m")
    to_lonlat = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)

    # 各ピクセルの中心の、測量座標 → 経度、緯度 → タイルの中の位置
    east = origin[0] + (np.arange(width) + 0.5) * size[0] / width
    north = origin[1] + size[1] - (np.arange(height) + 0.5) * size[1] / height
    grid_east, grid_north = np.meshgrid(east, north)
    lon, lat = to_lonlat.transform(grid_east, grid_north)
    tx, ty = tile_position(lon, lat)

    # 必要なタイルを、1 枚の大きな画像につなぐ。補間のために、1 ピクセル余分に
    x0, x1 = int(np.floor(tx.min())) - 1, int(np.floor(tx.max())) + 1
    y0, y1 = int(np.floor(ty.min())) - 1, int(np.floor(ty.max())) + 1
    mosaic = Image.new("RGB", ((x1 - x0 + 1) * TILE_SIZE, (y1 - y0 + 1) * TILE_SIZE))
    for x in range(x0, x1 + 1):
        for y in range(y0, y1 + 1):
            mosaic.paste(fetch(ZOOM, x, y), ((x - x0) * TILE_SIZE, (y - y0) * TILE_SIZE))
    pixels = np.asarray(mosaic, dtype=np.float64)

    # ピクセルの中心は、(番号 + 0.5) の位置。双一次補間
    px = (tx - x0) * TILE_SIZE - 0.5
    py = (ty - y0) * TILE_SIZE - 0.5
    ix = np.clip(np.floor(px).astype(int), 0, pixels.shape[1] - 2)
    iy = np.clip(np.floor(py).astype(int), 0, pixels.shape[0] - 2)
    fx = np.clip(px - ix, 0.0, 1.0)[..., None]
    fy = np.clip(py - iy, 0.0, 1.0)[..., None]
    out = (
        pixels[iy, ix] * (1 - fx) * (1 - fy)
        + pixels[iy, ix + 1] * fx * (1 - fy)
        + pixels[iy + 1, ix] * (1 - fx) * fy
        + pixels[iy + 1, ix + 1] * fx * fy
    )
    return Image.fromarray(np.clip(np.rint(out), 0, 255).astype(np.uint8))


def sidecar_extent(sidecar: dict) -> tuple[tuple[float, float], tuple[float, float], str]:
    """.json から、(origin の 東, 北)、(東西, 南北の長さ)、座標系 を読む。足りなければ ValueError。"""
    origin, size, crs = sidecar.get("origin"), sidecar.get("size"), sidecar.get("crs")
    if not (isinstance(origin, list) and len(origin) == 3 and isinstance(size, list) and len(size) == 3):
        raise ValueError("origin と size がありません")
    if not isinstance(crs, str) or not crs:
        raise ValueError("crs がありません (座標系が分からないと、写真を重ねられません)")
    # size は、GLB の軸 (x = 東、y = 高さ、z = 南) の順
    return (float(origin[0]), float(origin[1])), (float(size[0]), float(size[2])), crs


def build(directory: Path, fetch: Fetch = download, force: bool = False) -> list[Path]:
    """directory の、全ての地形 (.json) に、写真 (.jpg) を作る。作った .jpg を返す。"""
    written = []
    for sidecar_path in sorted(directory.glob("*.json")):
        output = sidecar_path.with_suffix(".jpg")
        if output.exists() and not force:
            print(f"そのまま: {output.name}")
            continue
        try:
            sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
            origin, size, crs = sidecar_extent(sidecar)
        except (ValueError, json.JSONDecodeError) as error:
            print(f"飛ばす: {sidecar_path.name} ({error})")
            continue
        image = render(origin, size, crs, fetch)
        image.save(output, quality=90)
        print(f"作った: {output.name} ({image.width} x {image.height})")
        written.append(output)
    return written


def main() -> None:
    parser = argparse.ArgumentParser(description="地形ごとに、航空写真 (.jpg) を作る")
    parser.add_argument("directory", type=Path, help="変換した地形の置き場 (例: data/processed)")
    parser.add_argument("--force", action="store_true", help="ある .jpg も、作り直す")
    args = parser.parse_args()
    build(args.directory, force=args.force)


if __name__ == "__main__":
    main()
