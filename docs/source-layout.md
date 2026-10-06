# 源码与测试组织（v0.8.0）

`moon.mod` 的 `source = "src"` 将物理源码根移至 `src/`，对外包仍为 `prowk/moonsqlitefile`。所有原公开类型仍属于原包；没有扩大 API、移动类型归属或拆开错误枚举。正式 v0.7.0 的 237 项声明加入兼容基线。

| 路径 | 职责 |
| --- | --- |
| `src/*.mbt` | 无宿主 I/O 的核心格式解析、范围源、检查器和游标 |
| `src/*_wbtest.mbt` | 可访问内部实现的既有解析、损坏和状态机回归 |
| `src/public_contract_test.mbt` | 通过公开包导入验证字段构造、预算、宿主错误、供页及取消 |
| `src/cmd/inspect/` | JS CLI 桥接和报告序列化；文件操作位于 `tools/range_io.cjs` |
| `src/cmd/async-bridge/` | 核心到独立 JS 适配层的桥接；不随核心安装包发布 |
| `src/cmd/fuzz/` | 相同输入上的旧源、范围源、适配器、缓存及故障报告比较 |
| `src/examples/basic/`、`src/examples/cursors/` | 四后端可运行示例；保留公开导入路径 |
| `adapters/async/` | 独立异步 JS 协议、Node/Blob 源与生命周期 |
| `examples/offline-viewer/` | HTML/CSS/JS/Worker；位置不变 |
| `fixtures/`、`tools/` | 独立 SQLite oracle、契约与宿主验证；不作为核心运行依赖 |

## 内部拆包评估

当前保持单一核心包。底层 `binary/header/record/page` 依赖公开的 `SqliteError/Header/Value/Page`；扫描与 payload 共用页占用状态、诊断 trace 和 observer；schema、ownership、freelist、Ptrmap 与全库游标共享计费和归属状态。跨文件调用不是现成的单向包依赖：先拆这些文件会要求移动公开类型、增加可见接口或建立反向 facade，单纯减少根目录文件数不足以证明这些代价合理。

物理目录已解决根目录拥挤问题。CLI、异步桥接和示例原本就是独立下游包，迁移后仍只导入核心。后续真正拆内部包须先明确共享类型归属及无环依赖，并通过名义类型、构造/穷举和实际外部消费验证；本版不以内部拆包为由扩张公开 API。

## 嵌入数据评估

两个生成数据文件约 1.14 MB，仍保留为 `*_wbtest.mbt`，按固定 fixture 字节离线复现。正常四后端 `moon build` 的编译计划均排除所有测试文件，包括这两个嵌入文件；`verify_layout.py` 持续检查。发布包保留测试源码，但消费方正常构建不编入它们，且没有 Python、SQLite、文件系统或构建时生成依赖。

将数据放入独立生产包会使 fixture 进入正常依赖或增加测试专用公开接口；构建时生成则给安装消费者引入新的工具或离线风险。现有约束下，继续保留测试专用嵌入源码有更直接的四后端与离线证据。`generate_fixtures.py --check` 和 `generate_btree_fixtures.py --check` 同时检查新路径的字节稳定性。

## 脚本与发布内容

`moon build --target js src/cmd/inspect`、`moon run --target js src/examples/basic` 使用新物理路径。编译产物路径仍为 `_build/js/debug/build/cmd/...`，不额外增加 `src` 层；Node launcher 和离线打包器验证该实际输出。

`verify_consumer.py` 解包真正的 `moon package` 输出，检查 `src/moon.pkg`、接口与示例路径及排除项，然后在独立工作区运行四后端。`verify_examples.py` 使用同一实际包编译运行 README 与使用指南的原文示例；独立 JS 包另外通过离线 npm tarball 消费。本地打包验证与真实 registry 消费分别记录，v0.8.0 发布后的安装验证证据见对应 Release。
