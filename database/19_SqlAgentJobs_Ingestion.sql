-- ============================================================
-- 19_SqlAgentJobs_Ingestion.sql
-- Scheduled validation/processing and archive maintenance
-- Prefer T-SQL steps (no Worker dependency) for ingestion.
-- ============================================================
USE msdb;
GO

/* EDIP_ProcessPendingImports — every 15 minutes */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ProcessPendingImports')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ProcessPendingImports';

DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ProcessPendingImports',
    @enabled = 1,
    @description = N'Validates and processes pending EDIP import batches (retry-safe).',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Process pending batches',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC ingest.usp_ProcessPendingBatches @MaxBatches = 25;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Ingest_Every15Min')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Ingest_Every15Min',
        @freq_type = 4,              -- daily
        @freq_interval = 1,
        @freq_subday_type = 4,       -- minutes
        @freq_subday_interval = 15,
        @active_start_time = 0;
END

EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'EDIP_ProcessPendingImports',
    @schedule_name = N'EDIP_Ingest_Every15Min';

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'EDIP_ProcessPendingImports',
    @server_name = N'(LOCAL)';
GO

/* EDIP_ArchiveImportHistory — daily at 02:00 */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ArchiveImportHistory')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ArchiveImportHistory';

DECLARE @ArchiveJobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ArchiveImportHistory',
    @enabled = 1,
    @description = N'Archives completed EDIP import batches older than retention.',
    @owner_login_name = N'sa',
    @job_id = @ArchiveJobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @ArchiveJobId,
    @step_name = N'Archive import history',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC ingest.usp_ArchiveImportHistory @RetainDays = 90;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Ingest_DailyArchive')
BEGIN
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Ingest_DailyArchive',
        @freq_type = 4,
        @freq_interval = 1,
        @freq_subday_type = 1,
        @active_start_time = 20000; -- 02:00
END

EXEC msdb.dbo.sp_attach_schedule
    @job_name = N'EDIP_ArchiveImportHistory',
    @schedule_name = N'EDIP_Ingest_DailyArchive';

EXEC msdb.dbo.sp_add_jobserver
    @job_name = N'EDIP_ArchiveImportHistory',
    @server_name = N'(LOCAL)';
GO

PRINT 'EDIP ingestion Agent jobs created (T-SQL steps against EDIP database).';
GO
