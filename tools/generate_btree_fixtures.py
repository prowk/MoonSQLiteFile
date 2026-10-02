#!/usr/bin/env python3
"""生成索引与 WITHOUT ROWID 样本，并由 SQLite 查询取得独立记录 oracle。"""

from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import tempfile

from generate_fixtures import moonbit_source


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "fixtures" / "btree.sqlite"
EXPECTED = ROOT / "fixtures" / "btree_expected.json"
EMBEDDED = ROOT / "btree_fixture_wbtest.mbt"


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def value_json(value):
    if value is None:
        return {"type": "null", "value": None}
    if isinstance(value, int):
        return {"type": "integer", "value": str(value)}
    if isinstance(value, float):
        return {"type": "real", "value": value}
    if isinstance(value, bytes):
        return {"type": "blob", "value": value.hex()}
    return {"type": "text", "value": value}


def make_btree(path, page_size=512, encoding="UTF-8"):
    db = sqlite3.connect(path)
    db.execute(f"PRAGMA page_size={page_size}")
    db.execute(f"PRAGMA encoding='{encoding}'")
    db.execute("PRAGMA journal_mode=DELETE")
    db.execute("PRAGMA auto_vacuum=NONE")
    db.execute("CREATE TABLE indexed_rows(id INTEGER PRIMARY KEY, mixed, name TEXT, trimmed TEXT, extra BLOB)")
    mixed = [None, -9223372036854775808, -129, 0, 1, 9223372036854775807,
             -1.25, 0.125, 1e100, "", "a", "中文🌙", b"", b"\x00\xff"]
    for i in range(600):
        db.execute("INSERT INTO indexed_rows VALUES (?, ?, ?, ?, ?)",
                   (i - 130, mixed[i % len(mixed)], ("ALPHA" if i % 2 else "alpha") + f"-{i % 17:02d}",
                    f"trim-{i % 13:02d}" + " " * (i % 3), bytes([i % 256]) * 5))
    db.execute("CREATE INDEX mixed_index ON indexed_rows(mixed ASC, name COLLATE NOCASE DESC, trimmed COLLATE RTRIM ASC)")
    db.execute("CREATE TABLE keyed(payload TEXT, tag TEXT, k2 INTEGER, k1 TEXT, bits BLOB, PRIMARY KEY(k1 COLLATE NOCASE DESC, k2 ASC)) WITHOUT ROWID")
    for i in range(96):
        db.execute("INSERT INTO keyed VALUES (?, ?, ?, ?, ?)",
                   (f"value-{i:03d}-" + "月" * (i % 5), f"tag-{i % 7}" + " " * (i % 3),
                    i // 12, ("GROUP" if i % 2 else "group") + f"-{i % 12:02d}", bytes([i]) * (i % 8)))
    db.execute("CREATE INDEX keyed_tag ON keyed(tag COLLATE RTRIM DESC, payload COLLATE NOCASE ASC)")
    db.execute("CREATE TABLE long_keys(id INTEGER PRIMARY KEY, key TEXT)")
    for i in range(24):
        db.execute("INSERT INTO long_keys VALUES (?, ?)", (i + 1, f"{i:03d}-" + "月🌙abc" * 65))
    db.execute("CREATE INDEX long_key_index ON long_keys(key DESC)")
    db.execute("CREATE TABLE unique_keys(id INTEGER PRIMARY KEY, value UNIQUE)")
    for i, value in enumerate([None, None, None, -5, 0, 9, 1.25, "", "a", "A", "中文", b"", b"\x00"]):
        db.execute("INSERT INTO unique_keys VALUES (?, ?)", (i + 1, value))
    db.execute("CREATE TABLE plain(id INTEGER PRIMARY KEY, note TEXT)")
    db.executemany("INSERT INTO plain VALUES (?, ?)", [(-7, "负行号"), (0, "零行号"), (9223372036854775807, "最大行号")])
    db.commit()
    return db


def tree_shape(data, page_size, root):
    """仅读取页头与子页指针，确认样本含实际内部页记录，不复制记录解码实现。"""
    pages, interior_cells = [], 0
    stack = [(root, 1)]
    depth = 0
    while stack:
        number, level = stack.pop()
        assert number not in [item["number"] for item in pages], "样本 B-tree 存在重复子页"
        page = data[(number - 1) * page_size : number * page_size]
        header = 100 if number == 1 else 0
        kind = page[header]
        count = int.from_bytes(page[header + 3 : header + 5], "big")
        assert kind in (2, 5, 10, 13)
        offsets = [int.from_bytes(page[header + (12 if kind in (2, 5) else 8) + 2 * i:
                                             header + (12 if kind in (2, 5) else 8) + 2 * i + 2], "big") for i in range(count)]
        pages.append({"number": number, "kind": kind, "cell_offsets": offsets})
        depth = max(depth, level)
        if kind in (2, 5):
            if kind == 2:
                interior_cells += count
            children = [int.from_bytes(page[offset:offset + 4], "big") for offset in offsets]
            children.append(int.from_bytes(page[header + 8:header + 12], "big"))
            stack.extend((child, level + 1) for child in children)
    return {"depth": depth, "interior_records": interior_cells, "pages": sorted(pages, key=lambda item: item["number"])}


def storage_layout(db, name):
    return [{"name": item[2] if item[1] >= 0 else "rowid", "cid": item[1],
             "descending": bool(item[3]), "collation": item[4], "key": bool(item[5])}
            for item in db.execute(f"PRAGMA index_xinfo({quote(name)})")]


def collect_btree_oracle(db, data):
    page_size = db.execute("PRAGMA page_size").fetchone()[0]
    tables, indexes = {}, {}
    schema = db.execute("SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY rowid").fetchall()
    for kind, name, table, root, sql in schema:
        if kind == "table":
            columns = db.execute(f"PRAGMA table_info({quote(name)})").fetchall()
            without_rowid = "WITHOUT ROWID" in sql.upper()
            if without_rowid:
                layout = storage_layout(db, name)
                selected = [quote(column["name"]) for column in layout]
                ordering = [f'{quote(column["name"])} COLLATE {quote(column["collation"])} ' + ("DESC" if column["descending"] else "ASC")
                            for column in layout if column["key"]]
                query = f"SELECT {', '.join(selected)} FROM {quote(name)} ORDER BY {', '.join(ordering)}"
                expected_rows = [{"rowid": None, "values": [value_json(value) for value in row]} for row in db.execute(query)]
                storage_columns = [column["name"] for column in layout]
            else:
                # INTEGER PRIMARY KEY 的存储字段为 NULL；由 SQL 显式投影得到原始 record 语义。
                selected = ["NULL" if column[2].upper() == "INTEGER" and column[5] == 1 else quote(column[1]) for column in columns]
                query = f"SELECT rowid, {', '.join(selected)} FROM {quote(name)} ORDER BY rowid"
                expected_rows = [{"rowid": str(row[0]), "values": [value_json(value) for value in row[1:]]} for row in db.execute(query)]
                storage_columns = [column[1] for column in columns]
            tables[name] = {"root_page": root, "without_rowid": without_rowid, "storage_columns": storage_columns,
                            "query": query, "expected_rows": expected_rows, "tree": tree_shape(data, page_size, root)}
        elif kind == "index":
            layout = storage_layout(db, name)
            selected = ["rowid" if column["cid"] == -1 else quote(column["name"]) for column in layout]
            # 附加 rowid 或复合主键也是平局排序的一部分；排序方向及 collation 来自 SQLite 自身。
            ordering = [f'{expression} COLLATE {quote(column["collation"])} ' + ("DESC" if column["descending"] else "ASC")
                        for column, expression in zip(layout, selected)]
            query = f"SELECT {', '.join(selected)} FROM {quote(table)} INDEXED BY {quote(name)} ORDER BY {', '.join(ordering)}"
            rows = [{"rowid": None, "values": [value_json(value) for value in row]} for row in db.execute(query)]
            indexes[name] = {"table": table, "root_page": root, "definition": sql, "storage_columns": layout,
                             "query": query, "expected_rows": rows, "tree": tree_shape(data, page_size, root)}
    return {"sha256": hashlib.sha256(data).hexdigest(), "size_bytes": len(data), "page_size": page_size,
            "encoding": db.execute("PRAGMA encoding").fetchone()[0],
            "integrity_check": db.execute("PRAGMA integrity_check").fetchone()[0], "tables": tables, "indexes": indexes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="核验已提交样本、SQLite 查询结果及嵌入字节")
    args = parser.parse_args()
    if args.check:
        data = FIXTURE.read_bytes()
        with closing(sqlite3.connect(FIXTURE.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            expected = collect_btree_oracle(db, data)
        assert json.loads(EXPECTED.read_text(encoding="utf-8")) == expected, "btree_expected.json 与真实 SQLite 查询结果不一致"
        source = EMBEDDED.read_text(encoding="utf-8")
        literals = re.findall(r'b"((?:\\x[0-9a-fA-F]{2})*)"', source)
        assert bytes.fromhex("".join(literals).replace("\\x", "")) == data, "btree_fixture_wbtest.mbt 嵌入字节不一致"
        size = re.search(r"FixedArray::make\((\d+),\s*0\)", source)
        assert size and int(size[1]) == len(data), "嵌入数组大小不一致"
    else:
        with tempfile.TemporaryDirectory(prefix="moonsqlite-btree-") as temporary:
            path = Path(temporary) / "btree.sqlite"
            with closing(make_btree(path)) as db:
                data = path.read_bytes()
                expected = collect_btree_oracle(db, data)
        assert len(data) < 200_000, "索引样本应小于 200KB"
        FIXTURE.write_bytes(data)
        EXPECTED.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        source = moonbit_source({"btree": data}).replace("tools/generate_fixtures.py", "tools/generate_btree_fixtures.py")
        EMBEDDED.write_text(source, encoding="utf-8")
    assert expected["integrity_check"] == "ok"
    assert expected["indexes"]["mixed_index"]["tree"]["depth"] >= 3
    assert expected["indexes"]["mixed_index"]["tree"]["interior_records"] > 0
    assert expected["tables"]["keyed"]["tree"]["interior_records"] > 0
    print(f"{'Verified' if args.check else 'Generated'} B-tree fixture: {len(data)} bytes, {len(expected['tables'])} tables, {len(expected['indexes'])} indexes")


if __name__ == "__main__":
    main()
