"""人工の点群から、Godot の読み込み確認用のサンプル世界 (GLB) を作る。

使い方:
    python tools/make_sample_world.py
"""

from pathlib import Path

import pointcloud_to_mesh as p2m
from sample_cloud import synthetic_cloud

OUTPUT = Path(__file__).resolve().parent.parent / "game" / "assets" / "sample_world.glb"


def main() -> None:
    mesh = p2m.convert(synthetic_cloud(), voxel_size=0.5)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    mesh.export(OUTPUT)
    print(f"書き出し: {OUTPUT} (頂点 {len(mesh.vertices):,} / 面 {len(mesh.faces):,})")


if __name__ == "__main__":
    main()
