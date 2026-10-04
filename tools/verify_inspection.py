#!/usr/bin/env python3
"""以 SQLite 元数据、可用时的 dbstat 和受控损坏样本验证全局检查报告。"""
import json
from collections import Counter
from contextlib import closing
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from generate_btree_fixtures import make_btree

ROOT = Path(__file__).resolve().parents[1]
DBSTAT_PAGES = 0


def inspect(path, exit_code=0, command="inspect"):
    result = subprocess.run(["node", str(ROOT / "tools/inspect.cjs"), str(path), command],
                            cwd=ROOT, capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == exit_code, (path.name, result.returncode, result.stderr, result.stdout[:500])
    assert result.stderr == "", result.stderr
    return json.loads(result.stdout)


def page_reports(path, numbers):
    # 同一进程重复加载 CLI，保留真实命令入口，避免逐页启动数千个 Node 进程。
    script = r'''
const fs = require('node:fs');
const compiled = process.argv[1], bytes = new Uint8Array(fs.readFileSync(process.argv[2]));
const reports = [];
for (const number of JSON.parse(process.argv[3])) {
  let code = 0;
  globalThis.moonsqlitefileHost = {
    args: [process.argv[2], 'page-inspect', String(number)], bytes,
    output: text => reports.push(JSON.parse(text)),
    error: text => { throw new Error(text); },
    exitCode: value => { code = value; },
  };
  delete require.cache[require.resolve(compiled)];
  require(compiled);
  if (code !== 0) throw new Error(JSON.stringify(reports.at(-1)));
}
process.stdout.write(JSON.stringify(reports));
'''
    compiled = ROOT / '_build/js/debug/build/cmd/inspect/inspect.js'
    result = subprocess.run(['node', '-e', script, str(compiled), str(path), json.dumps(numbers)],
                            cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
    assert result.returncode == 0, result.stderr
    return {item['page']['number']: item for item in json.loads(result.stdout)}


def verify(path):
    global DBSTAT_PAGES
    report = inspect(path)
    detailed = inspect(path, command='inspect-details')
    assert detailed['inspection'] == report and detailed['locations'] == []
    summary = inspect(path, command='summary-json')
    assert summary['status'] == report['status'] and summary['ownership_complete']
    assert summary['ptrmap_checked'] and not summary['diagnostics_truncated'] and summary['issue_count'] == 0
    assert summary['claimed_pages'] == len(report['pages']) and summary['unclaimed_pages'] == 0
    assert summary['records_decoded'] == report['records_decoded'] and summary['payload_bytes'] == report['payload_bytes']
    kinds = {item['kind']: item['pages'] for item in summary['page_kinds']}
    observed_kinds = Counter(page['kind'] for page in report['pages'])
    assert len(kinds) == 8 and {kind: count for kind, count in kinds.items() if count} == observed_kinds
    assert report["status"] == "complete" and report["ownership_complete"]
    assert report["ptrmap_checked"] and not report["diagnostics_truncated"]
    assert report["issues"] == [] and report["unclaimed_pages"] == []
    with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
        assert db.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
        count = db.execute("PRAGMA page_count").fetchone()[0]
        free_count = db.execute("PRAGMA freelist_count").fetchone()[0]
        roots = {name: root for name, root in db.execute("SELECT name,rootpage FROM sqlite_schema WHERE rootpage>0")}
        roots["sqlite_schema"] = 1
        assert [(obj['root_page'], obj['object_name']) for obj in summary['objects']] == sorted((root, name) for name, root in roots.items())
        pages = {page["page_number"]: page for page in report["pages"]}
        layouts = page_reports(path, [number for number, page in pages.items()
                                     if page['kind'] in {'btree_root', 'btree_child'}])
        size = db.execute('PRAGMA page_size').fetchone()[0]
        assert summary['page_size'] == size and summary['logical_pages'] == count
        for obj in summary['objects']:
            owners = [page for page in report['pages'] if page['root_page'] == obj['root_page'] and page['object_name'] == obj['object_name']]
            assert obj['btree_pages'] == sum(page['kind'] in {'btree_root', 'btree_child'} for page in owners)
            assert obj['overflow_pages'] == sum(page['kind'] in {'overflow_first', 'overflow_continuation'} for page in owners)
            assert int(obj['storage_bytes']) == len(owners) * size
        data = path.read_bytes()
        assert sum(int(item['statistics']['payload_bytes']) for item in layouts.values()) == int(report['payload_bytes'])
        for number, item in layouts.items():
            stats = item['statistics']
            assert item['status'] == 'complete' and item['diagnostic'] is None
            assert sum(stats[key] for key in ('database_header_bytes', 'btree_header_bytes', 'pointer_bytes',
                       'unallocated_bytes', 'cell_bytes', 'freeblock_bytes', 'fragmented_bytes', 'reserved_bytes')) == size
            offset = (number - 1) * size + (100 if number == 1 else 0)
            assert item['page']['cell_count'] == int.from_bytes(data[offset + 3:offset + 5], 'big')
            assert stats['fragmented_bytes'] == data[offset + 7]
            assert stats['database_header_bytes'] == (100 if number == 1 else 0)
            assert stats['reserved_bytes'] == data[20]
            assert int(stats['local_payload_bytes']) <= int(stats['payload_bytes'])
            assert stats['overflow_cells'] <= item['page']['cell_count']
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
            statistics = db.execute("SELECT name,pageno,pagetype,path,ncell,payload,unused,mx_payload FROM dbstat").fetchall()
        except sqlite3.OperationalError as error:
            if "no such table: dbstat" not in str(error):
                raise
            if sys.platform.startswith('linux'):
                raise RuntimeError('Linux 正式验收必须启用 SQLite dbstat，不能跳过物理页对照') from error
            statistics = None
        if statistics is not None:
            DBSTAT_PAGES += len(statistics)
            for obj in summary['objects']:
                object_rows = [row for row in statistics if row[0] == obj['object_name']]
                assert obj['btree_pages'] == sum(row[2] != 'overflow' for row in object_rows)
                assert obj['overflow_pages'] == sum(row[2] == 'overflow' for row in object_rows)
            active = {row[1] for row in statistics}
            assert active == {number for number, page in pages.items() if page["kind"] in {"btree_root", "btree_child", "overflow_first", "overflow_continuation"}}
            for name, number, kind, tree_path, cells, payload, unused, maximum in statistics:
                owner = pages[number]
                assert owner["object_name"] == name
                expected = ("overflow_first" if tree_path.endswith("+000000") else "overflow_continuation") if kind == "overflow" else ("btree_root" if number == roots[name] else "btree_child")
                assert owner["kind"] == expected
                if kind != 'overflow':
                    layout = layouts[number]
                    stats = layout['statistics']
                    assert layout['page']['cell_count'] == cells
                    assert int(stats['local_payload_bytes']) == payload
                    assert stats['max_payload_bytes'] == maximum
                    assert stats['unallocated_bytes'] + stats['freeblock_bytes'] + stats['fragmented_bytes'] == unused
        print(f"Verified ownership {path.name}: {count} pages, {len(roots)} roots, dbstat={'yes' if statistics is not None else 'unavailable'}")
        return count


def make_auto(path, mode, size, encoding):
    with closing(sqlite3.connect(path)) as db:
        db.execute(f"PRAGMA page_size={size}")
        db.execute(f"PRAGMA encoding='{encoding}'")
        db.execute(f"PRAGMA auto_vacuum={mode}")
        db.execute("VACUUM")
        db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, body TEXT)")
        db.execute("CREATE INDEX by_body ON items(body)")
        db.execute("CREATE TABLE keyed(k TEXT PRIMARY KEY, n INTEGER) WITHOUT ROWID")
        db.executemany("INSERT INTO items VALUES(?,?)", ((i, "月" * 700 + str(i)) for i in range(60)))
        db.executemany("INSERT INTO keyed VALUES(?,?)", ((f"key-{i:03}", i) for i in range(30)))
        db.commit()
        db.execute("DELETE FROM items WHERE id%3=0")
        db.commit()


def verify_fragmented_pages(directory):
    """让 SQLite 自己产生碎片和空闲块，避免以同一套解析逻辑生成 oracle。"""
    total, fragmented, freeblocks = 0, 0, 0
    kinds = set()
    for size, encoding in ((512, "UTF-8"), (1024, "UTF-16le"), (4096, "UTF-16be"), (65536, "UTF-8")):
        path = directory / f"fragmented-{size}.sqlite"
        with closing(sqlite3.connect(path)) as db:
            db.execute(f"PRAGMA page_size={size}")
            db.execute(f"PRAGMA encoding='{encoding}'")
            db.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, body BLOB, label TEXT)")
            db.execute("CREATE INDEX by_label ON items(label)")
            db.execute("CREATE TABLE keyed(k TEXT PRIMARY KEY, body BLOB) WITHOUT ROWID")
            db.execute("CREATE TABLE tiny(value)")
            db.execute("CREATE INDEX tiny_value ON tiny(value)")
            lengths = (0, 1, 2, 3, 15, 50, 90, 110, 480, 900)
            db.executemany("INSERT INTO items VALUES(?,?,?)", (
                (i - 200, bytes([i % 256]) * lengths[i % len(lengths)], f"{i:04}-" + "月" * (i % 31))
                for i in range(400)
            ))
            db.executemany("INSERT INTO keyed VALUES(?,?)", (
                (f"{i:04}-" + "🌙" * (i % 70), bytes([i % 256]) * (i % 23)) for i in range(160)
            ))
            db.executemany("INSERT INTO tiny VALUES(?)", ((None,) for _ in range(150)))
            db.commit()
            # 删除与变长更新制造真实空间复用，不能在检查前 VACUUM 消除碎片。
            db.execute("DELETE FROM items WHERE id%4=0")
            db.execute("DELETE FROM keyed WHERE substr(k,1,4)%3=0")
            db.commit()
            db.execute("UPDATE items SET body=substr(body,1,length(body)/2) WHERE id%3=0")
            db.execute("UPDATE keyed SET body=zeroblob(31) WHERE substr(k,1,4)%5=0")
            db.commit()
        total += verify(path)
        report = inspect(path)
        data = path.read_bytes()
        for owner in report["pages"]:
            if owner["kind"] not in {"btree_root", "btree_child"}:
                continue
            offset = (owner["page_number"] - 1) * size + (100 if owner["page_number"] == 1 else 0)
            kinds.add(data[offset])
            fragmented += data[offset + 7] > 0
            freeblocks += int.from_bytes(data[offset + 1:offset + 3], "big") > 0
    assert kinds == {2, 5, 10, 13}, kinds
    assert fragmented > 0 and freeblocks > 0, (fragmented, freeblocks)
    print(f"Verified SQLite-generated page space: {fragmented} fragmented pages, {freeblocks} pages with freeblocks, four B-tree kinds")
    return total


