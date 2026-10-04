///|
priv struct HostSource {
  wal : Bool
}

///|
extern "js" fn host_size64(wal : Bool) -> Int64 =
  #| wal => { const h = globalThis.moonsqlitefileHost; return BigInt(wal ? (h.walSize ?? h.walBytes.length) : (h.fileSize ?? h.bytes.length)); }

///|
extern "js" fn host_read64(wal : Bool, offset : Int64, count : Int) -> Bytes =
  #| (wal, offset, count) => { const h = globalThis.moonsqlitefileHost; h.readError = ''; try { const read = wal ? h.readWalRange : h.readRange; if (read) return read(offset, count); const bytes = wal ? h.walBytes : h.bytes; return bytes.slice(Number(offset), Number(offset) + count); } catch (error) { h.readError = error.message; return new Uint8Array(0); } }

///|
extern "js" fn host_read_error() -> String =
  #| () => globalThis.moonsqlitefileHost.readError

///|
extern "js" fn host_has_wal() -> Bool =
  #| () => { const h = globalThis.moonsqlitefileHost; return h.walSize !== undefined || h.walBytes !== undefined; }

///|
extern "js" fn host_wal_prefix() -> Bool =
  #| () => globalThis.moonsqlitefileHost.walPrefix === true

///|
extern "js" fn host_option(name : String, fallback : Int) -> Int =
  #| (name, fallback) => globalThis.moonsqlitefileHost.options?.[name] ?? fallback

///|
extern "js" fn host_payload_budget() -> UInt64 =
  #| () => BigInt(globalThis.moonsqlitefileHost.options?.['max-total-payload-bytes'] ?? 67108864n)

///|
impl @sqlite.RangeSource for HostSource with fn byte_length64(self) {
  host_size64(self.wal)
}

///|
impl @sqlite.RangeSource for HostSource with fn read_range64(
  self,
  offset,
  count,
) {
  let bytes = host_read64(self.wal, offset, count)
  let message = host_read_error()
  if message != "" {
    raise @sqlite.HostFailure(message)
  }
  bytes
}

///|
fn cli_database() -> (@sqlite.Database, @sqlite.RangeWalSource?) raise @sqlite.SqliteError {
  let base = @sqlite.CachedSource::new(
    HostSource::{ wal: false, },
    max_pages=host_option("cache-pages", 256),
  )
  let limits : @sqlite.Limits = {
    max_rows: host_option("max-rows", 100000),
    max_pages: host_option("max-pages", 100000),
    max_payload_bytes: host_option("max-payload-bytes", 16777216),
    max_depth: 64,
  }
  if host_has_wal() {
    let source = @sqlite.RangeWalSource::new(
      base,
      HostSource::{ wal: true, },
      tail_policy=if host_wal_prefix() {
        @sqlite.UseValidPrefix
      } else {
        @sqlite.RejectInvalidTail
      },
      max_frames=host_option("max-frames", 100000),
      max_overlay_pages=host_option("max-overlay-pages", 100000),
    )
    (
      @sqlite.open_range_wal_source(
        source,
        limits~,
        max_report_pages=host_option("max-report-pages", 100000),
      ),
      Some(source),
    )
  } else {
    (
      @sqlite.open_range_source(
        base,
        limits~,
        max_report_pages=host_option("max-report-pages", 100000),
      ),
      None,
    )
  }
}
