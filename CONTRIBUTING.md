# 贡献与验证

先阅读[架构与源码职责](docs/architecture.md)、[范围源](docs/range-source.md)及[异步契约](docs/async-source.md)。核心只依赖 MoonBit 标准库，宿主与验证工具保持在下游。

所有文本使用 UTF-8，修改保留原有编码，代码注释使用中文。PowerShell 读取中文前执行 `chcp 65001` 并设置 UTF-8 输出，使用 `Get-Content -Encoding UTF8`。实现与白盒测试位于 `src/`；新增公开行为以黑盒测试和独立包消费验证。

## 环境准备

固定验收版本及宿主范围由[支持说明](docs/support.md)和 [tools/toolchain.json](tools/toolchain.json)维护。使用对应 MoonBit、Node 和 Python；本机已有安装先运行 `python tools/verify_toolchain.py` 核对，避免覆盖全局环境。latest 通道须安装官方 latest 或核实安装与官方当前分发完全一致，不能只改环境变量冒充新工具链。

全目标构建中的 native 后端还需要可用的 C 编译和链接驱动，以及对应平台的头文件与库。准备 MoonBit 支持的 `cc`、`gcc` 或 `clang`；若驱动不在 PATH，可通过 `MOON_CC` 指定。出现 `no system C compiler found` 时先补齐这项环境依赖，再重新执行完整验证。

