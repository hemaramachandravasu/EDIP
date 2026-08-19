-- ============================================================
-- 21_Procs_Etl.sql
-- Reusable transform functions + configurable ETL pipeline
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER FUNCTION etl.fn_TransformText
(
    @Value NVARCHAR(500),
    @TransformType NVARCHAR(32),
    @Param1 NVARCHAR(200),
    @Param2 NVARCHAR(200)
)
RETURNS NVARCHAR(500)
AS
BEGIN
    DECLARE @Result NVARCHAR(500) = @Value;

    IF @TransformType = N'Trim'
        SET @Result = LTRIM(RTRIM(@Value));
    ELSE IF @TransformType = N'Upper'
        SET @Result = UPPER(LTRIM(RTRIM(@Value)));
    ELSE IF @TransformType = N'Lower'
        SET @Result = LOWER(LTRIM(RTRIM(@Value)));
    ELSE IF @TransformType = N'NullDefault'
        SET @Result = CASE WHEN @Value IS NULL OR LTRIM(RTRIM(@Value)) = N'' THEN @Param1 ELSE @Value END;
    ELSE IF @TransformType = N'Replace'
        SET @Result = REPLACE(@Value, ISNULL(@Param1, N''), ISNULL(@Param2, N''));

    RETURN @Result;
END
GO

CREATE OR ALTER FUNCTION etl.fn_TryNormalizeDate
(
    @Value NVARCHAR(50)
)
RETURNS DATE
AS
BEGIN
    DECLARE @v NVARCHAR(50) = LTRIM(RTRIM(@Value));
    DECLARE @d DATE =
        COALESCE(
            TRY_CONVERT(DATE, @v, 23),
            TRY_CONVERT(DATE, @v, 121),
            TRY_CONVERT(DATE, @v, 101),
            TRY_CONVERT(DATE, @v, 103),
            TRY_CONVERT(DATE, @v, 112),
            TRY_CONVERT(DATE, @v)
        );
    RETURN @d;
END
GO