def corrupt_page_space(directory):
    original = bytearray((ROOT / "fixtures/btree.sqlite").read_bytes())
    report = inspect(ROOT / "fixtures/btree.sqlite")
    size = 512
    target = next(owner for owner in report["pages"]
                  if owner["kind"] in {"btree_root", "btree_child"}
                  and owner["object_name"] == "indexed_rows"
                  and original[(owner["page_number"] - 1) * size] == 13)
    offset = (target["page_number"] - 1) * size
    start = int.from_bytes(original[offset + 5:offset + 7], "big")
    pointers_end = 8 + 2 * int.from_bytes(original[offset + 3:offset + 5], "big")
    assert start >= pointers_end + 4 and original[offset + 7] < 60
    for name in ("fragment-count", "untracked-gap"):
        data = original.copy()
        if name == "fragment-count":
            data[offset + 7] += 1
        else:
            data[offset + 5:offset + 7] = (start - 4).to_bytes(2, "big")
        path = directory / (name + ".sqlite")
        path.write_bytes(data)
        failed = inspect(path, exit_code=1)
        assert failed["status"] == "failed" and not failed["ownership_complete"]
        assert any(issue["code"] == "scan_error" and issue["error_kind"] == "invalid" for issue in failed["issues"])
        result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(path), 'page-inspect', str(target['page_number'])],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
        assert result.returncode == 1 and result.stderr == '', (result.returncode, result.stderr)
        located = json.loads(result.stdout)
        assert located['status'] == 'failed' and located['statistics'] is None and located['page'] is None
        diagnostic = located['diagnostic']
        assert diagnostic['code'] == 'fragment_count'
        assert diagnostic['page_number'] == target['page_number'] and diagnostic['error_kind'] == 'invalid'
        assert diagnostic['byte_offset'] == 7
        assert diagnostic['cell_index'] is None
        detailed = inspect(path, exit_code=1, command='inspect-details')
        assert detailed['inspection'] == failed
        assert len(detailed['locations']) == len(failed['issues'])
        location = next(location for issue, location in zip(failed['issues'], detailed['locations'])
                        if issue['code'] == 'scan_error')
        assert location['phase'] == 'page_layout' and location['page_number'] == target['page_number']
        assert location['byte_offset'] == diagnostic['byte_offset'] and location['page_code'] == diagnostic['code']
        result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(path), 'tree-inspect', str(target['root_page'])],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
        assert result.returncode == 1 and result.stderr == ''
        tree = json.loads(result.stdout)
        assert tree['root_page'] == target['root_page'] and tree['status'] == 'failed'
        assert tree['location'] == location
        summary = inspect(path, exit_code=1, command='summary-json')
        assert summary['status'] == 'failed' and not summary['ownership_complete']
        assert summary['claimed_pages'] == len(failed['pages'])
        assert summary['unclaimed_pages'] == len(failed['unclaimed_pages'])
        result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(path), 'summary'],
                                cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
        assert result.returncode == 1 and result.stderr == ''
        assert '检查状态：失败' in result.stdout and '以下为已观察结果' in result.stdout
        assert f"页：{target['page_number']}" in result.stdout and f"页内偏移：{diagnostic['byte_offset']}" in result.stdout
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            assert db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]
    print("Verified controlled fragment-count and untracked-gap corruption against SQLite")


