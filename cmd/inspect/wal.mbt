///|
extern "js" fn host_has_wal() -> Bool =
  #| () => globalThis.moonsqlitefileHost.walBytes !== undefined

///|
extern "js" fn host_wal_bytes() -> Bytes =
  #| () => globalThis.moonsqlitefileHost.walBytes

///|
extern "js" fn host_wal_prefix() -> Bool =
  #| () => globalThis.moonsqlitefileHost.walPrefix === true

///|
fn cli_database() -> (@sqlite.Database, @sqlite.WalSource?) raise @sqlite.SqliteError {
  if host_has_wal() {
    let tail_policy = if host_wal_prefix() {
      @sqlite.UseValidPrefix
    } else {
      @sqlite.RejectInvalidTail
    }
    let source = @sqlite.WalSource::new(
      @sqlite.BytesSource::new(host_bytes()),
      host_wal_bytes(),
      tail_policy~,
    )
    (@sqlite.open_wal_source(source), Some(source))
  } else {
    (@sqlite.open_database(host_bytes()), None)
  }
}

///|
fn wal_json(report : @sqlite.WalInspection) -> Json {
  let header = match report.header {
    None => Json::null()
    Some(header) =>
      Json::object({
        "checksum_order": Json::string(
          match header.checksum_order {
            @sqlite.LittleEndianChecksum => "little_endian"
            @sqlite.BigEndianChecksum => "big_endian"
          },
        ),
        "version": header.version.to_json(),
        "page_size": header.page_size.to_json(),
        "checkpoint_sequence": header.checkpoint_sequence.to_json(),
        "salt1": header.salt1.to_json(),
        "salt2": header.salt2.to_json(),
        "checksum1": header.checksum1.to_json(),
        "checksum2": header.checksum2.to_json(),
      })
  }
  let stop = match report.stop_reason {
    @sqlite.WalEndOfFile => "end_of_file"
    @sqlite.WalTruncatedFrame => "truncated_frame"
    @sqlite.WalSaltMismatch => "salt_mismatch"
    @sqlite.WalChecksumMismatch => "checksum_mismatch"
    @sqlite.WalInvalidFrame => "invalid_frame"
    @sqlite.WalFrameLimit => "frame_limit"
  }
  Json::object({
    "header": header,
    "frames": Json::array(
      report.frames.map(frame => {
        Json::object({
          "index": frame.index.to_json(),
          "byte_offset": frame.byte_offset.to_json(),
          "page_number": frame.page_number.to_json(),
          "database_pages": frame.database_pages.to_json(),
          "checksum1": frame.checksum1.to_json(),
          "checksum2": frame.checksum2.to_json(),
        })
      }),
    ),
    "commits": Json::array(
      report.commits.map(commit => {
        Json::object({
          "frame_index": commit.frame_index.to_json(),
          "database_pages": commit.database_pages.to_json(),
        })
      }),
    ),
    "committed_frames": report.committed_frames.to_json(),
    "uncommitted_frames": (report.frames.length() - report.committed_frames).to_json(),
    "database_pages": match report.database_pages {
      Some(pages) => pages.to_json()
      None => Json::null()
    },
    "stop_reason": Json::string(stop),
    "stop_offset": report.stop_offset.to_json(),
    "trailing_bytes": report.trailing_bytes.to_json(),
  })
}
