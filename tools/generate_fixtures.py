#!/usr/bin/env python3
"""使用标准库 sqlite3 生成可重复的 SQLite 文件及类型化查询结果。"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "fixtures"


def value_json(value):
    """保留整数精度及 BLOB 类型，避免 JSON 的数值转换丢失信息。"""
    if value is None:
        return {"type": "null"}
    if isinstance(value, int):
        return {"type": "integer", "value": str(value)}
    if isinstance(value, float):
        return {"type": "real", "value": value}
    if isinstance(value, bytes):
        return {"type": "blob", "hex": value.hex()}
    return {"type": "text", "value": value}


def connect(path: Path, page_size=512, encoding="UTF-8"):
    connection = sqlite3.connect(path)
    connection.execute(f"PRAGMA page_size={page_size}")
    connection.execute(f"PRAGMA encoding='{encoding}'")
    connection.execute("PRAGMA auto_vacuum=NONE")
    connection.execute("PRAGMA journal_mode=DELETE")
    connection.execute("PRAGMA secure_delete=ON")
    return connection


def make_core(path: Path):
    db = connect(path)
    db.execute("CREATE TABLE samples(id INTEGER PRIMARY KEY, label TEXT, n INTEGER, x REAL, data BLOB, missing)")
    db.executemany(
        "INSERT INTO samples VALUES (?, ?, ?, ?, ?, ?)",
        [
            (-7, "中文 SQLite 🌙", -9223372036854775808, -1.25, bytes.fromhex("00ff104180"), None),
            (0, "", 0, 0.0, b"", None),
            (1, "hello", 1, 3.141592653589793, b"hello", None),
            (127, "varint 127", 127, 1e100, b"\x7f", None),
            (128, "varint 128", 128, 1e-100, b"\x80", None),
            (16384, "大整数", 9223372036854775807, 42.0, b"\xff", None),
        ],
    )
    db.execute("CREATE TABLE branches(id INTEGER PRIMARY KEY, label TEXT)")
    db.executemany(
        "INSERT INTO branches VALUES (?, ?)",
        ((i, f"row-{i:04d}-" + "x" * 33) for i in range(1, 681)),
    )
    db.execute("CREATE TABLE overflow_data(id INTEGER PRIMARY KEY, content TEXT, payload BLOB)")
    db.execute(
        "INSERT INTO overflow_data VALUES (?, ?, ?)",
        (1, "月亮🌙" * 400, bytes(range(256)) * 8),
    )
    db.execute("CREATE TABLE keyed(name TEXT PRIMARY KEY, value INTEGER) WITHOUT ROWID")
    db.executemany("INSERT INTO keyed VALUES (?, ?)", [("alpha", 1), ("中文", 2), ("🌙", 3)])
    db.execute("CREATE INDEX samples_label ON samples(label)")
    db.execute("CREATE TABLE deleted(payload BLOB)")
    db.executemany("INSERT INTO deleted VALUES (?)", [(b"d" * 700,)] * 4)
    db.commit()
    db.execute("DROP TABLE deleted")
    db.commit()
    return db


def make_encoding(path: Path, encoding: str):
    db = connect(path, encoding=encoding)
    db.execute("CREATE TABLE words(id INTEGER PRIMARY KEY, text_value TEXT)")
    db.executemany("INSERT INTO words VALUES (?, ?)", [(1, "中文🌙"), (2, "AéΩ𐐷"), (3, "")])
    db.commit()
    return db


def make_large_page(path: Path):
    db = connect(path, page_size=65536)
    db.execute("CREATE TABLE large_page(id INTEGER PRIMARY KEY, message TEXT)")
    db.execute("INSERT INTO large_page VALUES (1, '65536-byte page 🌙')")
    db.commit()
    return db


def make_empty(path: Path):
    db = connect(path)
    db.execute("VACUUM")
    return db


def rowid_tree_depth(data: bytes, page_size: int, page_number: int):
    """独立检查生成数据确实包含三层行号树；此处不解析记录内容。"""
    page = data[(page_number - 1) * page_size : page_number * page_size]
    header = 100 if page_number == 1 else 0
    if page[header] == 13:
        return 1
    assert page[header] == 5
    count = int.from_bytes(page[header + 3 : header + 5], "big")
    children = [int.from_bytes(page[header + 8 : header + 12], "big")]
    for index in range(count):
        start = header + 12 + 2 * index
        offset = int.from_bytes(page[start : start + 2], "big")
        children.append(int.from_bytes(page[offset : offset + 4], "big"))
    return 1 + max(rowid_tree_depth(data, page_size, child) for child in children)


def collect_oracle(db, data: bytes):
    schema = [
        {"type": kind, "name": name, "table": table, "root_page": root, "sql": sql}
        for kind, name, table, root, sql in db.execute(
            "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_schema ORDER BY rowid"
        )
    ]
    tables = {}
    for entry in schema:
        if entry["type"] != "table":
            continue
        name = entry["name"]
        quoted = '"' + name.replace('"', '""') + '"'
        without_rowid = "WITHOUT ROWID" in entry["sql"].upper()
        if without_rowid:
            columns = [item[1] for item in db.execute(f"PRAGMA table_info({quoted})")]
            rows = [{"values": [value_json(v) for v in row]} for row in db.execute(f"SELECT * FROM {quoted} ORDER BY 1")]
        else:
            cursor = db.execute(f"SELECT rowid, * FROM {quoted} ORDER BY rowid")
            columns = [column[0] for column in cursor.description][1:]
            rows = [{"rowid": str(row[0]), "values": [value_json(v) for v in row[1:]]} for row in cursor]
        tables[name] = {"columns": columns, "without_rowid": without_rowid, "rows": rows}
        if not without_rowid:
            tables[name]["rowid_tree_depth"] = rowid_tree_depth(data, db.execute("PRAGMA page_size").fetchone()[0], entry["root_page"])
    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "size_bytes": len(data),
        "page_size": db.execute("PRAGMA page_size").fetchone()[0],
        "page_count": db.execute("PRAGMA page_count").fetchone()[0],
        "freelist_count": db.execute("PRAGMA freelist_count").fetchone()[0],
        "encoding": db.execute("PRAGMA encoding").fetchone()[0],
        "integrity_check": db.execute("PRAGMA integrity_check").fetchone()[0],
        "schema": schema,
        "tables": tables,
    }


def moonbit_source(databases):
    lines = ["// 由 tools/generate_fixtures.py 自动生成；sqlite3 仅用于生成测试数据。", ""]
    for name, data in databases.items():
        lines.extend(["///|", f"fn fixture_{name}() -> Bytes {{", "  let chunks : Array[Bytes] = ["])
        for start in range(0, len(data), 512):
            literal = "".join(f"\\x{value:02x}" for value in data[start : start + 512])
            lines.append(f'    b"{literal}",')
        lines.extend([
            "  ]",
            f"  let output : FixedArray[Byte] = FixedArray::make({len(data)}, 0)",
            "  let mut offset = 0",
            "  for chunk in chunks {",
            "    for i = 0; i < chunk.length(); i = i + 1 {",
            "      output[offset + i] = chunk[i]",
            "    }",
            "    offset = offset + chunk.length()",
            "  }",
            "  Bytes::from_array(output[:])",
            "}", "",
        ])
    return "\n".join(lines)


def generate():
    databases, expected = {}, {}
    makers = {
        "core": make_core,
        "utf16le": lambda path: make_encoding(path, "UTF-16le"),
        "utf16be": lambda path: make_encoding(path, "UTF-16be"),
        "page65536": make_large_page,
        "empty": make_empty,
    }
    with tempfile.TemporaryDirectory(prefix="moonsqlite-fixtures-") as temporary:
        for name, make in makers.items():
            path = Path(temporary) / f"{name}.sqlite"
            db = make(path)
            try:
                data = path.read_bytes()
                expected[name] = collect_oracle(db, data)
            finally:
                db.close()
            databases[name] = data
    assert sum(map(len, databases.values())) < 200_000, "二进制测试数据总量应小于 200KB"
    assert all(item["integrity_check"] == "ok" for item in expected.values())
    assert expected["core"]["freelist_count"] > 0
    assert expected["core"]["tables"]["branches"]["rowid_tree_depth"] >= 3
    return databases, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="检查数据库及 oracle 逐字节一致，并核对已嵌入的测试字节")
    args = parser.parse_args()
    databases, expected = generate()
    artifacts = {FIXTURES / f"{name}.sqlite": data for name, data in databases.items()}
    artifacts[FIXTURES / "expected.json"] = (json.dumps(expected, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    artifacts[ROOT / "fixture_bytes_wbtest.mbt"] = moonbit_source(databases).encode("utf-8")
    if args.check:
        source_path = ROOT / "fixture_bytes_wbtest.mbt"
        mismatches = [str(path.relative_to(ROOT)) for path, data in artifacts.items() if path != source_path and (not path.exists() or path.read_bytes() != data)]
        # MoonBit 格式化只影响布局，检查嵌入数据本身而非源码空白。
        source = source_path.read_text(encoding="utf-8") if source_path.exists() else ""
        functions = re.findall(r"fn fixture_(\w+)\(\) -> Bytes \{(.*?)(?=\n///\||\Z)", source, re.S)
        embedded = {}
        for name, body in functions:
            literals = re.findall(r'b"((?:\\x[0-9a-fA-F]{2})*)"', body)
            data = bytes.fromhex("".join(literals).replace("\\x", ""))
            size = re.search(r"FixedArray::make\((\d+),\s*0\)", body)
            if size is None or int(size[1]) != len(data):
                mismatches.append(f"fixture_bytes_wbtest.mbt:fixture_{name} 大小")
            embedded[name] = data
        if embedded != databases:
            mismatches.append("fixture_bytes_wbtest.mbt 嵌入字节")
        if mismatches:
            raise SystemExit("生成结果不一致: " + ", ".join(mismatches))
    else:
        FIXTURES.mkdir(parents=True, exist_ok=True)
        for path, data in artifacts.items():
            path.write_bytes(data)
    print(f"{'Verified' if args.check else 'Generated'} {len(databases)} fixtures; {sum(map(len, databases.values()))} binary bytes; SQLite {sqlite3.sqlite_version}")


if __name__ == "__main__":
    main()
