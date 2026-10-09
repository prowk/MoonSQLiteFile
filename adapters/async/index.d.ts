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
export interface Progress {phase?: string; records_read?: number; pages_read?: number; payload_bytes?: Decimal; frames_read?: number; offset?: Decimal; location?: Location | null}
export interface ScanProgress {records_read: number; pages_read: number; payload_bytes: Decimal}
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
export interface Header {page_size: number; page_count: number; [field: string]: number}
export interface PageOwner {page_number: number; kind: string; root_page: number | null; parent_page: number | null; object_name: string | null}
export interface Issue {code: string; error_kind?: string; message?: string; page_number?: number; [field: string]: unknown}
export interface Inspection {status: Status; pages: PageOwner[]; issues: Issue[]; records_decoded: number; payload_bytes: Decimal; ownership_complete: boolean; ptrmap_checked: boolean; diagnostics_truncated: boolean; [field: string]: unknown}
export interface InspectionResult {header: Header; inspection: Inspection; summary: {claimed_pages: number; unclaimed_pages: number; objects: Array<{root_page: number; object_name: string | null; btree_pages: number; overflow_pages: number}>; page_kinds: Array<{kind: string; pages: number}>; [field: string]: unknown}; locations: Array<Location | null>; reason?: string}
export interface PageResult {status: Status; page: {number: number; kind: string; cell_count: number; cell_offsets: number[]; [field: string]: unknown} | null; statistics: {[field: string]: number | Decimal} | null; diagnostic: {code: string; page_number: number; byte_offset: number | null; cell_index: number | null; error_kind: string; message: string} | null; error?: {kind: string; message: string}; reason?: string}
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
export class WalSource implements AsyncSource {size: bigint; closed: boolean; pageSize: number; pageCount: number; inspection: Record<string, unknown>; constructor(base: AsyncSource, wal: AsyncSource, core: unknown, index: unknown, report: Record<string, unknown>); read(offset: bigint, count: number, options?: ReadOptions): Promise<Uint8Array>; close(): Promise<void>}
export class Scan<T = RawRecord> implements AsyncIterableIterator<T, ScanResult> {
  constructor(database: Database, root: number, options?: ScanOptions);
  progress: ScanProgress; result: ScanResult | null; signal: AbortSignal;
  next(): Promise<IteratorResult<T, ScanResult>>; return(): Promise<IteratorResult<T, ScanResult>>;
  [Symbol.asyncIterator](): this;
}
export class Database {
  constructor(core: unknown, handle: unknown, source: AsyncSource, options: OpenOptions);
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
