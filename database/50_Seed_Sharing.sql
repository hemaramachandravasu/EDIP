-- ============================================================
-- 50_Seed_Sharing.sql
-- Exportable-column whitelist, demo shares (active / expired /
-- revoked), demo exports in every status, scheduled jobs.
-- Idempotent: demo shares/exports are only created once.
-- ============================================================
USE EDIP;
GO

SET NOCOUNT ON;

EXEC share.usp_SyncExportableColumns @ReturnSummary = 1;
GO

-- ------------------------------------------------------------
-- Demo shares
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM share.DatasetShare)
   AND EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER')
   AND EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'ORDER')
BEGIN
    DECLARE @ShareId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);
    DECLARE @In30 DATETIME2(3) = DATEADD(DAY, 30, SYSUTCDATETIME());
    DECLARE @In5 DATETIME2(3) = DATEADD(DAY, 5, SYSUTCDATETIME());

    -- Active: viewer gets Read on CUSTOMER (Confidential needs Write to export → denied as InsufficientAccess)
    EXEC share.usp_CreateDatasetShare
        @DatasetCode = N'CUSTOMER', @RecipientUserName = N'gov.viewer', @AccessLevelCode = N'Read',
        @SharedByUserName = N'gov.owner', @ExpiresUtc = @In30, @Notes = N'Quarterly dashboard read access',
        @ShareId = @ShareId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Share CUSTOMER -> viewer: ', @Code);

    -- Expired (computed at read time; persisted status stays Active until the expiry job runs)
    SET @ShareId = NULL; SET @Code = NULL; SET @Msg = NULL;
    EXEC share.usp_CreateDatasetShare
        @DatasetCode = N'ORDER', @RecipientUserName = N'gov.viewer', @AccessLevelCode = N'Write',
        @SharedByUserName = N'gov.owner', @ExpiresUtc = @In5, @Notes = N'Temporary order reconciliation',
        @ShareId = @ShareId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created'
    BEGIN
        UPDATE share.DatasetShare
        SET SharedUtc = DATEADD(DAY, -40, SYSUTCDATETIME()), ExpiresUtc = DATEADD(DAY, -10, SYSUTCDATETIME())
        WHERE ShareId = @ShareId;
        UPDATE share.DatasetShareHistory
        SET ActionUtc = DATEADD(DAY, -40, SYSUTCDATETIME()), NewExpiresUtc = DATEADD(DAY, -10, SYSUTCDATETIME())
        WHERE ShareId = @ShareId;
    END
    PRINT CONCAT('Share ORDER -> viewer (backdated to expired): ', @Code);

    -- Revoked
    SET @ShareId = NULL; SET @Code = NULL; SET @Msg = NULL;
    EXEC share.usp_CreateDatasetShare
        @DatasetCode = N'ORDER', @RecipientUserName = N'gov.analyst', @AccessLevelCode = N'Read',
        @SharedByUserName = N'gov.steward', @Notes = N'Ad-hoc order analysis',
        @ShareId = @ShareId OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created'
        EXEC share.usp_RevokeDatasetShare
            @ShareId = @ShareId, @ActorUserName = N'gov.owner', @RevokeReason = N'Analysis complete',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Share ORDER -> analyst then revoke: ', @Code);
END
GO

-- ------------------------------------------------------------
-- Demo exports (one per status)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM share.ExportRequest)
   AND EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER')
