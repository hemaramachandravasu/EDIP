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
    "13_Seed_Quality.sql",
    "15_Schema_Ingestion.sql",
    "16_Procs_Ingestion.sql",
    "17_Views_Ingestion.sql",
    "18_Seed_Ingestion.sql",
    "20_Schema_Etl.sql",
    "21_Procs_Etl.sql",
    "22_Views_Etl.sql",
    "23_Seed_Etl.sql",
    "25_Schema_Profile.sql",
    "26_Procs_Profile.sql",
    "27_Views_Profile.sql",
    "28_Seed_Profile.sql",
    "30_Schema_Analytics.sql",
    "31_Procs_Analytics.sql",
    "32_Views_Analytics.sql",
    "33_Seed_Analytics.sql",
    "35_Schema_Lineage.sql",
    "36_Procs_Lineage.sql",
    "37_Views_Lineage.sql",
    "38_Seed_Lineage.sql"
)

$dbDir = Join-Path $ScriptRoot "database"
foreach ($file in $scripts) {
    $path = Join-Path $dbDir $file
    Write-Host "Running $file ..."
    & sqlcmd -S $Server -E -C -I -b -i $path
    if ($LASTEXITCODE -ne 0) { throw "Failed on $file" }
}

Write-Host "Core EDIP database deployment complete (registry, metadata, jobs, quality, ingestion, ETL, profile, analytics, lineage)."
Write-Host "Publish Edip.Worker, then run database\09_SqlAgentJobs.sql, 14_SqlAgentJobs_Quality.sql, 19_SqlAgentJobs_Ingestion.sql, 24_SqlAgentJobs_Etl.sql, 29_SqlAgentJobs_Profile.sql, 39_SqlAgentJobs_Lineage.sql."
Write-Host "database\34_SqlAgentJobs_Analytics.sql runs standalone (TSQL subsystem - no Worker needed)."
