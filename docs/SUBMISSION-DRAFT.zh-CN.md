# 11 月黑客松申报文案草稿（未提交）

**项目名：** MoonPMTiles

**一句话：** 用 MoonBit 读取 PMTiles v3 单文件地图归档，通过字节范围请求从大型远程文件中查找指定 XYZ 瓦片。

**问题与用户场景：** 地图应用只需要当前区域的少数瓦片。PMTiles 由 Protomaps 定义并被 Overture Maps 等公开数据生产者采用；MoonBit 程序若要读取这类归档，需要头部、Hilbert TileID、压缩根/叶目录和瓦片范围查找能力。本项目补充 MoonBit 原生归档核心及可运行的 Node 范围读取适配，不宣称格式或技术首创。

**已实现：** MoonBit 文件头与目录读写、双向 TileID、Web Mercator 坐标及范围覆盖、根/叶目录查找、瓦片原始字节读取、目录树审计、MVT 图层/要素摘要。Node 适配支持本地文件、HTTP Range、gzip、元数据、ETag 检查和命令行演示。MoonBit 测试覆盖 JS/Wasm GC/Native；Node 端到端测试与官方 PMTiles JS 实现做差分。

**可核查证据：** [验证记录](VALIDATION.zh-CN.md)列出 Protomaps 两份真实测试归档的哈希、与官方 JS 的逐瓦片对照，以及 Overture 约 191.7 GB 公开归档的 1/0/0 实际 Range 和解压瓦片哈希。它只证明这些样本和查询通过，不代表完整格式覆盖或性能更好。

**与已有项目的关系：** 官方 JS/Go/Python 实现成熟，本项目是 MoonBit 生态移植。`yyyt0807/moonmvt` 针对瓦片内容，本项目负责归档定位；`NBB2006/routeweave` 涉及瓦片坐标/覆盖。当前自建 MVT 摘要演示没有调用 moonmvt，不应说成外部项目采用。公开索引及网页暂未找到直接 MoonBit PMTiles 库，详见[选题复查](NOVELTY.zh-CN.md)；赛事内部重复申报情况未知。

**开源与复现：** Apache-2.0。`npm ci && npm test`、三个 `moon test --target` 命令、CLI 样例见 [README](../README.md)。第三方规范、测试样本和依赖见 [THIRD_PARTY](../THIRD_PARTY.md)。

**仍需填入：** GitHub ID 已从参考申报书获知；[公开仓库](https://github.com/wangjiale6036-dotcom/moonpmtiles)已有一次浏览器上传提交。仍需补齐 CI 配置及运行链接、后续真实提交记录、赛事方内部查重答复。填入并复核前，不提交本草稿。
