#!/usr/bin/env python3
"""保护统一验收覆盖、失败传播、文档旧链接及版本核对逻辑。"""
from pathlib import Path
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
import os
import re
import tarfile
import tempfile
from urllib.parse import unquote
from verify import CHECKS, ROOT, run_checks
from verify_release import verify_assets, verify_ci


def anchor(title):
    title = re.sub(r'<[^>]*>', '', title).strip().lower().replace(' ', '-')
    return ''.join(character for character in title if character.isalnum() or character in '_-')


def anchors(text):
    result = set(re.findall(r'<a\s+id="([^"]+)"', text))
    seen = {}
    for title in re.findall(r'^#+ (.+)$', text, re.M):
        name = anchor(title)
        count = seen.get(name, 0)
        result.add(name if count == 0 else f'{name}-{count}')
        seen[name] = count+1
    return result


def verify_links():
    # 本地规划和申报草稿不属于公共使用文档。
    paths = [ROOT/'README.md', ROOT/'CONTRIBUTING.md', ROOT/'CHANGELOG.md']
    paths += [path for path in (ROOT/'docs').glob('*.md') if path.name not in {'roadmap.md', 'proposal.md'}]
    paths += list((ROOT/'adapters').rglob('README.md')) + list((ROOT/'examples').rglob('README.md'))
    for source in paths:
        text = source.read_text(encoding='utf-8')
        for link in re.findall(r'\]\(([^)]+)\)', text):
            target = unquote(link.split(' "', 1)[0].strip('<>'))
            if re.match(r'\w+://', target) or target.startswith(('mailto:', 'app:')):
                continue
            name, _, fragment = target.partition('#')
            path = (source.parent/name).resolve() if name else source
            assert path.exists(), f'文档链接缺失：{source.relative_to(ROOT)} → {link}'
            if fragment and path.suffix == '.md':
                assert fragment in anchors(path.read_text(encoding='utf-8')), f'文档锚点缺失：{source.relative_to(ROOT)} → {link}'
    for name, required in json.loads((ROOT/'fixtures/verification/legacy-anchors.json').read_text(encoding='utf-8')).items():
        assert set(required) <= anchors((ROOT/name).read_text(encoding='utf-8')), f'历史锚点丢失：{name}'


def runner_regressions():
    baseline = json.loads((ROOT/'fixtures/verification/v0.8.0.json').read_text(encoding='utf-8'))
    assert baseline['commit'] == 'cf7bdc5d9c9dd808640190d7f6904be4a21de8f9'
    old = [tuple(command) for command in baseline['checks']]
    assert len(old) == 34 and len(set(CHECKS)) == len(CHECKS)
    assert [check for check in CHECKS if check in old] == old, '原 34 项检查缺失或顺序变化'
    ci = (ROOT/'.github/workflows/ci.yml').read_text(encoding='utf-8')
    assert ci.count('run: python tools/verify.py') == 1
    assert 'toolchain: [pinned, latest]' in ci and 'playwright@1.62.1' in ci
    for command in old:
        assert ' '.join(command) not in ci, 'CI 又维护了第二份检查命令'
    with tempfile.TemporaryDirectory(prefix='runner-regression-', dir=ROOT/'_build') as temporary:
        directory = Path(temporary)
        # 子进程记录执行顺序；失败后的步骤不得执行，不能把失败当作完成。
        commands = [('python', '-c', "from pathlib import Path; Path('order').write_text('1', encoding='utf-8')"),
                    ('python', '-c', "from pathlib import Path; p=Path('order'); p.write_text(p.read_text(encoding='utf-8')+'2', encoding='utf-8'); raise SystemExit(7)"),
                    ('python', '-c', "raise SystemExit('不应执行')")]
        with redirect_stdout(io.StringIO()):
            assert run_checks(commands, directory, directory/'failed', dict(os.environ)) == 1
        results = json.loads((directory/'failed/results.json').read_text(encoding='utf-8'))
        assert [item['exit_code'] for item in results] == [0, 7]
        assert (directory/'order').read_text(encoding='utf-8') == '12'
        with redirect_stdout(io.StringIO()):
            assert run_checks(commands[:1], directory, directory/'passed', dict(os.environ)) == 0
            assert run_checks([('missing-moonsqlite-tool',)], directory, directory/'missing', dict(os.environ)) == 1


def release_regressions():
    commit = 'a'*40
    evidence = {'head_sha': commit, 'status': 'completed', 'conclusion': 'success',
                'html_url': 'https://github.com/prowk/MoonSQLiteFile/actions/runs/1',
                'jobs': [{'name': f'test ({name})', 'conclusion': 'success'} for name in ['pinned', 'latest']]}
    verify_ci(evidence, commit)
    for mutate in [lambda value: value.update(head_sha='b'*40), lambda value: value['jobs'].pop(),
                   lambda value: value.update(conclusion='failure')]:
        broken = copy.deepcopy(evidence); mutate(broken)
        try:
            verify_ci(broken, commit)
        except AssertionError:
            pass
        else:
            raise AssertionError('tag/CI 错配漏检')
    with tempfile.TemporaryDirectory(prefix='asset-regression-', dir=ROOT/'_build') as temporary:
        directory = Path(temporary)
        (directory/'moonsqlitefile-viewer-0.0.0.html').write_text('v0.0.0', encoding='utf-8')
        with tarfile.open(directory/'prowk-moonsqlitefile-async-0.0.0.tgz', 'w:gz') as archive:
            files = {'package.json': json.dumps({'name': '@prowk/moonsqlitefile-async', 'version': '0.0.0'}).encode('utf-8'),
                     'core.mjs': b'', 'index.mjs': b'', 'node.mjs': b'', 'LICENSE': b''}
            for name, data in files.items():
                item = tarfile.TarInfo('package/'+name); item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        checksums = ''.join(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n' for path in sorted(directory.iterdir()))
        (directory/'SHA256SUMS').write_text(checksums, encoding='utf-8')
        verify_assets(directory, '0.0.0')
        (directory/'moonsqlitefile-viewer-0.0.0.html').write_text('changed', encoding='utf-8')
        try:
            verify_assets(directory, '0.0.0')
        except AssertionError:
            pass
        else:
            raise AssertionError('附件内容变化漏检')


def main():
    runner_regressions()
    release_regressions()
    verify_links()
    print('Verified original 34-check coverage, runner failures, version evidence and documentation links/anchors')


if __name__ == '__main__':
    main()
