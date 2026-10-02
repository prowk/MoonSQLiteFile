#!/usr/bin/env python3
"""逐行比较 MoonBit CLI 与独立 SQLite 查询结果，验证类型、边界及错误行为。"""

from __future__ import annotations

import argparse
from contextlib import closing
import json
import math
from pathlib import Path
import random
import sqlite3
import subprocess
import tempfile

from generate_fixtures import collect_oracle


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "tools" / "inspect.cjs"


def run_cli(path: Path, *arguments: str, expect_error=False):
    result = subprocess.run(
        ["node", str(CLI), str(path), *map(str, arguments)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        timeout=60,
    )
    label = " ".join((path.name, *map(str, arguments)))
    if expect_error:
        assert result.returncode != 0, f"{label}: 预期失败，但退出状态为 0"
        assert result.stderr.strip(), f"{label}: 错误应写入 stderr"
        return None
    assert result.returncode == 0, f"{label}: {result.stderr.strip()}"
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"{label}: stdout 不是单个 JSON 文档: {result.stdout[:300]!r}") from error


def compare_value(actual, expected, label, primary_key_rowid=None):
    """按 SQLite 查询语义物化整数主键及 REAL affinity，不丢失整数精度。"""
    if primary_key_rowid is not None and actual["type"] == "null":
        actual = {"type": "integer", "value": str(primary_key_rowid)}
    if actual["type"] == "null":
        actual = {"type": "null"}
    elif actual["type"] == "blob":
        actual = {"type": "blob", "hex": actual["value"]}
    expected_type = expected["type"]
    if expected_type == "real" and actual["type"] in ("real", "integer"):
        left, right = float(actual["value"]), expected["value"]
        assert left == right or math.isclose(left, right, rel_tol=1e-15, abs_tol=0), f"{label}: {actual!r} != {expected!r}"
    else:
        assert actual == expected, f"{label}: {actual!r} != {expected!r}"


def integer_primary_key_column(db, table):
    quoted = '"' + table.replace('"', '""') + '"'
    columns = db.execute(f"PRAGMA table_info({quoted})").fetchall()
    primary_keys = [index for index, column in enumerate(columns) if column[5] != 0]
    if len(primary_keys) == 1 and columns[primary_keys[0]][2].upper() == "INTEGER":
        # 测试 schema 不使用 INTEGER PRIMARY KEY DESC，它不别名化行号。
        return primary_keys[0]
    return None


def compare_database(path: Path, expected):
    header = run_cli(path, "header")
    assert header["page_size"] == expected["page_size"], f"{path.name}: 页大小不一致"
    assert header["page_count"] == expected["page_count"], f"{path.name}: 页数不一致"
    assert header["usable_size"] == expected["page_size"], f"{path.name}: 可用空间不一致"
    assert header["freelist_pages"] == expected["freelist_count"], f"{path.name}: freelist 长度不一致"
    # 空数据库可使用磁盘编码 0，PRAGMA encoding 仍返回连接默认值 UTF-8。
    encoding_number = int.from_bytes(path.read_bytes()[56:60], "big")
    if expected["schema"]:
        assert encoding_number == {"UTF-8": 1, "UTF-16le": 2, "UTF-16be": 3}[expected["encoding"]]
    assert header["text_encoding"] == encoding_number, f"{path.name}: 编码不一致"
    schema = [
        {"type": entry["object_type"], "name": entry["name"], "table": entry["table_name"], "root_page": entry["root_page"], "sql": entry["sql"]}
        for entry in run_cli(path, "schema")
    ]
    assert schema == expected["schema"], f"{path.name}: schema 与 SQLite 不一致"
    freelist = run_cli(path, "freelist")
    assert len(freelist) == expected["freelist_count"], f"{path.name}: freelist 计数不一致"
    assert len(set(freelist)) == len(freelist), f"{path.name}: freelist 重复页"
    assert all(1 <= page <= expected["page_count"] for page in freelist), f"{path.name}: freelist 页越界"
    checked = 0
    with closing(sqlite3.connect(path)) as db:
        for name, table in expected["tables"].items():
            if table["without_rowid"]:
                run_cli(path, "rows", name, expect_error=True)
                continue
            rows = run_cli(path, "rows", name)
            assert len(rows) == len(table["rows"]), f"{path.name}/{name}: 行数不一致"
            primary_key = integer_primary_key_column(db, name)
            for index, (actual, reference) in enumerate(zip(rows, table["rows"])):
                label = f"{path.name}/{name}[{index}]"
                assert actual["rowid"] == reference["rowid"], f"{label}: 行号不一致"
                assert len(actual["values"]) == len(reference["values"]), f"{label}: 列数不一致"
                for column, (value, expected_value) in enumerate(zip(actual["values"], reference["values"])):
                    compare_value(value, expected_value, f"{label}/column-{column}", actual["rowid"] if column == primary_key else None)
                checked += 1
            assert run_cli(path, "rows", name, 0) == [], f"{path.name}/{name}: LIMIT 0 应为空"
            limited = run_cli(path, "rows", name, 2)
            assert limited == rows[:2], f"{path.name}/{name}: LIMIT 2 与前两行不一致"
            run_cli(path, "rows", name, -1, expect_error=True)
            run_cli(path, "rows", name, "not-a-number", expect_error=True)
        run_cli(path, "rows", "missing_table", expect_error=True)
    print(f"Verified {path.name}: {len(expected['schema'])} schema entries, {checked} rows, {len(freelist)} free pages")
    return checked


