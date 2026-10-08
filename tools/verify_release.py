#!/usr/bin/env python3
"""只读核对源码版本及可选的既有 tag/附件/CI 证据，不创建或发布任何内容。"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def version_of(manifest):
    return re.search(r'^version = "([^"]+)"', manifest, re.M)[1]


def verify_assets(directory, version):
    names = {f'moonsqlitefile-viewer-{version}.html', f'prowk-moonsqlitefile-async-{version}.tgz'}
    entries = {}
    for line in (directory/'SHA256SUMS').read_text(encoding='utf-8').splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\]+)', line)
        assert match and match[2] not in entries, '校验清单格式或文件名重复'
        entries[match[2]] = match[1]
    assert entries.keys() == names, '附件缺失或清单包含未知附件'
    for name, checksum in entries.items():
        assert hashlib.sha256((directory/name).read_bytes()).hexdigest() == checksum, f'附件校验失败：{name}'
    html = (directory/f'moonsqlitefile-viewer-{version}.html').read_text(encoding='utf-8')
    assert f'v{version}' in html and '__VERSION__' not in html, 'HTML 版本未同步'
    with tarfile.open(directory/f'prowk-moonsqlitefile-async-{version}.tgz') as package:
        manifest = json.load(package.extractfile('package/package.json'))
        assert manifest['name'] == '@prowk/moonsqlitefile-async' and manifest['version'] == version
        assert {'package/core.mjs', 'package/index.mjs', 'package/node.mjs', 'package/LICENSE'} <= set(package.getnames())


def verify_ci(evidence, commit):
    assert evidence['head_sha'] == commit and evidence['status'] == 'completed' and evidence['conclusion'] == 'success'
    for channel in ['pinned', 'latest']:
        assert any(job['name'] == f'test ({channel})' and job['conclusion'] == 'success'
                   for job in evidence['jobs']), f'缺少成功的 {channel} CI'
    assert evidence['html_url'].startswith('https://github.com/prowk/MoonSQLiteFile/actions/runs/')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag', help='核对已经存在的本地发布 tag（不会创建 tag）')
    parser.add_argument('--assets', type=Path, help='核对已有附件目录及 SHA256SUMS')
    parser.add_argument('--ci-evidence', type=Path, help='核对已有 GitHub CI JSON，须同时指定 tag')
    args = parser.parse_args()
    if args.tag:
        assert re.fullmatch(r'v\d+\.\d+\.\d+', args.tag), 'tag 格式无效'
        version = args.tag[1:]
        commit = subprocess.check_output(['git', 'rev-parse', args.tag+'^{commit}'], cwd=ROOT, text=True).strip()
        def read(name):
            return subprocess.check_output(['git', 'show', f'{commit}:{name}'], cwd=ROOT).decode('utf-8')
    else:
        def read(name):
            return (ROOT/name).read_text(encoding='utf-8')
        version = version_of(read('moon.mod'))
    assert version_of(read('moon.mod')) == version
    assert json.loads(read('adapters/async/package.json'))['version'] == version
    assert re.search(r'^## '+re.escape(version)+r'(?:\s|$)', read('CHANGELOG.md'), re.M), '缺少对应 CHANGELOG'
    if not args.tag:
        built = json.loads((ROOT/'_build/async-adapter/package.json').read_text(encoding='utf-8'))
        assert built['version'] == version, '构建的异步包版本未同步'
        html = (ROOT/'_build/moonsqlitefile-viewer.html').read_text(encoding='utf-8')
        assert f'离线数据库检查器 · v{version}</span>' in html and '__VERSION__' not in html, '构建的 HTML 版本未同步'
    if args.assets:
        verify_assets(args.assets, version)
    if args.ci_evidence:
        assert args.tag, 'CI 证据必须对应既有 tag 的提交'
        verify_ci(json.loads(args.ci_evidence.read_text(encoding='utf-8')), commit)
    print(f'Verified version consistency: {version}; optional evidence checked only when supplied')


if __name__ == '__main__':
    main()
