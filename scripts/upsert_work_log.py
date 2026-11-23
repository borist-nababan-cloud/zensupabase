#!/usr/bin/env python3
r"""
Idempotent upsert of one or more work_logs entries into Supabase PostgreSQL.
Used automatically by the "update catatan" workflow.

Usage:
    python upsert_work_log.py --json-file path/to/logs.json [--env production|staging]
    python upsert_work_log.py --json '{"tanggal":"2026-11-23",...}' [--env production|staging]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional

SUPABASE_DIR = Path(r"d:\BEN\Zen\WORK_SPACE\backend\supabase")
ENV_PATH = SUPABASE_DIR / ".env"
SQL_OUT_PATH = SUPABASE_DIR / "backups" / "last_upsert_work_log.sql"
PSQL_PATH = Path(r"C:\Program Files\PostgreSQL\18\bin\psql.exe")


def load_env(path: Path) -> Dict[str, str]:
    env_vars: Dict[str, str] = {}
    if not path.exists():
        return env_vars
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        env_vars[k.strip()] = v.strip()
    return env_vars


def sql_literal(val: Optional[str]) -> str:
    if val is None:
        return "NULL"
    return "'" + str(val).replace("'", "''") + "'"


def normalize_entry(item: dict) -> dict:
    required = ["tanggal", "apps_name", "path", "title", "have_done"]
    for field in required:
        if not item.get(field):
            raise ValueError(f"Missing required field '{field}' in work_log entry: {item}")

    tanggal = str(item["tanggal"]).strip()
    apps_name = str(item["apps_name"]).strip()
    path = str(item["path"]).strip()
    title = str(item["title"]).strip()
    have_done = str(item["have_done"]).strip()
    aksi = str(item.get("aksi") or "Diperbarui").strip()
    tested = True  # Always enforced true per business standard
    trained = bool(item.get("trained", False))
    commit_hash = str(item["commit_hash"]).strip() if item.get("commit_hash") else None
    source_hash = (
        str(item["source_hash"]).strip()
        if item.get("source_hash")
        else hashlib.sha256(f"auto:{tanggal}:{apps_name}:{title}".encode("utf-8")).hexdigest()
    )

    return {
        "tanggal": tanggal,
        "apps_name": apps_name,
        "path": path,
        "title": title,
        "have_done": have_done,
        "aksi": aksi,
        "tested": tested,
        "trained": trained,
        "commit_hash": commit_hash,
        "source_hash": source_hash,
    }


def build_sql(entries: List[dict]) -> str:
    lines = ["BEGIN;", ""]
    for e in entries:
        lines.append(
            "INSERT INTO public.work_logs "
            "(tanggal, apps_name, path, title, have_done, aksi, tested, trained, commit_hash, source_hash) "
            f"VALUES ({sql_literal(e['tanggal'])}::date, {sql_literal(e['apps_name'])}, {sql_literal(e['path'])}, "
            f"{sql_literal(e['title'])}, {sql_literal(e['have_done'])}, {sql_literal(e['aksi'])}, "
            f"true, {'true' if e['trained'] else 'false'}, "
            f"{sql_literal(e['commit_hash'])}, {sql_literal(e['source_hash'])}) "
            "ON CONFLICT (source_hash) DO UPDATE SET "
            "tanggal = EXCLUDED.tanggal, "
            "apps_name = EXCLUDED.apps_name, "
            "path = EXCLUDED.path, "
            "title = EXCLUDED.title, "
            "have_done = EXCLUDED.have_done, "
            "aksi = EXCLUDED.aksi, "
            "tested = true, "
            "commit_hash = COALESCE(EXCLUDED.commit_hash, public.work_logs.commit_hash), "
            "updated_at = now();"
        )
    lines.extend(["", "COMMIT;"])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Upsert work_logs entries into Supabase")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--json-file", help="Path to JSON file containing object or array of objects")
    group.add_argument("--json", help="Inline JSON string containing object or array of objects")
    parser.add_argument("--env", choices=["production", "staging"], default="production")
    args = parser.parse_args()

    if args.json_file:
        raw = Path(args.json_file).read_text(encoding="utf-8")
    else:
        raw = args.json

    payload = json.loads(raw)
    if isinstance(payload, dict):
        items = [payload]
    elif isinstance(payload, list):
        items = payload
    else:
        raise ValueError("JSON root must be an object or array of objects")

    if not items:
        print("No entries provided; nothing to upsert.")
        return 0

    entries = [normalize_entry(item) for item in items]

    SQL_OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    SQL_OUT_PATH.write_text(build_sql(entries), encoding="utf-8")

    env_vars = load_env(ENV_PATH)
    key = "SUPABASE_DB_URL_PROD" if args.env == "production" else "SUPABASE_DB_URL_STAGING"
    db_url = env_vars.get(key) or os.environ.get(key)
    if not db_url:
        print(f"ERROR: {key} not found in {ENV_PATH}", file=sys.stderr)
        return 1
    if not PSQL_PATH.exists():
        print(f"ERROR: psql.exe not found at {PSQL_PATH}", file=sys.stderr)
        return 1

    proc_env = os.environ.copy()
    proc_env["PGCLIENTENCODING"] = "UTF8"

    res = subprocess.run(
        [str(PSQL_PATH), db_url, "-v", "ON_ERROR_STOP=1", "-f", str(SQL_OUT_PATH)],
        env=proc_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if res.returncode != 0:
        print("STDOUT:\n", res.stdout)
        print("STDERR:\n", res.stderr, file=sys.stderr)
        return res.returncode

    hashes_sql = ", ".join(sql_literal(e["source_hash"]) for e in entries)
    ver = subprocess.run(
        [
            str(PSQL_PATH),
            db_url,
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            f"SELECT id, tanggal, apps_name, path, title, tested, trained, updated_at FROM public.work_logs WHERE source_hash IN ({hashes_sql}) ORDER BY apps_name;",
        ],
        env=proc_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    print(f"Upserted {len(entries)} work_logs entry/entries to {args.env} successfully.")
    print(ver.stdout)
    return ver.returncode


if __name__ == "__main__":
    raise SystemExit(main())
