#!/usr/bin/env python3
"""
db_query.py — 查询团队 dev / fat MariaDB 的命令行工具
配套 skill: .claude/skills/query-db.md

默认只读（SELECT/SHOW/DESCRIBE/EXPLAIN/USE），DDL/DML 必须显式 --confirm。
通过 --env 切换环境：dev（默认，每个微服务独立账号）/ fat（统一 root 账号）。
"""
import argparse
import json
import re
import sys

import pymysql
import pymysql.cursors

# 环境配置
# - creds：库名 -> (用户名, 密码)，库专属凭据
# - default_creds：(用户名, 密码) 或 None；当 --db 不在 creds 时回退到该凭据
#   * dev：账号 = 库名，密码各库独立，没有 default_creds
#   * fat：单一 root 账号可访问所有库
ENVS = {
    "dev": {
        "host": "dev-mariadb.imchenr1024.com",
        "port": 13307,
        "creds": {
            "tp_system": ("tp_system", "rYFi8p2Ak4dW8NYF"),
            "tp_auth": ("tp_auth", "5bKMtkkhxb3GWEpz"),
            "tp_functional": ("tp_functional", "Zyz8HZsDSjR4a55D"),
            "tp_storage": ("tp_storage", "MzneehQNcBY8JTPR"),
            "tp_interface": ("tp_interface", "arGtWAWcRsGJbZAb"),
            "tp_task": ("tp_task", "t6kSKrhQMMsNQjit"),
            "tp_code_review": ("tp_code_review", "HSn3jQs5mHi6EsXn"),
            "tp_ui_test_base": ("tp_ui_test_base", "tx7b5e7FETxMAeB3"),
        },
        "default_creds": None,
    },
    "fat": {
        "host": "47.109.54.181",
        "port": 23307,
        "creds": {},
        "default_creds": ("root", "mariadb_4NWCkt"),
    },
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


def get_conn(env: str, db: str):
    if env not in ENVS:
        print(
            f"❌ Unknown env '{env}'. Known: {sorted(ENVS)}",
            file=sys.stderr,
        )
        sys.exit(2)
    cfg = ENVS[env]
    if db in cfg["creds"]:
        user, pwd = cfg["creds"][db]
    elif cfg["default_creds"]:
        user, pwd = cfg["default_creds"]
    else:
        print(
            f"❌ Unknown database '{db}' in env '{env}'. Known: {sorted(cfg['creds'])}",
            file=sys.stderr,
        )
        sys.exit(2)
    return pymysql.connect(
        host=cfg["host"],
        port=cfg["port"],
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


def run_sql(env: str, db: str, sql: str, as_json: bool):
    with get_conn(env, db) as conn:
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
        description="Query dev/fat MariaDB (read-only by default)."
    )
    parser.add_argument(
        "--env",
        default="dev",
        choices=sorted(ENVS),
        help="Environment to connect to (default: dev).",
    )
    parser.add_argument(
        "--db",
        default="tp_system",
        help="Database name (default: tp_system). dev creds: "
        + ", ".join(sorted(ENVS["dev"]["creds"])),
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

    run_sql(args.env, args.db, sql, args.json)


if __name__ == "__main__":
    main()
