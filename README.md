# MoonPMTiles

MoonBit 实现的 [PMTiles v3](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md) 只读归档核心。输入地图瓦片坐标 `(z, x, y)`，通过 Hilbert TileID 和根/叶目录定位瓦片，只请求所需字节。项目提供 Node.js 本地文件与 HTTP Range 适配，以及一个 MoonBit MVT 图层摘要消费示例。

**状态：开发预览版。已用两份 Protomaps 真实测试归档和官方 JS 读取器逐瓦片对比；[公开仓库](https://github.com/wangjiale6036-dotcom/moonpmtiles)已创建，但源码尚未推送，也没有赛事内部查重结论。** 现有证据不能保证通过黑客松初审；[验证记录](docs/VALIDATION.zh-CN.md)列出已完成项和申报前缺口。

## 运行

需要 MoonBit 工具链、Node.js 24 或更新版本。进入本目录后运行：

```sh
moon test --target js
moon test --target wasm-gc
moon test --target native
npm ci
npm test
node cli.mjs info test-fixtures/generated/gzip.pmtiles
node cli.mjs metadata test-fixtures/generated/gzip.pmtiles
node cli.mjs tile test-fixtures/generated/gzip.pmtiles 1 1 0
node cli.mjs mvt test-fixtures/generated/gzip.pmtiles 1 1 0
node cli.mjs cover test-fixtures/generated/gzip.pmtiles -1 -1 1 1 1
node cli.mjs audit test-fixtures/generated/gzip.pmtiles
```

`npm test` 会编译 MoonBit JS 引擎、生成可复现的合成 PMTiles 归档，再执行本地与 HTTP Range 端到端测试。首次单独使用 CLI 时先运行 `npm run build`。`node cli.mjs tile <文件或 URL> z x y --decode --output tile.mvt` 可以将解压后的瓦片写入指定路径。HTTP 地址必须返回准确的 `206`、`Content-Range`，并提供强 ETag 或 Last-Modified 以检测归档版本变化。

## 能力与边界

| 层 | 实现 |
| --- | --- |
| MoonBit 核心 `src/` | 127 字节 v3 头、Hilbert TileID 双向转换、目录解析与编码、根/叶查询、目录树审计、范围检查、瓦片原始字节读取、经纬度转 XYZ 与有限范围瓦片覆盖、MVT 图层和要素数量摘要。JS、Wasm GC、Native 均可编译与测试。 |
| Node 适配 `reader.mjs` | 本地文件和 HTTP Range、gzip 解压（已在真实样本上验证）、Brotli/Zstd 解压分支（尚未用归档验证）、元数据 JSON、强 ETag/Last-Modified 一致性检查、解压输出上限。归档解析和查询决策由 MoonBit 导出函数执行。 |
| CLI `cli.mjs` | `info`、`metadata`、`tile`、`mvt`、`cover`、`audit` 六个命令；报告实际读取的范围与字节数。`audit` 遍历目录树并核对声明的瓦片数，不读取全部瓦片内容。 |

MoonBit 核心通过 `locate_with_decoder` / `read_tile_with_decoder` 接受范围读取及解压回调，因此可接入其他运行时。`locate` / `read_tile` 便利函数仅适用于无压缩内部目录。Node 适配采用十六进制字符串跨 JS 导出边界，适合功能验证与中小瓦片，不宣称最佳性能。同一个 `Archive` 会缓存已解压目录（总计最多 8 MiB），减少连续瓦片查询的网络请求。MVT 摘要只统计图层与要素，**不**解析几何或属性。

内存与兼容性边界：已解压目录和元数据各限 8 MiB，瓦片原始字节读取限 32 MiB，Node 瓦片解压输出限 64 MiB，MVT 摘要限 16 MiB，查询最多穿过四级目录；无法用 JS 精确表示的文件范围被拒绝。PMTiles 中未定义或不支持的压缩类型会报错。不是 PMTiles 写入器、地图渲染器或完整 MVT 解码器。

## MoonBit API

核心包名是 `wangjiale6036-dotcom/moonpmtiles`。以下代码展示回调接口，`...` 需替换为实际的范围读取实现：

```moonbit
let reader : (Int64, Int) -> Bytes raise @moonpmtiles.PMError = (offset, length) => {
  // 从你的文件或对象存储中精确读取 [offset, offset + length)；短读应报错。
  ...
}
let tile = @moonpmtiles.read_tile(reader, 0, 0, 0)
```

有 gzip 目录时，给 `read_tile_with_decoder` 传入运行时解压回调；回调必须限制最大输出。`None` 表示有效归档中找不到该坐标，格式损坏或读取失败抛出 `PMError`。`parse_header`、`tile_id`、`tile_coords`、`parse_directory`、`resolve_directory` 可单独使用。

## 来源与申报

格式遵循 [Protomaps PMTiles v3 规范](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md)；这是 MoonBit 生态移植，不声称 PMTiles 或随机访问技术首创。[第三方说明](THIRD_PARTY.md)记录来源与许可。`test-fixtures/generated/` 是本地生成的**合成数据**，`test-fixtures/upstream/` 是从 Protomaps 仓库取得并以 SHA-256 固定的真实测试归档；测试用 `pmtiles@4.5.0` 官方 JS 包逐瓦片比较。多级叶目录另通过 [Overture 2026-10-21 公开归档](https://docs.overturemaps.org/examples/overture-tiles/) 的在线 Range 对照验证，证据见[验证记录](docs/VALIDATION.zh-CN.md)。仍需赛事方核对未公开报名方向，以及将源码推送至已创建的公开仓库、形成实际持续提交记录，才可作为申报版本。[选题复查](../2026-11-02-选题复查.md)说明公开查重的时间范围和限制。

许可证：Apache-2.0，见 [LICENSE](LICENSE)。