def verify_summary_names(directory):
    path = directory / 'summary-names.sqlite'
    name = '月"表\n第二行\t'
    quoted = '"' + name.replace('"', '""') + '"'
    with closing(sqlite3.connect(path)) as db:
        db.execute('PRAGMA page_size=512')
        db.execute(f'CREATE TABLE {quoted}(id INTEGER PRIMARY KEY, body TEXT)')
        db.execute(f'INSERT INTO {quoted} VALUES(1,?)', ('Moon' * 256,))
        db.commit()
    pages = verify(path)
    summary = inspect(path, command='summary-json')
    assert summary['objects'][1]['object_name'] == name
    result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(path), 'summary'],
                            cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
    assert result.returncode == 0 and result.stderr == ''
    label = json.dumps(name, ensure_ascii=False)
    assert sum(label in line for line in result.stdout.splitlines()) == 1
    assert name not in result.stdout
    return pages


def corrupt_ptrmap(directory, source):
    original = bytearray(source.read_bytes())
    size = int.from_bytes(original[16:18], "big")
    usable = size - original[20]
    pages = inspect(source)["pages"]
    root = next(page for page in pages if page["kind"] == "btree_root" and page["page_number"] != 1)
    child = next(page for page in pages if page["kind"] == "btree_child")
    for name, owner, tag, parent in (
        ("root-as-free", root, 2, 0),
        ("wrong-parent", child, 5, child["page_number"] + 1 if root["page_number"] == child["parent_page"] else root["page_number"]),
        ("invalid-tag", root, 0, 0),
        ("invalid-parent", root, 1, 1),
    ):
        number = owner["page_number"]
        map_page = (number - 2) // (usable // 5 + 1) * (usable // 5 + 1) + 2
        offset = (map_page - 1) * size + (number - map_page - 1) * 5
        data = original.copy()
        data[offset] = tag
        data[offset + 1:offset + 5] = parent.to_bytes(4, "big")
        path = directory / (name + ".sqlite")
        path.write_bytes(data)
        report = inspect(path, exit_code=1)
        assert report["status"] == "failed" and report["ownership_complete"]
        detailed = inspect(path, exit_code=1, command='inspect-details')
        assert detailed['inspection'] == report and len(detailed['locations']) == len(report['issues'])
        location = detailed['locations'][0]
        assert location['phase'] == 'ptrmap_check' and location['page_number'] == map_page
        assert location['byte_offset'] == (offset % size + (1 if name == 'invalid-parent' else 0))
        assert location['cell_index'] is None and location['page_code'] is None
        if name in {"root-as-free", "wrong-parent"}:
            assert report["ptrmap_checked"]
            issue = next(issue for issue in report["issues"] if issue["code"] == "ptrmap_mismatch")
            assert issue["page_number"] == number and issue["ptrmap_type"] == tag
            assert issue["parent_page"] == parent and issue["expected_owner"] == owner
        else:
            assert not report["ptrmap_checked"]
            assert any(issue["code"] == "scan_error" and issue["error_kind"] == "invalid" for issue in report["issues"])
        with closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)) as db:
            try:
                assert db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]
            except sqlite3.DatabaseError:
                pass
    # 超过报告上限后必须明示截断，并保留已经发现的错误。
    data = original.copy()
    changed = 0
    for owner in pages:
        if owner["kind"] not in {"btree_child", "overflow_first", "overflow_continuation"}:
            continue
        number = owner["page_number"]
        map_page = (number - 2) // (usable // 5 + 1) * (usable // 5 + 1) + 2
        offset = (map_page - 1) * size + (number - map_page - 1) * 5
        data[offset:offset + 5] = b"\x02\x00\x00\x00\x00"
        changed += 1
        if changed == 101:
            break
    assert changed == 101
    path = directory / "many-mismatches.sqlite"
    path.write_bytes(data)
    report = inspect(path, exit_code=1)
    assert report["diagnostics_truncated"] and not report["ptrmap_checked"]
    assert len(report["issues"]) == 100 and report["ownership_complete"]


