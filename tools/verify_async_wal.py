#!/usr/bin/env python3
"""在独立 SQLite 恢复对照的同一 29 个静态快照上核对异步宿主。"""
import subprocess
import verify_wal_oracle as oracle


def main():
    original = oracle.verify
    checked = 0

    def verify(directory, name, base, wal):
        nonlocal checked
        records = original(directory, name, base, wal)
        damaged = oracle.parse(wal)['stop_reason'] != 'end_of_file'
        case = directory / name
        subprocess.run(['node', 'tools/verify_async.mjs', '--snapshot', str(case / 'input.db'),
                        str(case / 'input.wal'), 'prefix' if damaged else 'strict'],
                       cwd=oracle.ROOT, check=True, timeout=90)
        checked += 1
        return records

    oracle.verify = verify
    oracle.main()
    print(f'Asynchronous SQLite WAL acceptance passed: {checked} snapshots')


if __name__ == '__main__':
    main()
