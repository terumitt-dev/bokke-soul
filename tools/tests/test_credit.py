import argparse
import json

import numpy as np

import dem_to_mesh as d2m
import pointcloud_to_mesh as p2m


def make_mesh():
    xs, ys = np.arange(0, 5) * 0.5, np.arange(0, 4) * 0.5
    return d2m.convert(xs, ys, np.full((4, 5), 100.0))


def args(**kwargs):
    return argparse.Namespace(**{"credit": None, "license_url": None, **kwargs})


def test_credit_is_written_next_to_the_glb(tmp_path):
    mesh = make_mesh()
    p2m.apply_credit(mesh, args(credit="データ (提供元) を加工して作成 / CC BY 4.0", license_url="https://example.com/license"))
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)

    meta = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    # ゲーム側 (WorldLoader.credit_for) が読むキー名と、同じでなければならない
    assert meta["credit"] == "データ (提供元) を加工して作成 / CC BY 4.0"
    assert meta["license_url"] == "https://example.com/license"
    assert "origin" in meta  # 出典を足しても、元の座標への復元情報は残る


def test_no_credit_means_no_keys(tmp_path):
    mesh = make_mesh()
    p2m.apply_credit(mesh, args())
    output = tmp_path / "world.glb"
    p2m.write_outputs(mesh, output)

    meta = json.loads(output.with_suffix(".json").read_text(encoding="utf-8"))
    assert "credit" not in meta and "license_url" not in meta


def test_credit_arguments_are_parsed():
    parser = argparse.ArgumentParser()
    p2m.add_credit_arguments(parser)
    parsed = parser.parse_args(["--credit", "出典", "--license-url", "https://example.com"])
    assert parsed.credit == "出典" and parsed.license_url == "https://example.com"
