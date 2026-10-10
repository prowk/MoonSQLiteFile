/** JSON 中的 64 位整数为十进制文本；运行时偏移使用 bigint。 */
export type Decimal = string;
export type Status = 'complete' | 'incomplete' | 'failed';
export type ErrorCategory = 'argument' | 'corruption' | 'source' | 'budget' | 'cancelled' | 'unsupported';
export interface ErrorInfo {category: ErrorCategory; kind: string; message: string}
export interface ReadOptions {signal?: AbortSignal}
export interface AsyncSource {
  readonly size: bigint;
  read(offset: bigint, count: number, options?: ReadOptions): Promise<Uint8Array>;
  close?(): Promise<void> | void;
}
export interface Statistics {reads: number; bytes: number; maxRead: number}
export interface CacheStatistics {hits: number; misses: number; bytes: number; residentPages: number}
export interface Location {phase?: string; page_number: number | null; byte_offset?: number | null; cell_index?: number | null; page_code?: string | null}
export interface ScanProgress {records_read: number; pages_read: number; payload_bytes: Decimal}
export type DiagnosticPhase = 'configuration' | 'read_page' | 'page_layout' | 'tree_traversal' | 'cell_payload' | 'overflow_chain' | 'record_decode' | 'schema_decode' | 'freelist_check' | 'ptrmap_check' | 'page_ownership_check';
export type Progress = (ScanProgress & {phase: 'scan' | 'inspection'; location?: Location | null; frames_read?: never; offset?: never}) |
  {phase: 'wal'; frames_read: number; offset: Decimal; records_read?: never; pages_read?: never; payload_bytes?: never; location?: never};
export interface ScanResult extends ScanProgress {status: Status; reason: string; completion?: string; error?: {kind: string; message: string}; location?: Location | null}
export type DiskValue = {type: 'null'; value: null} | {type: 'integer' | 'text' | 'blob'; value: string} | {type: 'real'; value: number | 'NaN' | 'Infinity' | '-Infinity'};
export interface RawRecord {rowid: Decimal | null; page_number: number; cell_offset: number; values: DiskValue[]}
export interface SchemaEntry {object_type: string; name: string; table_name: string; root_page: number; sql: string | null}
export interface SchemaResult extends ScanResult {entries: SchemaEntry[]}
export interface ScanOptions extends ReadOptions {limit?: number; max_total_payload_bytes?: bigint | Decimal; onProgress?: (progress: Progress) => void}
export interface InspectionOptions extends ReadOptions {max_issues?: number; max_total_payload_bytes?: bigint | Decimal; onProgress?: (progress: Progress) => void}
export interface OpenOptions extends ReadOptions {
  wal?: AsyncSource; tailPolicy?: 'strict' | 'valid_prefix'; closeSources?: boolean;
  blockSize?: number; cachePages?: number; max_rows?: number; max_pages?: number;
  max_payload_bytes?: number; max_depth?: number; max_report_pages?: number;
  max_frames?: number; max_overlay_pages?: number; onProgress?: (progress: Progress) => void;
}
export interface Header {page_size: number; usable_size: number; page_count: number; write_version: number; read_version: number; change_counter: number; declared_pages: number; freelist_trunk: number; freelist_pages: number; schema_cookie: number; schema_format: number; largest_root_page: number; incremental_vacuum: number; text_encoding: number; user_version: number; application_id: number; version_valid_for: number; sqlite_version: number}
export type PageOwnerKind = 'btree_root' | 'btree_child' | 'overflow_first' | 'overflow_continuation' | 'freelist_trunk' | 'freelist_leaf' | 'pointer_map' | 'lock_byte';
export interface PageOwner {page_number: number; kind: PageOwnerKind; root_page: number | null; parent_page: number | null; object_name: string | null}
export type Issue = {code: 'scan_error'; root_page: number | null; error_kind: SqliteErrorKind; message: string} |
  {code: 'page_conflict'; first: PageOwner; second: PageOwner} |
  {code: 'unclaimed_page'; page_number: number} |
  {code: 'unsupported_feature'; message: string} |
  {code: 'ptrmap_mismatch'; page_number: number; map_page: number; ptrmap_type: number; parent_page: number; expected_owner: PageOwner};
