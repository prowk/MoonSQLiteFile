'use strict';
// 构造按需生成的有效 WAL，独立累计 checksum，不在磁盘或内存保存 2 GiB 日志。
const fs = require('node:fs'), assert = require('node:assert/strict');
const size = 65536, count = 32769, frameSize = size + 24;
const payload = Buffer.alloc(size);
payload.write('SQLite format 3\0', 'binary'); payload.writeUInt16BE(1,16);
payload[18]=2;payload[19]=2;payload[21]=64;payload[22]=32;payload[23]=32;
payload.writeUInt32BE(1,24);payload.writeUInt32BE(1,28);payload.writeUInt32BE(4,44);payload.writeUInt32BE(1,56);payload.writeUInt32BE(1,92);payload[100]=13;
const header = Buffer.alloc(32);header.writeUInt32BE(0x377f0683,0);header.writeUInt32BE(3007000,4);header.writeUInt32BE(size,8);header.writeUInt32BE(123,16);header.writeUInt32BE(456,20);
function checksum(data,a=0,b=0){for(let i=0;i<data.length;i+=8){a=(a+data.readUInt32BE(i)+b)>>>0;b=(b+data.readUInt32BE(i+4)+a)>>>0;}return [a,b];}
function multiply(a,b){return [0,1,2,3].map(i=>(Math.imul(a[(i>>1)*2],b[i%2])+Math.imul(a[(i>>1)*2+1],b[2+i%2]))>>>0);}
let power=[1,1,1,2], matrix=[1,0,0,1], n=size/8;
while(n){if(n&1)matrix=multiply(matrix,power);power=multiply(power,power);n>>>=1;}
const constant=checksum(payload), initial=checksum(header.subarray(0,24));header.writeUInt32BE(initial[0],24);header.writeUInt32BE(initial[1],28);
let state=initial,index=0,maxOffset=0n,readCalls=0,lateReads=0;
function read(offset,length){
  readCalls++;if(offset>maxOffset)maxOffset=offset;
  if(offset===0n&&length===32)return header;
  const lastPayload=32n+BigInt(count-1)*BigInt(frameSize)+24n;
  if(offset===lastPayload&&length===100){lateReads++;return payload.subarray(0,100);}
  assert.equal(length,frameSize);assert.equal(offset,32n+BigInt(index)*BigInt(frameSize));index++;
  const frame=Buffer.alloc(frameSize);frame.writeUInt32BE(1,0);frame.writeUInt32BE(1,4);frame.writeUInt32BE(123,8);frame.writeUInt32BE(456,12);payload.copy(frame,24);
  const head=checksum(frame.subarray(0,8),...state);
  state=[(Math.imul(matrix[0],head[0])+Math.imul(matrix[1],head[1])+constant[0])>>>0,(Math.imul(matrix[2],head[0])+Math.imul(matrix[3],head[1])+constant[1])>>>0];
  if(index===1||index===count)assert.deepEqual(state,checksum(payload,...head));
  frame.writeUInt32BE(state[0],16);frame.writeUInt32BE(state[1],20);return frame;
}
let result,error,exitCode=0;const start=Date.now();
globalThis.moonsqlitefileHost={args:['virtual.db','wal-info'],bytes:new Uint8Array(0),walSize:32n+BigInt(count)*BigInt(frameSize),readWalRange:read,output:t=>result=JSON.parse(t),error:t=>error=t,exitCode:c=>exitCode=c};
require('../_build/js/debug/build/cmd/inspect/inspect.js');
assert.equal(error,undefined);assert.equal(exitCode,0);assert.equal(result.wal.committed_frames,count);assert.equal(result.snapshot.page_count,1);assert(maxOffset>2147483647n);assert.equal(lateReads,1);
const report={frames:count,size:String(32n+BigInt(count)*BigInt(frameSize)),max_offset:String(maxOffset),reads:readCalls,late_reads:lateReads,peak_rss_bytes:process.resourceUsage().maxRSS*1024,seconds:(Date.now()-start)/1000};
fs.writeFileSync('_build/wide-wal.json',JSON.stringify(report,null,2),'utf8');console.log(JSON.stringify(report));
