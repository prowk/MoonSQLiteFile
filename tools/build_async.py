#!/usr/bin/env python3
"""打包独立异步 JS 适配器，内嵌同一 MoonBit 核心桥接，不引入运行时依赖。"""
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / '_build/js/debug/build/cmd/async-bridge/async-bridge.js'
    if not source.exists():
        raise SystemExit('请先执行 moon build --target js src/cmd/async-bridge')
    output = ROOT / '_build/async-adapter'
    output.mkdir(exist_ok=True)
    for path in (ROOT / 'adapters/async').iterdir():
        if path.is_file() and path.name in ('package.json', 'index.mjs', 'node.mjs', 'index.d.ts', 'node.d.ts', 'README.md', 'example-node.mjs', 'example-browser.mjs'):
            shutil.copyfile(path, output / path.name)
    shutil.copyfile(ROOT / 'LICENSE', output / 'LICENSE')
    core = re.sub(r'^//# sourceMappingURL=.*$', '', source.read_text(encoding='utf-8'), flags=re.M)
    (output / 'core.mjs').write_text(core + '\nexport default globalThis.moonsqlitefileAsyncBridge;\n', encoding='utf-8')
    print(f'Built asynchronous adapter: {output}, core {len(core.encode("utf-8"))} bytes')


if __name__ == '__main__':
    main()
