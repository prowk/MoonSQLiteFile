# 发布材料规范

本页集中维护正式版本的核对与正文规则。当前正式版本目标为 v0.8.1，用户已确认主要交互和视觉，可在剩余验证完成后冻结。开发阶段不创建中间版本的 tag、Release 或 registry 包；页面正式标识、包和附件统一使用最终版本，站点部署不代表包发布。

## 一致性与证据

源码版本以 `moon.mod` 为准，异步 `package.json` 和报告元数据同步。开发期使用开发标识，不发布该标识的包；正式冻结时统一设置稳定版本，并整理对应 CHANGELOG 章节。完整项目验证包含 `python tools/verify_release.py` 的只读源码一致性检查；它不访问 registry 或 GitHub，也不创建任何发布内容。

正式发版准备时统一设置 `0.8.1`，以最终内容验证打包及消费；计划版本不等于已经发布。

未来发布前集中核对以下信息，不能沿用旧版本通过结果：

1. 最终内容通过[完整验收](../CONTRIBUTING.md#完整验证)，提交后对应 SHA 的 GitHub CI pinned/latest 均成功。
2. 标题为 `MoonSQLiteFile vX.Y.Z`，tag、源码、异步包、安装命令、附件内容和 CHANGELOG 版本一致；已存在 tag 指向正确提交，不改写历史 tag。
3. HTML 为 `moonsqlitefile-viewer-X.Y.Z.html`，异步附件为 `prowk-moonsqlitefile-async-X.Y.Z.tgz`，`SHA256SUMS` 列出两者的 SHA256。附件只从该最终内容构建，不沿用旧二进制。
4. 核对目标版本的 Mooncakes API、tag 固定 CHANGELOG/迁移文档、上一发布版本完整差异链接，以及该 tag 提交的 CI 链接。仅在对应 registry 实际发布及消费通过后说明可从该渠道安装；本地打包不等于已发布。

脚本可对未来准备好的既有材料做只读核对（不创建 tag、附件或 Release）：

```sh
python tools/verify_release.py --tag vX.Y.Z --assets _build/release-X.Y.Z --ci-evidence _build/release-X.Y.Z/remote-ci.json
```

`remote-ci.json` 使用 GitHub 实际返回的 `head_sha`、`status`、`conclusion`、`html_url` 和 jobs；须覆盖 pinned/latest 且 SHA 与 tag 一致。脚本检查本地提供的证据一致性，不能代替访问 GitHub 核实证据来源、registry 消费或人工审查正文和链接。

## 中文 Release 正文

正文面向使用者，回答改了什么、升级注意什么、如何安装或下载。开头用一句话概述版本重点，按“概述 → 主要更新 → 升级说明（如需）→ 安装 → 验证 → 使用边界（如需）→ 相关链接”组织；小版本优先简短。

“主要更新”和“安装”使用二级标题。更新以该版 CHANGELOG 为依据，通常用 3–5 条用户可见的能力、修复或行为变化；变化少时可更少。工程和文档调整概括说明，不罗列文件、注释数量或开发过程。

有 API 不兼容、行为收紧、工具链变化或迁移步骤时，在主要更新后加“升级说明”，写明影响、必要操作并链接该 tag 的迁移章节；未经核实不声称没有破坏性变化。安装用独立 `sh` 代码块，已发布到 registry 的对应版本才写 `moon add prowk/moonsqlitefile@X.Y.Z`。附件简述用途及下载或安装方式；未发布渠道不能写成 registry 安装。

验证用 1–2 句话概括本版实际完成的关键检查，链接 tag 所指 SHA 的 CI。数量、样本规模、性能和核验过程留在对应版本证据记录；不要重复整份日志。使用边界只保留有助于正确使用本版的关键限制，升级风险必须写在升级说明，不能仅给链接。

相关链接紧凑提供对应 Mooncakes API、tag 固定 CHANGELOG 和与上一发布版本的完整差异；首个版本省略差异。按需链接详细材料，避免重复。精简不能省略升级风险或把计划写成已支持。

## 历史材料

历史 Release 仅依据该版本真实 CHANGELOG、迁移、附件和 CI 整理，保持当时的能力边界。旧 tag 下的文档不改写；当前仓库的合并迁移保留各版本事实。v0.6.0 是合入 v0.7.0 的内部里程碑，未单独发布。

线上编辑需要对应授权，不在文档整理时自动执行。现有 v0.8.0 的长期核验入口见[版本记录](validation-v0.8.0.md)，其他历史版本见[CHANGELOG](../CHANGELOG.md)和[升级说明](migration.md)。
