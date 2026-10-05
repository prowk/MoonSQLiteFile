// 固定正式版本的导出名称、函数 arity 和公开原型；不把实现对象复制成测试替身。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const root = path.resolve(import.meta.dirname, '..');
export function declarations(mod) {
  return Object.fromEntries(Object.keys(mod).sort().map(name => {
    const value = mod[name];
    return [name, {type: typeof value, arity: typeof value === 'function' ? value.length : null,
      prototype: value?.prototype ? Object.getOwnPropertyNames(value.prototype).filter(name => name !== 'constructor').sort().map(key => {
        const item = Object.getOwnPropertyDescriptor(value.prototype, key);
        return {name: key, get: typeof item.get === 'function', set: typeof item.set === 'function',
          arity: typeof item.value === 'function' ? item.value.length : null};
      }) : []}];
  }));
}
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.filename)) {
  const baseline = JSON.parse(fs.readFileSync(path.join(root,'tools/async-api-v0.7.0.json'),'utf8'));
  assert.equal(baseline.commit,'8a3a4c79ecd54c893604839f9136081289b8f21b');
  for (const entry of ['index','node']) {
    const mod = await import(pathToFileURL(path.join(root,`_build/async-adapter/${entry}.mjs`)));
    assert.deepEqual(declarations(mod),baseline[entry]);
  }
  console.log('Verified released async exports, arities and public prototype compatibility');
}
