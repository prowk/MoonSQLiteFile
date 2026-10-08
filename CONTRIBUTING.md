# 贡献与验证

先阅读[架构与源码职责](docs/architecture.md)、[范围源](docs/range-source.md)及[异步契约](docs/async-source.md)。核心只依赖 MoonBit 标准库，宿主与验证工具保持在下游。

所有文本使用 UTF-8，修改保留原有编码，代码注释使用中文。PowerShell 读取中文前执行 `chcp 65001` 并设置 UTF-8 输出，使用 `Get-Content -Encoding UTF8`。实现与白盒测试位于 `src/`；新增公开行为以黑盒测试和独立包消费验证。

## 环境准备

固定验收版本及宿主范围由[支持说明](docs/support.md)和 [tools/toolchain.json](tools/toolchain.json)维护。使用对应 MoonBit、Node 和 Python；本机已有安装先运行 `python tools/verify_toolchain.py` 核对，避免覆盖全局环境。latest 通道须安装官方 latest 或核实安装与官方当前分发完全一致，不能只改环境变量冒充新工具链。

真实浏览器准备与 CI 一致的 Playwright/Chromium，或者设置 `MOONSQLITE_PLAYWRIGHT` 为该版本包的绝对路径、`MOONSQLITE_BROWSER` 为符合验收要求的已有浏览器路径。浏览器启动边界见[支持说明](docs/support.md#浏览器启动方式)。CI 负责安装依赖、固定/latest 矩阵及保存产物，项目检查统一在下文入口执行。

使用当前固定浏览器配置时，从仓库根目录准备：

```sh
npm install --prefix _build/browser-tools --no-audit --no-fund --ignore-scripts playwright@1.62.1
node _build/browser-tools/node_modules/playwright/cli.js install chromium
```

Linux CI 安装 Chromium 时另带 `--with-deps` 准备系统依赖。统一入口自动发现上述目录；使用已有安装时以显式环境变量为准。

<a id="完整验证命令"></a>

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

## 记录与发布材料

当前说明按用途集中在使用、架构、支持和专题契约中；历史行为放在[升级说明](docs/migration.md)与 CHANGELOG，具体统计与长期证据放在对应版本记录（例如 [v0.8.0](docs/validation-v0.8.0.md)）。CI 产物可辅助排查，但长期证据不能只依赖会过期的日志。

公开发布需要单独授权。版本、tag、附件、校验值和精简 Release 正文规则集中在[发布材料规范](docs/releases.md)；本地 `moon package` / `npm pack` 属于消费验证，不表示已发布。比赛记录只作[项目背景](docs/competition.md)，来源与许可独立见[来源说明](docs/provenance.md)。
