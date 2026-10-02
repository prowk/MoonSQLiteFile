#!/usr/bin/env python3
"""以 SQLite 元数据、可用时的 dbstat 和受控损坏样本验证全局检查报告。"""
import json
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
from generate_btree_fixtures import make_btree

ROOT = Path(__file__).resolve().parents[1]


def inspect(path, exit_code=0):
    result = subprocess.run(["node", str(ROOT / "tools/inspect.cjs"), str(path), "inspect"],
                            cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == exit_code, (path.name, result.returncode, result.stderr, result.stdout[:500])
    assert result.stderr == "", result.stderr
    return json.loads(result.stdout)


def verify(path):
    report = inspect(path)
    assert report["status"] == "complete" and report["ownership_complete"]
    assert report["ptrmap_checked"] and not report["diagnostics_truncated"]
    assert report["issues"] == [] and report["unclaimed_pages"] == []
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
        count = db.execute("PRAGMA page_count").fetchone()[0]
        free_count = db.execute("PRAGMA freelist_count").fetchone()[0]
        roots = {name: root for name, root in db.execute("SELECT name,rootpage FROM sqlite_schema WHERE rootpage>0")}
        roots["sqlite_schema"] = 1
        pages = {page["page_number"]: page for page in report["pages"]}
        assert sorted(pages) == list(range(1, count + 1)) and len(report["pages"]) == count
        assert report["roots_inspected"] == len(roots)
        assert sum(page["kind"].startswith("freelist_") for page in pages.values()) == free_count
        for page in pages.values():
            kind = page["kind"]
            if kind == "btree_root":
                assert page["page_number"] == roots[page["object_name"]] == page["root_page"]
                assert page["parent_page"] is None
            elif kind in {"btree_child", "overflow_first", "overflow_continuation"}:
                parent = pages[page["parent_page"]]
                assert parent["object_name"] == page["object_name"] and parent["root_page"] == page["root_page"]
                expected = {"overflow_first", "overflow_continuation"} if kind == "overflow_continuation" else {"btree_root", "btree_child"}
                assert parent["kind"] in expected
            else:
                assert page["root_page"] is None and page["object_name"] is None
        # 部分 Windows SQLite 构建没有 dbstat；Linux CI 可追加独立物理页对照。
        try:
            statistics = db.execute("SELECT name,pageno,pagetype,path FROM dbstat").fetchall()
        except sqlite3.OperationalError as error:
            if "no such table: dbstat" not in str(error):
                raise
            statistics = None
        if statistics is not None:
            active = {number for _, number, _, _ in statistics}
            assert active == {number for number, page in pages.items() if page["kind"] in {"btree_root", "btree_child", "overflow_first", "overflow_continuation"}}
            for name, number, kind, tree_path in statistics:
                owner = pages[number]
                assert owner["object_name"] == name
                expected = ("overflow_first" if tree_path.endswith("+000000") else "overflow_continuation") if kind == "overflow" else ("btree_root" if number == roots[name] else "btree_child")
                assert owner["kind"] == expected
        print(f"Verified ownership {path.name}: {count} pages, {len(roots)} roots, dbstat={'yes' if statistics is not None else 'unavailable'}")
        return count


def main():
    total = sum(verify(ROOT / "fixtures" / (name + ".sqlite")) for name in ("core", "btree", "utf16le", "utf16be", "page65536", "empty"))
    with tempfile.TemporaryDirectory(prefix="moonsqlite-inspection-") as temporary:
        directory = Path(temporary)
        for size, encoding in ((512, "UTF-8"), (1024, "UTF-16le"), (4096, "UTF-16be")):
            path = directory / f"ownership-{size}.sqlite"
            make_btree(path, size, encoding).close()
            total += verify(path)
        alias = directory / "alias.sqlite"
        shutil.copyfile(ROOT / "fixtures/btree.sqlite", alias)
        with closing(sqlite3.connect(alias)) as db:
            root = db.execute("SELECT rootpage FROM sqlite_schema WHERE name='indexed_rows'").fetchone()[0]
            db.execute("PRAGMA writable_schema=ON")
            db.execute("UPDATE sqlite_schema SET rootpage=? WHERE name='plain'", (root,))
            db.commit()
        report = inspect(alias, exit_code=1)
        assert report["status"] == "failed" and not report["ownership_complete"]
        assert any(issue["code"] == "page_conflict" and issue["first"]["object_name"] == "indexed_rows" and issue["second"]["object_name"] == "plain" for issue in report["issues"])
        orphan = directory / "orphan.sqlite"
        data = bytearray((ROOT / "fixtures/empty.sqlite").read_bytes())
        size = int.from_bytes(data[16:18], "big")
        size = 65536 if size == 1 else size
        pages = len(data) // size
        data[28:32] = (pages + 1).to_bytes(4, "big")
        data[92:96] = data[24:28]
        data.extend(bytes(size))
        orphan.write_bytes(data)
        report = inspect(orphan, exit_code=1)
        assert report["status"] == "failed" and report["ownership_complete"] and report["unclaimed_pages"] == [pages + 1]
        bad_args = subprocess.run(["node", str(ROOT / "tools/inspect.cjs"), str(orphan), "inspect", "extra"], cwd=ROOT, capture_output=True)
        assert bad_args.returncode == 1 and not bad_args.stdout and bad_args.stderr
    print(f"All ownership checks passed: {total} pages and controlled alias/orphan failures")


if __name__ == "__main__":
    main()