export interface Inspection {status: Status; pages: PageOwner[]; issues: Issue[]; roots_inspected: number; records_decoded: number; payload_bytes: Decimal; unclaimed_pages: number[]; ownership_complete: boolean; ptrmap_checked: boolean; diagnostics_truncated: boolean}
export interface ObjectSummary {root_page: number; object_name: string | null; btree_pages: number; overflow_pages: number; storage_bytes: Decimal}
export interface InspectionSummary {status: Status; ownership_complete: boolean; ptrmap_checked: boolean; diagnostics_truncated: boolean; logical_pages: number; page_size: number; claimed_pages: number; unclaimed_pages: number; roots_inspected: number; records_decoded: number; payload_bytes: Decimal; issue_count: number; objects: ObjectSummary[]; page_kinds: Array<{kind: PageOwnerKind; pages: number}>}
export interface InspectionResult {header: Header; inspection: Inspection; summary: InspectionSummary; locations: Array<Location | null>; reason?: string}
export type BTreePageKind = 'table_leaf' | 'table_interior' | 'index_leaf' | 'index_interior';
export interface BTreePage {number: number; kind: BTreePageKind; first_freeblock: number; cell_count: number; content_start: number; fragmented_bytes: number; right_child: number | null; cell_offsets: number[]}
export interface PageStatistics {database_header_bytes: number; btree_header_bytes: number; pointer_bytes: number; unallocated_bytes: number; cell_bytes: number; freeblock_bytes: number; fragmented_bytes: number; reserved_bytes: number; payload_bytes: Decimal; local_payload_bytes: Decimal; max_payload_bytes: number; overflow_cells: number}
export type PageDiagnosticCode = 'page_read' | 'page_type_tag' | 'page_header' | 'cell_pointer' | 'cell_format' | 'freeblock' | 'space_overlap' | 'untracked_space' | 'fragment_count' | 'child_pointer';
export interface PageDiagnostic {code: PageDiagnosticCode; page_number: number; byte_offset: number | null; cell_index: number | null; error_kind: SqliteErrorKind; message: string}
export type PageResult = {status: 'complete'; page: BTreePage; statistics: PageStatistics; diagnostic: null} |
  {status: 'failed' | 'incomplete'; page: BTreePage | null; statistics: PageStatistics | null; diagnostic: PageDiagnostic | null; error?: {kind: string; message: string}; reason?: string};
