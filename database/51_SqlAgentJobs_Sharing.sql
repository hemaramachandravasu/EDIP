-- ============================================================
-- 51_SqlAgentJobs_Sharing.sql
-- ============================================================
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ExpireDatasetShares')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ExpireDatasetShares';

DECLARE @JobId UNIQUEIDENTIFIER;
EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ExpireDatasetShares',
    @enabled = 1,
    @description = N'EDIP: persist Expired status for dataset shares past their expiry.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Expire dataset shares',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC share.usp_ExpireDatasetShares;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Share_Hourly')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Share_Hourly',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 8, @freq_subday_interval = 1,
        @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_ExpireDatasetShares', @schedule_name = N'EDIP_Share_Hourly';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_ExpireDatasetShares', @server_name = N'(LOCAL)';
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_CleanupStaleExports')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_CleanupStaleExports';

DECLARE @CleanId UNIQUEIDENTIFIER;
EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_CleanupStaleExports',
    @enabled = 1,
    @description = N'EDIP: fail timed-out Processing exports and cancel abandoned Pending exports.',
    @owner_login_name = N'sa',
    @job_id = @CleanId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @CleanId,
    @step_name = N'Cleanup stale exports',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC share.usp_CleanupStaleExports @ProcessingTimeoutMinutes = 120, @PendingTimeoutHours = 72;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Share_Every15Min')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Share_Every15Min',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 4, @freq_subday_interval = 15,
        @active_start_time = 0;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_CleanupStaleExports', @schedule_name = N'EDIP_Share_Every15Min';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_CleanupStaleExports', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP sharing/export Agent jobs created.';
GO