def random_database(path: Path, seed: int, page_size: int, encoding: str):
    """额外生成独立随机数据库，避免测试仅覆盖固定样本布局。"""
    rng = random.Random(seed)
    db = sqlite3.connect(path)
    db.execute(f"PRAGMA page_size={page_size}")
    db.execute(f"PRAGMA encoding='{encoding}'")
    db.execute("PRAGMA secure_delete=ON")
    db.execute("CREATE TABLE random_rows(id INTEGER PRIMARY KEY, n INTEGER, f REAL, text_value TEXT, payload BLOB, missing)")
    integer_boundaries = [-9223372036854775808, -140737488355329, -2147483649, -8388609, -32769, -129, -128, -1, 0, 1, 127, 128, 32767, 32768, 8388607, 8388608, 2147483647, 2147483648, 140737488355327, 140737488355328, 9223372036854775807]
    text_tokens = ["a", "中", "月", "🌙", "é", "Ω", "𐐷", "\x00"]
    rowids = [-9223372036854775808, -100, -1, 0, 1, 127, 128, 16383, 16384, 2147483648, 9223372036854775807]
    rowids += rng.sample(range(20000, 900000), 110)
    for index, rowid in enumerate(rowids):
        n = integer_boundaries[index % len(integer_boundaries)]
        f = [0.0, 1.0, -42.0, 1.25, -1e-100, 1e100, math.pi][index % 7]
        text = "".join(rng.choice(text_tokens) for _ in range(rng.choice([0, 1, 8, 31, 100, 800])))
        payload = rng.randbytes(rng.choice([0, 1, 8, 39, 300, 512, 2048]))
        db.execute("INSERT INTO random_rows VALUES (?, ?, ?, ?, ?, NULL)", (rowid, n, f, text, payload))
    # 长 schema SQL 会让 sqlite_schema 记录通过 overflow 页面保存。
    columns = ", ".join(f"column_{i:04d} TEXT" for i in range(90))
    db.execute(f"CREATE TABLE long_schema({columns})")
    db.execute("INSERT INTO long_schema(column_0000, column_0089) VALUES ('首列', '末列🌙')")
    db.execute("CREATE TABLE plain(n INTEGER, t TEXT)")
    db.execute("INSERT INTO plain(rowid, n, t) VALUES (-5, -129, '非别名主键')")
    db.execute("CREATE INDEX random_text_idx ON random_rows(text_value)")
    db.execute("CREATE TABLE keyed(k TEXT PRIMARY KEY, v) WITHOUT ROWID")
    db.execute("INSERT INTO keyed VALUES ('key', 1)")
    db.execute("CREATE TABLE removed(payload BLOB)")
    db.executemany("INSERT INTO removed VALUES (?)", [(b"a" * 4000,)] * 3)
    db.commit()
    db.execute("DROP TABLE removed")
    db.commit()
    try:
        return collect_oracle(db, path.read_bytes())
    finally:
        db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-only", action="store_true", help="仅检查仓库内数据库，跳过临时随机数据库")
    args = parser.parse_args()
    assert CLI.is_file(), "缺少 tools/inspect.cjs；请先生成 CLI"
    expected_path = ROOT / "fixtures" / "expected.json"
    expected = json.loads(expected_path.read_text(encoding="utf-8"))
    total = 0
    for name, oracle in expected.items():
        total += compare_database(ROOT / "fixtures" / f"{name}.sqlite", oracle)
    with tempfile.TemporaryDirectory(prefix="moonsqlite-oracle-") as temporary:
        directory = Path(temporary)
        if not args.fixtures_only:
            for index, (page_size, encoding) in enumerate([(512, "UTF-8"), (1024, "UTF-16le"), (4096, "UTF-16be")]):
                path = directory / f"random-{page_size}.sqlite"
                oracle = random_database(path, 20261001 + index, page_size, encoding)
                total += compare_database(path, oracle)
        run_cli(directory / "missing.sqlite", "header", expect_error=True)
        bad = directory / "not-sqlite.db"
        bad.write_bytes(b"not a SQLite file")
        run_cli(bad, "header", expect_error=True)
        source = ROOT / "fixtures" / "core.sqlite"
        run_cli(source, "unknown-command", expect_error=True)
        run_cli(source, "rows", expect_error=True)
        run_cli(source, "rows", "samples", "2.5", expect_error=True)
    print(f"All SQLite oracle checks passed: {total} rows")


if __name__ == "__main__":
    main()
