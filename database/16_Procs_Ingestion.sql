-- ============================================================
-- 16_Procs_Ingestion.sql
-- Batch management, validation, processing, errors, monitoring
-- ============================================================
USE EDIP;
GO

-- ------------------------------------------------------------
-- Create import batch header
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_CreateImportBatch
    @DatasetCode   NVARCHAR(64),
    @DataSourceId  UNIQUEIDENTIFIER = NULL,
    @SourceInfo    NVARCHAR(500) = NULL,
    @BatchId       UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER;

    SELECT @DatasetId = DatasetId
    FROM ingest.Dataset
    WHERE DatasetCode = @DatasetCode AND IsActive = 1;

    IF @DatasetId IS NULL
        THROW 50001, N'Dataset not found or inactive.', 1;

    IF @BatchId IS NULL
        SET @BatchId = NEWID();

    INSERT INTO ingest.ImportBatch
        (BatchId, DatasetId, DataSourceId, SourceInfo, Status)
    VALUES
        (@BatchId, @DatasetId, @DataSourceId, @SourceInfo, N'Pending');

    SELECT
        b.BatchId,
        d.DatasetCode,
        b.Status,
        b.ImportUtc
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    WHERE b.BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Finalize staging load counts
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_CompleteStagingLoad
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM ingest.ImportBatch WHERE BatchId = @BatchId)
        THROW 50002, N'Batch not found.', 1;

    UPDATE b
    SET
        TotalRecords = s.Cnt,
        Status = N'Loaded'
    FROM ingest.ImportBatch b
    CROSS APPLY (
        SELECT COUNT(*) AS Cnt
        FROM ingest.StagingCustomer sc
        WHERE sc.BatchId = @BatchId
    ) s
    WHERE b.BatchId = @BatchId;

    SELECT BatchId, Status, TotalRecords
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Validate staging rows for a customer batch
-- Captures errors without blocking valid rows
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_ValidateCustomerBatch
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER;
    DECLARE @Status NVARCHAR(32);

    SELECT @DatasetId = DatasetId, @Status = Status
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    IF @Status NOT IN (N'Loaded', N'Validated', N'CompletedWithErrors', N'Failed', N'RetryPending', N'Pending')
        THROW 50003, N'Batch is not in a state that allows validation.', 1;

    BEGIN TRAN;

    UPDATE ingest.ImportBatch
    SET Status = N'Validating', StartedUtc = ISNULL(StartedUtc, SYSUTCDATETIME())
    WHERE BatchId = @BatchId;

    -- Clear prior validation errors for re-validation / retry
    DELETE FROM ingest.ImportError
    WHERE BatchId = @BatchId
      AND ErrorCode NOT LIKE N'PROC_%';

    -- Reset non-processed rows
    UPDATE ingest.StagingCustomer
    SET
        RowStatus = N'Pending',
        IsDuplicateInBatch = 0,
        CustomerCode = NULL,
        CustomerName = NULL,
        CountryCode = NULL,
        Email = NULL,
        CreditLimit = NULL,
        Status = NULL,
        CreatedDate = NULL
    WHERE BatchId = @BatchId
      AND RowStatus <> N'Processed';

    /* ---- Required / null checks ---- */
    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CustomerCode', s.RawCustomerCode,
        N'REQ_CUSTOMER_CODE', N'CustomerCode is required.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND (s.RawCustomerCode IS NULL OR LTRIM(RTRIM(s.RawCustomerCode)) = N'');

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CustomerName', s.RawCustomerName,
        N'REQ_CUSTOMER_NAME', N'CustomerName is required.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND (s.RawCustomerName IS NULL OR LTRIM(RTRIM(s.RawCustomerName)) = N'');

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CountryCode', s.RawCountryCode,
        N'REQ_COUNTRY_CODE', N'CountryCode is required.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND (s.RawCountryCode IS NULL OR LTRIM(RTRIM(s.RawCountryCode)) = N'');

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CreatedDate', s.RawCreatedDate,
        N'REQ_CREATED_DATE', N'CreatedDate is required.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND (s.RawCreatedDate IS NULL OR LTRIM(RTRIM(s.RawCreatedDate)) = N'');

    /* ---- Data type / format checks ---- */
    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CreatedDate', s.RawCreatedDate,
        N'TYPE_CREATED_DATE', N'CreatedDate is not a valid date (expected yyyy-MM-dd).'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND s.RawCreatedDate IS NOT NULL AND LTRIM(RTRIM(s.RawCreatedDate)) <> N''
      AND TRY_CONVERT(DATE, LTRIM(RTRIM(s.RawCreatedDate)), 23) IS NULL;

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CreditLimit', s.RawCreditLimit,
        N'TYPE_CREDIT_LIMIT', N'CreditLimit is not a valid decimal number.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND s.RawCreditLimit IS NOT NULL AND LTRIM(RTRIM(s.RawCreditLimit)) <> N''
      AND TRY_CONVERT(DECIMAL(18,2), LTRIM(RTRIM(s.RawCreditLimit))) IS NULL;

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CustomerCode', s.RawCustomerCode,
        N'LEN_CUSTOMER_CODE', N'CustomerCode exceeds 32 characters.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND LEN(LTRIM(RTRIM(s.RawCustomerCode))) > 32;

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CountryCode', s.RawCountryCode,
        N'INV_COUNTRY_LEN', N'CountryCode must be a 2-letter ISO code.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND s.RawCountryCode IS NOT NULL AND LTRIM(RTRIM(s.RawCountryCode)) <> N''
      AND LEN(LTRIM(RTRIM(s.RawCountryCode))) <> 2;

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'Email', s.RawEmail,
        N'INV_EMAIL', N'Email format is invalid.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND s.RawEmail IS NOT NULL AND LTRIM(RTRIM(s.RawEmail)) <> N''
      AND (
            CHARINDEX(N'@', s.RawEmail) < 2
            OR CHARINDEX(N'.', s.RawEmail, CHARINDEX(N'@', s.RawEmail)) = 0
            OR LEN(s.RawEmail) > 256
      );

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'Status', s.RawStatus,
        N'INV_STATUS', N'Status must be Active, Inactive, or Prospect.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND s.RawStatus IS NOT NULL AND LTRIM(RTRIM(s.RawStatus)) <> N''
      AND UPPER(LTRIM(RTRIM(s.RawStatus))) NOT IN (N'ACTIVE', N'INACTIVE', N'PROSPECT');

    /* ---- Business rules ---- */
    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CreatedDate', s.RawCreatedDate,
        N'BR_FUTURE_DATE', N'CreatedDate cannot be in the future.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND TRY_CONVERT(DATE, LTRIM(RTRIM(s.RawCreatedDate)), 23) > CAST(SYSUTCDATETIME() AS DATE);

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CreditLimit', s.RawCreditLimit,
        N'BR_NEG_CREDIT', N'CreditLimit cannot be negative.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND TRY_CONVERT(DECIMAL(18,2), LTRIM(RTRIM(s.RawCreditLimit))) < 0;

    /* ---- Referential integrity ---- */
    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CountryCode', UPPER(LTRIM(RTRIM(s.RawCountryCode))),
        N'RI_COUNTRY', N'CountryCode does not exist in ingest.Country reference data.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND LEN(LTRIM(RTRIM(ISNULL(s.RawCountryCode, N'')))) = 2
      AND NOT EXISTS (
            SELECT 1 FROM ingest.Country c
            WHERE c.CountryCode = UPPER(LTRIM(RTRIM(s.RawCountryCode)))
              AND c.IsActive = 1
      );

    /* ---- Duplicate within batch (keep first RowNumber as candidate) ---- */
    ;WITH Dupes AS (
        SELECT
            StagingRowId,
            ROW_NUMBER() OVER (
                PARTITION BY UPPER(LTRIM(RTRIM(RawCustomerCode)))
                ORDER BY RowNumber
            ) AS rn
        FROM ingest.StagingCustomer
        WHERE BatchId = @BatchId
          AND RowStatus = N'Pending'
          AND RawCustomerCode IS NOT NULL
          AND LTRIM(RTRIM(RawCustomerCode)) <> N''
    )
    UPDATE s
    SET IsDuplicateInBatch = 1
    FROM ingest.StagingCustomer s
    INNER JOIN Dupes d ON d.StagingRowId = s.StagingRowId
    WHERE d.rn > 1;

    INSERT INTO ingest.ImportError
        (BatchId, DatasetId, StagingRowId, RowReference, ColumnName, InvalidValue, ErrorCode, ErrorDescription)
    SELECT
        s.BatchId, s.DatasetId, s.StagingRowId,
        CONCAT(N'Row ', s.RowNumber), N'CustomerCode', s.RawCustomerCode,
        N'DUP_IN_BATCH', N'Duplicate CustomerCode within the same import batch.'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.IsDuplicateInBatch = 1 AND s.RowStatus = N'Pending';

    /* ---- Mark invalid rows (any validation error) ---- */
    UPDATE s
    SET RowStatus = N'Invalid'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId
      AND s.RowStatus = N'Pending'
      AND EXISTS (
          SELECT 1 FROM ingest.ImportError e
          WHERE e.StagingRowId = s.StagingRowId
      );

    /* ---- Populate typed columns for remaining valid rows ---- */
    UPDATE s
    SET
        CustomerCode = LEFT(UPPER(LTRIM(RTRIM(s.RawCustomerCode))), 32),
        CustomerName = LEFT(LTRIM(RTRIM(s.RawCustomerName)), 200),
        CountryCode  = UPPER(LTRIM(RTRIM(s.RawCountryCode))),
        Email        = NULLIF(LTRIM(RTRIM(s.RawEmail)), N''),
        CreditLimit  = ISNULL(TRY_CONVERT(DECIMAL(18,2), LTRIM(RTRIM(s.RawCreditLimit))), 0),
        Status       = CASE UPPER(LTRIM(RTRIM(ISNULL(NULLIF(s.RawStatus, N''), N'Active'))))
                           WHEN N'INACTIVE' THEN N'Inactive'
                           WHEN N'PROSPECT' THEN N'Prospect'
                           ELSE N'Active'
                       END,
        CreatedDate  = TRY_CONVERT(DATE, LTRIM(RTRIM(s.RawCreatedDate)), 23),
        RowStatus    = N'Valid'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId
      AND s.RowStatus = N'Pending';

    /* ---- Batch counters ---- */
    DECLARE @Valid INT, @Invalid INT, @ErrCnt INT, @Total INT, @AlreadyProcessed INT;

    SELECT
        @Valid = SUM(CASE WHEN RowStatus = N'Valid' THEN 1 ELSE 0 END),
        @Invalid = SUM(CASE WHEN RowStatus = N'Invalid' THEN 1 ELSE 0 END),
        @AlreadyProcessed = SUM(CASE WHEN RowStatus = N'Processed' THEN 1 ELSE 0 END),
        @Total = COUNT(*)
    FROM ingest.StagingCustomer
    WHERE BatchId = @BatchId;

    SELECT @ErrCnt = COUNT(*) FROM ingest.ImportError WHERE BatchId = @BatchId;

    UPDATE ingest.ImportBatch
    SET
        TotalRecords = @Total,
        ValidRecords = ISNULL(@Valid, 0),
        RejectedRecords = ISNULL(@Invalid, 0),
        ProcessedRecords = ISNULL(@AlreadyProcessed, 0),
        ErrorCount = @ErrCnt,
        Status = N'Validated'
    WHERE BatchId = @BatchId;

    COMMIT;

    SELECT
        BatchId, Status, TotalRecords, ValidRecords, RejectedRecords, ErrorCount, ProcessedRecords
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Process valid staging rows into target (idempotent / retry-safe)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_ProcessCustomerBatch
    @BatchId     UNIQUEIDENTIFIER,
    @TriggerType NVARCHAR(16) = N'Manual'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER;
    DECLARE @Status NVARCHAR(32);
    DECLARE @Attempt INT;
    DECLARE @AttemptId BIGINT;
    DECLARE @Inserted INT = 0;
    DECLARE @Updated INT = 0;
    DECLARE @Processed INT = 0;

    SELECT @DatasetId = DatasetId, @Status = Status, @Attempt = AttemptCount
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    IF @Status NOT IN (N'Loaded', N'Validated', N'CompletedWithErrors', N'Failed', N'RetryPending', N'Completed')
        THROW 50004, N'Batch must be loaded/validated before processing (or marked for retry).', 1;

    IF @TriggerType NOT IN (N'Manual', N'Agent', N'Retry', N'Api')
        SET @TriggerType = N'Manual';

    -- Auto-validate if only Loaded
    IF @Status = N'Loaded'
    BEGIN
        EXEC ingest.usp_ValidateCustomerBatch @BatchId = @BatchId;
        SELECT @Status = Status FROM ingest.ImportBatch WHERE BatchId = @BatchId;
    END

    BEGIN TRAN;

    SET @Attempt = ISNULL(@Attempt, 0) + 1;

    UPDATE ingest.ImportBatch
    SET
        Status = N'Processing',
        AttemptCount = @Attempt,
        StartedUtc = ISNULL(StartedUtc, SYSUTCDATETIME()),
        LastErrorMessage = NULL
    WHERE BatchId = @BatchId;

    INSERT INTO ingest.BatchProcessAttempt
        (BatchId, AttemptNumber, TriggerType, Status)
    VALUES
        (@BatchId, @Attempt, @TriggerType, N'Running');

    SET @AttemptId = SCOPE_IDENTITY();

    BEGIN TRY
        /* Merge only Valid (not yet Processed) rows — retry safe */
        DECLARE @MergeOutput TABLE (ActionTaken NVARCHAR(10));

        MERGE ingest.Customer AS t
        USING (
            SELECT
                CustomerCode, CustomerName, CountryCode, Email,
                CreditLimit, Status, CreatedDate, BatchId
            FROM ingest.StagingCustomer
            WHERE BatchId = @BatchId
              AND RowStatus = N'Valid'
              AND CustomerCode IS NOT NULL
        ) AS s
        ON t.CustomerCode = s.CustomerCode
        WHEN MATCHED THEN
            UPDATE SET
                CustomerName  = s.CustomerName,
                CountryCode   = s.CountryCode,
                Email         = s.Email,
                CreditLimit   = s.CreditLimit,
                Status        = s.Status,
                CreatedDate   = s.CreatedDate,
                SourceBatchId = s.BatchId,
                ModifiedUtc   = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN
            INSERT (CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, SourceBatchId)
            VALUES (s.CustomerCode, s.CustomerName, s.CountryCode, s.Email, s.CreditLimit, s.Status, s.CreatedDate, s.BatchId)
        OUTPUT $action INTO @MergeOutput;

        SELECT
            @Inserted = SUM(CASE WHEN ActionTaken = N'INSERT' THEN 1 ELSE 0 END),
            @Updated  = SUM(CASE WHEN ActionTaken = N'UPDATE' THEN 1 ELSE 0 END)
        FROM @MergeOutput;

        SET @Inserted = ISNULL(@Inserted, 0);
        SET @Updated  = ISNULL(@Updated, 0);
        SET @Processed = @Inserted + @Updated;

        UPDATE ingest.StagingCustomer
        SET RowStatus = N'Processed', ProcessedUtc = SYSUTCDATETIME()
        WHERE BatchId = @BatchId
          AND RowStatus = N'Valid';

        DECLARE @Rejected INT, @ErrCnt INT, @TotalProcessed INT;

        SELECT
            @Rejected = SUM(CASE WHEN RowStatus = N'Invalid' THEN 1 ELSE 0 END),
            @TotalProcessed = SUM(CASE WHEN RowStatus = N'Processed' THEN 1 ELSE 0 END)
        FROM ingest.StagingCustomer
        WHERE BatchId = @BatchId;

        SELECT @ErrCnt = COUNT(*) FROM ingest.ImportError WHERE BatchId = @BatchId;

        UPDATE ingest.ImportBatch
        SET
            ProcessedRecords = ISNULL(@TotalProcessed, 0),
            InsertedRecords  = InsertedRecords + @Inserted,
            UpdatedRecords   = UpdatedRecords + @Updated,
            RejectedRecords  = ISNULL(@Rejected, 0),
            ErrorCount       = @ErrCnt,
            CompletedUtc     = SYSUTCDATETIME(),
            Status = CASE
                WHEN ISNULL(@Rejected, 0) > 0 OR @ErrCnt > 0 THEN N'CompletedWithErrors'
                ELSE N'Completed'
            END
        WHERE BatchId = @BatchId;

        UPDATE ingest.BatchProcessAttempt
        SET
            Status = CASE WHEN ISNULL(@Rejected, 0) > 0 THEN N'Partial' ELSE N'Succeeded' END,
            CompletedUtc = SYSUTCDATETIME(),
            ProcessedCount = @Processed,
            InsertedCount = @Inserted,
            UpdatedCount = @Updated
        WHERE AttemptId = @AttemptId;

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        UPDATE ingest.ImportBatch
        SET
            Status = N'Failed',
            LastErrorMessage = LEFT(ERROR_MESSAGE(), 2000),
            CompletedUtc = SYSUTCDATETIME()
        WHERE BatchId = @BatchId;

        UPDATE ingest.BatchProcessAttempt
        SET
            Status = N'Failed',
            CompletedUtc = SYSUTCDATETIME(),
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE AttemptId = @AttemptId;

        INSERT INTO ingest.ImportError
            (BatchId, DatasetId, RowReference, ErrorCode, ErrorDescription, Severity)
        VALUES
            (@BatchId, @DatasetId, N'BATCH', N'PROC_FAILURE', LEFT(ERROR_MESSAGE(), 1000), N'Error');

        THROW;
    END CATCH;

    SELECT
        BatchId, Status, TotalRecords, ValidRecords, RejectedRecords,
        ProcessedRecords, InsertedRecords, UpdatedRecords, ErrorCount,
        AttemptCount, StartedUtc, CompletedUtc
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Retry failed / partial batches without reprocessing successes
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_RetryFailedBatch
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status NVARCHAR(32);

    SELECT @Status = Status FROM ingest.ImportBatch WHERE BatchId = @BatchId;
    IF @Status IS NULL
        THROW 50002, N'Batch not found.', 1;

    IF @Status NOT IN (N'Failed', N'CompletedWithErrors', N'RetryPending', N'Validated')
        THROW 50005, N'Batch is not eligible for retry.', 1;

    -- Re-validate only unprocessed rows, then process remaining Valid rows
    UPDATE ingest.ImportBatch SET Status = N'RetryPending' WHERE BatchId = @BatchId;

    EXEC ingest.usp_ValidateCustomerBatch @BatchId = @BatchId;
    EXEC ingest.usp_ProcessCustomerBatch @BatchId = @BatchId, @TriggerType = N'Retry';
