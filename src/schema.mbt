///|
pub(all) struct SchemaEntry {
  object_type : String
  name : String
  table_name : String
  root_page : Int
  sql : String?
} derive(Debug)

///|
pub extend SchemaEntry with @debug.Debug::{to_repr}

///|
/// 异步适配层校验已解码的 sqlite_schema 记录，语义与同步 schema 一致。
pub fn decode_schema_entry(
  values : Array[Value],
  page_count : Int,
) -> SchemaEntry raise SqliteError {
  schema_entry(values, page_count)
}

///|
pub fn Database::schema(
  self : Database,
) -> Array[SchemaEntry] raise SqliteError {
  let entries : Array[SchemaEntry] = []
  for row in self.read_table(1) {
    entries.push(schema_entry(row.values, self.page_count))
  }
  entries
}

///|
fn schema_entry(
  values : Array[Value],
  page_count : Int,
) -> SchemaEntry raise SqliteError {
  match values {
    [Text(object_type), Text(name), Text(table_name), root_value, sql_value] => {
      let root = match root_value {
        Integer(value) => value
        Null => 0L
        _ => raise Invalid("schema rootpage 字段类型无效")
      }
      if root < 0L || root > page_count.to_int64() {
        raise Invalid("schema root page 越界")
      }
      if object_type != "table" &&
        object_type != "index" &&
        object_type != "view" &&
        object_type != "trigger" {
        raise Invalid("schema 包含未知对象类型")
      }
      let sql = match sql_value {
        Text(value) => Some(value)
        Null => None
        _ => raise Invalid("schema SQL 字段类型无效")
      }
      { object_type, name, table_name, root_page: root.to_int(), sql, }
    }
    _ => raise Invalid("sqlite_schema 记录不包含标准五列")
  }
}

///|
pub fn Database::table_rows(
  self : Database,
  name : String,
  limit? : Int = self.limits.max_rows,
) -> Array[Row] raise SqliteError {
  if name == "sqlite_schema" || name == "sqlite_master" {
    return self.read_table(1, limit~)
  }
  for entry in self.schema() {
    if entry.object_type == "table" && entry.name == name {
      if entry.root_page == 0 {
        raise Unsupported("虚拟表没有独立数据 B-tree")
      }
      return self.read_table(entry.root_page, limit~)
    }
  }
  raise Invalid("未找到表：\{name}")
}

///|
/// 返回普通表或 WITHOUT ROWID 表的原始存储记录，不推断 SQL 列顺序。
pub fn Database::table_records(
  self : Database,
  name : String,
  limit? : Int = self.limits.max_rows,
) -> Array[BTreeRecord] raise SqliteError {
  if name == "sqlite_schema" || name == "sqlite_master" {
    return self.read_btree(1, limit~)
  }
  for entry in self.schema() {
    if entry.object_type == "table" && entry.name == name {
      if entry.root_page == 0 {
        raise Unsupported("虚拟表没有独立数据 B-tree")
      }
      return self.read_btree(entry.root_page, limit~)
    }
  }
  raise Invalid("未找到表：\{name}")
}

///|
pub fn Database::index_records(
  self : Database,
  name : String,
  limit? : Int = self.limits.max_rows,
) -> Array[BTreeRecord] raise SqliteError {
  for entry in self.schema() {
    if entry.object_type == "index" && entry.name == name {
      if entry.root_page == 0 {
        raise Invalid("索引没有有效根页")
      }
      return self.read_index(entry.root_page, limit~)
    }
  }
  raise Invalid("未找到索引：\{name}")
}
