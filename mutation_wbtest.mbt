///|
test "deterministic mutations remain within typed errors and resource budgets" {
  let original = fixture_btree()
  let limits = Limits::{
    max_rows: 64,
    max_payload_bytes: 4096,
    max_pages: 128,
    max_depth: 16,
  }
  let mut rejected = 0
  // 固定样本覆盖 header、页头、cell、overflow 与未分配区域；不把每次改字节都当成损坏。
  for iteration = 0; iteration < 192; iteration = iteration + 1 {
    let mutated = original.to_array()
    let offset = if iteration < 16 {
      iteration
    } else {
      (iteration * 997 + 100) % mutated.length()
    }
    mutated[offset] = (mutated[offset].to_int() ^ (1 << (iteration % 8))).to_byte()
    let failed = try {
      let db = open_database(Bytes::from_array(mutated), limits~)
      let entries = db.schema()
      for entry in entries {
        if entry.root_page != 0 &&
          (entry.object_type == "table" || entry.object_type == "index") {
          let summary = db.scan_btree(
            entry.root_page,
            _ => true,
            limit=64,
            max_total_payload_bytes=65536UL,
          )
          assert_true(summary.records_read <= 64)
          assert_true(summary.pages_read <= 128)
          assert_true(summary.payload_bytes <= 65536UL)
        }
      }
      false
    } catch {
      Invalid(_) | Unsupported(_) | LimitExceeded(_) => true
      error => raise error
    }
    if failed {
      rejected = rejected + 1
    }
  }
  // 魔数的每个单比特变更必须被拒绝，其余结构变更可合法或通过限额提前终止。
  assert_true(rejected >= 16)
}
