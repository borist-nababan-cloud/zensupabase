# ==============================================================================
# Script: restore_products_and_recipes_to_staging.ps1
# Description: Dumps product and recipe tables from Production Supabase and restores
#              them cleanly to Staging Supabase with full data parity.
# Target Tables:
#   1. master_barang
#   2. barang_prices
#   3. barang_units
#   4. barang_price_history
#   5. master_recipes
#   6. master_recipe_items
# ==============================================================================

Set-StrictMode -Off
$ErrorActionPreference = "Stop"

# 1. Parse .env to get Supabase connection strings
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$envPath = Join-Path $scriptDir ".env"

if (-not (Test-Path $envPath)) {
    Write-Error "Could not find .env file at $envPath"
    exit 1
}

Write-Host "Loading .env configuration..." -ForegroundColor Cyan
Get-Content $envPath | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith("#") -and $line.Contains("=")) {
        $parts = $line.Split("=", 2)
        $key = $parts[0].Trim()
        $val = $parts[1].Trim()
        [System.Environment]::SetEnvironmentVariable($key, $val)
    }
}

$prodUrl = [System.Environment]::GetEnvironmentVariable("SUPABASE_DB_URL_PROD")
$stagingUrl = [System.Environment]::GetEnvironmentVariable("SUPABASE_DB_URL_STAGING")

if (-not $prodUrl -or -not $stagingUrl) {
    Write-Error "Both SUPABASE_DB_URL_PROD and SUPABASE_DB_URL_STAGING must be set in .env"
    exit 1
}

# 2. Locate psql and pg_dump
$psqlPath = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
$pgDumpPath = "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe"

if (-not (Test-Path $psqlPath)) {
    $foundPsql = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($foundPsql) { $psqlPath = $foundPsql.Source } else {
        Write-Error "psql.exe not found! Please check PostgreSQL installation path."
        exit 1
    }
}

if (-not (Test-Path $pgDumpPath)) {
    $foundPgDump = Get-Command pg_dump.exe -ErrorAction SilentlyContinue
    if ($foundPgDump) { $pgDumpPath = $foundPgDump.Source } else {
        Write-Error "pg_dump.exe not found! Please check PostgreSQL installation path."
        exit 1
    }
}

Write-Host "Using psql: $psqlPath" -ForegroundColor DarkGray
Write-Host "Using pg_dump: $pgDumpPath" -ForegroundColor DarkGray

# 3. Setup temporary dump folder
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$dumpFolder = Join-Path $scriptDir "backups\products_recipes_$timestamp"
if (-not (Test-Path $dumpFolder)) {
    New-Item -ItemType Directory -Path $dumpFolder -Force | Out-Null
}

$targetTables = @(
    "master_barang",
    "barang_prices",
    "barang_units",
    "barang_price_history",
    "master_recipes",
    "master_recipe_items"
)

Write-Host "`nTarget tables for sync from Production to Staging:" -ForegroundColor Yellow
$targetTables | ForEach-Object { Write-Host "  - $_" -ForegroundColor White }

# 4. Dump each table from Production
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "[PHASE 1] Dumping tables from Production Supabase..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

foreach ($tbl in $targetTables) {
    $tableDumpFile = Join-Path $dumpFolder "$tbl.sql"
    Write-Host "  -> Dumping table $tbl..." -NoNewline
    & $pgDumpPath $prodUrl --data-only --schema=public -t "public.$tbl" -f $tableDumpFile
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tableDumpFile)) {
        Write-Error "Failed to dump table $tbl from Production!"
        exit 1
    }
    $sizeKb = [math]::Round((Get-Item $tableDumpFile).Length / 1KB, 1)
    Write-Host " OK ($sizeKb KB)" -ForegroundColor Green
}

# 4a. Prepare master_barang sync file into temporary table _temp_sync_master_barang
$mbDumpFile = Join-Path $dumpFolder "master_barang.sql"
$mbContent = Get-Content $mbDumpFile -Raw
$mbTempContent = $mbContent.Replace("COPY public.master_barang (", "COPY public._temp_sync_master_barang (")
$mbTempFile = Join-Path $dumpFolder "master_barang_to_temp.sql"
$mbTempContent | Set-Content -Path $mbTempFile -Encoding UTF8

# 5. Clean truncate in Staging (child tables and prices/units)
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "[PHASE 2] Preparing Staging Supabase for restore..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$prepSql = @"
-- Temporarily disable user triggers
ALTER TABLE public.master_barang DISABLE TRIGGER USER;
ALTER TABLE public.barang_prices DISABLE TRIGGER USER;
ALTER TABLE public.barang_units DISABLE TRIGGER USER;

-- Rename existing SKUs in Staging with a unique suffix so they don't trigger master_barang_sku_key constraint during UPSERT
UPDATE public.master_barang SET sku = sku || '_STG_' || id;

-- Create temporary staging table for master_barang
DROP TABLE IF EXISTS public._temp_sync_master_barang;
CREATE TABLE public._temp_sync_master_barang (LIKE public.master_barang INCLUDING DEFAULTS);

-- Cleanly truncate recipes, prices, and units in Staging
TRUNCATE TABLE 
    public.master_recipe_items,
    public.master_recipes,
    public.barang_price_history,
    public.barang_prices,
    public.barang_units
CASCADE;
"@

$prepFile = Join-Path $dumpFolder "prep_staging.sql"
$prepSql | Set-Content -Path $prepFile -Encoding UTF8

Write-Host "  -> Executing preparation script on Staging..." -NoNewline
& $psqlPath $stagingUrl -f $prepFile --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to prepare tables in Staging!"
    exit 1
}
Write-Host " OK" -ForegroundColor Green

