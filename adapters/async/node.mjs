import {open} from 'node:fs/promises';
import {read as readFileRange} from 'node:fs';
import {SourceError, checkAbort, withAbort} from './index.mjs';

// 使用带 BigInt position 的回调式范围读取，不依赖 Number 文件位置或共享顺序游标。
export async function openFileSource(path) {
  const handle = await open(path, 'r');
  try {
    const original = await handle.stat({bigint: true}), pending = new Set();
    let closed = false;
    const source = {
      get closed() { return closed; },
      size: original.size, statistics: {reads: 0, bytes: 0, maxRead: 0},
      async read(offset, count, {signal} = {}) {
        checkAbort(signal);
        if (closed) throw new SourceError('host_failure', '文件源已关闭');
        if (typeof offset !== 'bigint' || !Number.isInteger(count) || count < 0 || count > 2147483647 ||
            offset < 0n || offset > original.size || BigInt(count) > original.size - offset) throw new SourceError('range_out_of_bounds', '文件范围越界');
        const operation = (async () => {
          const current = await handle.stat({bigint: true});
          checkAbort(signal);
          if (current.size !== original.size || current.mtimeNs !== original.mtimeNs || current.ctimeNs !== original.ctimeNs) throw new SourceError('host_failure', '文件在检查期间发生变化');
          const bytes = new Uint8Array(count);
          let copied = 0;
          while (copied < count) {
            checkAbort(signal);
            const length = await new Promise((resolve, reject) => {
              readFileRange(handle.fd, bytes, copied, count - copied, offset + BigInt(copied), (error, actual) => error ? reject(error) : resolve(actual));
            });
            if (!length) throw new SourceError('short_read', '文件提前到达 EOF');
            copied += length;
          }
          checkAbort(signal);
          source.statistics.reads++; source.statistics.bytes += copied;
          source.statistics.maxRead = Math.max(source.statistics.maxRead, count);
          return bytes;
        })();
        pending.add(operation);
        operation.finally(() => pending.delete(operation)).catch(() => {});
        return withAbort(operation, signal);
      },
      async close() {
        if (closed) return;
        closed = true;
        await Promise.allSettled([...pending]);
        await handle.close();
      },
    };
    return source;
  } catch (error) { await handle.close(); throw error; }
}
