#!/usr/bin/env python3
"""同一环境、同一静态输入上比较正式 v0.7.0 与当前源码的 I/O/RSS/时间。"""
from pathlib import Path
import io
import json
import subprocess
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parents[1]
BASELINE='8a3a4c79ecd54c893604839f9136081289b8f21b'


def main():
    archive=subprocess.check_output(['git','archive','--format=zip',BASELINE],cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix='benchmark-v07-',dir=ROOT/'_build') as temporary:
        baseline=Path(temporary).resolve()
        assert baseline.is_relative_to((ROOT/'_build').resolve())
        with zipfile.ZipFile(io.BytesIO(archive)) as package:
            assert all((baseline/name).resolve().is_relative_to(baseline) for name in package.namelist())
            package.extractall(baseline)
        subprocess.run(['moon','build','--target','js','--deny-warn'],cwd=baseline,check=True)
        subprocess.run(['python','tools/benchmark_io.py','--compare-cli',str(baseline/'tools/inspect.cjs'),
                        '--output',str(ROOT/'_build/compatibility-benchmark.json')],cwd=ROOT,check=True)
    output=ROOT/'_build/compatibility-benchmark.json'
    evidence=json.loads(output.read_text(encoding='utf-8'))
    evidence['baseline_commit']=BASELINE
    evidence['comparison']='same_static_inputs_same_environment'
    output.write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Verified v0.7/current I/O equality on 12 fixed-scale same-input benchmarks')


if __name__=='__main__':
    main()
