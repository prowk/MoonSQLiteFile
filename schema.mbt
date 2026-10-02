///|
pub(all) struct SchemaEntry {
  object_type : String
  name : String
  table_name : String
  root_page : Int
  sql : String?
} derive(Debug)

///|
pub fn Database::schema(self : Database) -> Array[SchemaEntry] raise SqliteError {
  let entries : Array[SchemaEntry] = []
  for row in self.read_table(1) {
    match row.values {
      [Text(object_type), Text(name), Text(table_name), Integer(root), sql_value] => {
        if root < 0L || root > self.page_count.to_int64() { raise Invalid("schema root page 越界") }
        if object_type != "table" && object_type != "index" && object_type != "view" && object_type != "trigger" {
          raise Invalid("schema 包含未知对象类型")
        }
        let sql = match sql_value {
          Text(value) => Some(value)
          Null => None
          _ => raise Invalid("schema SQL 字段类型无效")
        }
        entries.push({ object_type, name, table_name, root_page: root.to_int(), sql })
      }
      _ => raise Invalid("sqlite_schema 记录不包含标准五列")
    }
  }
  entries
}

///|
pub fn Database::table_rows(self : Database, name : String, limit? : Int = self.limits.max_rows) -> Array[Row] raise SqliteError {
  if name == "sqlite_schema" || name == "sqlite_master" { return self.read_table(1, limit~) }
  for entry in self.schema() {
    if entry.object_type == "table" && entry.name == name {
      if entry.root_page == 0 { raise Unsupported("虚拟表没有独立数据 B-tree") }
      return self.read_table(entry.root_page, limit~)
    }
  }
  raise Invalid("未找到表：\{name}")
}
