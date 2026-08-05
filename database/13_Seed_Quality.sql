-- ============================================================
-- 13_Seed_Quality.sql
-- Seed DQ jobs for local catalog
-- ============================================================
USE EDIP;
GO

DECLARE @LocalSql UNIQUEIDENTIFIER = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
DECLARE @ProfileJob UNIQUEIDENTIFIER = 'EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE';
DECLARE @QualityJob UNIQUEIDENTIFIER = 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF';
DECLARE @SyncJob UNIQUEIDENTIFIER = '11111111-1111-1111-1111-111111111111';
DECLARE @ArchiveJob UNIQUEIDENTIFIER = '22222222-2222-2222-2222-222222222222';

IF EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @LocalSql)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ProfileJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@ProfileJob, N'Local SQL Data Profiling', N'Scheduled profiling of local catalog', @LocalSql, N'DataProfiling', 1, 2, 90);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ProfileJob, N'Daily', 1440, DATEADD(MINUTE, 15, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @QualityJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@QualityJob, N'Local SQL Quality Assessment', N'Runs quality scoring after profiling', @LocalSql, N'QualityAssessment', 1, 2, 90);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @QualityJob, N'Daily', 1440, DATEADD(MINUTE, 30, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @SyncJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@SyncJob, N'Local SQL Metadata Sync', N'Synchronizes metadata and detects schema changes', @LocalSql, N'MetadataSync', 1, 2, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @SyncJob, N'Hourly', 60, DATEADD(MINUTE, 20, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ArchiveJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@ArchiveJob, N'Archive Profiling History', N'Purges DQ history older than retention window', @LocalSql, N'ArchiveProfilingHistory', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ArchiveJob, N'Weekly', 10080, DATEADD(DAY, 1, SYSUTCDATETIME()), 1);
    END
END
GO

PRINT 'Quality seed jobs applied.';
GO
