///|
suberror CliError {
  Usage(String)
}

///|
// JavaScript 桥接仅提供进程参数和字节输入；文件格式解析全部在 MoonBit 中进行。
extern "js" fn host_args() -> FixedArray[String] =
  #| () => globalThis.moonsqlitefileHost.args

///|
extern "js" fn host_bytes() -> Bytes =
  #| () => globalThis.moonsqlitefileHost.bytes

///|
extern "js" fn host_output(text : String) -> Unit =
  #| text => globalThis.moonsqlitefileHost.output(text)

///|
extern "js" fn host_error(text : String) -> Unit =
  #| text => globalThis.moonsqlitefileHost.error(text)

///|
fn parse_number(text : String, allow_zero : Bool) -> Int raise CliError {
  if text.is_empty() {
    raise Usage("数字参数不能为空")
  }
  let mut value = 0
  for character in text {
    if character < '0' || character > '9' {
      raise Usage("数字参数只能包含十进制数字：\{text}")
    }
    let digit = character.to_int() - '0'.to_int()
    if value > (2147483647 - digit) / 10 {
      raise Usage("数字参数超出 Int 范围：\{text}")
    }
    value = value * 10 + digit
  }
  if value == 0 && !allow_zero {
    raise Usage("页号必须大于零")
  }
  value
}

///|
fn blob_hex(bytes : Bytes) -> String {
  let digits = "0123456789abcdef"
  let builder = StringBuilder()
  for byte in bytes {
    let value = byte.to_int()
    builder.write_char(digits[value >> 4].to_char().unwrap())
    builder.write_char(digits[value & 15].to_char().unwrap())
  }
  builder.to_string()
}

///|
fn value_json(value : @sqlite.Value) -> Json {
  let (kind, data) : (String, Json) = match value {
    @sqlite.Null => ("null", Json::null())
    @sqlite.Integer(number) => ("integer", Json::string(number.to_string()))
    @sqlite.Real(number) => {
      // 非有限 IEEE 值使用字符串保留，避免生成无效 JSON 数字。
      let data = if number.is_nan() {
        Json::string("NaN")
      } else if number.is_pos_inf() {
        Json::string("Infinity")
      } else if number.is_neg_inf() {
        Json::string("-Infinity")
      } else {
        Json::number(number)
      }
      ("real", data)
    }
    @sqlite.Text(text) => ("text", Json::string(text))
    @sqlite.Blob(bytes) => ("blob", Json::string(blob_hex(bytes)))
  }
  Json::object({ "type": Json::string(kind), "value": data })
}

///|
fn header_json(db : @sqlite.Database) -> Json {
  let h = db.header()
  Json::object({
    "page_size": h.page_size.to_json(),
    "usable_size": h.usable_size.to_json(),
    "page_count": db.page_count().to_json(),
    "write_version": h.write_version.to_json(),
    "read_version": h.read_version.to_json(),
    "change_counter": h.change_counter.to_json(),
    "declared_pages": h.declared_pages.to_json(),
    "freelist_trunk": h.freelist_trunk.to_json(),
    "freelist_pages": h.freelist_pages.to_json(),
    "schema_cookie": h.schema_cookie.to_json(),
    "schema_format": h.schema_format.to_json(),
    "text_encoding": h.text_encoding.to_json(),
    "user_version": h.user_version.to_json(),
    "application_id": h.application_id.to_json(),
    "version_valid_for": h.version_valid_for.to_json(),
    "sqlite_version": h.sqlite_version.to_json(),
  })
}

///|
fn page_json(page : @sqlite.Page) -> Json {
  let kind = match page.kind {
    @sqlite.TableLeaf => "table_leaf"
    @sqlite.TableInterior => "table_interior"
    @sqlite.IndexLeaf => "index_leaf"
    @sqlite.IndexInterior => "index_interior"
  }
  Json::object({
    "number": page.number.to_json(),
    "kind": Json::string(kind),
    "first_freeblock": page.first_freeblock.to_json(),
    "cell_count": page.cell_count.to_json(),
    "content_start": page.content_start.to_json(),
    "fragmented_bytes": page.fragmented_bytes.to_json(),
    "right_child": match page.right_child {
      Some(number) => number.to_json()
      None => Json::null()
    },
    "cell_offsets": page.cell_offsets.to_json(),
  })
}

///|
fn run(args : FixedArray[String]) -> Json raise {
  let usage = "用法：node tools/inspect.cjs FILE header|schema|page N|rows TABLE [LIMIT]|freelist"
  if args.length() < 2 {
    raise Usage(usage)
  }
  let command = args[1]
  match command {
    "header" | "schema" | "freelist" =>
      if args.length() != 2 {
        raise Usage(usage)
      }
    "page" => if args.length() != 3 { raise Usage(usage) }
    "rows" => if args.length() != 3 && args.length() != 4 { raise Usage(usage) }
    _ => raise Usage("未知命令：\{command}\n\{usage}")
  }
  let db = @sqlite.open_database(host_bytes())
  match command {
    "header" => header_json(db)
    "schema" => {
      let entries = db.schema()
      Json::array(
        entries.map(entry => {
          Json::object({
            "object_type": Json::string(entry.object_type),
            "name": Json::string(entry.name),
            "table_name": Json::string(entry.table_name),
            "root_page": entry.root_page.to_json(),
            "sql": match entry.sql {
              Some(text) => Json::string(text)
              None => Json::null()
            },
          })
        }),
      )
    }
    "page" => page_json(db.page(parse_number(args[2], false)))
    "rows" => {
      let rows = if args.length() == 4 {
        db.table_rows(args[2], limit=parse_number(args[3], true))
      } else {
        db.table_rows(args[2])
      }
      Json::array(
        rows.map(row => {
          Json::object({
            // 值按 record 存储顺序输出，不推断 INTEGER PRIMARY KEY 等 SQL 语义。
            "rowid": Json::string(row.rowid.to_string()),
            "page_number": row.page_number.to_json(),
            "values": Json::array(row.values.map(value_json)),
          })
        }),
      )
    }
    "freelist" => db.freelist().to_json()
    _ => raise Usage(usage)
  }
}

///|
fn main {
  try {
    let result = run(host_args())
    host_output(result.stringify())
  } catch {
    Usage(message) => host_error(message)
    error => host_error("\{error}")
  }
}
