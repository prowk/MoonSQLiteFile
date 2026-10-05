///|
/// 返回 freelist 中的 trunk 与 leaf 页号，并校验计数与循环。
pub fn Database::freelist(self : Database) -> Array[Int] raise SqliteError {
  self.freelist_observed((_, _, _) => ())
}

///|
fn Database::freelist_observed(
  self : Database,
  claim : (Int, PageKind, Int?) -> Unit raise SqliteError,
  trace? : InspectionTrace = InspectionTrace::new(),
) -> Array[Int] raise SqliteError {
  let cursor = self.freelist_cursor(claim, trace)
  while cursor.next() is Some(number) {
    cursor.supplied = Some(self.read_page(number))
  }
  cursor.result
}
