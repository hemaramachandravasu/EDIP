-- ============================================================
-- 29_SqlAgentJobs_Profile.sql
-- Scheduled dataset quality profiling and history archive
-- ============================================================
USE msdb;
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_DatasetQualityProfile')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_DatasetQualityProfile';

DECLARE @JobId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_DatasetQualityProfile',
    @enabled = 1,
    @description = N'Profiles enabled ingest datasets and stores quality metrics.',
    @owner_login_name = N'sa',
    @job_id = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @JobId,
    @step_name = N'Profile due datasets',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'
-- Ensure catalog rows exist, then profile
INSERT INTO profile.DatasetProfile (DatasetId, ProfileScope)
SELECT d.DatasetId, N''Processed''
FROM ingest.Dataset d
WHERE d.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM profile.DatasetProfile p WHERE p.DatasetId = d.DatasetId);

EXEC profile.usp_ProfileDueDatasets @MaxDatasets = 25;
',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Profile_Daily')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Profile_Daily',
        @freq_type = 4, @freq_interval = 1,
        @freq_subday_type = 1, @active_start_time = 30000; -- 03:00

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_DatasetQualityProfile', @schedule_name = N'EDIP_Profile_Daily';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_DatasetQualityProfile', @server_name = N'(LOCAL)';
GO

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'EDIP_ArchiveProfileHistory')
    EXEC msdb.dbo.sp_delete_job @job_name = N'EDIP_ArchiveProfileHistory';

DECLARE @ArchId UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name = N'EDIP_ArchiveProfileHistory',
    @enabled = 1,
    @description = N'Archives aged dataset quality profile runs.',
    @owner_login_name = N'sa',
    @job_id = @ArchId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id = @ArchId,
    @step_name = N'Archive profile history',
    @subsystem = N'TSQL',
    @database_name = N'EDIP',
    @command = N'EXEC profile.usp_ArchiveProfileHistory @RetainDays = 180;',
    @on_success_action = 1,
    @on_fail_action = 2;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = N'EDIP_Profile_WeeklyArchive')
    EXEC msdb.dbo.sp_add_schedule
        @schedule_name = N'EDIP_Profile_WeeklyArchive',
        @freq_type = 8, @freq_interval = 1,
        @freq_recurrence_factor = 1,
        @freq_subday_type = 1, @active_start_time = 40000;

EXEC msdb.dbo.sp_attach_schedule @job_name = N'EDIP_ArchiveProfileHistory', @schedule_name = N'EDIP_Profile_WeeklyArchive';
EXEC msdb.dbo.sp_add_jobserver @job_name = N'EDIP_ArchiveProfileHistory', @server_name = N'(LOCAL)';
GO

PRINT 'EDIP profile Agent jobs created.';
GO
