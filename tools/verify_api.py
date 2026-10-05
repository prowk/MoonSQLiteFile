#!/usr/bin/env python3
"""核实 历史版本公开签名、结构字段、枚举分支及开放数据源契约仍可使用。"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def declarations(source):
    # 生成的接口每个声明独占一行或一个无嵌套大括号块；完整块比较保护构造与穷举匹配。
    # moon info 的私有字段占位注释不属于公开声明；仍完整比较所有可见字段及类型。
    source = re.sub(r'^  // private fields\n', '', source, flags=re.M)
    return re.findall(r'^pub[^\n{]*(?:\{[^}]*\}[^\n]*|[^\n]*)', source, re.M)


def main():
    interface = ROOT / 'src/pkg.generated.mbti'
    expected = interface.read_text(encoding='utf-8')
    # 先从当前代码生成实际接口，不能用未同步的接口文件冒充兼容性证据。
    result = subprocess.run(['moon', 'info'], cwd=ROOT, text=True, encoding='utf-8', capture_output=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    actual = interface.read_text(encoding='utf-8')
    if actual != expected:
        raise SystemExit('公开接口文件未同步；已生成当前接口，请审查变化并重新验证')
    current = set(declarations(actual))
    for version in ['0.3.0', '0.4.0', '0.5.0', '0.6.0']:
        baseline = declarations((ROOT / f'tools/api-v{version}.mbti').read_text(encoding='utf-8'))
        assert baseline, f'公开 API 基线为空：{version}'
        removed = [declaration for declaration in baseline if declaration not in current]
        if removed:
            raise SystemExit(f'v{version} 公开声明发生不兼容变化，请评估迁移与版本契约：\n' + '\n'.join(removed))
        print(f'Verified public API compatibility against v{version}: {len(baseline)} declarations; additions allowed')



if __name__ == '__main__':
    main()
