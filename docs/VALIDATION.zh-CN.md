# MoonPMTiles 验证记录

记录日期：2026-11-02。环境：MoonBit `moon 0.1.20260713`、Node.js `v24.21.0`、npm `11.19.0`、官方 JS 包 `pmtiles@4.5.0`。本文件记录已经运行的检查，不把测试计划当作完成结果。

## 可重复执行

在项目目录运行 `moon test --target js`、`moon test --target wasm-gc`、`moon test --target native`：每个目标 **16/16** 通过。`npm test` 执行 **11/11** Node 端到端测试，含本地文件、真正的本地 HTTP Range 服务器、元数据、根/叶目录、重复瓦片、空缺瓦片、缓存、地理范围、审计和错误输入。`moon package` 成功生成 ZIP；将其解压到全新目录后，`moon test --target js`、`npm ci --offline`、`npm test` 再次通过（16/16、11/11）。[公开仓库](https://github.com/wangjiale6036-dotcom/moonpmtiles)已上传完整源码和 CI 配置；[GitHub Actions 首次运行](https://github.com/wangjiale6036-dotcom/moonpmtiles/actions/runs/41454771328)在提交 `c2714a8` 上通过，JS、Wasm GC、Native 和 Node 示例四项任务均为成功。

`node cli.mjs cover test-fixtures/generated/gzip.pmtiles -1 -1 1 1 1` 返回 4 个 z1 瓦片位置，其中 3 个存在，且只读取文件头、根目录和叶目录，共 185 字节，不读取瓦片内容。`node cli.mjs audit test-fixtures/generated/gzip.pmtiles` 检查两个目录、3 个瓦片条目和 4 个逻辑瓦片，也只读取 185 字节。

## Protomaps 真实测试归档

两份文件来自 [Protomaps 官方测试数据目录](https://github.com/protomaps/PMTiles/tree/main/js/test/data)，上游测试源码说明使用 Tippecanoe 从 Polygon GeoJSON 生成。文件本体位于 `test-fixtures/upstream/`，测试先检查 SHA-256，再以官方 `pmtiles@4.5.0` 读取器为独立对照，比较头、元数据、`0/0/0` 解压后的瓦片字节及 `1/0/0` 不存在的结果。

| 文件 | 字节数 | SHA-256 | 差分结果 |
| --- | ---: | --- | --- |
| `test_fixture_1.pmtiles` | 468 | `f3f65093582c81625cdfab11b3d1a27c2fb6aadcf8bd9802b2ad694d4d7cdca5` | 一致 |
| `test_fixture_2.pmtiles` | 466 | `7ee80a53000bfb15a5d54162bc3161094239e775fef180fffb2d3ff607e46c1a` | 一致 |

两份真实样本各只有一个瓦片，因此多级叶目录另由合成样本与官方 JS 读取器对照，不将它们冒充复杂生产归档。

## Overture 大归档在线对照

[Overture 官方文档](https://docs.overturemaps.org/examples/overture-tiles/)公布了 2026-10-21.0 发布版的 `base.pmtiles` HTTP 地址。`node scripts/overture-check.mjs --write-evidence` 在 2026-11-02 在线运行，记录到 [原始证据 JSON](evidence/overture-2026-10-21-base.json)：归档 `191,739,583,566` 字节；读取 `1/0/0` 时经 `0..16383` 头/根目录、546 字节元数据、20,501 字节叶目录和 3,162,059 字节瓦片，共取回 `3,199,490` 字节。实际范围、ETag、瓦片偏移和哈希均在 JSON 中。

本项目将瓦片解压为 `5,745,572` 字节，SHA-256 为 `c583a979b0c9ad31a449ea4630e69844af25a59218bd477af831735146ba3b31`，与官方 JS 读取器逐字节一致。MoonBit 的 MVT 消费函数识别了 `bathymetry`、`land`、`land_cover`、`water` 四个图层，分别统计 `107455`、`25386`、`723`、`14169` 个要素。这证明此坐标的真实大归档按需读取与内容消费可用；**不是**整包、所有缩放级别或性能优势的证明。网络代理偶有 TLS/超时失败，脚本只在所有比较成功后写入结果。

## 安全与限制

- 目录解压上限 8 MiB，元数据解压上限 8 MiB，原始瓦片读取上限 32 MiB，Node 瓦片解压上限 64 MiB；MVT 摘要桥接上限 16 MiB。查询最多 4 级目录，完整审计最多 20,000 个目录和 256 MiB 压缩目录字节。
- HTTP 读取要求 `206`、精确 `Content-Range`、长度、稳定总大小与强 ETag 或 Last-Modified；检测到归档变化就停止。Node 在代理环境下可能需要 `NODE_USE_ENV_PROXY=1`。
- 真实归档已验证 gzip；Brotli/Zstd 解压分支尚无真实归档样本。MoonBit 纯核心通过回调支持 gzip，但未内置跨目标 gzip 实现；Node 适配使用内置 `zlib`。
- MVT 摘要只解析 protobuf 外层并统计要素，不验证几何、标签语义或地图渲染。
- 核心源码、Node CLI、测试、文档和 `.github/workflows/ci.yml` 等配置已公开；首次上传遗漏的三个隐藏文件已通过 Git 补传。首次线上 CI 四项任务通过；尚无 Mooncakes 发布记录。公开查重无法覆盖赛事内部报名。

## 申报前需完成的外部事项

1. 让赛事方确认当前 11 月未公开报名中没有 PMTiles v3 读取方向的实质重复。公开检索只能证明未发现，不能替代内部核对。
2. 后续工作保留真实提交记录。`moon.mod` 已填入仓库地址；CI 配置和首次运行链接已核验。
3. 如要声称完整跨平台 gzip 支持，需安装并实测 MoonBit gzip 依赖；本次尝试下载 Mooncakes 包时发生 TLS 握手失败，因此没有作此声称。

以上事项完成前，材料应标注为开发预览版，不应宣称已符合全部申报条件或保证通过初审。
