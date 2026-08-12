-- ============================================================
-- 18_Seed_Ingestion.sql
-- Reference data, sample staging load, validation test scenarios
-- ============================================================
USE EDIP;
GO

-- Countries for RI checks
MERGE ingest.Country AS t
USING (VALUES
    (N'US', N'United States'),
    (N'UK', N'United Kingdom'),
    (N'DE', N'Germany'),
    (N'IN', N'India'),
    (N'CA', N'Canada'),
    (N'FR', N'France'),
    (N'AU', N'Australia')
) AS s (CountryCode, CountryName)
ON t.CountryCode = s.CountryCode
WHEN MATCHED THEN UPDATE SET CountryName = s.CountryName, IsActive = 1
WHEN NOT MATCHED THEN INSERT (CountryCode, CountryName) VALUES (s.CountryCode, s.CountryName);
GO

DECLARE @CustomerDataset UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @CustomerDataset)
BEGIN
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable)
    VALUES (
        @CustomerDataset,
        N'CUSTOMER',
        N'Customer Master',
        N'Staged customer imports with validation into ingest.Customer',
        N'ingest.StagingCustomer',
        N'ingest.Customer'
    );
END
GO

-- Seed job definitions for Agent / Worker automation
DECLARE @SampleCsv UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';
DECLARE @ProcessImportsJob UNIQUEIDENTIFIER = '44444444-4444-4444-4444-444444444444';
DECLARE @ArchiveImportsJob UNIQUEIDENTIFIER = '55555555-5555-5555-5555-555555555555';

IF EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @SampleCsv)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ProcessImportsJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob
            (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES
            (@ProcessImportsJob, N'Process Pending Import Batches',
             N'Validates and processes Loaded/RetryPending import batches',
             @SampleCsv, N'ProcessPendingImports', 1, 2, 60);

        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ProcessImportsJob, N'Hourly', 60, DATEADD(MINUTE, 5, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ArchiveImportsJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob
            (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES
            (@ArchiveImportsJob, N'Archive Import History',
             N'Purges completed import batches older than retention window',
             @SampleCsv, N'ArchiveImportHistory', 1, 1, 60);

        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ArchiveImportsJob, N'Weekly', 10080, DATEADD(DAY, 1, SYSUTCDATETIME()), 1);
    END
END
GO

-- ------------------------------------------------------------
-- Demo batch with mixed valid / invalid rows (test scenarios)
-- ------------------------------------------------------------
DECLARE @DatasetId UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @DemoBatch UNIQUEIDENTIFIER = '66666666-6666-6666-6666-666666666666';
DECLARE @CsvSource UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';

IF NOT EXISTS (SELECT 1 FROM ingest.ImportBatch WHERE BatchId = @DemoBatch)
   AND EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @DatasetId)
BEGIN
    INSERT INTO ingest.ImportBatch
        (BatchId, DatasetId, DataSourceId, SourceInfo, Status)
    VALUES
        (@DemoBatch, @DatasetId, @CsvSource, N'samples/customers_ingest_demo.csv', N'Pending');

    INSERT INTO ingest.StagingCustomer
    (
        BatchId, DatasetId, RowNumber,
        RawCustomerCode, RawCustomerName, RawCountryCode, RawEmail,
        RawCreditLimit, RawStatus, RawCreatedDate, SourceInfo
    )
    VALUES
        -- Valid rows
        (@DemoBatch, @DatasetId, 1, N'CUST-001', N'Acme Corp', N'US', N'ops@acme.example', N'10000', N'Active', N'2024-01-15', N'demo'),
        (@DemoBatch, @DatasetId, 2, N'CUST-002', N'Globex', N'UK', N'info@globex.example', N'25000', N'Active', N'2024-02-20', N'demo'),
        (@DemoBatch, @DatasetId, 3, N'CUST-003', N'Initech', N'US', N'hello@initech.example', N'5000', N'Prospect', N'2024-03-01', N'demo'),
        -- Required field missing
        (@DemoBatch, @DatasetId, 4, NULL, N'No Code Inc', N'US', N'a@b.com', N'100', N'Active', N'2024-01-01', N'demo'),
        -- Invalid country (RI)
        (@DemoBatch, @DatasetId, 5, N'CUST-005', N'Unknown Land', N'ZZ', N'zz@example.com', N'100', N'Active', N'2024-01-01', N'demo'),
        -- Invalid email + negative credit
        (@DemoBatch, @DatasetId, 6, N'CUST-006', N'Bad Email Co', N'DE', N'not-an-email', N'-50', N'Active', N'2024-01-01', N'demo'),
        -- Duplicate in batch
        (@DemoBatch, @DatasetId, 7, N'CUST-001', N'Acme Duplicate', N'US', N'dup@acme.example', N'1', N'Active', N'2024-01-15', N'demo'),
        -- Invalid date type
        (@DemoBatch, @DatasetId, 8, N'CUST-008', N'Bad Date LLC', N'CA', N'date@example.com', N'200', N'Active', N'not-a-date', N'demo'),
        -- Invalid status
        (@DemoBatch, @DatasetId, 9, N'CUST-009', N'Weird Status', N'IN', N'status@example.com', N'300', N'Suspended', N'2024-06-01', N'demo'),
        -- Valid update candidate (re-run after seed)
        (@DemoBatch, @DatasetId, 10, N'CUST-010', N'Stark Industries', N'US', N'tony@stark.example', N'99999', N'Active', N'2024-04-02', N'demo');

    EXEC ingest.usp_CompleteStagingLoad @BatchId = @DemoBatch;
    EXEC ingest.usp_ValidateCustomerBatch @BatchId = @DemoBatch;
    EXEC ingest.usp_ProcessCustomerBatch @BatchId = @DemoBatch, @TriggerType = N'Manual';
END
GO

PRINT 'Ingestion seed data and demo batch applied.';
GO
