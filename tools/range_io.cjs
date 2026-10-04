'use strict';
// 宿主保持文件描述符，精确读取请求区间；不缓存整文件，不修改输入。
const fs = require('node:fs');
function openFileSource(file) {
  const fd = fs.openSync(file, 'r');
  const initial = fs.fstatSync(fd, {bigint: true});
  const statistics = {reads: 0, bytes: 0, maxRead: 0, peakRss: process.memoryUsage().rss};
  let closed = false;
  return {
    size: initial.size,
    statistics,
    read(offset, count) {
      if (closed) throw new Error('数据源已经关闭');
      if (typeof offset !== 'bigint' || !Number.isSafeInteger(count) || count < 0 ||
          offset < 0n || offset > initial.size || BigInt(count) > initial.size - offset) {
        throw new Error('文件读取范围越界');
      }
      const current = fs.fstatSync(fd, {bigint: true});
      if (current.size !== initial.size || current.mtimeNs !== initial.mtimeNs || current.ctimeNs !== initial.ctimeNs) {
        throw new Error('静态输入在读取期间发生变化');
      }
      const buffer = Buffer.alloc(count);
      let copied = 0;
      while (copied < count) {
        const length = fs.readSync(fd, buffer, copied, count - copied, offset + BigInt(copied));
        if (length === 0) throw new Error(`文件短读：offset=${offset}, expected=${count}, actual=${copied}`);
        copied += length;
      }
      statistics.reads += 1;
      statistics.bytes += count;
      statistics.maxRead = Math.max(statistics.maxRead, count);
      statistics.peakRss = Math.max(statistics.peakRss, process.memoryUsage().rss);
      return new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
    },
    close() { if (!closed) { closed = true; fs.closeSync(fd); } },
  };
}
module.exports = {openFileSource};
