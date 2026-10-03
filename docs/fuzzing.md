# 可重放的持续模糊测试

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

同名 `.json` 必须保留。重放仍使用当前工具的资源上限；要重现旧版本，应检出失败运行的提交。发现解析缺陷后，增加能说明预期行为的四后端回归，并将必要的最小样本提交到 corpus 或测试。

这是有界、基于字节变更的 JavaScript 后端持续模糊测试，没有覆盖率引导，不证明所有恶意输入都正确处理。核心回归仍在 Wasm、WasmGC、JavaScript 和 native 执行，SQLite oracle 另行核实合法输入的记录、页面空间与归属。