def main():
    total = sum(verify(ROOT / "fixtures" / (name + ".sqlite")) for name in ("core", "btree", "utf16le", "utf16be", "page65536", "empty"))
    result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(ROOT / 'fixtures/empty.sqlite'), 'page-inspect', '2'],
                            cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
    assert result.returncode == 2 and result.stderr == ''
    unavailable = json.loads(result.stdout)
    assert unavailable['status'] == 'incomplete' and unavailable['statistics'] is None
    assert unavailable['diagnostic']['code'] == 'page_read' and unavailable['diagnostic']['byte_offset'] is None
    result = subprocess.run(['node', str(ROOT / 'tools/inspect.cjs'), str(ROOT / 'fixtures/btree.sqlite'), 'summary'],
                            cwd=ROOT, capture_output=True, text=True, encoding='utf-8')
    assert result.returncode == 0 and result.stderr == ''
    assert '检查状态：完整（当前结构检查范围）' in result.stdout and '已认领页：198' in result.stdout
    assert '"long_key_index"，根页 143：B-tree 4，overflow 48' in result.stdout
    with tempfile.TemporaryDirectory(prefix="moonsqlite-inspection-") as temporary:
        directory = Path(temporary)
        total += verify_summary_names(directory)
        total += verify_fragmented_pages(directory)
        corrupt_page_space(directory)
        for size, encoding in ((512, "UTF-8"), (1024, "UTF-16le"), (4096, "UTF-16be")):
            path = directory / f"ownership-{size}.sqlite"
            make_btree(path, size, encoding).close()
            total += verify(path)
        for mode, size, encoding in ((1, 512, "UTF-8"), (2, 512, "UTF-8"), (2, 1024, "UTF-16le"), (1, 65536, "UTF-16be")):
            path = directory / f"auto-{mode}-{size}.sqlite"
            make_auto(path, mode, size, encoding)
            total += verify(path)
            report = inspect(path)
            assert any(page["kind"] == "pointer_map" for page in report["pages"])
            if mode == 2 and size == 512:
                assert any(page["kind"] == "freelist_leaf" for page in report["pages"])
                assert any(page["kind"] == "overflow_continuation" for page in report["pages"])
                corrupt_ptrmap(directory, path)
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
    print(f"All ownership checks passed: {total} pages, auto-vacuum and controlled alias/orphan/Ptrmap failures")
    evidence = dict(ownership_pages=total, dbstat_pages=DBSTAT_PAGES,
                    dbstat_required=sys.platform.startswith('linux'), sqlite=sqlite3.sqlite_version)
    (ROOT / '_build/inspection-evidence.json').write_text(
        json.dumps(evidence, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(evidence, ensure_ascii=False))


if __name__ == "__main__":
    main()
