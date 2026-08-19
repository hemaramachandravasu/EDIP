-- ============================================================
-- 23_Seed_Etl.sql
-- Config, transform/validation rules, ETL jobs, demo batches
-- ============================================================
USE EDIP;
GO

DECLARE @CustomerDataset UNIQUEIDENTIFIER =
    (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');

IF @CustomerDataset IS NULL
BEGIN
    SET @CustomerDataset = '33333333-3333-3333-3333-333333333333';
    IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @CustomerDataset)
        INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable, KeyColumn)
        VALUES (@CustomerDataset, N'CUSTOMER', N'Customer Master',
                N'Staged customer imports', N'ingest.StagingCustomer', N'ingest.Customer', N'CustomerCode');
END

UPDATE ingest.Dataset
SET KeyColumn = N'CustomerCode',
    DefaultLoadMode = N'Incremental',
    DefaultDuplicateStrategy = N'Update',
    MaxRetries = 3
WHERE DatasetId = @CustomerDataset;

IF NOT EXISTS (SELECT 1 FROM etl.DatasetConfig WHERE DatasetId = @CustomerDataset)
    INSERT INTO etl.DatasetConfig (DatasetId, KeyColumn, LoadMode, DuplicateStrategy, MaxRetries)
    VALUES (@CustomerDataset, N'CustomerCode', N'Incremental', N'Update', 3);
GO