CREATE OR ALTER FUNCTION etl.fn_TryNormalizeDecimal
(
    @Value NVARCHAR(50)
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @v NVARCHAR(50) = LTRIM(RTRIM(@Value));
    SET @v = REPLACE(REPLACE(REPLACE(@v, N'$', N''), N',', N''), N' ', N'');
    RETURN TRY_CONVERT(DECIMAL(18,2), @v);
END
GO

-- Maps logical column -> raw staging column (whitelist)
CREATE OR ALTER FUNCTION etl.fn_RawColumn
(
    @LogicalColumn NVARCHAR(128)
)
RETURNS NVARCHAR(128)
AS
BEGIN
    RETURN CASE @LogicalColumn
        WHEN N'CustomerCode' THEN N'RawCustomerCode'
        WHEN N'CustomerName' THEN N'RawCustomerName'
        WHEN N'CountryCode'  THEN N'RawCountryCode'
        WHEN N'Email'        THEN N'RawEmail'
        WHEN N'CreditLimit'  THEN N'RawCreditLimit'
        WHEN N'Status'       THEN N'RawStatus'
        WHEN N'CreatedDate'  THEN N'RawCreatedDate'
        ELSE NULL
    END;
END
GO

-- ------------------------------------------------------------
-- Create batch with ETL options (also used by ingest API)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE ingest.usp_CreateImportBatch
    @DatasetCode         NVARCHAR(64),
    @DataSourceId        UNIQUEIDENTIFIER = NULL,
    @SourceInfo          NVARCHAR(500) = NULL,
    @BatchId             UNIQUEIDENTIFIER = NULL OUTPUT,
    @SourceFile          NVARCHAR(500) = NULL,
    @LoadMode            NVARCHAR(16) = NULL,
    @DuplicateStrategy   NVARCHAR(16) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER;
    DECLARE @CfgLoad NVARCHAR(16);
    DECLARE @CfgDup NVARCHAR(16);
    DECLARE @CfgRetry INT;
    DECLARE @ImportId UNIQUEIDENTIFIER = NEWID();

    SELECT
        @DatasetId = d.DatasetId,
        @CfgLoad = ISNULL(c.LoadMode, d.DefaultLoadMode),
        @CfgDup = ISNULL(c.DuplicateStrategy, d.DefaultDuplicateStrategy),
        @CfgRetry = ISNULL(c.MaxRetries, d.MaxRetries)
    FROM ingest.Dataset d
    LEFT JOIN etl.DatasetConfig c ON c.DatasetId = d.DatasetId
    WHERE d.DatasetCode = @DatasetCode AND d.IsActive = 1;

    IF @DatasetId IS NULL
        THROW 50001, N'Dataset not found or inactive.', 1;

    SET @LoadMode = ISNULL(NULLIF(@LoadMode, N''), @CfgLoad);
    SET @DuplicateStrategy = ISNULL(NULLIF(@DuplicateStrategy, N''), @CfgDup);

    IF @LoadMode NOT IN (N'Incremental', N'Full')
        THROW 50010, N'LoadMode must be Incremental or Full.', 1;
    IF @DuplicateStrategy NOT IN (N'Skip', N'Update', N'Reject')
        THROW 50011, N'DuplicateStrategy must be Skip, Update, or Reject.', 1;

    IF @BatchId IS NULL
        SET @BatchId = NEWID();

    INSERT INTO ingest.ImportBatch
        (BatchId, DatasetId, DataSourceId, SourceInfo, SourceFile, Status, ImportId, LoadMode, DuplicateStrategy, MaxRetries)
    VALUES
        (@BatchId, @DatasetId, @DataSourceId, @SourceInfo, @SourceFile, N'Pending', @ImportId, @LoadMode, @DuplicateStrategy, ISNULL(@CfgRetry, 3));

    SELECT
        b.BatchId,
        b.ImportId,
        d.DatasetCode,
        b.Status,
        b.LoadMode,
        b.DuplicateStrategy,
        b.ImportUtc
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    WHERE b.BatchId = @BatchId;
END
GO

CREATE OR ALTER PROCEDURE ingest.usp_CompleteStagingLoad
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM ingest.ImportBatch WHERE BatchId = @BatchId)
        THROW 50002, N'Batch not found.', 1;

    UPDATE s
    SET
        ImportId = b.ImportId,
        SourceFile = ISNULL(s.SourceFile, b.SourceFile)
    FROM ingest.StagingCustomer s
    INNER JOIN ingest.ImportBatch b ON b.BatchId = s.BatchId
    WHERE s.BatchId = @BatchId
      AND s.ImportId IS NULL;

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

    SELECT BatchId, ImportId, Status, TotalRecords
    FROM ingest.ImportBatch
    WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Set-based transformation driven by etl.TransformRule
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_TransformCustomerBatch
    @BatchId UNIQUEIDENTIFIER,
    @RunId   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER, @Status NVARCHAR(32);

    SELECT @DatasetId = DatasetId, @ImportId = ImportId, @Status = Status
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    UPDATE ingest.ImportBatch SET Status = N'Transforming' WHERE BatchId = @BatchId;

    DECLARE @Col NVARCHAR(128), @Type NVARCHAR(32), @P1 NVARCHAR(200), @P2 NVARCHAR(200), @RawCol NVARCHAR(128);
    DECLARE @Sql NVARCHAR(MAX);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT ColumnName, TransformType, Param1, Param2
        FROM etl.TransformRule
        WHERE DatasetId = @DatasetId AND IsActive = 1
          AND TransformType IN (N'Trim', N'Upper', N'Lower', N'NullDefault', N'Replace')
        ORDER BY StepOrder, TransformRuleId;

    OPEN c;
    FETCH NEXT FROM c INTO @Col, @Type, @P1, @P2;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @RawCol = etl.fn_RawColumn(@Col);
        IF @RawCol IS NOT NULL
        BEGIN
            SET @Sql = N'
                UPDATE ingest.StagingCustomer
                SET ' + QUOTENAME(@RawCol) + N' = etl.fn_TransformText(' + QUOTENAME(@RawCol) + N', @Type, @P1, @P2)
                WHERE BatchId = @BatchId
                  AND RowStatus <> N''Processed'';';
            EXEC sp_executesql @Sql,
                N'@BatchId UNIQUEIDENTIFIER, @Type NVARCHAR(32), @P1 NVARCHAR(200), @P2 NVARCHAR(200)',
                @BatchId = @BatchId, @Type = @Type, @P1 = @P1, @P2 = @P2;
        END
        FETCH NEXT FROM c INTO @Col, @Type, @P1, @P2;
    END
    CLOSE c; DEALLOCATE c;

    -- Standardize (set-based join)
    UPDATE s
    SET RawStatus = m.TargetValue
    FROM ingest.StagingCustomer s
    INNER JOIN etl.StandardizationMap m
        ON m.DatasetId = s.DatasetId
       AND m.ColumnName = N'Status'
       AND UPPER(LTRIM(RTRIM(ISNULL(s.RawStatus, N'')))) = UPPER(m.SourceValue)
    WHERE s.BatchId = @BatchId AND s.RowStatus <> N'Processed';

    UPDATE s
    SET RawCountryCode = m.TargetValue
    FROM ingest.StagingCustomer s
    INNER JOIN etl.StandardizationMap m
        ON m.DatasetId = s.DatasetId
       AND m.ColumnName = N'CountryCode'
       AND UPPER(LTRIM(RTRIM(ISNULL(s.RawCountryCode, N'')))) = UPPER(m.SourceValue)
    WHERE s.BatchId = @BatchId AND s.RowStatus <> N'Processed';

    -- Date normalize (write ISO string back to raw + typed)
    IF EXISTS (SELECT 1 FROM etl.TransformRule WHERE DatasetId = @DatasetId AND TransformType = N'DateNormalize' AND IsActive = 1)
    BEGIN
        UPDATE ingest.StagingCustomer
        SET RawCreatedDate = CONVERT(CHAR(10), etl.fn_TryNormalizeDate(RawCreatedDate), 23)
        WHERE BatchId = @BatchId
          AND RowStatus <> N'Processed'
          AND etl.fn_TryNormalizeDate(RawCreatedDate) IS NOT NULL;

        INSERT INTO etl.EtlError
            (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase)
        SELECT
            @RunId, s.BatchId, s.DatasetId, @ImportId, s.StagingRowId, s.RowNumber,
            N'CreatedDate', s.RawCreatedDate, N'XFORM_DATE', N'Date value could not be normalized.', N'Transform'
        FROM ingest.StagingCustomer s
        INNER JOIN etl.TransformRule r
            ON r.DatasetId = s.DatasetId AND r.ColumnName = N'CreatedDate' AND r.TransformType = N'DateNormalize' AND r.IsActive = 1
        WHERE s.BatchId = @BatchId
          AND s.RowStatus <> N'Processed'
          AND s.RawCreatedDate IS NOT NULL AND LTRIM(RTRIM(s.RawCreatedDate)) <> N''
          AND etl.fn_TryNormalizeDate(s.RawCreatedDate) IS NULL;
    END

    -- Numeric normalize
    IF EXISTS (SELECT 1 FROM etl.TransformRule WHERE DatasetId = @DatasetId AND TransformType = N'NumericNormalize' AND IsActive = 1)
    BEGIN
        UPDATE ingest.StagingCustomer
        SET RawCreditLimit = CONVERT(NVARCHAR(50), etl.fn_TryNormalizeDecimal(RawCreditLimit))
        WHERE BatchId = @BatchId
          AND RowStatus <> N'Processed'
          AND etl.fn_TryNormalizeDecimal(RawCreditLimit) IS NOT NULL;

        INSERT INTO etl.EtlError
            (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase)
        SELECT
            @RunId, s.BatchId, s.DatasetId, @ImportId, s.StagingRowId, s.RowNumber,
            N'CreditLimit', s.RawCreditLimit, N'XFORM_NUMERIC', N'Numeric value could not be normalized.', N'Transform'
        FROM ingest.StagingCustomer s
        INNER JOIN etl.TransformRule r
            ON r.DatasetId = s.DatasetId AND r.ColumnName = N'CreditLimit' AND r.TransformType = N'NumericNormalize' AND r.IsActive = 1
        WHERE s.BatchId = @BatchId
          AND s.RowStatus <> N'Processed'
          AND s.RawCreditLimit IS NOT NULL AND LTRIM(RTRIM(s.RawCreditLimit)) <> N''
          AND etl.fn_TryNormalizeDecimal(s.RawCreditLimit) IS NULL;
    END

    UPDATE ingest.StagingCustomer
    SET IsTransformed = 1
    WHERE BatchId = @BatchId AND RowStatus <> N'Processed';

    DECLARE @Xform INT =
        (SELECT COUNT(*) FROM ingest.StagingCustomer WHERE BatchId = @BatchId AND IsTransformed = 1);

    UPDATE ingest.ImportBatch
    SET TransformedRecords = @Xform, Status = N'Transformed'
    WHERE BatchId = @BatchId;

    SELECT BatchId, Status, TransformedRecords
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Configurable validation (set-based, unpivoted raw columns)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_ValidateCustomerBatch
    @BatchId UNIQUEIDENTIFIER,
    @RunId   UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER;

    SELECT @DatasetId = DatasetId, @ImportId = ImportId
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    UPDATE ingest.ImportBatch SET Status = N'Validating' WHERE BatchId = @BatchId;

    DELETE FROM etl.EtlError
    WHERE BatchId = @BatchId AND Phase = N'Validate';

    UPDATE ingest.StagingCustomer
    SET
        RowStatus = N'Pending',
        IsDuplicateInBatch = 0,
        IsDuplicateVsTarget = 0,
        CustomerCode = NULL, CustomerName = NULL, CountryCode = NULL,
        Email = NULL, CreditLimit = NULL, Status = NULL, CreatedDate = NULL
    WHERE BatchId = @BatchId AND RowStatus <> N'Processed';

    ;WITH RawCols AS (
        SELECT s.StagingRowId, s.BatchId, s.DatasetId, s.RowNumber, v.ColumnName, v.RawValue
        FROM ingest.StagingCustomer s
        CROSS APPLY (VALUES
            (N'CustomerCode', s.RawCustomerCode),
            (N'CustomerName', s.RawCustomerName),
            (N'CountryCode',  s.RawCountryCode),
            (N'Email',        s.RawEmail),
            (N'CreditLimit',  s.RawCreditLimit),
            (N'Status',       s.RawStatus),
            (N'CreatedDate',  s.RawCreatedDate)
        ) v (ColumnName, RawValue)
        WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
    )
    INSERT INTO etl.EtlError
        (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase, Severity)
    SELECT
        @RunId, c.BatchId, c.DatasetId, @ImportId, c.StagingRowId, c.RowNumber,
        c.ColumnName, LEFT(c.RawValue, 500), r.ErrorCode, r.ErrorMessage, N'Validate', r.Severity
    FROM RawCols c
    INNER JOIN etl.ValidationRule r
        ON r.DatasetId = c.DatasetId AND r.ColumnName = c.ColumnName AND r.IsActive = 1
    WHERE
        (r.RuleType = N'Required' AND (c.RawValue IS NULL OR LTRIM(RTRIM(c.RawValue)) = N''))
        OR (r.RuleType = N'MinLength' AND c.RawValue IS NOT NULL AND LTRIM(RTRIM(c.RawValue)) <> N''
            AND LEN(LTRIM(RTRIM(c.RawValue))) < TRY_CONVERT(INT, r.Param1))
        OR (r.RuleType = N'MaxLength' AND c.RawValue IS NOT NULL
            AND LEN(c.RawValue) > TRY_CONVERT(INT, r.Param1))
        OR (r.RuleType = N'DataType' AND r.Param1 = N'Date'
            AND c.RawValue IS NOT NULL AND LTRIM(RTRIM(c.RawValue)) <> N''
            AND etl.fn_TryNormalizeDate(c.RawValue) IS NULL)
        OR (r.RuleType = N'DataType' AND r.Param1 IN (N'Decimal', N'Numeric')
            AND c.RawValue IS NOT NULL AND LTRIM(RTRIM(c.RawValue)) <> N''
            AND etl.fn_TryNormalizeDecimal(c.RawValue) IS NULL)
        OR (r.RuleType = N'MinValue'
            AND etl.fn_TryNormalizeDecimal(c.RawValue) < TRY_CONVERT(DECIMAL(18,2), r.Param1))
        OR (r.RuleType = N'MaxValue'
            AND etl.fn_TryNormalizeDecimal(c.RawValue) > TRY_CONVERT(DECIMAL(18,2), r.Param1))
        OR (r.RuleType = N'DateMin'
            AND etl.fn_TryNormalizeDate(c.RawValue) < TRY_CONVERT(DATE, r.Param1, 23))
        OR (r.RuleType = N'DateMax'
            AND etl.fn_TryNormalizeDate(c.RawValue) > ISNULL(TRY_CONVERT(DATE, r.Param1, 23), CAST(SYSUTCDATETIME() AS DATE)))
        OR (r.RuleType = N'AllowedValues'
            AND c.RawValue IS NOT NULL AND LTRIM(RTRIM(c.RawValue)) <> N''
            AND NOT EXISTS (
                SELECT 1 FROM etl.AllowedValue a
                WHERE a.DatasetId = c.DatasetId AND a.ColumnName = c.ColumnName
                  AND UPPER(a.AllowedValue) = UPPER(LTRIM(RTRIM(c.RawValue)))
            ))
        OR (r.RuleType = N'Regex' AND r.Param1 = N'Email'
            AND c.RawValue IS NOT NULL AND LTRIM(RTRIM(c.RawValue)) <> N''
            AND (CHARINDEX(N'@', c.RawValue) < 2
                 OR CHARINDEX(N'.', c.RawValue, CHARINDEX(N'@', c.RawValue)) = 0));

    -- Referential integrity (Country whitelist via ReferentialRule + ingest.Country)
    INSERT INTO etl.EtlError
        (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase)
    SELECT
        @RunId, s.BatchId, s.DatasetId, @ImportId, s.StagingRowId, s.RowNumber,
        N'CountryCode', s.RawCountryCode, r.ErrorCode, r.ErrorMessage, N'Validate'
    FROM ingest.StagingCustomer s
    INNER JOIN etl.ValidationRule r
        ON r.DatasetId = s.DatasetId AND r.ColumnName = N'CountryCode' AND r.RuleType = N'Referential' AND r.IsActive = 1
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND LEN(LTRIM(RTRIM(ISNULL(s.RawCountryCode, N'')))) > 0
      AND NOT EXISTS (
            SELECT 1 FROM ingest.Country c
            WHERE c.CountryCode = UPPER(LTRIM(RTRIM(s.RawCountryCode))) AND c.IsActive = 1
      );

    -- In-batch duplicates on key
    ;WITH Dupes AS (
        SELECT StagingRowId,
               ROW_NUMBER() OVER (
                   PARTITION BY UPPER(LTRIM(RTRIM(RawCustomerCode)))
                   ORDER BY RowNumber) AS rn
        FROM ingest.StagingCustomer
        WHERE BatchId = @BatchId AND RowStatus = N'Pending'
          AND RawCustomerCode IS NOT NULL AND LTRIM(RTRIM(RawCustomerCode)) <> N''
    )
    UPDATE s
    SET IsDuplicateInBatch = 1
    FROM ingest.StagingCustomer s
    INNER JOIN Dupes d ON d.StagingRowId = s.StagingRowId
    WHERE d.rn > 1;

    INSERT INTO etl.EtlError
        (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase)
    SELECT
        @RunId, s.BatchId, s.DatasetId, @ImportId, s.StagingRowId, s.RowNumber,
        N'CustomerCode', s.RawCustomerCode, N'DUP_IN_BATCH', N'Duplicate key within the import batch.', N'Validate'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.IsDuplicateInBatch = 1 AND s.RowStatus = N'Pending';

    UPDATE s
    SET RowStatus = N'Invalid'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending'
      AND EXISTS (SELECT 1 FROM etl.EtlError e WHERE e.StagingRowId = s.StagingRowId AND e.Phase = N'Validate' AND e.Severity = N'Error');

    UPDATE s
    SET
        CustomerCode = LEFT(UPPER(LTRIM(RTRIM(s.RawCustomerCode))), 32),
        CustomerName = LEFT(LTRIM(RTRIM(s.RawCustomerName)), 200),
        CountryCode  = UPPER(LTRIM(RTRIM(s.RawCountryCode))),
        Email        = NULLIF(LTRIM(RTRIM(s.RawEmail)), N''),
        CreditLimit  = ISNULL(etl.fn_TryNormalizeDecimal(s.RawCreditLimit), 0),
        Status       = CASE UPPER(LTRIM(RTRIM(ISNULL(NULLIF(s.RawStatus, N''), N'Active'))))
                           WHEN N'INACTIVE' THEN N'Inactive'
                           WHEN N'PROSPECT' THEN N'Prospect'
                           ELSE N'Active'
                       END,
        CreatedDate  = etl.fn_TryNormalizeDate(s.RawCreatedDate),
        RowStatus    = N'Valid'
    FROM ingest.StagingCustomer s
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Pending';

    DECLARE @Valid INT, @Invalid INT, @Total INT, @Processed INT, @Dup INT, @Err INT;
    SELECT
        @Valid = SUM(CASE WHEN RowStatus = N'Valid' THEN 1 ELSE 0 END),
        @Invalid = SUM(CASE WHEN RowStatus = N'Invalid' THEN 1 ELSE 0 END),
        @Processed = SUM(CASE WHEN RowStatus = N'Processed' THEN 1 ELSE 0 END),
        @Dup = SUM(CASE WHEN IsDuplicateInBatch = 1 THEN 1 ELSE 0 END),
        @Total = COUNT(*)
    FROM ingest.StagingCustomer WHERE BatchId = @BatchId;

    SELECT @Err = COUNT(*) FROM etl.EtlError WHERE BatchId = @BatchId;

    UPDATE ingest.ImportBatch
    SET
        TotalRecords = @Total,
        ValidRecords = ISNULL(@Valid, 0),
        RejectedRecords = ISNULL(@Invalid, 0),
        ProcessedRecords = ISNULL(@Processed, 0),
        DuplicateRecords = ISNULL(@Dup, 0),
        ErrorCount = @Err,
        Status = N'Validated'
    WHERE BatchId = @BatchId;

    SELECT BatchId, Status, TotalRecords, ValidRecords, RejectedRecords, DuplicateRecords, ErrorCount
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;
END
GO

