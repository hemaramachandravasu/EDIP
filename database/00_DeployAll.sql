-- ============================================================
-- 00_DeployAll.sql
-- Runs core scripts in order (Agent job is optional / separate)
-- ============================================================
:r .\01_CreateDatabase.sql
:r .\02_Schema_Registry.sql
:r .\03_Schema_Metadata.sql
:r .\04_Schema_Processing.sql
:r .\05_Schema_Monitoring.sql
:r .\06_StoredProcedures.sql
:r .\07_Views_Reports.sql
:r .\08_SeedData.sql
:r .\10_Schema_Quality.sql
:r .\11_Procs_Quality.sql
:r .\12_Views_Quality.sql
:r .\13_Seed_Quality.sql
:r .\15_Schema_Ingestion.sql
:r .\16_Procs_Ingestion.sql
:r .\17_Views_Ingestion.sql
:r .\18_Seed_Ingestion.sql

PRINT 'EDIP core + quality + ingestion deployment complete. Run 09/14/19 Agent scripts after publishing Edip.Worker.';
GO
