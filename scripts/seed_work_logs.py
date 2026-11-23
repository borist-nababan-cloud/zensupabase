#!/usr/bin/env python3
r"""
Seed `public.work_logs` and backfill `public.work_log_releases` on Supabase Production
from `d:\BEN\Zen\WORK_SPACE\docs\HAVE_DONE.md` and live `storage.objects`.

Usage:
    python seed_work_logs.py [--dry-run] [--env production|staging]
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple

WORKSPACE_ROOT = Path(r"d:\BEN\Zen\WORK_SPACE")
HAVE_DONE_PATH = WORKSPACE_ROOT / "docs" / "HAVE_DONE.md"
SUPABASE_DIR = WORKSPACE_ROOT / "backend" / "supabase"
ENV_PATH = SUPABASE_DIR / ".env"
SQL_OUT_PATH = SUPABASE_DIR / "backups" / "seed_work_logs_prod.sql"
PSQL_PATH = Path(r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
PROD_PROJECT_URL = "https://ihdlwogvjfgawgsalgng.supabase.co"

INDONESIAN_MONTHS = {
    "januari": 1,
    "februari": 2,
    "maret": 3,
    "april": 4,
    "mei": 5,
    "juni": 6,
    "juli": 7,
    "agustus": 8,
    "september": 9,
    "oktober": 10,
    "november": 11,
    "desember": 12,
}

# Order matters slightly when single bullet hits one unambiguous path
APP_RULES: List[Tuple[str, str, List[str]]] = [
    (
        "WHMS App",
        r"frontend\warehousemanagement",
        [
            "frontend\\warehousemanagement",
            "frontend/warehousemanagement",
            "warehousemanagement",
            "whms",
            "zen-warehouse-management",
            "menu_access_matrix.md",
            "user_guide.md",
            "sidebar.tsx",
            "protectedroute.tsx",
            "stockopname",
            "stocreate",
            "stogoods",
            "storequest",
            "stolist",
            "stopaydown",
            "stoarreport",
            "purchaseorder",
            "productpage",
            "mastertypepage",
            "supplierpage",
            "priceunitmanager",
            "outletinfopage",
            "customersales",
            "customerpage",
            "customersettlement",
            "reportcustomer",
            "reporttrfaults",
            "reportemployeefaults",
            "reportemployeekpi",
            "trcreateevaluation",
            "trcategorypage",
            "trvariablepage",
            "trreportlist",
            "trfaultspage",
            "masterfaultspage",
            "kpivariablepage",
            "kpimasterfaults",
            "employeefaults",
            "employeekpi",
            "karyawaninfopage",
            "crminbox",
            "crmchatbox",
            "newspromopage",
            "usertestimonialspage",
            "gallerypage",
            "servicespage",
            "servicesmenupage",
            "facilitiespage",
            "masterfacilitiespage",
            "posperiodicdashboard",
            "useposlivedashboarddata",
            "recipeformpage",
            "productionrunpage",
            "financialaccountspage",
            "generaltransactionspage",
            "transactioncategoriespage",
            "issuecategoriespage",
            "shrinkagecategoriespage",
            "shrinkageformpage",
            "internalusage",
            "internalreturn",
            "reportinternal",
            "reportsto",
            "poreport",
            "reportgrsupplier",
            "outstandingpo",
            "supplierperformance",
            "apagingreport",
            "invoicesreport",
            "cashflowreport",
            "inventoryreport",
            "usermanagementpage",
            "changepasswordpage",
            "tutorialpage",
            "decimal-price-input",
            "authcallbackpage",
            "analisis arsitektur mrt",
            "whm",
        ],
    ),
    (
        "Supabase Backend",
        r"backend\supabase",
        [
            "backend\\supabase",
            "backend/supabase",
            "supabase\\migrations",
            "supabase/migrations",
            "deploy_supabase",
            "sync_prod_to_env",
            "restore_prod_tables",
            "restore_products_and_recipes",
            "seed_staging_to_prod",
            "zensupabase",
            "database synchronization (prod -> staging)",
            "sinkronisasi & seeding data staging ke production",
            "database & skema (supabase)",
            "config.toml",
            ".sql",
        ],
    ),
    (
        "ZenSystem Desktop",
        r"desktop\ZenSystem",
        [
            "desktop\\zensystem",
            "desktop/zensystem",
            "zensystem",
            "fmasterkaryawan",
            "freportpayroll",
            "fpayrolladmin",
            "freportpendapatan",
            "fbalireportpendapatan",
            "fpostransmain",
            "fpospembayaran",
            "fconfigsetup",
            "fdmdb",
        ],
    ),
    (
        "SyncAgent",
        r"desktop\SyncAgent",
        [
            "desktop\\syncagent",
            "desktop/syncagent",
            "syncagent",
            "possync.pas",
            "fmanualsync",
        ],
    ),
    (
        "ZenDashboard",
        r"frontend\dashboard",
        [
            "frontend\\dashboard",
            "frontend/dashboard",
            "zen-dashboard",
            "zengardensummary",
            "roomtherapistanalysis",
            "outletpanoramagrid",
            "financepromoanalysis",
            "usedashboarddata",
            "dateutils.ts",
            "tv_banner.png",
            "mainactivity.java",
            "androidmanifest.xml",
            "build.gradle",
            "capacitor.config",
            "smart tv tcl",
        ],
    ),
    (
        "ZenInternal App",
        r"frontend\internalapp",
        [
            "frontend\\internalapp",
            "frontend/internalapp",
            "internalapp",
            "zen internal",
            "zeninternal",
            "payrollpage",
            "attendancepage",
            "commissionpage",
            "employeelinkscreen",
            "deploy_to_coolify_internalapp",
            "zen-frontend-internalapp",
        ],
    ),
    (
        "Website Static",
        r"frontend\website",
        [
            "frontend\\website",
            "frontend/website",
            "zen-website-static",
            "floatingchatwidget",
            "testimonialssection",
            "testimonialmodal",
            "servicessection",
            "gallerysection",
            "herosection",
            "philosophysection",
            "outletssection",
            "memberprofilemodal",
            "deploy_web_static",
        ],
    ),
    (
        "WorkLogs App",
        r"frontend\worklogs",
        [
            "frontend\\worklogs",
            "frontend/worklogs",
            "zen-workslogs",
            "worklogs",
        ],
    ),
    (
        "AI Backend",
        r"frontend\aibackend",
        [
            "frontend\\aibackend",
            "frontend/aibackend",
            "aibackend",
        ],
    ),
]


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


def parse_date_header(header_text: str) -> Optional[Tuple[str, str, str]]:
    """
    Returns (tanggal_iso, date_display, session_label) or None.
    """
    raw = header_text.strip()
    session_label = ""
    paren_match = re.search(r"\(([^)]+)\)\s*$", raw)
    if paren_match:
        session_label = paren_match.group(1).strip()
        date_part = raw[: paren_match.start()].strip()
    else:
        date_part = raw

    m = re.search(r"(?:\w+,\s*)?(\d{1,2})\s+([A-Za-z]+)\s+(\d{4})", date_part)
    if not m:
        return None
    day = int(m.group(1))
    month_name = m.group(2).lower()
    year = int(m.group(3))
    month = INDONESIAN_MONTHS.get(month_name)
    if not month:
        return None
    tanggal_iso = f"{year:04d}-{month:02d}-{day:02d}"
    return tanggal_iso, date_part, session_label


def classify_module(module_name: str, details: str, session_context: str) -> Tuple[str, str]:
    name_low = module_name.lower()

    # Explicit multi-repo or cross-app items -> Ecosystem / Global
    matched_apps_in_name = []
    for app_name, app_path, keywords in APP_RULES:
        if any(kw in name_low for kw in keywords):
            matched_apps_in_name.append((app_name, app_path))

    if len(matched_apps_in_name) == 1:
        return matched_apps_in_name[0]
    if len(matched_apps_in_name) > 1:
        # e.g. `frontend\warehousemanagement` & `frontend\website` (Git Push Produksi)
        # Check if one isn't just a false positive like `whm` inside something else
        distinct = {a[0]: a for a in matched_apps_in_name}
        if len(distinct) == 1:
            return next(iter(distinct.values()))
        return ("Ecosystem / Global", ".")

    # Global/N8N/Rule artifacts
    if any(k in name_low for k in [".antigraviy", ".antigravity", "command_templates", "n8n workflow"]):
        return ("Ecosystem / Global", ".")

    # Fallback: check details text
    det_low = details.lower()
    matched_in_details = []
    for app_name, app_path, keywords in APP_RULES:
        # Use path-like or strong keywords for detail matching
        strong = [kw for kw in keywords if "\\" in kw or "/" in kw or len(kw) >= 6]
        if any(kw in det_low for kw in strong):
            matched_in_details.append((app_name, app_path))
    if len(matched_in_details) == 1:
        return matched_in_details[0]

    # Fallback: check session summary context (e.g., short filenames like `vite.config.ts` in WHMS session)
    ctx_low = session_context.lower()
    for app_name, app_path, keywords in APP_RULES:
        strong = [kw for kw in keywords if "\\" in kw or "/" in kw or app_name.lower() in ctx_low]
        if any(kw in ctx_low for kw in strong) or app_name.lower() in ctx_low:
            return (app_name, app_path)

    # Special hint for WHMS / ZenDashboard / InternalApp generic React files
    if any(ext in name_low for ext in [".tsx", ".ts", ".jsx", ".css"]):
        if "warehousemanagement" in ctx_low or "whms" in ctx_low:
            return ("WHMS App", r"frontend\warehousemanagement")
        if "dashboard" in ctx_low:
            return ("ZenDashboard", r"frontend\dashboard")
        if "internal" in ctx_low:
            return ("ZenInternal App", r"frontend\internalapp")
        if "website" in ctx_low:
            return ("Website Static", r"frontend\website")

    if "nginx" in name_low or "dockerfile" in name_low or "coolify" in name_low:
        if "whms" in ctx_low or "warehousemanagement" in ctx_low:
            return ("WHMS App", r"frontend\warehousemanagement")
        if "dashboard" in ctx_low:
            return ("ZenDashboard", r"frontend\dashboard")
        if "internalapp" in ctx_low or "internal super-app" in ctx_low:
            return ("ZenInternal App", r"frontend\internalapp")
        if "website" in ctx_low:
            return ("Website Static", r"frontend\website")

    return ("Ecosystem / Global", ".")


def parse_have_done_sessions(markdown_text: str) -> List[dict]:
    # Normalize `---## ` artifact
    normalized = re.sub(r"^---\s*(##\s+)", r"---\n\n\1", markdown_text, flags=re.MULTILINE)
    lines = normalized.splitlines()

    sessions: List[dict] = []
    current_session = None
    current_module = None
    in_modules = False
    summary_lines: List[str] = []
    detail_lines: List[str] = []

    def flush_module():
        nonlocal current_module, detail_lines
        if current_session is not None and current_module is not None:
            current_module["details"] = "\n".join(detail_lines).strip()
            current_session["modules"].append(current_module)
        current_module = None
        detail_lines = []

    def flush_session():
        nonlocal current_session, summary_lines, in_modules
        flush_module()
        if current_session is not None:
            current_session["summary"] = "\n".join(summary_lines).strip()
            sessions.append(current_session)
        current_session = None
        summary_lines = []
        in_modules = False

    for line in lines:
        stripped = line.strip()

        if stripped.startswith("## "):
            header_body = stripped[3:].strip()
            parsed = parse_date_header(header_body)
            if parsed:
                flush_session()
                tanggal_iso, date_display, session_label = parsed
                current_session = {
                    "index": len(sessions) + 1,
                    "tanggal": tanggal_iso,
                    "date_display": date_display,
                    "session_label": session_label,
                    "header_raw": header_body,
                    "summary": "",
                    "modules": [],
                }
                continue

        if current_session is None:
            continue

        if stripped == "---":
            in_modules = False
            flush_module()
            continue

        if stripped.startswith("### "):
            # e.g. ### 📦 Modul yang Dibuat / Diperbarui or ### 🗄️ Database & Skema (Supabase)
            in_modules = True
            flush_module()
            continue

        # Module bullet: `*   **Nama Modul:** ...` or `*   **Nama Migrasi / Tabel:** ...`
        m_mod = re.match(r"^\*\s+\*\*(?:Nama\s+Modul|Nama\s+Migrasi\s*/\s*Tabel):\*\*\s*(.+)$", stripped)
        if m_mod:
            in_modules = True
            flush_module()
            mod_name = m_mod.group(1).strip()
            current_module = {
                "module_name": mod_name,
                "action": "Diperbarui",
                "details": "",
            }
            continue

        if in_modules and current_module is not None:
            m_act = re.match(r"^\*\s+\*\*Aksi:\*\*\s*(.+)$", stripped)
            if m_act:
                current_module["action"] = m_act.group(1).strip()
                continue

            m_det = re.match(r"^\*\s+\*\*Detail(?:\s+Perubahan)?:\*\*\s*(.*)$", stripped)
            if m_det:
                first_part = m_det.group(1).strip()
                if first_part:
                    detail_lines.append(first_part)
                continue

            if stripped:
                # Preserve indentation lightly for nested lists
                indent = "  " if line.startswith("        ") or line.startswith("\t\t") else ""
                detail_lines.append(f"{indent}{stripped}")
        else:
            # Summary or other section (e.g. Langkah Selanjutnya)
            if stripped.startswith("**Ringkasan:**"):
                txt = stripped.replace("**Ringkasan:**", "", 1).strip()
                if txt:
                    summary_lines.append(txt)
            elif stripped and not stripped.startswith("#"):
                # Don't swallow orphan Next Steps unless useful; keep clean
                if not stripped.startswith("*"):
                    summary_lines.append(stripped)

    flush_session()
    return sessions


def truncate_clean(text: str, max_len: int = 120) -> str:
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= max_len:
        return text
    cut = text[:max_len].rsplit(" ", 1)[0].rstrip(",;:-")
    return cut + "..."


def normalize_aksi(actions: List[str], combined_text: str) -> str:
    joined = " ".join(actions).lower()
    txt = combined_text.lower()
    if "dibuat baru" in joined and "diperbarui" not in joined:
        return "Dibuat Baru"
    if any(k in joined for k in ["perbaikan", "fix", "resolusi"]) or (
        "rca" in txt and "dibuat baru" not in joined
    ):
        return "Perbaikan Bug"
    if any(k in joined for k in ["diterapkan", "dideploy", "live deployed", "sinkronisasi", "push"]):
        if "dibuat baru" in joined:
            return "Dibuat Baru"
        return "Infrastruktur"
    if "dibuat baru" in joined:
        return "Dibuat Baru"
    return "Diperbarui"


def extract_commit_hashes(text: str) -> Optional[str]:
    # Look for backticked 7-char hex git hashes like `e042ded`
    candidates = re.findall(r"`([0-9a-f]{7})`", text)
    # Filter out pure digits (like zip/port numbers) and hex colors
    valid: List[str] = []
    for c in candidates:
        if c.isdigit():
            continue
        if not any(ch.isalpha() for ch in c):
            continue
        if c not in valid:
            valid.append(c)
    return ", ".join(valid) if valid else None


def build_seed_rows(sessions: List[dict]) -> List[dict]:
    rows: List[dict] = []

    for sess in sessions:
        tanggal = sess["tanggal"]
        session_idx = sess["index"]
        summary = sess["summary"]
        session_label = sess["session_label"]
        ctx = f"{sess['header_raw']} {summary}"

        # Group modules by (apps_name, path) preserving order
        grouped: Dict[Tuple[str, str], List[dict]] = {}
        for mod in sess["modules"]:
            app_name, app_path = classify_module(mod["module_name"], mod["details"], ctx)
            grouped.setdefault((app_name, app_path), []).append(mod)

        if not grouped:
            # Fallback if a session had summary only
            app_name, app_path = classify_module("", summary, ctx)
            grouped[(app_name, app_path)] = []

        multi_app = len(grouped) > 1

        for (app_name, app_path), mods in grouped.items():
            # Build clean title
            if session_label and not multi_app:
                title = truncate_clean(session_label, 120)
            elif not multi_app and summary:
                first_sentence = re.split(r"(?<=[.!?;])\s+", summary)[0]
                title = truncate_clean(first_sentence, 125)
            else:
                # Multi-app session: summarize modules for this specific app
                clean_mod_names = []
                for m in mods:
                    # Extract short filename or label
                    raw_n = m["module_name"].replace("`", "")
                    parts = [p.strip() for p in re.split(r"[,&]", raw_n)]
                    for p in parts:
                        cleaned_p = re.sub(r"\s*\(.*?\)", "", p).strip()
                        short = cleaned_p.split("\\")[-1].split("/")[-1].strip()
                        if short and short not in clean_mod_names:
                            clean_mod_names.append(short)
                mod_preview = ", ".join(clean_mod_names[:3])
                if len(clean_mod_names) > 3:
                    mod_preview += f" (+{len(clean_mod_names) - 3} modul)"
                prefix = f"{session_label} — " if session_label else ""
                title = truncate_clean(f"{prefix}{app_name}: {mod_preview}".replace("`", ""), 130)

            title = title.replace("`", "")

            # Build structured markdown `have_done`
            md_parts: List[str] = []
            if summary:
                md_parts.append(f"**Ringkasan Sesi ({sess['date_display']}):**\n{summary}")

            if mods:
                md_parts.append("### Modul & Perubahan")
                for m in mods:
                    md_parts.append(f"- **Modul:** {m['module_name']}")
                    md_parts.append(f"  - **Aksi:** {m['action']}")
                    if m["details"]:
                        det_lines = m["details"].splitlines()
                        if len(det_lines) == 1 and not det_lines[0].startswith("-"):
                            md_parts.append(f"  - **Detail:** {det_lines[0]}")
                        else:
                            md_parts.append("  - **Detail:**")
                            for dl in det_lines:
                                cleaned_dl = dl.strip()
                                if cleaned_dl.startswith("- "):
                                    md_parts.append(f"    {cleaned_dl}")
                                elif cleaned_dl.startswith("-"):
                                    md_parts.append(f"    - {cleaned_dl[1:].strip()}")
                                else:
                                    md_parts.append(f"    - {cleaned_dl}")

            have_done = "\n\n".join(md_parts) if md_parts else summary
            aksi = normalize_aksi([m["action"] for m in mods], f"{title} {have_done}")
            commit_hash = extract_commit_hashes(have_done)
            source_key = f"seed:{session_idx}:{tanggal}:{app_name}"
            source_hash = hashlib.sha256(source_key.encode("utf-8")).hexdigest()

            rows.append(
                {
                    "tanggal": tanggal,
                    "apps_name": app_name,
                    "path": app_path,
                    "title": title,
                    "have_done": have_done,
                    "aksi": aksi,
                    "tested": True,
                    "trained": True,  # Per user directive: all initial seed rows set to True
                    "trained_at": f"{tanggal} 17:00:00+07",
                    "commit_hash": commit_hash,
                    "source_hash": source_hash,
                }
            )

    return rows


def sql_literal(val: Optional[str]) -> str:
    if val is None:
        return "NULL"
    # Use standard escaped single-quote string literal
    escaped = val.replace("'", "''")
    return f"'{escaped}'"


def generate_sql(rows: List[dict]) -> str:
    lines: List[str] = [
        "-- Auto-generated idempotent seed for public.work_logs and public.work_log_releases",
        "BEGIN;",
        "",
    ]

    for r in rows:
        lines.append(
            "INSERT INTO public.work_logs "
            "(tanggal, apps_name, path, title, have_done, aksi, tested, trained, trained_at, commit_hash, source_hash) "
            f"VALUES ({sql_literal(r['tanggal'])}::date, {sql_literal(r['apps_name'])}, {sql_literal(r['path'])}, "
            f"{sql_literal(r['title'])}, {sql_literal(r['have_done'])}, {sql_literal(r['aksi'])}, "
            f"{'true' if r['tested'] else 'false'}, {'true' if r['trained'] else 'false'}, "
            f"{sql_literal(r['trained_at'])}::timestamptz, {sql_literal(r['commit_hash'])}, {sql_literal(r['source_hash'])}) "
            "ON CONFLICT (source_hash) DO UPDATE SET "
            "tanggal = EXCLUDED.tanggal, "
            "apps_name = EXCLUDED.apps_name, "
            "path = EXCLUDED.path, "
            "title = EXCLUDED.title, "
            "have_done = EXCLUDED.have_done, "
            "aksi = EXCLUDED.aksi, "
            "tested = EXCLUDED.tested, "
            "trained = EXCLUDED.trained, "
            "trained_at = EXCLUDED.trained_at, "
            "commit_hash = EXCLUDED.commit_hash, "
            "updated_at = now();"
        )

    lines.extend(
        [
            "",
            "-- Backfill active binary releases from storage.objects in zen-releases",
            f"""INSERT INTO public.work_log_releases (
    app_category, app_name, filename, original_name, mime_type, size, storage_path, download_url, uploaded_at
)
SELECT
    CASE
        WHEN o.name LIKE 'zen_desktop/%' THEN 'zen_desktop'
        WHEN o.name LIKE 'zen_sync/%' THEN 'zen_sync'
        WHEN o.name LIKE 'internal_android/%' THEN 'internal_android'
        WHEN o.name LIKE 'customer_android/%' THEN 'customer_android'
        WHEN o.name LIKE 'dashboard_tv/%' THEN 'dashboard_tv'
    END AS app_category,
    CASE
        WHEN o.name LIKE 'zen_desktop/%' THEN 'Zen Desktop System'
        WHEN o.name LIKE 'zen_sync/%' THEN 'Zen Sync App'
        WHEN o.name LIKE 'internal_android/%' THEN 'Internal Android App'
        WHEN o.name LIKE 'customer_android/%' THEN 'Customer Test Android App'
        WHEN o.name LIKE 'dashboard_tv/%' THEN 'Zen Dashboard Android TV'
    END AS app_name,
    regexp_replace(o.name, '^.*/', '') AS filename,
    regexp_replace(o.name, '^.*/', '') AS original_name,
    COALESCE(o.metadata->>'mimetype', 'application/octet-stream') AS mime_type,
    COALESCE((o.metadata->>'size')::bigint, 0) AS size,
    o.name AS storage_path,
    '{PROD_PROJECT_URL}/storage/v1/object/public/zen-releases/' || o.name AS download_url,
    COALESCE(o.updated_at, o.created_at, now()) AS uploaded_at
