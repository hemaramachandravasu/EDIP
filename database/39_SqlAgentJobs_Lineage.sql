-- ============================================================
-- 39_SqlAgentJobs_Lineage.sql
-- SQL Server Agent jobs for lineage sync / archive (T-SQL subsystem)
-- ============================================================
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_SyncPlatformLineage')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_SyncPlatformLineage';

DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_SyncPlatformLineage',
    @enabled = 1,
    @description = N'EDIP: sync lineage from imports/ETL/profile into lineage schema.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Sync platform lineage',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC lineage.usp_SyncPlatformLineage @CreatedBy = N''Agent'', @MaxBatches = 200;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Lineage_HourlySync')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Lineage_HourlySync',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 8, @freq_subday_interval = 1,
        @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_SyncPlatformLineage', @schedule_name = N'EDIP_Lineage_HourlySync';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_SyncPlatformLineage', @server_name = N'(LOCAL)';
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ArchiveLineageHistory')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ArchiveLineageHistory';

DECLARE @ArchId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ArchiveLineageHistory',
    @enabled = 1,
    @description = N'EDIP: archive old lineage capture logs.',
    @owner_login_name = N'sa',
    @job_id = @ArchId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @ArchId,
    @step_name = N'Archive lineage capture logs',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC lineage.usp_ArchiveLineageHistory @RetainDays = 365;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Lineage_WeeklyArchive')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Lineage_WeeklyArchive',
        @freq_type = 8, @freq_interval = 1,
        @freq_recurrence_factor = 1,
        @freq_subday_type = 1, @active_start_time = 43000;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_ArchiveLineageHistory', @schedule_name = N'EDIP_Lineage_WeeklyArchive';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_ArchiveLineageHistory', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP lineage Agent jobs created.';
GO
