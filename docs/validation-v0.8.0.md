# v0.8.0 验证记录

本页保存 v0.8.0 已有材料中的长期事实，核对日期为 2026-10-06。它描述历史发布，不证明后续源码已通过。当前工具链和使用边界分别由[支持说明](support.md)及专题契约维护。

发布 tag 为 `v0.8.0`，提交 `cf7bdc5d9c9dd808640190d7f6904be4a21de8f9`；[该提交的 CI](https://github.com/prowk/MoonSQLiteFile/actions/runs/37474122802)完成 pinned/latest 两个通道。每个通道执行当时的完整 34 项本地/CI 检查，四后端各 127 项回归；六个 README/使用指南函数以真实核心包在独立项目运行。发布后的 Mooncakes v0.8.0 真实四后端消费通过。正式异步附件以 tarball 独立消费，未发布 npm registry。材料入口见[v0.8.0 Release](https://github.com/prowk/MoonSQLiteFile/releases/tag/v0.8.0)和[tag 固定 CHANGELOG](https://github.com/prowk/MoonSQLiteFile/blob/v0.8.0/CHANGELOG.md)。

## 环境与兼容

当时固定环境为 MoonBit `0.10.14+7d59c7ec9`、Node 22.14.0、Python 3.13.2、Playwright 1.62.1。2026-10-06 对照官方 Windows latest 分发，16 个二进制 checksum、1043 个标准库源码文件与固定安装一致，因此两通道是同一当前官方 release 的验收；未来 latest 变化必须重新验证。

v0.3.0–v0.7.0 核心 API 基线、正式 v0.7.0 异步导出/arity/原型和全部 17 个 CLI 命令的 22 个场景持续通过；v0.6.0 基线仅属内部里程碑。12 个同输入规模场景与 v0.7.0 的读取量对照及三个历史 fuzz 边界样本重放通过。具体可复现样本、成本方法见[基准记录](io-benchmark.md)与[贡献指南](../CONTRIBUTING.md#模糊测试与重放)。

## 范围、SQLite 与浏览器

范围验收包含 2 GiB 稀疏寻址和最大 Int 页号、54 组合法 SQL 操作、29 组 WAL 静态恢复快照及 5470 条恢复记录。虚拟 WAL 为 32769 个有效 65536 字节帧，实际索引读取偏移 2148270136；四后端边界回归另覆盖 4294967320 的整页和切片。这些测试不能替代合法大库全量处理或任意规模保证。

合法大 payload 样本为 1100 行 BLOB，累计 payload 72094000 字节；默认预算停止，增额后扫描和报告完成。另覆盖 17 MiB 单条记录、零累计预算、UInt64 最大值、JS 精确整数边界及非法参数。Linux 页归属对照强制 dbstat；Windows 缺 dbstat 时仅记录其他对照，不将其记为物理页统计通过。

Chrome 154.0.8037.93 的本机 HTTP 载入后断网验收覆盖 File、Blob Worker、WAL、导航、取消、切换、释放、损坏及短文件。72663040 字节合法库有 1100 条 BLOB；默认预算停在含 schema 的 1024 条，128 MiB 后完成 17740 页、1101 条记录，单次最多读取 4096 字节，初次约 10.1 秒。该时间是当次测量，不能作为跨机器承诺。直接 file:// 未通过真实验收。

复现后的原始 JSON 和截图位于 `_build/toolchain-*.json`、`layout-evidence.json`、`wide-wal.json`、`large-payload.json`、`io-benchmark.json`、`compatibility-benchmark.json`、`inspection-evidence.json`、`browser-acceptance.json` 和 `browser-acceptance/viewer-large.png`；这些路径会被后续运行覆盖。长期事实保存在本页，历史精确正文以发布 tag 和 Release 为准，不只依赖会过期的 CI 产物。