DECLARE @CustomerDataset UNIQUEIDENTIFIER =
    (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');

IF NOT EXISTS (SELECT 1 FROM etl.TransformRule WHERE DatasetId = @CustomerDataset)
BEGIN
    INSERT INTO etl.TransformRule (DatasetId, ColumnName, StepOrder, TransformType, Param1, Param2)
    VALUES
        (@CustomerDataset, N'CustomerCode', 1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'CustomerCode', 2, N'Upper', NULL, NULL),
        (@CustomerDataset, N'CustomerName', 1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'CountryCode',  1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'CountryCode',  2, N'Upper', NULL, NULL),
        (@CustomerDataset, N'Email',        1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'Email',        2, N'Lower', NULL, NULL),
        (@CustomerDataset, N'Status',       1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'Status',       2, N'NullDefault', N'Active', NULL),
        (@CustomerDataset, N'CreditLimit',  1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'CreditLimit',  2, N'NumericNormalize', NULL, NULL),
        (@CustomerDataset, N'CreditLimit',  3, N'NullDefault', N'0', NULL),
        (@CustomerDataset, N'CreatedDate',  1, N'Trim', NULL, NULL),
        (@CustomerDataset, N'CreatedDate',  2, N'DateNormalize', NULL, NULL),
        (@CustomerDataset, N'CountryCode',  3, N'Replace', N'USA', N'US');
END

IF NOT EXISTS (SELECT 1 FROM etl.StandardizationMap WHERE DatasetId = @CustomerDataset)
BEGIN
    INSERT INTO etl.StandardizationMap (DatasetId, ColumnName, SourceValue, TargetValue)
    VALUES
        (@CustomerDataset, N'Status', N'A', N'Active'),
        (@CustomerDataset, N'Status', N'I', N'Inactive'),
        (@CustomerDataset, N'Status', N'P', N'Prospect'),
        (@CustomerDataset, N'Status', N'ACTIVE', N'Active'),
        (@CustomerDataset, N'Status', N'INACTIVE', N'Inactive'),
        (@CustomerDataset, N'CountryCode', N'USA', N'US'),
        (@CustomerDataset, N'CountryCode', N'GB', N'UK'),
        (@CustomerDataset, N'CountryCode', N'GBR', N'UK');
END

IF NOT EXISTS (SELECT 1 FROM etl.AllowedValue WHERE DatasetId = @CustomerDataset)
BEGIN
    INSERT INTO etl.AllowedValue (DatasetId, ColumnName, AllowedValue)
    VALUES
        (@CustomerDataset, N'Status', N'Active'),
        (@CustomerDataset, N'Status', N'Inactive'),
        (@CustomerDataset, N'Status', N'Prospect');
END

IF NOT EXISTS (SELECT 1 FROM etl.ValidationRule WHERE DatasetId = @CustomerDataset)
BEGIN
    INSERT INTO etl.ValidationRule (DatasetId, ColumnName, RuleType, Param1, Param2, ErrorCode, ErrorMessage)
    VALUES
        (@CustomerDataset, N'CustomerCode', N'Required',  NULL, NULL, N'REQ_CUSTOMER_CODE', N'CustomerCode is required.'),
        (@CustomerDataset, N'CustomerName', N'Required',  NULL, NULL, N'REQ_CUSTOMER_NAME', N'CustomerName is required.'),
        (@CustomerDataset, N'CountryCode',  N'Required',  NULL, NULL, N'REQ_COUNTRY_CODE', N'CountryCode is required.'),
        (@CustomerDataset, N'CreatedDate',  N'Required',  NULL, NULL, N'REQ_CREATED_DATE', N'CreatedDate is required.'),
        (@CustomerDataset, N'CustomerCode', N'MaxLength', N'32', NULL, N'MAX_CUSTOMER_CODE', N'CustomerCode exceeds 32 characters.'),
        (@CustomerDataset, N'CustomerCode', N'MinLength', N'3',  NULL, N'MIN_CUSTOMER_CODE', N'CustomerCode must be at least 3 characters.'),
        (@CustomerDataset, N'CreatedDate',  N'DataType',  N'Date', NULL, N'TYPE_CREATED_DATE', N'CreatedDate is not a valid date.'),
        (@CustomerDataset, N'CreditLimit',  N'DataType',  N'Decimal', NULL, N'TYPE_CREDIT_LIMIT', N'CreditLimit is not a valid number.'),
        (@CustomerDataset, N'CreditLimit',  N'MinValue',  N'0', NULL, N'MIN_CREDIT', N'CreditLimit cannot be negative.'),
        (@CustomerDataset, N'CreditLimit',  N'MaxValue',  N'1000000', NULL, N'MAX_CREDIT', N'CreditLimit exceeds allowed maximum.'),
        (@CustomerDataset, N'CreatedDate',  N'DateMax',   NULL, NULL, N'BR_FUTURE_DATE', N'CreatedDate cannot be in the future.'),
        (@CustomerDataset, N'CreatedDate',  N'DateMin',   N'2000-01-01', NULL, N'BR_DATE_MIN', N'CreatedDate is earlier than 2000-01-01.'),
        (@CustomerDataset, N'Status',       N'AllowedValues', NULL, NULL, N'INV_STATUS', N'Status is not in the allowed list.'),
        (@CustomerDataset, N'Email',        N'Regex',     N'Email', NULL, N'INV_EMAIL', N'Email format is invalid.'),
        (@CustomerDataset, N'CountryCode',  N'Referential', NULL, NULL, N'RI_COUNTRY', N'CountryCode is not in the reference table.');
END

IF NOT EXISTS (SELECT 1 FROM etl.ReferentialRule WHERE DatasetId = @CustomerDataset)
    INSERT INTO etl.ReferentialRule (DatasetId, ColumnName, RefSchema, RefTable, RefColumn)
    VALUES (@CustomerDataset, N'CountryCode', N'ingest', N'Country', N'CountryCode');
GO

DECLARE @SampleCsv UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';
DECLARE @EtlJob UNIQUEIDENTIFIER = '77777777-7777-7777-7777-777777777777';
DECLARE @ArchiveJob UNIQUEIDENTIFIER = '88888888-8888-8888-8888-888888888888';
DECLARE @SnapJob UNIQUEIDENTIFIER = '99999999-9999-9999-9999-999999999999';
DECLARE @CleanupJob UNIQUEIDENTIFIER = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';

IF EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @SampleCsv)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @EtlJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@EtlJob, N'ETL Process Pending Batches', N'Transform, validate, and load pending import batches',
                @SampleCsv, N'EtlProcessPending', 1, 2, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @EtlJob, N'Hourly', 60, DATEADD(MINUTE, 8, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @ArchiveJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@ArchiveJob, N'ETL Archive Errors', N'Moves aged ETL errors into archive storage',
                @SampleCsv, N'EtlArchiveErrors', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @ArchiveJob, N'Weekly', 10080, DATEADD(DAY, 1, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @SnapJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@SnapJob, N'ETL Quality Snapshot', N'Generates dataset-level ETL quality summaries',
                @SampleCsv, N'EtlQualitySnapshot', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @SnapJob, N'Daily', 1440, DATEADD(MINUTE, 45, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @CleanupJob)
    BEGIN
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@CleanupJob, N'ETL Batch Cleanup', N'Removes completed ETL batches older than retention',
                @SampleCsv, N'EtlBatchCleanup', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @CleanupJob, N'Weekly', 10080, DATEADD(DAY, 2, SYSUTCDATETIME()), 1);
    END
END
GO

-- Demo ETL batch: mixed valid / invalid / transform / duplicate rows
DECLARE @DatasetId UNIQUEIDENTIFIER = (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');
DECLARE @EtlDemo UNIQUEIDENTIFIER = '77777777-AAAA-BBBB-CCCC-666666666666';
DECLARE @CsvSource UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';

IF @DatasetId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ingest.ImportBatch WHERE BatchId = @EtlDemo)
BEGIN
    INSERT INTO ingest.ImportBatch
        (BatchId, DatasetId, DataSourceId, SourceInfo, SourceFile, Status, ImportId, LoadMode, DuplicateStrategy, MaxRetries)
    VALUES
        (@EtlDemo, @DatasetId, @CsvSource, N'samples/etl_customer_demo.csv', N'etl_customer_demo.csv',
         N'Pending', 'AAAAAAAA-1111-2222-3333-444444444444', N'Incremental', N'Update', 3);

    INSERT INTO ingest.StagingCustomer
        (BatchId, DatasetId, RowNumber, RawCustomerCode, RawCustomerName, RawCountryCode, RawEmail,
         RawCreditLimit, RawStatus, RawCreatedDate, SourceInfo, SourceFile)
    VALUES
        (@EtlDemo, @DatasetId, 1, N'  etl-001  ', N'  Acme Transformed  ', N'usa', N'  OPS@ACME.EXAMPLE  ', N'$12,500.00', N'a', N'01/15/2024', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 2, N'etl-002', N'Globex', N'GB', N'Info@Globex.example', N'25000', N'Active', N'2024-02-20', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 3, NULL, N'Missing Code', N'US', N'a@b.com', N'10', N'Active', N'2024-01-01', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 4, N'etl-004', N'Bad Country', N'ZZ', N'zz@example.com', N'10', N'Active', N'2024-01-01', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 5, N'etl-005', N'Bad Email', N'DE', N'not-an-email', N'-25', N'Active', N'2024-01-01', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 6, N'etl-001', N'Duplicate Key', N'US', N'dup@acme.example', N'1', N'Active', N'2024-01-15', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 7, N'etl-007', N'Bad Date', N'CA', N'date@example.com', N'200', N'Active', N'not-a-date', N'demo', N'etl_customer_demo.csv'),
        (@EtlDemo, @DatasetId, 8, N'etl-008', N'Good Prospect', N'IN', N'p@example.com', N'300', N'P', N'20240601', N'demo', N'etl_customer_demo.csv');

    EXEC ingest.usp_CompleteStagingLoad @BatchId = @EtlDemo;
    EXEC etl.usp_RunPipeline @BatchId = @EtlDemo, @TriggerType = N'Manual';
END
GO

PRINT 'ETL seed data applied.';
GO
