# 第三方来源

- PMTiles v3 格式规范与已公开参考实现：[Protomaps/PMTiles](https://github.com/protomaps/PMTiles)，Apache-2.0。MoonPMTiles 的解析代码按规范独立编写，没有直接复制上游源码。
- MVT 图层结构参考：[Mapbox Vector Tile 规范](https://github.com/mapbox/vector-tile-spec)，CC-BY 3.0。MoonBit 示例只解析 protobuf 外层信息，不包含规范原文或上游实现代码。
- Node 适配使用 Node.js 内置 `fs`、`fetch`、`zlib`；没有运行时 npm 依赖。测试时使用 `pmtiles@4.5.0` 作为官方独立读取器，见 `package-lock.json`；其依赖 `fflate` 仅用于测试。
- `test-fixtures/create.mjs` 生成的两份 PMTiles 归档为本项目自造合成数据。
- `test-fixtures/upstream/test_fixture_1.pmtiles`、`test_fixture_2.pmtiles` 来自 [Protomaps 官方测试数据目录](https://github.com/protomaps/PMTiles/tree/main/js/test/data)，仓库为 Apache-2.0。两份文件的 SHA-256 分别为 `f3f65093582c81625cdfab11b3d1a27c2fb6aadcf8bd9802b2ad694d4d7cdca5`、`7ee80a53000bfb15a5d54162bc3161094239e775fef180fffb2d3ff607e46c1a`。上游测试源码说明其由 Tippecanoe 从 Polygon GeoJSON 生成。
- 大归档在线验证使用 [Overture Maps 官方说明](https://docs.overturemaps.org/examples/overture-tiles/)列出的 `2026-10-21.0/base.pmtiles`。仓库仅保存读取范围、摘要和哈希证据，不再分发该归档或瓦片内容；数据权利以 Overture 的[数据许可说明](https://docs.overturemaps.org/attribution/)为准。

本项目自身代码采用 Apache-2.0，见 `LICENSE`。今后如加入更多真实第三方归档，必须单独记录下载地址、版本、许可证、哈希和是否允许再分发。