真实浏览器准备与 CI 一致的 Playwright/Chromium，或者设置 `MOONSQLITE_PLAYWRIGHT` 为该版本包的绝对路径、`MOONSQLITE_BROWSER` 为符合验收要求的已有浏览器路径。浏览器启动边界见[支持说明](docs/support.md#浏览器启动方式)。CI 负责安装依赖、固定/latest 矩阵及保存产物，项目检查统一在下文入口执行。

历史恢复验收默认使用固定 Playwright 分发中完整 Chromium 的新 headless 模式，需要保留完整 Chromium 下载；仅安装 Headless Shell 不能覆盖真实 BFCache 恢复。

使用当前固定浏览器配置时，从仓库根目录准备：

```sh
python tools/prepare_acceptance.py
```

Linux 安装可另带 `--with-deps` 准备系统依赖。脚本与 CI 共用 `tools/toolchain.json` 的版本；统一入口自动发现上述目录，使用已有安装时以显式环境变量为准。


## 完整验证

从仓库根目录运行：

```sh
python tools/verify.py
```

此命令按依赖顺序执行原 CI 全部 34 项检查及维护契约检查；失败返回非零并停止后续步骤，输出逐项结果。检查集合与顺序仅在 `tools/verify.py` 维护，CI 使用同一命令。环境准备不属于脚本的自动安装职责；检查失败先修复或报告具体环境阻碍，不跳过或放宽条件，不提交。

逐项日志、结果、源码 SHA256 和摘要默认位于 `_build/verification/pinned/` 或 `latest/`，可用 `--output` 指定构建目录内的独立路径。检查期间修改源码会使验收失败。完整通过后修改须补验受影响项，提交前必须有覆盖最终内容的完整结果；推送后还要核对该 SHA 的远程 CI。

`.gitattributes` 将逐字节核对的 fixture JSON 与生成接口固定为 LF；Windows 检出也遵循该规则。fixture 字节检查失败时先查看差异，不把重新生成或关闭检查作为绕过方式。

## 开发反馈与契约审查

日常可单独运行 `moon test --target js --deny-warn`、`python tools/verify_api.py` 或 `node tools/verify_async.mjs`，修改异步适配后先重新构建并执行 `python tools/build_async.py`。单项通过只提供开发反馈，不代表提交验收通过。

公开 API 修改后用 `moon info` 同步 `src/pkg.generated.mbti`。核心检查保护签名、类型归属、结构字段与枚举；异步检查保护历史导出、arity 与原型，允许经审查的兼容新增；CLI 对照输出、空值、类型、退出码和错误通道。历史基线来源见[契约数据说明](fixtures/cli-contract/README.md)，不得用当前输出覆盖旧预期以制造通过。默认值、错误来源、源接管及部分报告也必须审查，需要收紧行为时同步[升级说明](docs/migration.md)。

`verify_layout.py` 检查公开契约注释、生成文档和正常构建不混入测试源码。`verify_examples.py` 从 README 与使用指南原文提取示例，在实际打包库的独立项目运行四后端；不能用另一份抄写示例替代。性能样本和复现方式集中在[基准记录](docs/io-benchmark.md)，不以跨机器时间或 RSS 波动作为保证。

## 模糊测试与重放

先运行 `moon build --target js --deny-warn`，再运行：

```sh
node tools/fuzz.cjs --seed 20261003 --iterations 512
```

每次 CI 执行固定种子的 512 次变更；`Scheduled fuzzing` 工作流每天执行 5000 次，默认用运行编号生成不同种子，也可手动指定种子和次数。输出记录种子和结果计数；同一版本的工具、corpus 和种子产生相同输入序列。

六个真实 SQLite corpus 覆盖空库、多层表树、索引内部页、WITHOUT ROWID、overflow、freelist、UTF-16 和 65536 字节页。变更包含位翻转、截断、页头/文件头边界值、定宽字段替换、随机区间与 corpus 拼接。原始 corpus 也先运行一次。变更后输入可能仍合法；接受、格式错误、不支持及限额不足都可以是正常结果，不能用“全部拒绝”作为正确性标准。

探针在独立 Node.js Worker 中调用 MoonBit 库，覆盖初始化、全局详细检查与纯汇总、随机页面空间检查、单树详细检查。验证预算、诊断对应关系与成功页面空间分项，不把字符串错误当作位置。全局上限为 256 条记录、1024 页、单 payload 65536 字节、累计 payload 1 MiB、深度 32、诊断 16 条；单树另限 64 条和 65536 字节。Worker 旧生代堆上限为 128 MiB（不是整个进程的总内存上限），单输入超过 5 秒即失败。

仅三类 `SqliteError` 是正常错误；panic、未知异常、越过资源预算、超时或 Worker 退出都会导致测试失败。失败时将原始输入及 seed、iteration、变更类型、页号、SHA-256 和错误保存到 `_build/fuzz-failures/`。CI 与定期任务上传该目录，可下载后重放：

```sh
node tools/fuzz.cjs --replay _build/fuzz-failures/SHA256.sqlite
```

同名 `.json` 必须保留。WAL 失败样本还需保留 `.base.sqlite`，携带构造覆盖快照所用的主文件；重放依据 `kind=wal` 自动选择 WAL 探针，不能只重放一个无关的主文件。重放仍使用当前工具的资源上限；要重现旧版本，应检出失败运行的提交。发现解析缺陷后，增加能说明预期行为的四后端回归，并将必要的最小样本提交到 corpus 或测试。

从 v0.5.0 起，每四次随机变更中一次针对 WAL。六个静态数据库另构造六个确定性双字节序 WAL corpus，包含完整提交与未提交页 1 更新。部分 WAL 变更会重算累计 checksum，使损坏内容进入覆盖源及数据库检查器，避免只覆盖 checksum 拒绝路径。WAL 探针限 256 帧，检查有效前缀边界，并以 `UseValidPrefix` 检查此前最新提交的只读视图，复用全局预算；仍不把预算不足当作快照成功。`wal_*` 结果计数区分 WAL 输入，`accepted` 只表示探针没有抛出错误，检查报告内部仍可能是 Failed 或 Incomplete。

65536 字节数据库页的头字段为 1，变更选择已按实际 65536 字节定位，避免将编码值误当作页长。

这是有界、基于字节变更的 JavaScript 后端持续模糊测试，没有覆盖率引导，不证明所有恶意输入都正确处理。核心回归仍在 Wasm、WasmGC、JavaScript 和 native 执行，SQLite oracle 另行核实合法输入的记录、页面空间与归属。

## 合法 SQL 序列与失败缩减

`python tools/sql_sequences.py --seed 20261011 --cases 4 --seconds 300` 复用现有 SQLite 物理记录 oracle，生成建表、增删改、提交/回滚、SAVEPOINT、VACUUM、页释放/复用及 WAL/checkpoint 序列。支持 rowid 表、WITHOUT ROWID、索引和溢出字段；只在无写事务的已提交边界复制 db/WAL。RESTART 留存的旧 WAL 尾部使用既有有效前缀读取契约，不能把旧尾部误报成记录解析缺陷。SQL 主键别名与 WITHOUT ROWID/索引的字段顺序由 SQLite 元数据归一化，不引入库中的 DDL 解析。

失败时，`_build/fuzz-failures/sql/` 保存 seed、SQLite 版本、完整 SQL 序列、匹配的静态 db/WAL、期望记录和错误见证。输出的 `--replay .../sequence.json` 命令独立重放；`python tools/sql_sequences.py --reduce .../sequence.json` 在有限时间内删除无关 SQL，并再次确认原类别、对象、快照与记录差异。语法失败、普通格式拒绝及不同记录差异均不能替代原失败。预算内的缩减不保证全局最小；确认真实缺陷后，将最小必要样本及预期行为纳入固定回归。

字节变异失败同时保留 `.original.sqlite`。`python tools/reduce_fuzz.py _build/fuzz-failures/SHA256.sqlite` 删除无关变异，保留原 Worker 故障签名及配对主文件；正常的格式拒绝不视为重现。历史失败缺少原始 corpus 时停止缩减，不猜测原始 WAL。定时和手动 `Scheduled fuzzing` 在既有变异检查后执行合法序列；数量与时间均有限，使用同一个 seed，失败材料由现有 artifact 保存。

覆盖反馈已在实际生成代码上评估：V8 `NODE_V8_COVERAGE` 能采集 Worker 中的生成 JS 函数范围，source map 保留 MoonBit 源文件；MoonBit 测试也提供 `--enable-coverage`。生成 JS 范围含标准库、运行时与编译器变换，不能直接声称 MoonBit 源分支覆盖率。当前将表/索引叶页与内部页、overflow、freelist、WITHOUT ROWID 和 WAL 等实际结构特征用于组合反馈；不把入口调用次数当覆盖率，不增加每个 commit 的覆盖门槛。需要进一步研究时可设置 `NODE_V8_COVERAGE=_build/fuzz-coverage` 运行既有 fuzz，再执行 `python tools/evaluate_fuzz_coverage.py _build/fuzz-coverage`；仅用于按需评估。

## 记录与发布材料

字段投影修改后先运行 `python tools/build_async.py`、`python tools/generate_browser_fixtures.py`、`python tools/verify_field_reads.py`；现有样本已生成时可复用。回归覆盖跨页头、UTF-8/UTF-16 前缀、未读损坏、超过完整读取上限的大字段、预算、分块寿命及取消/关闭。`node tools/benchmark_field_reads.mjs` 用独立进程对照实际读取量与 RSS；测量方法和局限见[基准记录](docs/io-benchmark.md#开发中字段投影对照2026-10-11)。这两项纳入统一入口，日常按影响选择，无须每次提交重复全量规模样本。

当前说明按用途集中在使用、架构、支持和专题契约中；历史行为放在[升级说明](docs/migration.md)与 CHANGELOG，具体统计与长期证据放在对应版本记录（例如 [v0.8.0](docs/validation-v0.8.0.md)）。CI 产物可辅助排查，但长期证据不能只依赖会过期的日志。

公开发布需要单独授权。版本、tag、附件、校验值和精简 Release 正文规则集中在[发布材料规范](docs/releases.md)；本地 `moon package` / `npm pack` 属于消费验证，不表示已发布。比赛记录只作[项目背景](docs/competition.md)，许可见 [LICENSE](LICENSE)。
