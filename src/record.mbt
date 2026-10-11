///|
/// SQLite 记录中的原始值，保留整数、浮点数与二进制数据的区别。
/// SQLite record 的磁盘值类型；Integer 保留 Int64，Text 按数据库编码解码，Blob 保留字节。不是 SQL 引擎计算后的逻辑值。
pub(all) enum Value {
  Null
  Integer(Int64)
  Real(Double)
  Text(String)
  Blob(Bytes)
} derive(Debug, Eq)

///|
pub extend Value with @debug.Debug::{to_repr}

///|
pub extend Value with Eq::{equal, not_equal}

///|
/// 物理列的 serial type、payload 内字节偏移和原始长度；没有 SQL 列名或亲和性转换。
pub(all) struct RecordField {
  index : Int
  serial_type : UInt64
  payload_offset : Int
  byte_length : Int
} derive(Debug, Eq)

///|
pub extend RecordField with @debug.Debug::{to_repr}

///|
pub extend RecordField with Eq::{equal, not_equal}

///|
/// 已校验的记录头和字段边界；不表示字段内容或完整 overflow 链已验证。
pub(all) struct RecordHeader {
  header_bytes : Int
  payload_bytes : Int
  fields : Array[RecordField]
} derive(Debug)

///|
pub extend RecordHeader with @debug.Debug::{to_repr}

///|
/// 只解析完整记录头，payload_size 为 cell 声明长度；先核对字段边界，不分配字段值。
pub fn parse_record_header(
  header : Bytes,
  payload_size : Int,
  max_fields? : Int = 65536,
) -> RecordHeader raise SqliteError {
  if max_fields < 1 {
    raise Invalid("记录字段上限必须为正数")
  }
  let (size, prefix) = decode_varint(header, 0)
  if payload_size < 0 ||
    size < prefix.to_uint64() ||
    size > payload_size.to_uint64() {
    raise Invalid("记录头长度超出 payload 边界")
  }
  let header_end = size.to_int()
  require_range(header, 0, header_end)
  let fields : Array[RecordField] = []
  let mut position = prefix
  let mut body = header_end
  while position < header_end {
    if fields.length() >= max_fields {
      raise LimitExceeded("记录字段数量超过限制")
    }
    let (serial, length) = decode_varint(header, position)
    if length > header_end - position {
      raise Invalid("serial type varint 跨越记录头边界")
    }
    let count = record_serial_length(serial)
    if count > payload_size - body {
      raise Invalid("记录字段长度超出 payload 边界")
    }
    fields.push({
      index: fields.length(),
      serial_type: serial,
      payload_offset: body,
      byte_length: count,
    })
    body = body + count
    position = position + length
  }
  if body != payload_size {
    raise Invalid("记录体含有未被 serial type 描述的剩余字节")
  }
  { header_bytes: header_end, payload_bytes: payload_size, fields, }
}

///|
fn record_serial_length(serial : UInt64) -> Int raise SqliteError {
  match serial {
    0UL | 8UL | 9UL => 0
    1UL => 1
    2UL => 2
    3UL => 3
    4UL => 4
    5UL => 6
    6UL | 7UL => 8
    10UL | 11UL => raise Invalid("记录包含保留 serial type：\{serial}")
    _ => {
      let length = (serial - 12UL) / 2UL
      if length > 2147483647UL {
        raise Invalid("记录字段长度超出可读取范围")
      }
      length.to_int()
    }
  }
}

///|
fn record_integer(payload : Bytes, offset : Int, count : Int) -> Int64 {
  let mut bits = 0UL
  for i = 0; i < count; i = i + 1 {
    bits = (bits << 8) | payload[offset + i].to_uint64()
  }
  if count < 8 && payload[offset].to_int() >= 128 {
    // SQLite 使用大端二进制补码，短整数必须进行符号扩展。
    bits.reinterpret_as_int64() - (1L << (count * 8))
  } else {
    bits.reinterpret_as_int64()
  }
}

///|
fn record_text(data : BytesView, encoding : Int) -> String raise SqliteError {
  try {
    match encoding {
      1 => @utf8.decode(data, ignore_bom=false)
      2 => @utf16.decode(data, ignore_bom=false, endianness=@utf16.Little)
      3 => @utf16.decode(data, ignore_bom=false, endianness=@utf16.Big)
      _ => raise Invalid("无效文本编码：\{encoding}")
    }
  } catch {
    _ => raise Invalid("记录文本不符合指定的 Unicode 编码")
  }
}

///|
/// 解码完整的 SQLite record payload；编码编号与数据库文件头保持一致。
/// 完整解码 record 的 serial types 与 payload；encoding 为 1/2/3，保留磁盘值顺序，不执行 SQL 转换。截断、非法编码或不支持类型通过 SqliteError 返回。
pub fn decode_record(
  payload : Bytes,
  encoding : Int,
) -> Array[Value] raise SqliteError {
  if encoding < 1 || encoding > 3 {
    raise Invalid("无效文本编码：\{encoding}")
  }
  let header = parse_record_header(
    payload,
    payload.length(),
    max_fields=payload.length(),
  )
  let values : Array[Value] = []
  for field in header.fields {
    let serial = field.serial_type
    let count = field.byte_length
    let body_cursor = field.payload_offset
    require_range(payload, body_cursor, count)
    let value = match serial {
      0UL => Null
      1UL | 2UL | 3UL | 4UL | 5UL | 6UL =>
        Integer(record_integer(payload, body_cursor, count))
      7UL =>
        Real(record_integer(payload, body_cursor, 8).reinterpret_as_double())
      8UL => Integer(0L)
      9UL => Integer(1L)
      _ => {
        let data = payload.exact_view(
          start=body_cursor,
          end=body_cursor + count,
        )
        if serial % 2UL == 0UL {
          Blob(data.to_owned())
        } else {
          Text(record_text(data, encoding))
        }
      }
    }
    values.push(value)
  }
  values
}
