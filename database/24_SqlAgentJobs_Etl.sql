-- ============================================================
-- 24_SqlAgentJobs_Etl.sql
-- Scheduled ETL processing, error archive, cleanup, quality snapshot
-- ============================================================
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_EtlProcessPending')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_EtlProcessPending';

DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_EtlProcessPending',
    @enabled = 1,
    @description = N'Transform, validate, and load pending EDIP ETL batches.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Run ETL pipeline',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC etl.usp_ProcessPendingBatches @MaxBatches = 25;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Etl_Every15Min')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Etl_Every15Min',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 4, @freq_subday_interval = 15,
        @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_EtlProcessPending', @schedule_name = N'EDIP_Etl_Every15Min';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_EtlProcessPending', @server_name = N'(LOCAL)';
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_EtlMaintenance')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_EtlMaintenance';

DECLARE @MaintId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_EtlMaintenance',
    @enabled = 1,
    @description = N'ETL error archival, batch cleanup, and quality snapshot.',
    @owner_login_name = N'sa',
    @job_id = @MaintId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @MaintId, @step_name = N'Archive errors',
    @subsystem = N'TSQL', @database_name = N'EDIP',
    @command = N'EXEC etl.usp_ArchiveErrors @RetainDays = 90;',
    @on_success_action = 3, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @MaintId, @step_name = N'Cleanup batches',
    @subsystem = N'TSQL', @database_name = N'EDIP',
    @command = N'EXEC etl.usp_CleanupBatches @RetainDays = 90;',
    @on_success_action = 3, @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @MaintId, @step_name = N'Quality snapshot',
    @subsystem = N'TSQL', @database_name = N'EDIP',
    @command = N'EXEC etl.usp_GenerateQualitySnapshot;',
    @on_success_action = 1, @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Etl_DailyMaint')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Etl_DailyMaint',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 1, @active_start_time = 23000;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_EtlMaintenance', @schedule_name = N'EDIP_Etl_DailyMaint';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_EtlMaintenance', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP ETL Agent jobs created.';
GO
