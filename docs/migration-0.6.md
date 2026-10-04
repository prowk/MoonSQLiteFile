# v0.6.0 升级说明

## 已有行为变化

- SQLite 正常产生的四字节及更长空闲间隙不再仅因长度被拒绝；统一累计所有未覆盖字节并核对页头 fragmented bytes，同时保留重叠、freeblock 链、越界和 60 字节上限。碎片计数不匹配统一定位为 `FragmentCount` / `fragment_count`，原有 `UntrackedSpace` 枚举仍保留，但不再用于提前拒绝这些间隙。