END
GO

-- ------------------------------------------------------------
-- Agent: process all pending / retry-eligible batches
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_ProcessPendingBatches
    @MaxBatches INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BatchId UNIQUEIDENTIFIER;
    DECLARE @Processed INT = 0;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@MaxBatches) BatchId
        FROM ingest.ImportBatch
        WHERE Status IN (N'Loaded', N'Validated', N'RetryPending', N'Failed')
        ORDER BY ImportUtc;

    OPEN c;
    FETCH NEXT FROM c INTO @BatchId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            IF (SELECT Status FROM ingest.ImportBatch WHERE BatchId = @BatchId) = N'Loaded'
                EXEC ingest.usp_ValidateCustomerBatch @BatchId = @BatchId;

            EXEC ingest.usp_ProcessCustomerBatch @BatchId = @BatchId, @TriggerType = N'Agent';
            SET @Processed += 1;
        END TRY
        BEGIN CATCH
            -- Continue with next batch; failure already recorded
            PRINT ERROR_MESSAGE();
        END CATCH;

        FETCH NEXT FROM c INTO @BatchId;
    END
    CLOSE c; DEALLOCATE c;

    SELECT @Processed AS BatchesProcessed;
END
GO

-- ------------------------------------------------------------
-- Error retrieval
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_GetErrorsByBatch
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.ErrorId,
        e.BatchId,
        e.DatasetId,
        e.StagingRowId,
        e.RowReference,
        e.ColumnName,
        e.InvalidValue,
        e.ErrorCode,
        e.ErrorDescription,
        e.Severity,
        e.ErrorUtc
    FROM ingest.ImportError e
    WHERE e.BatchId = @BatchId
    ORDER BY e.ErrorId;
