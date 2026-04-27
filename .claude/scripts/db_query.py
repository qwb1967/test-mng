#!/usr/bin/env python3
"""
db_query.py — 查询团队 dev MariaDB 的命令行工具
配套 skill: .claude/skills/query-dev-db.md

默认只读（SELECT/SHOW/DESCRIBE/EXPLAIN/USE），DDL/DML 必须显式 --confirm。
"""
import argparse
import json
import re
import sys

import pymysql
import pymysql.cursors

HOST = "dev-mariadb.imchenr1024.com"
PORT = 13307

# 库名 -> (用户名, 密码)
# 规则：账号 = 库名；密码各库独立
DB_CREDS = {
    "tp_system": ("tp_system", "rYFi8p2Ak4dW8NYF"),
    "tp_auth": ("tp_auth", "5bKMtkkhxb3GWEpz"),
    "tp_functional": ("tp_functional", "Zyz8HZsDSjR4a55D"),
    "tp_storage": ("tp_storage", "MzneehQNcBY8JTPR"),
    "tp_interface": ("tp_interface", "arGtWAWcRsGJbZAb"),
    "tp_task": ("tp_task", "t6kSKrhQMMsNQjit"),
    "tp_code_review": ("tp_code_review", "HSn3jQs5mHi6EsXn"),
    "tp_ui_test_base": ("tp_ui_test_base", "tx7b5e7FETxMAeB3"),
}

READ_ONLY_PREFIXES = {"SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "USE"}


def is_read_only(sql: str) -> bool:
    cleaned = re.sub(r"--.*?$", "", sql, flags=re.MULTILINE)
    cleaned = re.sub(r"/\*.*?\*/", "", cleaned, flags=re.DOTALL)
    statements = [s.strip() for s in cleaned.split(";") if s.strip()]
    if not statements:
        return True
    for s in statements:
        tokens = s.split()
        if not tokens:
            continue
        if tokens[0].upper() not in READ_ONLY_PREFIXES:
            return False
    return True


def get_conn(db: str):
    if db not in DB_CREDS:
        print(
            f"❌ Unknown database '{db}'. Known: {sorted(DB_CREDS)}",
            file=sys.stderr,
        )
        sys.exit(2)
    user, pwd = DB_CREDS[db]
    return pymysql.connect(
        host=HOST,
        port=PORT,
        user=user,
        password=pwd,
        database=db,
        charset="utf8mb4",
        connect_timeout=5,
    )


def render_table(rows):
    if not rows:
        print("(empty result set)")
        return
    cols = list(rows[0].keys())
    widths = [
        max(len(c), max((len(str(r[c])) for r in rows), default=0)) for c in cols
    ]
    print(" | ".join(c.ljust(widths[i]) for i, c in enumerate(cols)))
    print("-+-".join("-" * w for w in widths))
    for r in rows:
        print(" | ".join(str(r[c]).ljust(widths[i]) for i, c in enumerate(cols)))
    print(f"\n({len(rows)} rows)")


def run_sql(db: str, sql: str, as_json: bool):
    with get_conn(db) as conn:
        with conn.cursor(pymysql.cursors.DictCursor) as cur:
            cur.execute(sql)
            try:
                rows = cur.fetchall()
            except pymysql.err.Error:
                rows = []
            if as_json:
                print(json.dumps(rows, ensure_ascii=False, indent=2, default=str))
            else:
                if rows:
                    render_table(rows)
                else:
                    print(f"OK ({cur.rowcount} rows affected)")
            if not is_read_only(sql):
                conn.commit()


def main():
    parser = argparse.ArgumentParser(
        description="Query dev MariaDB (read-only by default)."
    )
    parser.add_argument(
        "--db",
        default="tp_system",
        help="Database name (default: tp_system). Known: " + ", ".join(sorted(DB_CREDS)),
    )
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--sql", help="SQL to execute (string).")
    src.add_argument("--file", help="Path to a .sql file.")
    src.add_argument(
        "--list-databases",
        action="store_true",
        help="Run SHOW DATABASES using --db's account.",
    )
    parser.add_argument(
        "--confirm",
        action="store_true",
        help="Required to execute DDL/DML statements.",
    )
    parser.add_argument("--json", action="store_true", help="Output JSON instead of table.")
    args = parser.parse_args()

    if args.list_databases:
        sql = "SHOW DATABASES"
    elif args.file:
        with open(args.file, "r", encoding="utf-8") as f:
            sql = f.read()
    else:
        sql = args.sql

    if not is_read_only(sql) and not args.confirm:
        print(
            "❌ Refused: SQL contains write/DDL operations. "
            "Re-run with --confirm after explicit user approval.",
            file=sys.stderr,
        )
        print(f"SQL: {sql.strip()}", file=sys.stderr)
        sys.exit(3)

    run_sql(args.db, sql, args.json)


if __name__ == "__main__":
    main()
