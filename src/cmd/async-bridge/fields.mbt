///|
fn request_fields(
  request : Map[String, Json],
) -> Array[Int]? raise @sqlite.SqliteError {
  if !request.contains("fields") {
    return None
  }
  let fields : Array[Int] = @json.from_json(request["fields"]) catch {
    _ => raise @sqlite.Invalid("fields 必须为整数数组")
  }
  // 与其他整数入口一致，不接受 JSON Int 解码可能截断的小数。
  if fields.to_json() != request["fields"] {
    raise @sqlite.Invalid("fields 必须为整数数组")
  }
  Some(fields)
}

///|
fn record_field_json(field : @sqlite.RecordField) -> Json {
  Json::object({
    "index": field.index.to_json(),
    "serial_type": Json::string(field.serial_type.to_string()),
    "payload_offset": field.payload_offset.to_json(),
    "byte_length": field.byte_length.to_json(),
  })
}

///|
fn projected_json(record : @sqlite.ProjectedRecord) -> Json {
  Json::object({
    "rowid": record.rowid
    .map(value => Json::string(value.to_string()))
    .unwrap_or(Json::null()),
    "page_number": record.page_number.to_json(),
    "cell_offset": record.cell_offset.to_json(),
    "header": Json::object({
      "header_bytes": record.header.header_bytes.to_json(),
      "payload_bytes": record.header.payload_bytes.to_json(),
      "fields": Json::array(record.header.fields.map(record_field_json)),
    }),
    "values": Json::array(
      record.values.map(value => {
        Json::object({
          "field": record_field_json(value.field),
          "value": value_json(value.value),
          "returned_bytes": value.returned_bytes.to_json(),
          "truncated": value.truncated.to_json(),
        })
      }),
    ),
    "record_complete": record.record_complete.to_json(),
    "overflow_chain_complete": record.overflow_chain_complete.to_json(),
    "copied_bytes": Json::string(record.copied_bytes.to_string()),
  })
}

///|
fn field_chunk_json(chunk : @sqlite.FieldChunk) -> Json {
  Json::object({
    "field": record_field_json(chunk.field),
    "offset": chunk.offset.to_json(),
    "hex": Json::string(blob_hex(chunk.bytes)),
    "more": chunk.more.to_json(),
    "overflow_chain_complete": chunk.overflow_chain_complete.to_json(),
    "copied_bytes": Json::string(chunk.copied_bytes.to_string()),
  })
}