END
GO

CREATE OR ALTER PROCEDURE ingest.usp_GetErrorsByDataset
    @DatasetCode NVARCHAR(64),
    @FromUtc DATETIME2(3) = NULL,
    @ToUtc   DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ToUtc = ISNULL(@ToUtc, SYSUTCDATETIME());
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -30, @ToUtc));

    SELECT
        e.ErrorId,
        e.BatchId,
        e.DatasetId,
        d.DatasetCode,
        e.StagingRowId,
        e.RowReference,
        e.ColumnName,
        e.InvalidValue,
        e.ErrorCode,
        e.ErrorDescription,
        e.Severity,
        e.ErrorUtc
    FROM ingest.ImportError e
    INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
    WHERE d.DatasetCode = @DatasetCode
      AND e.ErrorUtc >= @FromUtc AND e.ErrorUtc < @ToUtc
    ORDER BY e.ErrorUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE ingest.usp_GetBatchStatus
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        b.BatchId,
        d.DatasetCode,
        d.DisplayName AS DatasetName,
        b.DataSourceId,
        b.SourceInfo,
        b.ImportUtc,
        b.Status,
        b.TotalRecords,
        b.ValidRecords,
        b.RejectedRecords,
        b.ProcessedRecords,
        b.InsertedRecords,
        b.UpdatedRecords,
        b.ErrorCount,
        b.AttemptCount,
        b.StartedUtc,
        b.CompletedUtc,
        DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc) / 1000.0 AS DurationSeconds,
        b.LastErrorMessage
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    WHERE b.BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Archive old import history
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_ArchiveImportHistory
    @RetainDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    -- Cascades remove StagingCustomer, ImportError, BatchProcessAttempt
    DELETE FROM ingest.ImportBatch
    WHERE ImportUtc < @Cutoff
      AND Status IN (N'Completed', N'CompletedWithErrors', N'Failed');

    SELECT @@ROWCOUNT AS BatchesArchived;
END
GO

PRINT 'Ingestion procedures created.';
GO