-- ------------------------------------------------------------
-- Transactional load: Incremental MERGE or Full replace
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_LoadCustomerBatch
    @BatchId     UNIQUEIDENTIFIER,
    @RunId       UNIQUEIDENTIFIER = NULL,
    @ForceFail   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER;
    DECLARE @LoadMode NVARCHAR(16), @DupStrategy NVARCHAR(16);
    DECLARE @Inserted INT = 0, @Updated INT = 0, @Skipped INT = 0;

    SELECT
        @DatasetId = DatasetId, @ImportId = ImportId,
        @LoadMode = LoadMode, @DupStrategy = DuplicateStrategy
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    UPDATE ingest.ImportBatch SET Status = N'Processing' WHERE BatchId = @BatchId;

    -- Target duplicates vs curated table
    UPDATE s
    SET IsDuplicateVsTarget = 1
    FROM ingest.StagingCustomer s
    INNER JOIN ingest.Customer t ON t.CustomerCode = s.CustomerCode
    WHERE s.BatchId = @BatchId AND s.RowStatus = N'Valid';

    IF @DupStrategy = N'Reject'
    BEGIN
        INSERT INTO etl.EtlError
            (RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber, ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase)
        SELECT
            @RunId, s.BatchId, s.DatasetId, @ImportId, s.StagingRowId, s.RowNumber,
            N'CustomerCode', s.CustomerCode, N'DUP_TARGET', N'Duplicate key exists in target dataset (Reject strategy).', N'Load'
        FROM ingest.StagingCustomer s
        WHERE s.BatchId = @BatchId AND s.RowStatus = N'Valid' AND s.IsDuplicateVsTarget = 1;

        UPDATE ingest.StagingCustomer
        SET RowStatus = N'Invalid'
        WHERE BatchId = @BatchId AND RowStatus = N'Valid' AND IsDuplicateVsTarget = 1;
    END
    ELSE IF @DupStrategy = N'Skip'
    BEGIN
        UPDATE ingest.StagingCustomer
        SET RowStatus = N'Skipped'
        WHERE BatchId = @BatchId AND RowStatus = N'Valid' AND IsDuplicateVsTarget = 1;

        SET @Skipped = @@ROWCOUNT;
    END

    DECLARE @ValidCount INT =
        (SELECT COUNT(*) FROM ingest.StagingCustomer WHERE BatchId = @BatchId AND RowStatus = N'Valid');

    IF @LoadMode = N'Full' AND @ValidCount = 0
    BEGIN
        UPDATE ingest.ImportBatch
        SET Status = N'Failed',
            LastErrorMessage = N'Full import produced no valid records; existing dataset preserved.',
            CompletedUtc = SYSUTCDATETIME()
        WHERE BatchId = @BatchId;

        INSERT INTO etl.EtlError
            (RunId, BatchId, DatasetId, ImportId, RowNumber, ErrorCode, ErrorDescription, Phase)
        VALUES
            (@RunId, @BatchId, @DatasetId, @ImportId, NULL, N'FULL_EMPTY', N'Full import had zero valid rows; load aborted to preserve target.', N'Load');

        THROW 50020, N'Full import produced no valid records; existing dataset preserved.', 1;
    END

    BEGIN TRAN;

    BEGIN TRY
        IF @LoadMode = N'Full'
        BEGIN
            -- Replace target only after staging the valid set; rollback restores prior rows
            DELETE FROM ingest.Customer;

            INSERT INTO ingest.Customer
                (CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, SourceBatchId)
            SELECT
                CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, BatchId
            FROM ingest.StagingCustomer
            WHERE BatchId = @BatchId AND RowStatus = N'Valid';

            SET @Inserted = @@ROWCOUNT;
            SET @Updated = 0;
        END
        ELSE
        BEGIN
            DECLARE @MergeOutput TABLE (ActionTaken NVARCHAR(10));

            MERGE ingest.Customer AS t
            USING (
                SELECT CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, BatchId
                FROM ingest.StagingCustomer
                WHERE BatchId = @BatchId AND RowStatus = N'Valid'
            ) AS s
            ON t.CustomerCode = s.CustomerCode
            WHEN MATCHED AND @DupStrategy = N'Update' THEN
                UPDATE SET
                    CustomerName = s.CustomerName,
                    CountryCode = s.CountryCode,
                    Email = s.Email,
                    CreditLimit = s.CreditLimit,
                    Status = s.Status,
                    CreatedDate = s.CreatedDate,
                    SourceBatchId = s.BatchId,
                    ModifiedUtc = SYSUTCDATETIME()
            WHEN NOT MATCHED THEN
                INSERT (CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, SourceBatchId)
                VALUES (s.CustomerCode, s.CustomerName, s.CountryCode, s.Email, s.CreditLimit, s.Status, s.CreatedDate, s.BatchId)
            OUTPUT $action INTO @MergeOutput;

            SELECT
                @Inserted = ISNULL(SUM(CASE WHEN ActionTaken = N'INSERT' THEN 1 ELSE 0 END), 0),
                @Updated  = ISNULL(SUM(CASE WHEN ActionTaken = N'UPDATE' THEN 1 ELSE 0 END), 0)
            FROM @MergeOutput;
        END

        IF @ForceFail = 1
            THROW 50099, N'Forced failure for transaction rollback demonstration.', 1;

        UPDATE ingest.StagingCustomer
        SET RowStatus = N'Processed', ProcessedUtc = SYSUTCDATETIME()
        WHERE BatchId = @BatchId AND RowStatus = N'Valid';

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        INSERT INTO etl.EtlError
            (RunId, BatchId, DatasetId, ImportId, ErrorCode, ErrorDescription, Phase)
        VALUES
            (@RunId, @BatchId, @DatasetId, @ImportId, N'LOAD_FAILURE', LEFT(ERROR_MESSAGE(), 1000), N'Load');

        THROW;
    END CATCH;

    DECLARE @Rejected INT, @Err INT, @TotalProcessed INT, @Dup INT;
    SELECT
        @Rejected = SUM(CASE WHEN RowStatus = N'Invalid' THEN 1 ELSE 0 END),
        @TotalProcessed = SUM(CASE WHEN RowStatus = N'Processed' THEN 1 ELSE 0 END),
        @Skipped = SUM(CASE WHEN RowStatus = N'Skipped' THEN 1 ELSE 0 END),
        @Dup = SUM(CASE WHEN IsDuplicateInBatch = 1 OR IsDuplicateVsTarget = 1 THEN 1 ELSE 0 END)
    FROM ingest.StagingCustomer WHERE BatchId = @BatchId;

    SELECT @Err = COUNT(*) FROM etl.EtlError WHERE BatchId = @BatchId;

    UPDATE ingest.ImportBatch
    SET
        ProcessedRecords = ISNULL(@TotalProcessed, 0),
        InsertedRecords = InsertedRecords + @Inserted,
        UpdatedRecords = UpdatedRecords + @Updated,
        RejectedRecords = ISNULL(@Rejected, 0),
        DuplicateRecords = ISNULL(@Dup, 0),
        ErrorCount = @Err,
        CompletedUtc = SYSUTCDATETIME(),
        DurationMs = DATEDIFF(MILLISECOND, StartedUtc, SYSUTCDATETIME()),
        Status = CASE
            WHEN ISNULL(@Rejected, 0) > 0 OR @Err > 0 THEN N'CompletedWithErrors'
            ELSE N'Completed'
        END
    WHERE BatchId = @BatchId;

    SELECT
        @Inserted AS InsertedRecords,
        @Updated AS UpdatedRecords,
        @Skipped AS SkippedRecords,
        ISNULL(@Rejected, 0) AS RejectedRecords;