FROM storage.objects o
WHERE o.bucket_id = 'zen-releases'
  AND (
    o.name LIKE 'zen_desktop/%'
    OR o.name LIKE 'zen_sync/%'
    OR o.name LIKE 'internal_android/%'
    OR o.name LIKE 'customer_android/%'
    OR o.name LIKE 'dashboard_tv/%'
  )
ON CONFLICT (app_category) DO NOTHING;""",
            "",
            "COMMIT;",
        ]
    )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed work_logs from docs/HAVE_DONE.md")
    parser.add_argument("--dry-run", action="store_true", help="Parse and print summary without executing SQL")
    parser.add_argument("--env", choices=["production", "staging"], default="production")
    args = parser.parse_args()

    if not HAVE_DONE_PATH.exists():
        print(f"ERROR: {HAVE_DONE_PATH} not found", file=sys.stderr)
        return 1

    text = HAVE_DONE_PATH.read_text(encoding="utf-8")
    sessions = parse_have_done_sessions(text)
    rows = build_seed_rows(sessions)

    print(f"Parsed sessions: {len(sessions)}")
    print(f"Generated work_logs rows: {len(rows)}")

    by_app: Dict[str, int] = {}
    for r in rows:
        by_app[r["apps_name"]] = by_app.get(r["apps_name"], 0) + 1
    print("\nBreakdown by apps_name:")
    for app, cnt in sorted(by_app.items(), key=lambda x: (-x[1], x[0])):
        print(f"  - {app}: {cnt}")

    if args.dry_run:
        print("\nSample titles (first 15):")
        for r in rows[:15]:
            print(f"  [{r['tanggal']}] [{r['apps_name']}] ({r['aksi']}) {r['title']}")
        return 0

    SQL_OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    sql_content = generate_sql(rows)
    SQL_OUT_PATH.write_text(sql_content, encoding="utf-8")  # UTF-8 without BOM

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

    print(f"\nExecuting SQL seed against {args.env} via {PSQL_PATH}...")
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

    verify_sql = """
    SELECT apps_name,
           COUNT(*) AS total_rows,
           COUNT(*) FILTER (WHERE tested) AS tested_true,
           COUNT(*) FILTER (WHERE trained) AS trained_true
    FROM public.work_logs
    GROUP BY apps_name
    ORDER BY total_rows DESC, apps_name;

    SELECT app_category, filename, size, download_url
    FROM public.work_log_releases
    ORDER BY app_category;
    """
    ver = subprocess.run(
        [str(PSQL_PATH), db_url, "-v", "ON_ERROR_STOP=1", "-c", verify_sql],
        env=proc_env,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    print("\n=== DATABASE VERIFICATION ===")
    print(ver.stdout)
    if ver.returncode != 0:
        print(ver.stderr, file=sys.stderr)
        return ver.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
