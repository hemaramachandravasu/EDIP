-- ============================================================
-- 45_SqlAgentJobs_Governance.sql
-- ============================================================
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ExpireDatasetCertifications')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ExpireDatasetCertifications';

DECLARE @JobId UNIQUEIDENTIFIER;
EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ExpireDatasetCertifications',
    @enabled = 1,
    @description = N'EDIP: expire dataset certifications past expiry date.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Expire certifications',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC gov.usp_ExpireDatasetCertifications;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Gov_DailyExpire')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Gov_DailyExpire',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 1, @active_start_time = 20000;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_ExpireDatasetCertifications', @schedule_name = N'EDIP_Gov_DailyExpire';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_ExpireDatasetCertifications', @server_name = N'(LOCAL)';
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ArchiveGovernanceAudit')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ArchiveGovernanceAudit';

DECLARE @ArchId UNIQUEIDENTIFIER;
EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ArchiveGovernanceAudit',
    @enabled = 1,
    @description = N'EDIP: archive aged governance audit events.',
    @owner_login_name = N'sa',
    @job_id = @ArchId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @ArchId,
    @step_name = N'Archive governance audit',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC gov.usp_ArchiveGovernanceAudit @RetainDays = 730;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Gov_WeeklyArchive')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Gov_WeeklyArchive',
        @freq_type = 8, @freq_interval = 1,
        @freq_recurrence_factor = 1,
        @freq_subday_type = 1, @active_start_time = 23000;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_ArchiveGovernanceAudit', @schedule_name = N'EDIP_Gov_WeeklyArchive';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_ArchiveGovernanceAudit', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP governance Agent jobs created.';
GO