BEGIN
    DECLARE @Id UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500), @Rows BIGINT;

    -- Completed + downloaded: analyst (Write grant) exports CUSTOMER as CSV
    EXEC share.usp_SubmitExportRequest
        @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Csv',
        @SelectedColumnsJson = N'["CustomerId","CustomerCode","CustomerName","CountryCode","CreditLimit"]',
        @FiltersJson = N'[{"column":"CreditLimit","op":"ge","value":0}]',
        @SortJson = N'[{"column":"CustomerId","dir":"asc"}]',
        @ExportRequestId = @Id OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Export 1 submit: ', @Code, ' ', @Msg);
    IF @Code = N'Created'
    BEGIN
        EXEC share.usp_TransitionExportStatus @ExportRequestId = @Id, @NewStatus = N'Processing',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
        SELECT @Rows = COUNT_BIG(*) FROM ingest.Customer WHERE CreditLimit >= 0;
        EXEC share.usp_TransitionExportStatus @ExportRequestId = @Id, @NewStatus = N'Completed',
            @RecordCount = @Rows, @FileSizeBytes = 2048, @FileReference = N'exports/demo/customer-analyst.csv',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
        EXEC share.usp_RecordExportDownload @ExportRequestId = @Id, @UserName = N'gov.analyst',
            @ClientInfo = N'seed', @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
        PRINT CONCAT('Export 1 download: ', @Code);
    END

    -- Failed: owner JSON export fails in the worker
    SET @Id = NULL; SET @Code = NULL; SET @Msg = NULL;
    EXEC share.usp_SubmitExportRequest
        @DatasetCode = N'CUSTOMER', @UserName = N'gov.owner', @FormatCode = N'Json',
        @ExportRequestId = @Id OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created'
    BEGIN
        EXEC share.usp_TransitionExportStatus @ExportRequestId = @Id, @NewStatus = N'Processing',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
        EXEC share.usp_TransitionExportStatus @ExportRequestId = @Id, @NewStatus = N'Failed',
            @FailureReason = N'Export storage unavailable (demo)',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    END
    PRINT CONCAT('Export 2 (failed): ', @Code);

    -- Cancelled by requester
    SET @Id = NULL; SET @Code = NULL; SET @Msg = NULL;
    EXEC share.usp_SubmitExportRequest
        @DatasetCode = N'CUSTOMER', @UserName = N'gov.owner', @FormatCode = N'Parquet',
        @SelectedColumnsJson = N'["CustomerId","CustomerName"]',
        @ExportRequestId = @Id OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    IF @Code = N'Created'
        EXEC share.usp_TransitionExportStatus @ExportRequestId = @Id, @NewStatus = N'Cancelled',
            @ActorUserName = N'gov.owner', @FailureReason = N'No longer needed',
            @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Export 3 (cancelled): ', @Code);

    -- Denied: viewer only has a Read share on Confidential CUSTOMER (audited as ExportDenied)
    SET @Id = NULL; SET @Code = NULL; SET @Msg = NULL;
    EXEC share.usp_SubmitExportRequest
        @DatasetCode = N'CUSTOMER', @UserName = N'gov.viewer', @FormatCode = N'Csv',
        @ExportRequestId = @Id OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Export 5 (viewer, expect AccessDenied): ', @Code, ' ', @Msg);
END
GO

-- Pending (left in the queue for the worker / claim demo)
IF NOT EXISTS (SELECT 1 FROM share.ExportRequest WHERE FormatCode = N'Xlsx')
   AND EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER')
BEGIN
    DECLARE @Id UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);
    EXEC share.usp_SubmitExportRequest
        @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @FormatCode = N'Xlsx',
        @SelectedColumnsJson = N'["CustomerCode","CustomerName","Email"]',
        @FiltersJson = N'[{"column":"CountryCode","op":"in","value":["US","GB","DE","IN"]}]',
        @ExportRequestId = @Id OUTPUT, @StatusCode = @Code OUTPUT, @StatusMessage = @Msg OUTPUT;
    PRINT CONCAT('Export 4 (pending): ', @Code, ' ', @Msg);
END
GO

-- ------------------------------------------------------------
-- Platform scheduler jobs
-- ------------------------------------------------------------
DECLARE @SampleCsv UNIQUEIDENTIFIER =
    (SELECT TOP (1) DataSourceId FROM reg.DataSource WHERE IsDeleted = 0 ORDER BY CreatedUtc);

IF @SampleCsv IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Expire Dataset Shares')
    BEGIN
        DECLARE @Job1 UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@Job1, N'Expire Dataset Shares',
                N'Persists Expired status for shares past expiry and writes history/audit.',
                @SampleCsv, N'ExpireDatasetShares', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @Job1, N'Hourly', 60, DATEADD(MINUTE, 30, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Cleanup Stale Exports')
    BEGIN
        DECLARE @Job2 UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@Job2, N'Cleanup Stale Exports',
                N'Fails timed-out Processing exports and cancels abandoned Pending exports.',
                @SampleCsv, N'CleanupStaleExports', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @Job2, N'Minutely', 15, DATEADD(MINUTE, 15, SYSUTCDATETIME()), 1);
    END
END
GO

PRINT 'Sharing/export seed complete.';
GO