END
GO

-- ------------------------------------------------------------
-- Orchestrator: transform → validate → load (retry-safe)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE etl.usp_RunPipeline
    @BatchId     UNIQUEIDENTIFIER,
    @TriggerType NVARCHAR(16) = N'Manual',
    @ForceFail   BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @ImportId UNIQUEIDENTIFIER, @Status NVARCHAR(32);
    DECLARE @Attempts INT, @MaxRetries INT, @RunId UNIQUEIDENTIFIER = NEWID();
    DECLARE @Start DATETIME2(3) = SYSUTCDATETIME();

    SELECT
        @DatasetId = DatasetId, @ImportId = ImportId, @Status = Status,
        @Attempts = AttemptCount, @MaxRetries = MaxRetries
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    IF @DatasetId IS NULL
        THROW 50002, N'Batch not found.', 1;

    IF @Status = N'Exhausted'
        THROW 50021, N'Batch retry limit exhausted.', 1;

    IF @TriggerType = N'Retry' AND @Attempts >= @MaxRetries
    BEGIN
        UPDATE ingest.ImportBatch SET Status = N'Exhausted', LastErrorMessage = N'Max retries reached.'
        WHERE BatchId = @BatchId;
        THROW 50021, N'Batch retry limit exhausted.', 1;
    END

    IF @TriggerType NOT IN (N'Manual', N'Agent', N'Retry', N'Api')
        SET @TriggerType = N'Manual';

    SET @Attempts = ISNULL(@Attempts, 0) + 1;

    UPDATE ingest.ImportBatch
    SET
        AttemptCount = @Attempts,
        StartedUtc = ISNULL(StartedUtc, @Start),
        LastErrorMessage = NULL
    WHERE BatchId = @BatchId;

    INSERT INTO etl.EtlRun
        (RunId, BatchId, DatasetId, ImportId, TriggerType, Status, AttemptNumber, TotalRecords)
    SELECT @RunId, BatchId, DatasetId, ImportId, @TriggerType, N'Running', @Attempts, TotalRecords
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    INSERT INTO ingest.BatchProcessAttempt (BatchId, AttemptNumber, TriggerType, Status)
    VALUES (@BatchId, @Attempts, @TriggerType, N'Running');

    DECLARE @AttemptId BIGINT = SCOPE_IDENTITY();

    BEGIN TRY
        EXEC etl.usp_TransformCustomerBatch @BatchId = @BatchId, @RunId = @RunId;
        EXEC etl.usp_ValidateCustomerBatch @BatchId = @BatchId, @RunId = @RunId;
        EXEC etl.usp_LoadCustomerBatch @BatchId = @BatchId, @RunId = @RunId, @ForceFail = @ForceFail;

        DECLARE @Ins INT, @Upd INT, @Skip INT, @Xform INT, @Valid INT, @Invalid INT, @Dup INT, @Err INT, @Total INT, @Final NVARCHAR(32);

        SELECT
            @Ins = InsertedRecords, @Upd = UpdatedRecords, @Xform = TransformedRecords,
            @Valid = ValidRecords, @Invalid = RejectedRecords, @Dup = DuplicateRecords,
            @Err = ErrorCount, @Total = TotalRecords, @Final = Status
        FROM ingest.ImportBatch WHERE BatchId = @BatchId;

        SELECT @Skip = COUNT(*) FROM ingest.StagingCustomer WHERE BatchId = @BatchId AND RowStatus = N'Skipped';

        UPDATE etl.EtlRun
        SET
            Status = CASE WHEN @Final = N'Completed' THEN N'Succeeded' ELSE N'Partial' END,
            CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            TotalRecords = @Total,
            TransformedRecords = @Xform,
            ValidRecords = @Valid,
            InvalidRecords = @Invalid,
            DuplicateRecords = @Dup,
            InsertedRecords = @Ins,
            UpdatedRecords = @Upd,
            SkippedRecords = ISNULL(@Skip, 0),
            ProcessingErrors = @Err
        WHERE RunId = @RunId;

        UPDATE ingest.BatchProcessAttempt
        SET Status = CASE WHEN @Final = N'Completed' THEN N'Succeeded' ELSE N'Partial' END,
            CompletedUtc = SYSUTCDATETIME(),
            ProcessedCount = @Ins + @Upd,
            InsertedCount = @Ins,
            UpdatedCount = @Upd
        WHERE AttemptId = @AttemptId;
    END TRY
    BEGIN CATCH
        UPDATE ingest.ImportBatch
        SET
            Status = CASE WHEN @Attempts >= @MaxRetries THEN N'Exhausted' ELSE N'Failed' END,
            LastErrorMessage = LEFT(ERROR_MESSAGE(), 2000),
            CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, ISNULL(StartedUtc, @Start), SYSUTCDATETIME())
        WHERE BatchId = @BatchId;

        UPDATE etl.EtlRun
        SET
            Status = N'RolledBack',
            CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000),
            ProcessingErrors = ProcessingErrors + 1
        WHERE RunId = @RunId;

        UPDATE ingest.BatchProcessAttempt
        SET Status = N'Failed', CompletedUtc = SYSUTCDATETIME(), ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE AttemptId = @AttemptId;

        THROW;
    END CATCH;

    EXEC etl.usp_GetBatchStatus @BatchId = @BatchId;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_RetryFailedBatch
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status NVARCHAR(32), @Attempts INT, @MaxRetries INT;

    SELECT @Status = Status, @Attempts = AttemptCount, @MaxRetries = MaxRetries
    FROM ingest.ImportBatch WHERE BatchId = @BatchId;

    IF @Status IS NULL
        THROW 50002, N'Batch not found.', 1;
    IF @Status = N'Exhausted'
        THROW 50021, N'Batch retry limit exhausted.', 1;
    IF @Status NOT IN (N'Failed', N'CompletedWithErrors', N'RetryPending', N'Validated', N'Transformed', N'Loaded')
        THROW 50005, N'Batch is not eligible for retry.', 1;
    IF @Attempts >= @MaxRetries
    BEGIN
        UPDATE ingest.ImportBatch SET Status = N'Exhausted' WHERE BatchId = @BatchId;
        THROW 50021, N'Batch retry limit exhausted.', 1;
    END

    UPDATE ingest.ImportBatch SET Status = N'RetryPending' WHERE BatchId = @BatchId;
    EXEC etl.usp_RunPipeline @BatchId = @BatchId, @TriggerType = N'Retry';
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ProcessPendingBatches
    @MaxBatches INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @BatchId UNIQUEIDENTIFIER, @Processed INT = 0;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@MaxBatches) BatchId
        FROM ingest.ImportBatch
        WHERE Status IN (N'Loaded', N'Transformed', N'Validated', N'RetryPending', N'Failed')
          AND AttemptCount < MaxRetries
        ORDER BY ImportUtc;

    OPEN c;
    FETCH NEXT FROM c INTO @BatchId;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC etl.usp_RunPipeline @BatchId = @BatchId, @TriggerType = N'Agent';
            SET @Processed += 1;
        END TRY
        BEGIN CATCH
            PRINT ERROR_MESSAGE();
        END CATCH;
        FETCH NEXT FROM c INTO @BatchId;
    END
    CLOSE c; DEALLOCATE c;

    SELECT @Processed AS BatchesProcessed;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_GetBatchStatus
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        b.BatchId,
        b.ImportId,
        d.DatasetCode,
        d.DisplayName AS DatasetName,
        b.DataSourceId,
        b.SourceInfo,
        b.SourceFile,
        b.LoadMode,
        b.DuplicateStrategy,
        b.ImportUtc,
        b.Status,
        b.TotalRecords,
        b.ValidRecords,
        b.RejectedRecords,
        b.ProcessedRecords,
        b.InsertedRecords,
        b.UpdatedRecords,
        b.TransformedRecords,
        b.DuplicateRecords,
        b.ErrorCount,
        b.AttemptCount,
        b.MaxRetries,
        b.StartedUtc,
        b.CompletedUtc,
        b.DurationMs,
        CASE WHEN b.DurationMs IS NOT NULL THEN b.DurationMs / 1000.0
             WHEN b.StartedUtc IS NOT NULL AND b.CompletedUtc IS NOT NULL
                THEN DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc) / 1000.0
             ELSE NULL END AS DurationSeconds,
        b.LastErrorMessage
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    WHERE b.BatchId = @BatchId;
END
GO

