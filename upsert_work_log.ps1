param (
    [string]$JsonFile,
    [string]$Json,
    [ValidateSet('production', 'staging')]
    [string]$Env = 'production'
)

$scriptPath = Join-Path $PSScriptRoot "scripts\upsert_work_log.py"
if (-not (Test-Path $scriptPath)) {
    Write-Error "upsert_work_log.py not found at $scriptPath"
    exit 1
}

if ($JsonFile) {
    python $scriptPath --json-file $JsonFile --env $Env
} elseif ($Json) {
    python $scriptPath --json $Json --env $Env
} else {
    Write-Error "Provide either -JsonFile or -Json"
    exit 1
}

exit $LASTEXITCODE
