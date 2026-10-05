# 贡献与验证

先阅读[源码与测试组织](docs/source-layout.md)、[架构说明](docs/architecture.md)、[范围源契约](docs/range-source.md)及[异步契约](docs/async-source.md)。核心只依赖 MoonBit 标准库；不把 Node、SQLite、Python 或 async 运行时引入核心包。

所有文本读写使用 UTF-8，保留原有编码，代码注释使用中文。PowerShell 先设置 UTF-8 输出，再显式按 UTF-8 读取。实现与白盒测试位于 `src/`；新增公开行为用黑盒 `*_test.mbt` 和独立打包消费验证。正常构建不编入测试代码，嵌入 fixture 仅用于白盒测试。

修改公开 API 时运行 `moon info` 同步 `src/pkg.generated.mbti`，再运行 `python tools/verify_api.py`，不得通过改写历史基线隐藏不兼容。兼容审查覆盖类型归属、结构体构造/字段、枚举穷举、默认值、错误来源、CLI JSON 类型、退出码及部分报告。若需收紧行为，说明用户影响和迁移方式。

固定工具链、可用宿主及验收限制见[支持矩阵](docs/support.md)。完整命令列于 [README](README.md#开发与测试) 和 `.github/workflows/ci.yml`；不得只运行部分测试便提交。`verify_layout.py` 同时生成文档并检查注释与正常构建计划，`verify_examples.py` 从 README 提取原文，在实际打包库的独立消费项目运行四后端；不能以抄写的另一份示例代替它。

CLI 契约基线 `fixtures/cli-contract/v0.7.0.json` 来自正式 v0.7.0 tag `8a3a4c79ecd54c893604839f9136081289b8f21b`，覆盖全部 17 个命令的 22 个场景。发现差异时先判定是修复、兼容变化还是 bug，不能重新录制当前输出来制造通过。宿主路径/系统错误单独检查稳定类别，不硬编码平台文字。

失败 fuzz 输入及配对主文件保存在 `_build/fuzz-failures/`，使用 `node tools/fuzz.cjs --replay FILE` 重放。确认性质后缩减输入，保存原种子、迭代、SHA、预期及缩减方法；不要把格式拒绝当作崩溃，或因样本暂时通过就删除历史回归。持续 corpus 见 `fixtures/regressions/`。

性能复现见[固定数据基准](docs/io-benchmark.md)。同一工具链、宿主、SQLite、种子和数据规模下比较读取次数、字节、进程峰值 RSS 和时间；Windows/Linux 的 RSS 实现不同，跨机器耗时不能作为硬性性能保证。

每个提交围绕可独立审查和撤销的完整目的，相关实现、测试、接口和文档一起提交。完整本地 CI 通过后才 commit；检查后修改须重跑受影响项。推送后检查该 SHA 的远程 CI，不沿用旧提交结果。公开发布需另行授权、核对 tag、附件版本与 SHA256，并完成真实 registry 消费；本地 `moon package` 或 `npm pack` 不等于已发布。
