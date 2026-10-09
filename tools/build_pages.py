#!/usr/bin/env python3
"""从同一单文件查看器生成仓库子路径可用的 Pages 目录，不执行部署。"""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]


def main():
    version = re.search(r'^version = "([^"]+)"', (ROOT/'moon.mod').read_text(encoding='utf-8'), re.M)[1]
    source = ROOT/'_build/moonsqlitefile-viewer.html'
    document = source.read_text(encoding='utf-8')
    assert f'v{version}' in document
    output = ROOT/'_build/pages'
    output.mkdir(exist_ok=True)
    name = f'moonsqlitefile-viewer-{version}.html'
    # 下载文件与单文件构建逐字节相同；首页仅增加同目录下载入口。
    (output/name).write_bytes(source.read_bytes())
    link = f'<p><a download href="./{name}">下载本页对应的单文件 HTML（v{version}）</a> · 当前源码版本尚未发布包</p>'
    (output/'index.html').write_text(document.replace('<footer>', link+'<footer>'), encoding='utf-8')
    (output/'.nojekyll').write_text('', encoding='utf-8')
    assert (output/name).read_bytes() == source.read_bytes()
    # 内嵌解析器与 Worker 必须完全一致，不允许演示维护另一套解析逻辑。
    index = (output/'index.html').read_text(encoding='utf-8')
    for identifier in ['parser-source', 'worker-source', 'demo-bytes']:
        pattern = f'<script id="{identifier}" type="application/json">(.*?)</script>'
        assert re.search(pattern, index, re.S)[1] == re.search(pattern, document, re.S)[1]
    (output/'manifest.json').write_text(json.dumps({'version': version, 'distribution': 'unpublished-source',
        'download': name, 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}, indent=2)+'\n', encoding='utf-8')
    print(f'Built Pages artifact and identical HTML download: {output}, v{version}; not deployed')


if __name__ == '__main__':
    main()
