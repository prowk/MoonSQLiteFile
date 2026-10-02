#!/usr/bin/env python3
"""以 SQLite SQL 查询独立核验索引及 WITHOUT ROWID 的完整物理记录顺序。"""

from __future__ import annotations

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile

from generate_btree_fixtures import collect_btree_oracle, make_btree
from verify_oracle import run_cli


ROOT = Path(__file__).resolve().parents[1]


def compare_records(path, command, name, expected):
    rows = run_cli(path, command, name)
    assert len(rows) == len(expected["expected_rows"]), f"{path.name}/{name}: 记录数不一致（内部页记录也必须返回）"
    tree = expected["tree"]
    pages = {page["number"]: page for page in tree["pages"]}
    positions, interior = set(), 0
    for i, (actual, reference) in enumerate(zip(rows, expected["expected_rows"])):
        label = f"{path.name}/{name}[{i}]"
        assert {"rowid": actual["rowid"], "values": actual["values"]} == reference, f"{label}: {actual!r} != {reference!r}"
        page = pages.get(actual["page_number"])
        assert page is not None, f"{label}: 记录页不属于该树"
        assert actual["cell_offset"] in page["cell_offsets"], f"{label}: cell offset 不属于该页"
        position = (actual["page_number"], actual["cell_offset"])
        assert position not in positions, f"{label}: 同一 cell 被重复返回"
        positions.add(position)
        interior += page["kind"] == 2
    assert interior == tree["interior_records"], f"{path.name}/{name}: 内部页记录不完整"
    summary = run_cli(path, "scan", expected["root_page"])
    assert summary["records_read"] == len(rows) and summary["completion"] == "complete", f"{path.name}/{name}: 完成状态不一致"
    assert summary["pages_read"] >= len(tree["pages"]), f"{path.name}/{name}: 未统计完整 B-tree 页数"
    limited = run_cli(path, "scan", expected["root_page"], 2)
    assert limited["records_read"] == min(2, len(rows))
    assert limited["completion"] == ("record_limit" if len(rows) > 2 else "complete")
    for limit in (0, 1, 2, 7, 20, len(rows), len(rows) + 1):
        assert run_cli(path, command, name, limit) == rows[:limit], f"{path.name}/{name}: LIMIT {limit} 前缀不一致"
    for invalid in ("-1", "1.5", "not-a-number", "2147483648"):
        run_cli(path, command, name, invalid, expect_error=True)
    return len(rows)


def compare_database(path, expected):
    checked = 0
    for name, metadata in expected["tables"].items():
        checked += compare_records(path, "records", name, metadata)
        if metadata["without_rowid"]:
            run_cli(path, "rows", name, expect_error=True)
    for name, metadata in expected["indexes"].items():
        checked += compare_records(path, "index", name, metadata)
    for command in ("records", "index"):
        run_cli(path, command, "missing_object", expect_error=True)
        run_cli(path, command, expect_error=True)
    run_cli(path, "index", "indexed_rows", expect_error=True)
    run_cli(path, "records", "mixed_index", expect_error=True)
    print(f"Verified {path.name}: {checked} records including interior index cells")
    return checked


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-only", action="store_true", help="只核验已提交的 512 字节 UTF-8 样本")
    args = parser.parse_args()
    fixture = ROOT / "fixtures" / "btree.sqlite"
    recorded = json.loads((ROOT / "fixtures" / "btree_expected.json").read_text(encoding="utf-8"))
    with closing(sqlite3.connect(fixture.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        expected = collect_btree_oracle(db, fixture.read_bytes())
    assert expected == recorded, "btree_expected.json 与 SQLite 查询不一致"
    total = compare_database(fixture, expected)
    if not args.fixtures_only:
        with tempfile.TemporaryDirectory(prefix="moonsqlite-index-oracle-") as temporary:
            for size, encoding in ((1024, "UTF-16le"), (4096, "UTF-16be")):
                path = Path(temporary) / f"btree-{size}.sqlite"
                with closing(make_btree(path, size, encoding)) as db:
                    expected = collect_btree_oracle(db, path.read_bytes())
                total += compare_database(path, expected)
    print(f"All B-tree oracle checks passed: {total} records")


if __name__ == "__main__":
    main()
