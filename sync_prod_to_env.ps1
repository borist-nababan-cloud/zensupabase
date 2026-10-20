param (
    [Parameter(Mandatory = $false)]
    [ValidateSet('local', 'staging', 'all')]
    [string]$Target = 'all'
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$envFilePath = Join-Path $scriptRoot ".env"

if (-not (Test-Path $envFilePath)) {
    Write-Error ".env file not found in $scriptRoot"
    exit 1
}

# 1. Load environment variables
Write-Host "Loading .env configuration..." -ForegroundColor Cyan
Get-Content $envFilePath | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
    $name, $value = $_.Split('=', 2)
    [System.Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), [System.EnvironmentVariableTarget]::Process)
}

$prodUrl = [System.Environment]::GetEnvironmentVariable('SUPABASE_DB_URL_PROD')
$stagingUrl = [System.Environment]::GetEnvironmentVariable('SUPABASE_DB_URL_STAGING')
$localUrl = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"

if (-not $prodUrl) {
    Write-Error "SUPABASE_DB_URL_PROD is not set in .env!"
    exit 1
}

# Locate psql
$psqlPath = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
if (-not (Test-Path $psqlPath)) {
    $foundPsql = Get-Command psql.exe -ErrorAction SilentlyContinue
    if ($foundPsql) {
        $psqlPath = $foundPsql.Source
    } else {
        Write-Error "psql.exe not found on system!"
        exit 1
    }
}
Write-Host "Using PSQL binary: $psqlPath" -ForegroundColor Green

# Locate Supabase CLI
$supabaseCli = Join-Path $scriptRoot "node_modules\supabase\bin\supabase.exe"
if (-not (Test-Path $supabaseCli)) {
    $supabaseCli = "supabase"
}

# 2. Ensure backups directory
$backupsDir = Join-Path $scriptRoot "backups"
if (-not (Test-Path $backupsDir)) {
    New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$dumpFile = Join-Path $backupsDir "prod_public_data_$timestamp.sql"
$truncateFile = Join-Path $backupsDir "temp_truncate.sql"

# 3. Create Truncate Script
@'
DO $$ 
DECLARE 
    tbls text;
BEGIN
    SELECT string_agg(quote_ident(schemaname) || '.' || quote_ident(tablename), ', ')
    INTO tbls
    FROM pg_tables 
    WHERE schemaname = 'public' 
      AND tablename NOT IN ('schema_migrations', 'spatial_ref_sys', 'supabase_migrations', 'migration_locks');
    
    IF tbls IS NOT NULL THEN
        EXECUTE 'TRUNCATE TABLE ' || tbls || ' CASCADE;';
    END IF;
END $$;
'@ | Set-Content -Path $truncateFile -Encoding UTF8

# 4. Dump Production Data
Write-Host "`n[STEP 1/3] Dumping Full Public Data from Production Supabase..." -ForegroundColor Yellow
Write-Host "Target Dump File: $dumpFile"
& $supabaseCli db dump --db-url $prodUrl --data-only --schema public -f $dumpFile

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $dumpFile)) {
    Write-Error "Failed to dump production database!"
    exit 1
}

$dumpSizeMb = [math]::Round((Get-Item $dumpFile).Length / 1MB, 2)
Write-Host "Production dump successfully created ($dumpSizeMb MB)." -ForegroundColor Green

# Function to Restore
function Restore-ToDb {
    param (
        [string]$EnvName,
        [string]$DbUrl
    )

    Write-Host "`n[RESTORING] Synchronizing $EnvName database with Production data..." -ForegroundColor Yellow
    
    # a. Truncate
    Write-Host "  -> Truncating existing public tables in $EnvName..."
    & $psqlPath $DbUrl -f $truncateFile --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to truncate tables in $EnvName!"
        return
    }

    # b. Load Dump
    Write-Host "  -> Inserting Production records into $EnvName..."
    & $psqlPath $DbUrl -f $dumpFile --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to restore data into $EnvName!"
        return
    }

    # c. Verification
    Write-Host "  -> Verifying counts in ${EnvName}:" -ForegroundColor Cyan
    & $psqlPath $DbUrl -c "SELECT 'master_outlet' as tbl, count(*) FROM master_outlet UNION ALL SELECT 'ot_pos_trans_master', count(*) FROM ot_pos_trans_master UNION ALL SELECT 'ot_pos_trans_detail', count(*) FROM ot_pos_trans_detail UNION ALL SELECT 'ot_pos_trans_payment', count(*) FROM ot_pos_trans_payment UNION ALL SELECT 'ot_pos_trans_reject', count(*) FROM ot_pos_trans_reject UNION ALL SELECT 'ot_hrd_karyawan_info', count(*) FROM ot_hrd_karyawan_info UNION ALL SELECT 'ot_hrd_absen_harian', count(*) FROM ot_hrd_absen_harian UNION ALL SELECT 'ot_master_room', count(*) FROM ot_master_room;"
    
    Write-Host "Restore to $EnvName completed successfully! OK" -ForegroundColor Green
}

# 5. Execute Restore based on Target
if ($Target -eq 'local' -or $Target -eq 'all') {
    Restore-ToDb -EnvName "Local (127.0.0.1:54322)" -DbUrl $localUrl
}

if ($Target -eq 'staging' -or $Target -eq 'all') {
    if (-not $stagingUrl) {
        Write-Error "SUPABASE_DB_URL_STAGING is not set in .env!"
    } else {
        Restore-ToDb -EnvName "Staging Cloud (okchlapizmhoueeeldrh)" -DbUrl $stagingUrl
    }
}

# Clean temp truncate script
if (Test-Path $truncateFile) {
    Remove-Item $truncateFile -Force
}

Write-Host "`nAll operations completed successfully! Production data synchronized to $Target." -ForegroundColor Green
