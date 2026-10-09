#!/usr/bin/env python3
"""将已编译 MoonBit 检查器与界面打包成无外部依赖的单个 HTML。"""
import base64
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    source = ROOT / 'examples/offline-viewer'
    compiled = ROOT / '_build/js/debug/build/cmd/async-bridge/async-bridge.js'
    if not compiled.exists():
        raise SystemExit('请先执行 moon build --target js src/cmd/async-bridge')
    parser = compiled.read_text(encoding='utf-8')
    parser = re.sub(r'^//# sourceMappingURL=.*$', '', parser, flags=re.M)
    adapter = (ROOT / 'adapters/async/index.mjs').read_text(encoding='utf-8')
    adapter = re.sub(r'^import compiledCore.*$', '', adapter, flags=re.M)
    adapter = re.sub(r'^export ', '', adapter, flags=re.M)
    parser += '\nconst compiledCore = globalThis.moonsqlitefileAsyncBridge;\n' + adapter
    version = re.search(r'^version = "([^"]+)"', (ROOT / 'moon.mod').read_text(encoding='utf-8'), re.M)[1]
    # JSON 中转义小于号，避免编译代码中的字符串提前关闭 HTML script 元素。
    replacements = {
        '__PARSER_SOURCE__': json.dumps(parser, ensure_ascii=False).replace('<', '\\u003c'),
        '__DEMO_BYTES__': json.dumps(base64.b64encode((ROOT / 'fixtures/btree.sqlite').read_bytes()).decode('ascii')),
        '__WORKER_SOURCE__': json.dumps((source / 'worker.js').read_text(encoding='utf-8'), ensure_ascii=False).replace('<', '\\u003c'),
        '__VIEWER_JS__': (source / 'viewer.js').read_text(encoding='utf-8'),
        '__VIEWER_CSS__': (source / 'viewer.css').read_text(encoding='utf-8'),
        '__VERSION__': version,
    }
    document = (source / 'viewer.html').read_text(encoding='utf-8')
    for key, value in replacements.items():
        assert key in document
        document = document.replace(key, value)
    output = ROOT / '_build/moonsqlitefile-viewer.html'
    output.write_text(document, encoding='utf-8', newline='')
    print(f'Built offline viewer: {output.name}, {output.stat().st_size} bytes, v{version}')


if __name__ == '__main__':
    main()
