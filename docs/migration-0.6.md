# v0.6.0 升级说明

## 已有行为变化

- SQLite 正常产生的四字节及更长空闲间隙不再仅因长度被拒绝；统一累计所有未覆盖字节并核对页头 fragmented bytes，同时保留重叠、freeblock 链、越界和 60 字节上限。碎片计数不匹配统一定位为 `FragmentCount` / `fragment_count`，原有 `UntrackedSpace` 枚举仍保留，但不再用于提前拒绝这些间隙。
- 非根空 B-tree 页现在返回 `Invalid` / `Failed`，防止损坏文件缺失记录却以完整结果返回。空表/索引叶根仍可读取；仅页 1 可以保留零 cell 的内部虚拟根，实际子页须非空。叶页深度、键边界及重复页检查继续生效。
