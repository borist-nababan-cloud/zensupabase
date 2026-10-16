param (
    [Parameter(Mandatory = $true)]
    [ValidateSet('local', 'staging', 'production')]
    [string]$env
)

$envFilePath = Join-Path $PSScriptRoot ".env"

if (Test-Path $envFilePath) {
    Write-Host "Loading .env file..."
    Get-Content $envFilePath | Where-Object { $_ -match '^\s*[^#]' -and $_ -match '=' } | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        $name = $name.Trim()
        $value = $value.Trim()
        [System.Environment]::SetEnvironmentVariable($name, $value, [System.EnvironmentVariableTarget]::Process)
    }
}
else {
    if ($env -ne 'local') {
        Write-Error ".env file not found. It is required for deploying to staging and production."
        exit 1
    }
}

$localBin = Join-Path $PSScriptRoot "node_modules\supabase\bin\supabase.exe"
if (Test-Path $localBin) {
    $supabaseCmd = $localBin
    $prefixArgs = @()
} else {
    $supabaseCmd = "npx"
    $prefixArgs = @("supabase")
}

if ($env -eq 'local') {
    Write-Host "Pushing to Local Supabase..."
    $localDbUrl = "postgresql://postgres:postgres@127.0.0.1:54322/postgres"
    & $supabaseCmd @prefixArgs db push --db-url $localDbUrl --workdir $PSScriptRoot
}
elseif ($env -eq 'staging') {
    $dbUrl = [System.Environment]::GetEnvironmentVariable('SUPABASE_DB_URL_STAGING')
    if (-not $dbUrl) { 
        Write-Error "SUPABASE_DB_URL_STAGING is not set correctly in .env!"
        exit 1 
    }
    
    Write-Host "Pushing to Staging Supabase Cloud..."
    & $supabaseCmd @prefixArgs db push --db-url $dbUrl --workdir $PSScriptRoot
}
elseif ($env -eq 'production') {
    $dbUrl = [System.Environment]::GetEnvironmentVariable('SUPABASE_DB_URL_PROD')
    if (-not $dbUrl) { 
        Write-Error "SUPABASE_DB_URL_PROD is not set correctly in .env!"
        exit 1 
    }
    
    Write-Host "Pushing to Production Supabase Cloud..."
    & $supabaseCmd @prefixArgs db push --db-url $dbUrl --workdir $PSScriptRoot
}

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nDeployment to $env completed successfully! `u{2705}" -ForegroundColor Green
}
else {
    Write-Error "`nDeployment to $env failed with exit code $LASTEXITCODE."
    exit $LASTEXITCODE
}
