-- ============================================================
-- 34_SqlAgentJobs_Analytics.sql
-- Task 19 - Scheduled reporting maintenance (SQL Server Agent).
-- Uses the TSQL subsystem directly against EDIP - no Worker exe.
-- Requires the SQL Server Agent service to be running.
-- ============================================================
USE msdb;
GO

-- ------------------------------------------------------------
-- Job 1: refresh reporting summaries + trend snapshots (nightly)
-- ------------------------------------------------------------
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_RefreshAnalyticsSummary')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_RefreshAnalyticsSummary';

DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_RefreshAnalyticsSummary',
    @enabled = 1,
    @description = N'Rebuilds analytics.ReportingDailyMetric (trailing 10 days) and quality trend snapshots.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Refresh daily metrics',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'DECLARE @From DATE = DATEADD(DAY, -10, CAST(SYSUTCDATETIME() AS DATE));
EXEC analytics.usp_RefreshDailyMetrics @FromDate = @From, @ToDate = NULL;',
    @on_success_action = 3,   -- go to next step
    @on_fail_action = 2;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Snapshot quality trend',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'DECLARE @From DATE = DATEADD(DAY, -120, CAST(SYSUTCDATETIME() AS DATE));
EXEC analytics.usp_SnapshotQualityTrend @FromDate = @From, @ToDate = NULL;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Analytics_Daily_0215')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Analytics_Daily_0215',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 1, @active_start_time = 21500;  -- 02:15

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_RefreshAnalyticsSummary', @schedule_name = N'EDIP_Analytics_Daily_0215';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_RefreshAnalyticsSummary', @server_name = N'(LOCAL)';
GO

-- ------------------------------------------------------------
-- Job 2: prune obsolete reporting rows (weekly)
-- ------------------------------------------------------------
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_AnalyticsCleanup')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_AnalyticsCleanup';

DECLARE @CleanupId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_AnalyticsCleanup',
    @enabled = 1,
    @description = N'Purges analytics reporting rows and refresh logs older than the retention window.',
    @owner_login_name = N'sa',
    @job_id = @CleanupId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @CleanupId,
    @step_name = N'Cleanup analytics data',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC analytics.usp_CleanupAnalyticsData @RetainDays = 400;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Analytics_WeeklyCleanup')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Analytics_WeeklyCleanup',
        @freq_type = 8, @freq_interval = 1, @freq_recurrence_factor = 1,
        @freq_subday_type = 1, @active_start_time = 30000;  -- Sunday 03:00

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_AnalyticsCleanup', @schedule_name = N'EDIP_Analytics_WeeklyCleanup';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_AnalyticsCleanup', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP analytics Agent jobs created (EDIP_RefreshAnalyticsSummary, EDIP_AnalyticsCleanup).';
GO