/** WAL 报告偏移保留历史 number/十进制文本联合，不等同于源 read 的 bigint。 */
export type WalOffset = number | Decimal;
export type WalStopReason = 'end_of_file' | 'truncated_frame' | 'salt_mismatch' | 'checksum_mismatch' | 'invalid_frame' | 'frame_limit';
export interface WalHeader {checksum_order: 'little_endian' | 'big_endian'; version: number; page_size: number; checkpoint_sequence: number; salt1: number; salt2: number; checksum1: number; checksum2: number}
export interface WalFrame {index: number; byte_offset: WalOffset; page_number: number; database_pages: number; checksum1: number; checksum2: number}
export interface WalInspection {header: WalHeader | null; frames: WalFrame[]; commits: Array<{frame_index: number; database_pages: number}>; committed_frames: number; uncommitted_frames: number; database_pages: number | null; stop_reason: WalStopReason; stop_offset: WalOffset; trailing_bytes: WalOffset}
/** 低层构造器仅接收真实核心桥接与其句柄；常规接入使用 openDatabase。 */
export type CoreReply = {ok: true; result: unknown} | {ok: false; error: {kind: SqliteErrorKind; message: string}};
export type CoreBridge = (request: Record<string, unknown>, bytes?: Uint8Array) => CoreReply;
export interface DatabaseHandle {id: number; header: Header}
export interface WalIndexHandle {id: number; size: Decimal; page_size: number; page_count: number}
export interface ReportEnvelope<T> {format: 'moonsqlitefile-report'; format_version: 1; tool_version: string; scope: string; budgets: Record<string, unknown>; status: Status; partial: boolean; diagnostics: Array<ErrorInfo & {code?: string; location?: Location | null}>; result: T}
export class ParameterError extends TypeError {kind: 'invalid_argument'; constructor(message: string)}
export type SourceErrorKind = 'range_out_of_bounds' | 'short_read' | 'host_failure';
export type SqliteErrorKind = 'invalid' | 'unsupported' | 'limit_exceeded';
export class SourceError extends Error {kind: SourceErrorKind; constructor(kind: SourceErrorKind, message: string)}
export class CancelledError extends Error {kind: 'cancelled'; constructor(message?: string)}
export class SqliteError extends Error {kind: SqliteErrorKind; constructor(kind: SqliteErrorKind, message: string)}
export function errorInfo(error: unknown): ErrorInfo;
export function reportEnvelope<T extends InspectionResult | SchemaResult | ScanResult | PageResult>(result: T, context: {scope: string; budgets?: Record<string, unknown>}): ReportEnvelope<T>;
export function checkAbort(signal?: AbortSignal): void;
export function withAbort<T>(operation: PromiseLike<T> | T, signal?: AbortSignal): Promise<T>;
export function readExact(source: AsyncSource, offset: bigint, count: number, signal?: AbortSignal): Promise<Uint8Array>;
export class BlobSource implements AsyncSource {size: bigint; closed: boolean; statistics: Statistics; constructor(blob: Blob); read(offset: bigint, count: number, options?: ReadOptions): Promise<Uint8Array>; close(): Promise<void>}
export class CachedSource implements AsyncSource {size: bigint; closed: boolean; statistics: CacheStatistics; constructor(source: AsyncSource, options?: {blockSize?: number; cachePages?: number; closeSource?: boolean}); read(offset: bigint, count: number, options?: ReadOptions): Promise<Uint8Array>; close(): Promise<void>}
export class WalSource implements AsyncSource {size: bigint; closed: boolean; pageSize: number; pageCount: number; inspection: WalInspection; constructor(base: AsyncSource, wal: AsyncSource, core: CoreBridge, index: WalIndexHandle, report: WalInspection); read(offset: bigint, count: number, options?: ReadOptions): Promise<Uint8Array>; close(): Promise<void>}
export class Scan<T = RawRecord> implements AsyncIterableIterator<T, ScanResult> {
  constructor(database: Database, root: number, options?: ScanOptions);
  progress: ScanProgress; result: ScanResult | null; signal: AbortSignal;
  next(): Promise<IteratorResult<T, ScanResult>>; return(): Promise<IteratorResult<T, ScanResult>>;
  [Symbol.asyncIterator](): this;
}
export class Database {
  constructor(core: CoreBridge, handle: DatabaseHandle, source: AsyncSource, options: OpenOptions);
  readonly core: CoreBridge;
  header: Header; source: AsyncSource; closed: boolean; options: OpenOptions;
  readPage(page: number, signal?: AbortSignal): Promise<Uint8Array>;
  inspectPage(page: number, options?: ReadOptions): Promise<PageResult>;
  scan(root: number, options?: ScanOptions): Scan;
  scanBtree(root: number, visitor: (record: RawRecord, signal: AbortSignal) => boolean | void | Promise<boolean | void>, options?: ScanOptions): Promise<ScanResult>;
  schema(options?: ScanOptions): Promise<SchemaResult>;
  inspectDatabase(options?: InspectionOptions): Promise<InspectionResult>;
  close(): Promise<void>;
}
export function openDatabase(source: AsyncSource, options?: OpenOptions): Promise<Database>;
