# Optional helper: deploy core SQL scripts with sqlcmd (Windows Integrated auth)
param(
    [string]$Server = "localhost",
    [string]$ScriptRoot = (Join-Path $PSScriptRoot "..")
)

$ErrorActionPreference = "Stop"
$scripts = @(
    "01_CreateDatabase.sql",
    "02_Schema_Registry.sql",
    "03_Schema_Metadata.sql",
    "04_Schema_Processing.sql",
    "05_Schema_Monitoring.sql",
    "06_StoredProcedures.sql",
    "07_Views_Reports.sql",
    "08_SeedData.sql",
    "10_Schema_Quality.sql",
    "11_Procs_Quality.sql",
    "12_Views_Quality.sql",
    "13_Seed_Quality.sql"
)

$dbDir = Join-Path $ScriptRoot "database"
foreach ($file in $scripts) {
    $path = Join-Path $dbDir $file
    Write-Host "Running $file ..."
    & sqlcmd -S $Server -E -C -I -b -i $path
    if ($LASTEXITCODE -ne 0) { throw "Failed on $file" }
}

Write-Host "Core EDIP database deployment complete."
Write-Host "Publish Edip.Worker, then run database\09_SqlAgentJobs.sql."
