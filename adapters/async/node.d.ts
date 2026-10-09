import type {AsyncSource, Statistics} from './index.js';
/** Node 22 文件范围源；默认由 openDatabase 接管。 */
export interface FileSource extends AsyncSource {readonly closed: boolean; statistics: Statistics; close(): Promise<void>}
export function openFileSource(path: string | URL): Promise<FileSource>;
