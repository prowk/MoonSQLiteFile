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
export function compatible(actual, baseline) {
  for (const [name, expected] of Object.entries(baseline)) {
    const found = actual[name];
    assert(found, `历史导出被删除：${name}`);
    assert.equal(found.type, expected.type, `${name} 类型变化`);
    assert.equal(found.arity, expected.arity, `${name} arity 变化`);
    for (const member of expected.prototype) {
      assert.deepEqual(found.prototype.find(item => item.name === member.name), member,
        `${name}.${member.name} 原型契约变化`);
    }
  }
}
function regressions() {
  const old = {Database: {type: 'function', arity: 4, prototype: [{name: 'close', get: false, set: false, arity: 0}]}};
  const added = structuredClone(old);
  added.NewExport = {type: 'function', arity: 0, prototype: []};
  added.Database.prototype.push({name: 'newMethod', get: false, set: false, arity: 1});
  compatible(added, old);
  for (const mutate of [value => delete value.Database, value => value.Database.arity++,
    value => value.Database.type = 'object', value => value.Database.prototype.pop(),
    value => value.Database.prototype[0].arity++, value => value.Database.prototype[0].get = true]) {
    const broken = structuredClone(old); mutate(broken);
    assert.throws(() => compatible(broken, old), assert.AssertionError);
  }
}
if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.filename)) {
  regressions();
  for (const [version, commit] of [['0.7.0','8a3a4c79ecd54c893604839f9136081289b8f21b'],
    ['0.8.0','cf7bdc5d9c9dd808640190d7f6904be4a21de8f9']]) {
    const baseline = JSON.parse(fs.readFileSync(path.join(root,`tools/async-api-v${version}.json`),'utf8'));
    assert.equal(baseline.commit, commit);
    for (const entry of ['index','node']) {
      const mod = await import(pathToFileURL(path.join(root,`_build/async-adapter/${entry}.mjs`)));
      compatible(declarations(mod), baseline[entry]);
    }
  }
  console.log('Verified released async exports, arities and public prototype compatibility');
}