CREATE OR ALTER PROCEDURE ingest.usp_GetBatchStatus
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    EXEC etl.usp_GetBatchStatus @BatchId = @BatchId;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_GetErrorsByBatch
    @BatchId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.ErrorId, e.RunId, e.BatchId, e.DatasetId, e.ImportId,
        e.StagingRowId, e.RowNumber, e.ColumnName, e.InvalidValue,
        e.ErrorCode, e.ErrorDescription, e.Phase, e.Severity, e.ErrorUtc
    FROM etl.EtlError e
    WHERE e.BatchId = @BatchId
    ORDER BY e.ErrorId;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_GetErrorsByDataset
    @DatasetCode NVARCHAR(64),
    @FromUtc DATETIME2(3) = NULL,
    @ToUtc   DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToUtc = ISNULL(@ToUtc, SYSUTCDATETIME());
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -30, @ToUtc));

    SELECT
        e.ErrorId, e.RunId, e.BatchId, e.DatasetId, d.DatasetCode, e.ImportId,
        e.StagingRowId, e.RowNumber, e.ColumnName, e.InvalidValue,
        e.ErrorCode, e.ErrorDescription, e.Phase, e.Severity, e.ErrorUtc
    FROM etl.EtlError e
    INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
    WHERE d.DatasetCode = @DatasetCode
      AND e.ErrorUtc >= @FromUtc AND e.ErrorUtc < @ToUtc
    ORDER BY e.ErrorUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_ArchiveErrors
    @RetainDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    INSERT INTO etl.EtlErrorArchive
        (ErrorId, RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber,
         ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase, Severity, ErrorUtc)
    SELECT
        ErrorId, RunId, BatchId, DatasetId, ImportId, StagingRowId, RowNumber,
        ColumnName, InvalidValue, ErrorCode, ErrorDescription, Phase, Severity, ErrorUtc
    FROM etl.EtlError
    WHERE ErrorUtc < @Cutoff;

    DELETE FROM etl.EtlError WHERE ErrorUtc < @Cutoff;
    SELECT @@ROWCOUNT AS ErrorsArchived;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_CleanupBatches
    @RetainDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    DELETE FROM ingest.ImportBatch
    WHERE ImportUtc < @Cutoff
      AND Status IN (N'Completed', N'CompletedWithErrors', N'Exhausted');

    SELECT @@ROWCOUNT AS BatchesRemoved;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_GenerateQualitySnapshot
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO etl.QualitySnapshot
        (DatasetId, BatchCount30d, TotalRecords30d, ValidRecords30d, InvalidRecords30d, SuccessRatePct, AvgDurationMs)
    SELECT
        d.DatasetId,
        COUNT(b.BatchId),
        ISNULL(SUM(b.TotalRecords), 0),
        ISNULL(SUM(b.ValidRecords), 0),
        ISNULL(SUM(b.RejectedRecords), 0),
        CAST(100.0 * SUM(CASE WHEN b.Status IN (N'Completed', N'CompletedWithErrors') THEN 1 ELSE 0 END)
             / NULLIF(COUNT(b.BatchId), 0) AS DECIMAL(9,2)),
        AVG(b.DurationMs)
    FROM ingest.Dataset d
    LEFT JOIN ingest.ImportBatch b
        ON b.DatasetId = d.DatasetId
       AND b.ImportUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
    WHERE d.IsActive = 1
    GROUP BY d.DatasetId;

    SELECT @@ROWCOUNT AS SnapshotsWritten;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_GenerateTestBatch
    @RowCount INT = 1000,
    @BatchId  UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @DatasetId UNIQUEIDENTIFIER =
        (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER');

    EXEC ingest.usp_CreateImportBatch
        @DatasetCode = N'CUSTOMER',
        @SourceInfo = N'etl.usp_GenerateTestBatch',
        @SourceFile = N'generated-large-batch.csv',
        @LoadMode = N'Incremental',
        @DuplicateStrategy = N'Update',
        @BatchId = @BatchId OUTPUT;

    ;WITH n AS (
        SELECT TOP (@RowCount) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    )
    INSERT INTO ingest.StagingCustomer
        (BatchId, DatasetId, RowNumber, RawCustomerCode, RawCustomerName, RawCountryCode,
         RawEmail, RawCreditLimit, RawStatus, RawCreatedDate, SourceInfo)
    SELECT
        @BatchId, @DatasetId, n,
        CONCAT(N'GEN-', RIGHT(CONCAT(N'000000', n), 6)),
        CONCAT(N'Generated Customer ', n),
        CASE n % 5 WHEN 0 THEN N'US' WHEN 1 THEN N'UK' WHEN 2 THEN N'DE' WHEN 3 THEN N'IN' ELSE N'CA' END,
        CONCAT(N'user', n, N'@example.com'),
        CONVERT(NVARCHAR(20), (n % 50) * 100),
        N'Active',
        N'2024-01-15',
        N'generated'
    FROM n;

    EXEC ingest.usp_CompleteStagingLoad @BatchId = @BatchId;
    SELECT @BatchId AS BatchId, @RowCount AS RowsLoaded;
END
GO

PRINT 'ETL procedures created.';
GO
