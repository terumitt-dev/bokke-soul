"""areas.json に書いた、全てのマップ (タイル) を、まとめて GLB に変換する。

名前、出典、篝火の場所は、変換のたびに同じになる (名前は areas.json、場所は平らな所を探す)。

使い方:
    python tools/build_areas.py data/raw/virtual-shizuoka data/processed --stride 2
"""

import argparse
import json
from argparse import Namespace
from pathlib import Path

import numpy as np

from dem_to_mesh import convert, load_dem
from pointcloud_to_mesh import apply_credit, apply_name, apply_world_id, write_outputs

MANIFEST = Path(__file__).with_name("areas.json")


def load_manifest(path: Path = MANIFEST) -> dict:
    """areas.json を読んで、確かめる (名前とタイルが、空でなく、重ならない)。"""
    manifest = json.loads(path.read_text(encoding="utf-8"))
    areas = manifest["areas"]
    if not areas:
        raise ValueError("areas が空です")
    for key in ("tile", "name"):
        values = [area.get(key, "").strip() for area in areas]
        if not all(values):
            raise ValueError(f"{key} が空のマップがあります")
        if len(set(values)) != len(values):
            raise ValueError(f"{key} が重なっています")
    return manifest


def dem_path(raw_root: Path, manifest: dict, tile: str) -> Path:
    return raw_root / f"{manifest['source']}-{tile}" / f"{tile}_DEM.txt"


def build(raw_root: Path, out_dir: Path, stride: int, manifest: dict | None = None) -> list[Path]:
    manifest = manifest or load_manifest()
    outputs = []
    for area in manifest["areas"]:
        source = dem_path(raw_root, manifest, area["tile"])
        xs, ys, z = load_dem(source)
        mesh = convert(xs, ys, z, stride)
        apply_credit(mesh, Namespace(credit=manifest["credit"], license_url=manifest["license_url"]))
        apply_name(mesh, Namespace(name=area["name"]))
        apply_world_id(mesh, Namespace(world_id=None), source, np.array([xs[0], ys[0]]))
        output = out_dir / f"{area['tile']}.glb"
        write_outputs(mesh, output)
        outputs.append(output)
    return outputs


def main() -> None:
    parser = argparse.ArgumentParser(description="areas.json の全てのマップを、GLB に変換する")
    parser.add_argument("raw_root", type=Path, help="元データの置き場 (例: data/raw/virtual-shizuoka)")
    parser.add_argument("out_dir", type=Path, help="出力の置き場 (例: data/processed)")
    parser.add_argument("--stride", type=int, default=2, help="格子を何個おきに使うか")
    args = parser.parse_args()
    build(args.raw_root, args.out_dir, args.stride)


if __name__ == "__main__":
    main()
