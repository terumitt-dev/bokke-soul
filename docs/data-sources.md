# データの出典

使用する点群データの出典とライセンスをここに記録します。元データはリポジトリに含めません (`data/raw/` は除外対象)。

## 現在の採用データ

ローカルでの動作確認にだけ使っています。リポジトリには含めておらず、公開もしていません。本番で使うデータは未選定です。

### VIRTUAL SHIZUOKA (静岡県の 3 次元点群データ)

| 項目 | 内容 |
|---|---|
| 名称 | VIRTUAL SHIZUOKA, 3D Point Cloud Data (Grid: 標高グリッド) |
| 提供元 | 静岡県 (公開・管理は AIGID) |
| 使ったファイル | `2019/LP/Grid/08/OF/30/08OF3006.zip` (中身は `08OF3006_DEM.txt`) |
| 取得元 | `s3://virtual-shizuoka` (AWS Open Data。アカウント不要) |
| URL | https://registry.opendata.aws/virtual_shizuoka/ |
| ライセンス | CC BY 4.0 と ODbL のデュアルライセンス。このプロジェクトでは **CC BY 4.0** (https://creativecommons.org/licenses/by/4.0/) の条件で利用する |
| 取得日 | 2026-11-21 |
| 内容 | 400m x 300m、0.5m 間隔の標高グリッド (東 北 標高)。座標は EPSG:6676 (平面直角座標系 第 VIII 系) |
| 場所 | 伊豆半島の天城山の近く (北緯 34.835 度、東経 138.966 度付近)。座標から求めた推定で、現地では確認していない |
| 加工 | `tools/dem_to_mesh.py` で、格子を 1 つおき (1m 間隔) に間引いて三角形メッシュ (GLB) にした |
| 出典表示 | 「VIRTUAL SHIZUOKA (静岡県) を加工して作成 / CC BY 4.0」。公開する場合は、CC BY 4.0 の条件として、(1) 出典の表示、(2) ライセンスへのリンク、(3) 加工したことの明記が必要。ゲームのタイトル画面の隅とクレジットに表示する (変換時に `--credit`、`--license-url` で指定) |

データの全体像と形式は https://github.com/aigidjp/opendata_virtualshizuoka を参照。

## 選ぶ条件

- 再配布・改変が許可されているライセンス (CC BY など)
- 数十MB以下で、ダウンロードできる
- LAS / LAZ / PLY / E57 のいずれか

## 探す先の候補

- [G空間情報センター](https://www.geospatial.jp/)
- [国土交通データプラットフォーム](https://www.mlit-data.jp/)
- [Project PLATEAU](https://www.mlit.go.jp/plateau/)
- 各自治体のオープンデータ (BODIK など)

## 記録するもの

採用したデータごとに、次を書きます。

| 項目 | 内容 |
|---|---|
| 名称 | |
| 提供元 | |
| URL | |
| ライセンス | |
| 取得日 | |
| 加工内容 | |
