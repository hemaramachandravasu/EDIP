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
:r .\20_Schema_Etl.sql
:r .\21_Procs_Etl.sql
:r .\22_Views_Etl.sql
:r .\23_Seed_Etl.sql
:r .\25_Schema_Profile.sql
:r .\26_Procs_Profile.sql
:r .\27_Views_Profile.sql
:r .\28_Seed_Profile.sql
:r .\30_Schema_Analytics.sql
:r .\31_Procs_Analytics.sql
:r .\32_Views_Analytics.sql
:r .\33_Seed_Analytics.sql
:r .\35_Schema_Lineage.sql
:r .\36_Procs_Lineage.sql
:r .\37_Views_Lineage.sql
:r .\38_Seed_Lineage.sql

PRINT 'EDIP core + quality + ingestion + ETL + profile + analytics + lineage deployment complete. Run 09/14/19/24/29/39 Agent scripts after publishing Edip.Worker; 34_SqlAgentJobs_Analytics.sql runs standalone (TSQL subsystem).';
GO
