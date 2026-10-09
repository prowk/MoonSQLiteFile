# 静态副本的独立 Node 消费项目

本项目从实际安装的异步 tarball 读取记录与可选 WAL，并输出 schema/预览状态包装报告；不引用仓库核心或适配源码。当前版本未上传 npm，请先从根目录构建本地包：

```sh
moon build --target js --deny-warn
python tools/build_async.py
npm pack ./_build/async-adapter --pack-destination _build
cd examples/async-consumer
npm install --offline --ignore-scripts --no-audit --no-fund
node main.mjs ../../fixtures/core.sqlite
```

可再传同一时刻的 WAL 副本路径；Ctrl+C 通过 AbortSignal 取消，finally 等待关闭接管源。schema 最多 100 个对象、预览最多 3 条记录，预算不足时保留 incomplete。打开 WAL 文件前失败也会关闭先打开的主文件源。源生命周期、错误类别与 64 位规则见[契约说明](../../docs/contracts.md)。

完整验收会将本项目实际源码复制到独立消费目录，从离线 tarball 安装后运行，并在真实浏览器验证包内浏览器示例。它是可复现接入案例，不代表外部使用者的真实反馈。包内声明支持严格 NodeNext/Bundler，浏览器入口使用 BlobSource，不加载 Node 子入口。
