#!/usr/bin/env python3
"""核实 v0.3.0 公开签名、结构字段、枚举分支及开放数据源契约仍可使用。"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def declarations(source):
    # 生成的接口每个声明独占一行或一个无嵌套大括号块；完整块比较保护构造与穷举匹配。
    return re.findall(r'^pub[^\n{]*(?:\{[^}]*\}[^\n]*|[^\n]*)', source, re.M)


def main():
    baseline = declarations((ROOT / 'tools/api-v0.3.0.mbti').read_text(encoding='utf-8'))
    current = set(declarations((ROOT / 'pkg.generated.mbti').read_text(encoding='utf-8')))
    removed = [declaration for declaration in baseline if declaration not in current]
    if removed:
        raise SystemExit('v0.3.0 公开声明发生不兼容变化，请评估迁移并调整版本契约：\n' + '\n'.join(removed))
    print(f'Verified public API compatibility against v0.3.0: {len(baseline)} declarations; additions allowed')


if __name__ == '__main__':
    main()