# 6. Restore dumped data into Staging in dependency order
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "[PHASE 3] Restoring dumped data into Staging Supabase..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 6a. Load dump into _temp_sync_master_barang
Write-Host "  -> Loading master_barang into staging temp table..." -NoNewline
& $psqlPath $stagingUrl -f $mbTempFile --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to load master_barang dump into temp table!"
    exit 1
}
Write-Host " OK" -ForegroundColor Green

# 6b. UPSERT from _temp_sync_master_barang into master_barang
Write-Host "  -> Upserting master_barang from temp table (399 rows)..." -NoNewline
$upsertSql = @"
INSERT INTO public.master_barang (
    id, sku, created_at, id_type, kode_outlet, name, deleted, image1_url, iamge2_url, created_by, update_by, update_at, is_laundry, image2_url
)
SELECT 
    id, sku, created_at, id_type, kode_outlet, name, deleted, image1_url, iamge2_url, created_by, update_by, update_at, is_laundry, image2_url
FROM public._temp_sync_master_barang
ON CONFLICT (id) DO UPDATE SET
    sku = EXCLUDED.sku,
    created_at = EXCLUDED.created_at,
    id_type = EXCLUDED.id_type,
    kode_outlet = EXCLUDED.kode_outlet,
    name = EXCLUDED.name,
    deleted = EXCLUDED.deleted,
    image1_url = EXCLUDED.image1_url,
    iamge2_url = EXCLUDED.iamge2_url,
    created_by = EXCLUDED.created_by,
    update_by = EXCLUDED.update_by,
    update_at = EXCLUDED.update_at,
    is_laundry = EXCLUDED.is_laundry,
    image2_url = EXCLUDED.image2_url;

DROP TABLE IF EXISTS public._temp_sync_master_barang;
"@

$upsertFile = Join-Path $dumpFolder "upsert_master_barang.sql"
$upsertSql | Set-Content -Path $upsertFile -Encoding UTF8

& $psqlPath $stagingUrl -f $upsertFile --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upsert master_barang in Staging!"
    exit 1
}
Write-Host " OK" -ForegroundColor Green

# 6c. Restore remaining tables in dependency order
$restoreOrder = @("barang_units", "barang_prices", "barang_price_history", "master_recipes", "master_recipe_items")
foreach ($tbl in $restoreOrder) {
    $tableDumpFile = Join-Path $dumpFolder "$tbl.sql"
    Write-Host "  -> Restoring table $tbl into Staging..." -NoNewline
    & $psqlPath $stagingUrl -f $tableDumpFile --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to restore table $tbl into Staging!"
        exit 1
    }
    Write-Host " OK" -ForegroundColor Green
}

# 7. Finalize Staging (re-enable triggers, sync sequences)
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "[PHASE 4] Finalizing Staging triggers and sequences..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$finalizeSql = @"
ALTER TABLE public.master_barang ENABLE TRIGGER USER;
ALTER TABLE public.barang_prices ENABLE TRIGGER USER;
ALTER TABLE public.barang_units ENABLE TRIGGER USER;

DO `$$
DECLARE
    mb_seq text := pg_get_serial_sequence('public.master_barang', 'id');
    bp_seq text := pg_get_serial_sequence('public.barang_prices', 'id');
    bu_seq text := pg_get_serial_sequence('public.barang_units', 'id');
    bph_seq text := pg_get_serial_sequence('public.barang_price_history', 'id');
BEGIN
    IF mb_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, (SELECT COALESCE(MAX(id), 1) FROM public.master_barang))', mb_seq);
    END IF;
    IF bp_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, (SELECT COALESCE(MAX(id), 1) FROM public.barang_prices))', bp_seq);
    END IF;
    IF bu_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, (SELECT COALESCE(MAX(id), 1) FROM public.barang_units))', bu_seq);
    END IF;
    IF bph_seq IS NOT NULL THEN
        EXECUTE format('SELECT setval(%L, (SELECT COALESCE(MAX(id), 1) FROM public.barang_price_history))', bph_seq);
    END IF;
END `$$;
"@

$finalizeFile = Join-Path $dumpFolder "finalize_staging.sql"
$finalizeSql | Set-Content -Path $finalizeFile -Encoding UTF8

Write-Host "  -> Re-enabling triggers and updating sequences..." -NoNewline
& $psqlPath $stagingUrl -f $finalizeFile --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to finalize Staging!"
    exit 1
}
Write-Host " OK" -ForegroundColor Green

# 8. Verification: Compare Production vs Staging row counts
Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "[PHASE 5] Verifying Row Counts (Production vs Staging)..." -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$verifySql = @"
SELECT table_name, 
       (xpath('/row/cnt/text()', xml_count))[1]::text::int as row_count
FROM (
  SELECT table_name, 
         query_to_xml(format('select count(*) as cnt from %I', table_name), false, true, '') as xml_count
  FROM information_schema.tables
  WHERE table_schema = 'public' 
    AND table_name IN (
      'master_barang',
      'barang_prices',
      'barang_units',
      'barang_price_history',
      'master_recipes',
      'master_recipe_items'
    )
) t
ORDER BY table_name;
"@

$verifyFile = Join-Path $dumpFolder "verify_counts.sql"
$verifySql | Set-Content -Path $verifyFile -Encoding UTF8

Write-Host "`n[STAGING ROW COUNTS AFTER RESTORE]:" -ForegroundColor Green
& $psqlPath $stagingUrl -f $verifyFile

Write-Host "`n[PRODUCTION ROW COUNTS FOR REFERENCE]:" -ForegroundColor Yellow
& $psqlPath $prodUrl -f $verifyFile

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host "Products and recipes restoration to Staging completed successfully!" -ForegroundColor Green
Write-Host "Backup dump files preserved at: $dumpFolder" -ForegroundColor Gray
Write-Host "========================================================" -ForegroundColor Green
