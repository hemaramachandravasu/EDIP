-- ============================================================
-- 28_Seed_Profile.sql
-- Score weights, thresholds, dataset profile, demo run
-- ============================================================
USE EDIP;
GO

-- Global score weights (must sum to 100)
IF NOT EXISTS (SELECT 1 FROM profile.ScoreWeight WHERE DatasetId IS NULL AND DimensionCode = N'Completeness')
BEGIN
    INSERT INTO profile.ScoreWeight (DatasetId, DimensionCode, WeightPct)
    VALUES
        (NULL, N'Completeness', 30.00),
        (NULL, N'Validity',     30.00),
        (NULL, N'Uniqueness',   25.00),
        (NULL, N'Consistency',  15.00);
END
GO

-- Global default thresholds
IF NOT EXISTS (SELECT 1 FROM profile.QualityThreshold WHERE DatasetId IS NULL AND MetricCode = N'OVERALL_SCORE')
BEGIN
    INSERT INTO profile.QualityThreshold (DatasetId, MetricCode, OperatorCode, ThresholdValue, Severity)
    VALUES
        (NULL, N'COMPLETENESS_PCT', N'>=', 90.0, N'Error'),
        (NULL, N'VALIDITY_PCT',     N'>=', 95.0, N'Error'),
        (NULL, N'UNIQUENESS_PCT',   N'>=', 98.0, N'Warning'),
        (NULL, N'DUPLICATE_PCT',    N'<=',  2.0, N'Warning'),
        (NULL, N'OVERALL_SCORE',    N'>=', 80.0, N'Critical');
END
GO

DECLARE @CustomerDataset UNIQUEIDENTIFIER =
    (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');

IF @CustomerDataset IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM profile.DatasetProfile WHERE DatasetId = @CustomerDataset)
        INSERT INTO profile.DatasetProfile (DatasetId, ProfileScope, IsEnabled)
        VALUES (@CustomerDataset, N'Processed', 1);

    -- Dataset-specific threshold override example (slightly stricter overall)
    IF NOT EXISTS (SELECT 1 FROM profile.QualityThreshold WHERE DatasetId = @CustomerDataset AND MetricCode = N'OVERALL_SCORE')
        INSERT INTO profile.QualityThreshold (DatasetId, MetricCode, OperatorCode, ThresholdValue, Severity)
        VALUES (@CustomerDataset, N'OVERALL_SCORE', N'>=', 75.0, N'Critical');
END
GO

-- Seed jobs
DECLARE @SampleCsv UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';
DECLARE @ProfileJob UNIQUEIDENTIFIER = 'BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF';
DECLARE @ArchiveJob UNIQUEIDENTIFIER = 'CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA';

IF EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @SampleCsv)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ProfileJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@ProfileJob, N'Dataset Quality Profiling',
                N'Profiles ingest datasets for completeness, uniqueness, validity, and scores',
                @SampleCsv, N'DatasetQualityProfile', 1, 2, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ProfileJob, N'Daily', 1440, DATEADD(MINUTE, 25, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ArchiveJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@ArchiveJob, N'Archive Profile History',
                N'Purges aged dataset quality profile runs',
                @SampleCsv, N'ArchiveProfileHistory', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ArchiveJob, N'Weekly', 10080, DATEADD(DAY, 3, SYSUTCDATETIME()), 1);
    END
END
GO

-- Demo profile run against processed CUSTOMER data
IF EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER')
   AND EXISTS (SELECT 1 FROM ingest.Customer)
BEGIN
    DECLARE @RunId UNIQUEIDENTIFIER;
    EXEC profile.usp_ProfileCustomerDataset
        @DatasetCode = N'CUSTOMER',
        @ProfileScope = N'Processed',
        @TriggerType = N'Manual',
        @ProfileRunId = @RunId OUTPUT;
END
GO

PRINT 'Profile seed data applied.';
GO
