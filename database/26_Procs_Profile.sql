-- ============================================================
-- 26_Procs_Profile.sql
-- Dataset quality profiling engine (set-based, configurable score)
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER FUNCTION profile.fn_EvaluateThreshold
(
    @Actual DECIMAL(18,6),
    @Operator NVARCHAR(8),
    @Threshold DECIMAL(18,6)
)
RETURNS BIT
AS
BEGIN
    RETURN CASE @Operator
        WHEN N'>=' THEN CASE WHEN @Actual >= @Threshold THEN 1 ELSE 0 END
        WHEN N'>'  THEN CASE WHEN @Actual >  @Threshold THEN 1 ELSE 0 END
        WHEN N'<=' THEN CASE WHEN @Actual <= @Threshold THEN 1 ELSE 0 END
        WHEN N'<'  THEN CASE WHEN @Actual <  @Threshold THEN 1 ELSE 0 END
        WHEN N'='  THEN CASE WHEN @Actual =  @Threshold THEN 1 ELSE 0 END
        ELSE 0
    END;
END
GO

CREATE OR ALTER FUNCTION profile.fn_Grade
(
    @Score DECIMAL(5,2)
)
RETURNS NVARCHAR(8)
AS
BEGIN
    RETURN CASE
        WHEN @Score >= 90 THEN N'A'
        WHEN @Score >= 80 THEN N'B'
        WHEN @Score >= 70 THEN N'C'
        WHEN @Score >= 60 THEN N'D'
        ELSE N'F'
    END;
END
GO

-- Score weights for a dataset (dataset-specific overrides global)
CREATE OR ALTER FUNCTION profile.fn_GetWeight
(
    @DatasetId UNIQUEIDENTIFIER,
    @DimensionCode NVARCHAR(32)
)
RETURNS DECIMAL(5,2)
AS
BEGIN
    DECLARE @W DECIMAL(5,2);

    SELECT TOP (1) @W = WeightPct
    FROM profile.ScoreWeight
    WHERE DimensionCode = @DimensionCode AND IsActive = 1
      AND DatasetId = @DatasetId
    ORDER BY ScoreWeightId;

    IF @W IS NULL
        SELECT TOP (1) @W = WeightPct
        FROM profile.ScoreWeight
        WHERE DimensionCode = @DimensionCode AND IsActive = 1
          AND DatasetId IS NULL
        ORDER BY ScoreWeightId;

    RETURN ISNULL(@W, 0);
END
GO

CREATE OR ALTER PROCEDURE profile.usp_EnsureDatasetProfile
    @DatasetId UNIQUEIDENTIFIER,
    @DatasetProfileId UNIQUEIDENTIFIER OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @DatasetProfileId = DatasetProfileId
    FROM profile.DatasetProfile
    WHERE DatasetId = @DatasetId;

    IF @DatasetProfileId IS NULL
    BEGIN
        SET @DatasetProfileId = NEWID();
        INSERT INTO profile.DatasetProfile (DatasetProfileId, DatasetId, ProfileScope)
        VALUES (@DatasetProfileId, @DatasetId, N'Processed');
    END
END
GO

-- ------------------------------------------------------------
-- Core profiler for CUSTOMER curated + staging tables
-- Single-pass style aggregations via CTEs / window functions
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE profile.usp_ProfileCustomerDataset
    @DatasetCode   NVARCHAR(64) = N'CUSTOMER',
    @ProfileScope  NVARCHAR(16) = N'Processed', -- Processed | Staging | Both
    @TriggerType   NVARCHAR(16) = N'Manual',
    @ImportId      UNIQUEIDENTIFIER = NULL,
    @BatchId       UNIQUEIDENTIFIER = NULL,
    @ProfileRunId  UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER;
    DECLARE @KeyColumn NVARCHAR(128);
    DECLARE @DatasetProfileId UNIQUEIDENTIFIER;
    DECLARE @Start DATETIME2(3) = SYSUTCDATETIME();

    SELECT @DatasetId = DatasetId, @KeyColumn = KeyColumn
    FROM ingest.Dataset
    WHERE DatasetCode = @DatasetCode AND IsActive = 1;

    IF @DatasetId IS NULL
        THROW 51001, N'Dataset not found or inactive.', 1;

    IF @ProfileScope NOT IN (N'Processed', N'Staging', N'Both')
        SET @ProfileScope = N'Processed';
    IF @TriggerType NOT IN (N'Manual', N'Agent', N'Retry', N'Api')
        SET @TriggerType = N'Manual';

    EXEC profile.usp_EnsureDatasetProfile @DatasetId = @DatasetId, @DatasetProfileId = @DatasetProfileId OUTPUT;

    SET @ProfileRunId = ISNULL(@ProfileRunId, NEWID());

    INSERT INTO profile.ProfileRun
        (ProfileRunId, DatasetId, DatasetProfileId, ImportId, BatchId, ProfileScope, TriggerType, Status)
    VALUES
        (@ProfileRunId, @DatasetId, @DatasetProfileId, @ImportId, @BatchId, @ProfileScope, @TriggerType, N'Running');

    BEGIN TRY
        /* Working set: one scan of source into #Rows */
        CREATE TABLE #Rows
        (
            RowKey         NVARCHAR(64)  NOT NULL,
            CustomerCode   NVARCHAR(32)  NULL,
            CustomerName   NVARCHAR(200) NULL,
            CountryCode    NCHAR(2)      NULL,
            Email          NVARCHAR(256) NULL,
            CreditLimit    DECIMAL(18,2) NULL,
            Status         NVARCHAR(16)  NULL,
            CreatedDate    DATE          NULL,
            SourceScope    NVARCHAR(16)  NOT NULL
        );

        IF @ProfileScope IN (N'Processed', N'Both')
        BEGIN
            INSERT INTO #Rows (RowKey, CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, SourceScope)
            SELECT
                ISNULL(CustomerCode, CONCAT(N'#', CustomerId)),
                CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, N'Processed'
            FROM ingest.Customer;
        END

        IF @ProfileScope IN (N'Staging', N'Both')
        BEGIN
            INSERT INTO #Rows (RowKey, CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, SourceScope)
            SELECT
                ISNULL(CustomerCode, CONCAT(N'S', StagingRowId)),
                CustomerCode, CustomerName, CountryCode, Email, CreditLimit, Status, CreatedDate, N'Staging'
            FROM ingest.StagingCustomer
            WHERE (@BatchId IS NULL OR BatchId = @BatchId)
              AND (@ImportId IS NULL OR ImportId = @ImportId)
              AND RowStatus IN (N'Valid', N'Processed', N'Invalid', N'Skipped', N'Pending');
        END

        DECLARE @Total BIGINT = (SELECT COUNT(*) FROM #Rows);

        /* ---- Dataset-level completeness (cell matrix) ---- */
        DECLARE @NullCells BIGINT =
            (SELECT
                SUM(CASE WHEN CustomerCode IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN CustomerName IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN CountryCode IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN Email IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN CreditLimit IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN Status IS NULL THEN 1 ELSE 0 END) +
                SUM(CASE WHEN CreatedDate IS NULL THEN 1 ELSE 0 END)
             FROM #Rows);

        DECLARE @TotalCells BIGINT = @Total * 7;
        DECLARE @CompletenessPct DECIMAL(9,4) =
            CASE WHEN @TotalCells = 0 THEN 100.0
                 ELSE CAST(100.0 * (@TotalCells - ISNULL(@NullCells, 0)) / @TotalCells AS DECIMAL(9,4)) END;

        /* ---- Uniqueness on key column (CustomerCode) ---- */
        DECLARE @DistinctKeys BIGINT;
        DECLARE @DupRecords BIGINT;

        ;WITH KeyAgg AS (
            SELECT CustomerCode, COUNT(*) AS Cnt
            FROM #Rows
            WHERE CustomerCode IS NOT NULL
            GROUP BY CustomerCode
        )
        SELECT
            @DistinctKeys = COUNT(*),
            @DupRecords = ISNULL(SUM(CASE WHEN Cnt > 1 THEN Cnt - 1 ELSE 0 END), 0)
        FROM KeyAgg;

        DECLARE @NonNullKeys BIGINT =
            (SELECT COUNT(*) FROM #Rows WHERE CustomerCode IS NOT NULL);

        DECLARE @UniquenessPct DECIMAL(9,4) =
            CASE WHEN ISNULL(@NonNullKeys, 0) = 0 THEN CASE WHEN @Total = 0 THEN 100.0 ELSE 0 END
                 ELSE CAST(100.0 * @DistinctKeys / @NonNullKeys AS DECIMAL(9,4)) END;

        DECLARE @DuplicatePct DECIMAL(9,4) =
            CASE WHEN @Total = 0 THEN 0
                 ELSE CAST(100.0 * ISNULL(@DupRecords, 0) / @Total AS DECIMAL(9,4)) END;

        /* ---- Validity from ETL errors (dataset / import scoped) ---- */
        DECLARE @InvalidRecords BIGINT = 0;
        DECLARE @ValidationErrorCount BIGINT = 0;

        IF @ProfileScope IN (N'Staging', N'Both') OR @BatchId IS NOT NULL OR @ImportId IS NOT NULL
        BEGIN
            SELECT
                @ValidationErrorCount = COUNT(*),
                @InvalidRecords = COUNT(DISTINCT StagingRowId)
            FROM etl.EtlError e
            WHERE e.DatasetId = @DatasetId
              AND e.Phase IN (N'Validate', N'Transform', N'Load')
              AND e.Severity = N'Error'
              AND (@BatchId IS NULL OR e.BatchId = @BatchId)
              AND (@ImportId IS NULL OR e.ImportId = @ImportId)
              AND e.ErrorUtc >= DATEADD(DAY, -30, SYSUTCDATETIME());
        END
        ELSE
        BEGIN
            -- Processed scope: estimate invalid as 0 in target; surface recent ETL errors as issues only
            SELECT @ValidationErrorCount = COUNT(*)
            FROM etl.EtlError e
            WHERE e.DatasetId = @DatasetId
              AND e.Severity = N'Error'
              AND e.ErrorUtc >= DATEADD(DAY, -30, SYSUTCDATETIME());

            SET @InvalidRecords = 0;
        END

        DECLARE @ValidRecords BIGINT =
            CASE WHEN @Total = 0 THEN 0 ELSE @Total - ISNULL(@InvalidRecords, 0) END;
        IF @ValidRecords < 0 SET @ValidRecords = 0;

        DECLARE @ValidityPct DECIMAL(9,4) =
            CASE WHEN @Total = 0 THEN 100.0
                 ELSE CAST(100.0 * @ValidRecords / @Total AS DECIMAL(9,4)) END;

        DECLARE @ErrorPct DECIMAL(9,4) =
            CASE WHEN @Total = 0 THEN 0
                 ELSE CAST(100.0 * ISNULL(@InvalidRecords, 0) / @Total AS DECIMAL(9,4)) END;

        /* ---- Consistency: allowed Status + active Country ---- */
        DECLARE @Inconsistent BIGINT;
        ;WITH Bad AS (
            SELECT COUNT(*) AS Cnt
            FROM #Rows r
            WHERE
                (r.Status IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM etl.AllowedValue a
                    WHERE a.DatasetId = @DatasetId AND a.ColumnName = N'Status'
                      AND UPPER(a.AllowedValue) = UPPER(r.Status)))
                OR
                (r.CountryCode IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM ingest.Country c
                    WHERE c.CountryCode = r.CountryCode AND c.IsActive = 1))
        )
        SELECT @Inconsistent = Cnt FROM Bad;

        DECLARE @ConsistencyPct DECIMAL(9,4) =
            CASE WHEN @Total = 0 THEN 100.0
                 ELSE CAST(100.0 * (@Total - ISNULL(@Inconsistent, 0)) / @Total AS DECIMAL(9,4)) END;

        /* ---- Column profiles (set-based UNPIVOT-style via CROSS APPLY) ---- */
        ;WITH ColBase AS (
            SELECT v.ColumnName, v.DataCategory, v.TextVal, v.NumVal, v.DateVal, v.IsNull
            FROM #Rows r
            CROSS APPLY (VALUES
                (N'CustomerCode', N'Text',    CAST(r.CustomerCode AS NVARCHAR(500)), NULL, NULL, CASE WHEN r.CustomerCode IS NULL THEN 1 ELSE 0 END),
                (N'CustomerName', N'Text',    CAST(r.CustomerName AS NVARCHAR(500)), NULL, NULL, CASE WHEN r.CustomerName IS NULL THEN 1 ELSE 0 END),
                (N'CountryCode',  N'Text',    CAST(r.CountryCode AS NVARCHAR(500)),  NULL, NULL, CASE WHEN r.CountryCode IS NULL THEN 1 ELSE 0 END),
                (N'Email',        N'Text',    CAST(r.Email AS NVARCHAR(500)),        NULL, NULL, CASE WHEN r.Email IS NULL THEN 1 ELSE 0 END),
                (N'Status',       N'Text',    CAST(r.Status AS NVARCHAR(500)),       NULL, NULL, CASE WHEN r.Status IS NULL THEN 1 ELSE 0 END),
                (N'CreditLimit',  N'Numeric', CAST(r.CreditLimit AS NVARCHAR(500)),  CAST(r.CreditLimit AS DECIMAL(18,6)), NULL, CASE WHEN r.CreditLimit IS NULL THEN 1 ELSE 0 END),
                (N'CreatedDate',  N'Date',    CONVERT(NVARCHAR(500), r.CreatedDate, 23), NULL, r.CreatedDate, CASE WHEN r.CreatedDate IS NULL THEN 1 ELSE 0 END)
            ) v (ColumnName, DataCategory, TextVal, NumVal, DateVal, IsNull)
        ),
        Agg AS (
            SELECT
                ColumnName,
                MAX(DataCategory) AS DataCategory,
                COUNT(*) AS TotalRecords,
                SUM(CASE WHEN IsNull = 0 THEN 1 ELSE 0 END) AS NonNullRecords,
                SUM(IsNull) AS NullRecords,
                COUNT(DISTINCT CASE WHEN IsNull = 0 THEN TextVal END) AS DistinctCount
            FROM ColBase
            GROUP BY ColumnName
        ),
        DupCalc AS (
            SELECT ColumnName, SUM(CASE WHEN Cnt > 1 THEN Cnt - 1 ELSE 0 END) AS DuplicateValueCount
            FROM (
                SELECT ColumnName, TextVal, COUNT(*) AS Cnt
                FROM ColBase
                WHERE IsNull = 0
                GROUP BY ColumnName, TextVal
            ) x
            GROUP BY ColumnName
        ),
        TextStats AS (
            SELECT
                ColumnName,
                MIN(LEN(TextVal)) AS MinLength,
                MAX(LEN(TextVal)) AS MaxLength,
                AVG(CAST(LEN(TextVal) AS DECIMAL(18,4))) AS AvgLength,
                MIN(TextVal) AS MinValue,
                MAX(TextVal) AS MaxValue
            FROM ColBase
            WHERE DataCategory = N'Text' AND IsNull = 0
            GROUP BY ColumnName
        ),
        NumStats AS (
            SELECT
                ColumnName,
                MIN(NumVal) AS MinNum,
                MAX(NumVal) AS MaxNum,
                AVG(NumVal) AS AvgNum,
                STDEV(NumVal) AS StdDevNum
            FROM ColBase
            WHERE DataCategory = N'Numeric' AND IsNull = 0
            GROUP BY ColumnName
        ),
        MedStats AS (
            SELECT DISTINCT
                ColumnName,
                PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY NumVal) OVER (PARTITION BY ColumnName) AS MedianNum
            FROM ColBase
            WHERE DataCategory = N'Numeric' AND IsNull = 0
        ),
        DateStats AS (
            SELECT
                ColumnName,
                MIN(DateVal) AS MinDate,
                MAX(DateVal) AS MaxDate,
                COUNT(DISTINCT DateVal) AS DistinctDateCount,
                CONVERT(NVARCHAR(500), MIN(DateVal), 23) AS MinValue,
                CONVERT(NVARCHAR(500), MAX(DateVal), 23) AS MaxValue
            FROM ColBase
            WHERE DataCategory = N'Date' AND IsNull = 0
            GROUP BY ColumnName
        )
        INSERT INTO profile.ColumnProfile
            (ProfileRunId, ColumnName, DataCategory, TotalRecords, NonNullRecords, NullRecords,
             NullPct, CompletenessPct, DistinctCount, DuplicateValueCount, UniquePct, DuplicatePct,
             MinValue, MaxValue, AvgValue, MedianValue, StdDevValue,
             MinLength, MaxLength, AvgLength, MinDate, MaxDate, DistinctDateCount, InvalidCount)
        SELECT
            @ProfileRunId,
            a.ColumnName,
            a.DataCategory,
            a.TotalRecords,
            a.NonNullRecords,
            a.NullRecords,
            CASE WHEN a.TotalRecords = 0 THEN 0 ELSE CAST(100.0 * a.NullRecords / a.TotalRecords AS DECIMAL(9,4)) END,
            CASE WHEN a.TotalRecords = 0 THEN 100 ELSE CAST(100.0 * a.NonNullRecords / a.TotalRecords AS DECIMAL(9,4)) END,
            a.DistinctCount,
            ISNULL(d.DuplicateValueCount, 0),
            CASE WHEN a.NonNullRecords = 0 THEN 0 ELSE CAST(100.0 * a.DistinctCount / a.NonNullRecords AS DECIMAL(9,4)) END,
            CASE WHEN a.TotalRecords = 0 THEN 0 ELSE CAST(100.0 * ISNULL(d.DuplicateValueCount, 0) / a.TotalRecords AS DECIMAL(9,4)) END,
            COALESCE(t.MinValue, CONVERT(NVARCHAR(500), n.MinNum), ds.MinValue),
            COALESCE(t.MaxValue, CONVERT(NVARCHAR(500), n.MaxNum), ds.MaxValue),
            n.AvgNum,
            m.MedianNum,
            n.StdDevNum,
            t.MinLength, t.MaxLength, t.AvgLength,
            ds.MinDate, ds.MaxDate, ds.DistinctDateCount,
            0
        FROM Agg a
        LEFT JOIN DupCalc d ON d.ColumnName = a.ColumnName
        LEFT JOIN TextStats t ON t.ColumnName = a.ColumnName
        LEFT JOIN NumStats n ON n.ColumnName = a.ColumnName
        LEFT JOIN MedStats m ON m.ColumnName = a.ColumnName
        LEFT JOIN DateStats ds ON ds.ColumnName = a.ColumnName;

        /* Invalid counts per column from ETL errors */
        UPDATE cp
        SET InvalidCount = x.Cnt
        FROM profile.ColumnProfile cp
        INNER JOIN (
            SELECT ISNULL(ColumnName, N'(batch)') AS ColumnName, COUNT(*) AS Cnt
            FROM etl.EtlError
            WHERE DatasetId = @DatasetId
              AND Severity = N'Error'
              AND ErrorUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
              AND (@BatchId IS NULL OR BatchId = @BatchId)
            GROUP BY ColumnName
        ) x ON x.ColumnName = cp.ColumnName
        WHERE cp.ProfileRunId = @ProfileRunId;

        /* ---- Quality metrics (normalized) ---- */
        INSERT INTO profile.QualityMetric (ProfileRunId, MetricCode, MetricName, MetricScope, MetricValue, MetricUnit)
        VALUES
            (@ProfileRunId, N'TOTAL_RECORDS',       N'Total Records',           N'Dataset', @Total, N'count'),
            (@ProfileRunId, N'NULL_CELLS',          N'Null Cells',              N'Dataset', ISNULL(@NullCells, 0), N'count'),
            (@ProfileRunId, N'COMPLETENESS_PCT',    N'Completeness Percentage', N'Dataset', @CompletenessPct, N'pct'),
            (@ProfileRunId, N'DISTINCT_KEYS',       N'Distinct Key Values',     N'Dataset', ISNULL(@DistinctKeys, 0), N'count'),
            (@ProfileRunId, N'DUPLICATE_RECORDS',   N'Duplicate Records',       N'Dataset', ISNULL(@DupRecords, 0), N'count'),
            (@ProfileRunId, N'DUPLICATE_PCT',       N'Duplicate Percentage',    N'Dataset', @DuplicatePct, N'pct'),
            (@ProfileRunId, N'UNIQUENESS_PCT',      N'Uniqueness Percentage',   N'Dataset', @UniquenessPct, N'pct'),
            (@ProfileRunId, N'VALID_RECORDS',       N'Valid Records',           N'Dataset', @ValidRecords, N'count'),
            (@ProfileRunId, N'INVALID_RECORDS',     N'Invalid Records',         N'Dataset', ISNULL(@InvalidRecords, 0), N'count'),
            (@ProfileRunId, N'VALIDATION_ERRORS',   N'Validation Error Count',  N'Dataset', ISNULL(@ValidationErrorCount, 0), N'count'),
            (@ProfileRunId, N'VALIDITY_PCT',        N'Validity Percentage',     N'Dataset', @ValidityPct, N'pct'),
            (@ProfileRunId, N'ERROR_PCT',           N'Error Percentage',        N'Dataset', @ErrorPct, N'pct'),
            (@ProfileRunId, N'CONSISTENCY_PCT',     N'Consistency Percentage',  N'Dataset', @ConsistencyPct, N'pct');

        INSERT INTO profile.QualityMetric (ProfileRunId, MetricCode, MetricName, MetricScope, ColumnName, MetricValue, MetricUnit)
        SELECT
            @ProfileRunId,
            N'COL_COMPLETENESS',
            N'Column Completeness',
            N'Column',
            ColumnName,
            CompletenessPct,
            N'pct'
        FROM profile.ColumnProfile
        WHERE ProfileRunId = @ProfileRunId;

        /* ---- Score from configurable weights ---- */
        DECLARE @WComp DECIMAL(5,2) = profile.fn_GetWeight(@DatasetId, N'Completeness');
        DECLARE @WVal  DECIMAL(5,2) = profile.fn_GetWeight(@DatasetId, N'Validity');
        DECLARE @WUniq DECIMAL(5,2) = profile.fn_GetWeight(@DatasetId, N'Uniqueness');
        DECLARE @WCons DECIMAL(5,2) = profile.fn_GetWeight(@DatasetId, N'Consistency');
        DECLARE @WSum DECIMAL(5,2) = NULLIF(@WComp + @WVal + @WUniq + @WCons, 0);

        DECLARE @Overall DECIMAL(5,2) =
            CAST((
                (@CompletenessPct * @WComp) +
                (@ValidityPct * @WVal) +
                (@UniquenessPct * @WUniq) +
                (@ConsistencyPct * @WCons)
            ) / ISNULL(@WSum, 100) AS DECIMAL(5,2));

        DECLARE @Grade NVARCHAR(8) = profile.fn_Grade(@Overall);

        /* ---- Threshold evaluation ---- */
        INSERT INTO profile.ThresholdResult
            (ProfileRunId, ThresholdId, MetricCode, ActualValue, ThresholdValue, OperatorCode, Passed)
        SELECT
            @ProfileRunId,
            t.ThresholdId,
            t.MetricCode,
            CASE t.MetricCode
                WHEN N'COMPLETENESS_PCT' THEN @CompletenessPct
                WHEN N'VALIDITY_PCT' THEN @ValidityPct
                WHEN N'UNIQUENESS_PCT' THEN @UniquenessPct
                WHEN N'CONSISTENCY_PCT' THEN @ConsistencyPct
                WHEN N'DUPLICATE_PCT' THEN @DuplicatePct
                WHEN N'OVERALL_SCORE' THEN @Overall
                ELSE NULL
            END,
            t.ThresholdValue,
            t.OperatorCode,
            profile.fn_EvaluateThreshold(
                CASE t.MetricCode
                    WHEN N'COMPLETENESS_PCT' THEN @CompletenessPct
                    WHEN N'VALIDITY_PCT' THEN @ValidityPct
                    WHEN N'UNIQUENESS_PCT' THEN @UniquenessPct
                    WHEN N'CONSISTENCY_PCT' THEN @ConsistencyPct
                    WHEN N'DUPLICATE_PCT' THEN @DuplicatePct
                    WHEN N'OVERALL_SCORE' THEN @Overall
                    ELSE 0
                END,
                t.OperatorCode,
                t.ThresholdValue)
        FROM profile.QualityThreshold t
        WHERE t.IsActive = 1
          AND (t.DatasetId = @DatasetId OR t.DatasetId IS NULL)
          AND t.MetricCode IN (N'COMPLETENESS_PCT', N'VALIDITY_PCT', N'UNIQUENESS_PCT',
                               N'CONSISTENCY_PCT', N'DUPLICATE_PCT', N'OVERALL_SCORE')
          -- prefer dataset-specific: exclude global when dataset override exists
          AND (
              t.DatasetId = @DatasetId
              OR (
                  t.DatasetId IS NULL
                  AND NOT EXISTS (
                      SELECT 1 FROM profile.QualityThreshold x
                      WHERE x.IsActive = 1 AND x.DatasetId = @DatasetId AND x.MetricCode = t.MetricCode
                  )
              )
          );

        DECLARE @ThreshFail INT =
            (SELECT COUNT(*) FROM profile.ThresholdResult WHERE ProfileRunId = @ProfileRunId AND Passed = 0);
        DECLARE @ThreshResult NVARCHAR(16) =
            CASE WHEN NOT EXISTS (SELECT 1 FROM profile.ThresholdResult WHERE ProfileRunId = @ProfileRunId)
                 THEN N'Unknown'
                 WHEN @ThreshFail > 0 THEN N'Fail'
                 ELSE N'Pass' END;

        /* ---- Quality issues ---- */
        IF @Total = 0
            INSERT INTO profile.QualityIssue
                (ProfileRunId, DatasetId, ImportId, IssueType, AffectedCount, Description, Severity)
            VALUES
                (@ProfileRunId, @DatasetId, @ImportId, N'EmptyDataset', 0, N'Dataset has zero rows in the selected profile scope.', N'Critical');

        INSERT INTO profile.QualityIssue
            (ProfileRunId, DatasetId, ImportId, IssueType, ColumnName, AffectedCount, Description, Severity)
        SELECT
            @ProfileRunId, @DatasetId, @ImportId, N'MissingValue', ColumnName, NullRecords,
            CONCAT(N'Column ', ColumnName, N' has ', NullRecords, N' null values (', NullPct, N'%).'),
            CASE WHEN NullPct >= 50 THEN N'Error' WHEN NullPct >= 10 THEN N'Warning' ELSE N'Info' END
        FROM profile.ColumnProfile
        WHERE ProfileRunId = @ProfileRunId AND NullRecords > 0;

        IF ISNULL(@DupRecords, 0) > 0
            INSERT INTO profile.QualityIssue
                (ProfileRunId, DatasetId, ImportId, IssueType, ColumnName, AffectedCount, Description, Severity)
            VALUES
                (@ProfileRunId, @DatasetId, @ImportId, N'DuplicateRecord', ISNULL(@KeyColumn, N'CustomerCode'),
                 @DupRecords, CONCAT(N'Found ', @DupRecords, N' surplus duplicate key rows.'), N'Error');

        INSERT INTO profile.QualityIssue
            (ProfileRunId, DatasetId, ImportId, IssueType, ColumnName, ErrorCode, AffectedCount, SampleValue, Description, Severity)
        SELECT
            @ProfileRunId, @DatasetId, e.ImportId,
            CASE
                WHEN e.ErrorCode LIKE N'TYPE_%' OR e.ErrorCode LIKE N'XFORM_%' THEN N'DataTypeIssue'
                WHEN e.ErrorCode LIKE N'DUP_%' THEN N'DuplicateRecord'
                WHEN e.ErrorCode LIKE N'REQ_%' THEN N'MissingValue'
                WHEN e.ErrorCode LIKE N'INV_%' OR e.ErrorCode LIKE N'RI_%' THEN N'UnexpectedValue'
                ELSE N'ValidationFailure'
            END,
            e.ColumnName,
            e.ErrorCode,
            COUNT(*),
            MAX(LEFT(e.InvalidValue, 500)),
            MAX(e.ErrorDescription),
            N'Error'
        FROM etl.EtlError e
        WHERE e.DatasetId = @DatasetId
          AND e.Severity = N'Error'
          AND e.ErrorUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
          AND (@BatchId IS NULL OR e.BatchId = @BatchId)
          AND (@ImportId IS NULL OR e.ImportId = @ImportId)
        GROUP BY e.ImportId, e.ColumnName, e.ErrorCode,
            CASE
                WHEN e.ErrorCode LIKE N'TYPE_%' OR e.ErrorCode LIKE N'XFORM_%' THEN N'DataTypeIssue'
                WHEN e.ErrorCode LIKE N'DUP_%' THEN N'DuplicateRecord'
                WHEN e.ErrorCode LIKE N'REQ_%' THEN N'MissingValue'
                WHEN e.ErrorCode LIKE N'INV_%' OR e.ErrorCode LIKE N'RI_%' THEN N'UnexpectedValue'
                ELSE N'ValidationFailure'
            END;

        IF @ThreshResult = N'Fail'
            INSERT INTO profile.QualityIssue
                (ProfileRunId, DatasetId, ImportId, IssueType, ErrorCode, AffectedCount, Description, Severity)
            SELECT
                @ProfileRunId, @DatasetId, @ImportId, N'ThresholdBreach', tr.MetricCode, 1,
                CONCAT(N'Threshold failed for ', tr.MetricCode, N': actual ', tr.ActualValue,
                       N' ', tr.OperatorCode, N' ', tr.ThresholdValue, N' required.'),
                N'Critical'
            FROM profile.ThresholdResult tr
            WHERE tr.ProfileRunId = @ProfileRunId AND tr.Passed = 0;

        DECLARE @Cols INT = (SELECT COUNT(*) FROM profile.ColumnProfile WHERE ProfileRunId = @ProfileRunId);
        DECLARE @Issues INT = (SELECT COUNT(*) FROM profile.QualityIssue WHERE ProfileRunId = @ProfileRunId);
        DECLARE @Dur INT = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME());

        UPDATE profile.ProfileRun
        SET
            Status = N'Succeeded',
            CompletedUtc = SYSUTCDATETIME(),
            DurationMs = @Dur,
            TotalRecords = @Total,
            ValidRecords = @ValidRecords,
            InvalidRecords = ISNULL(@InvalidRecords, 0),
            DuplicateRecords = ISNULL(@DupRecords, 0),
            NullCellCount = ISNULL(@NullCells, 0),
            CompletenessPct = @CompletenessPct,
            UniquenessPct = @UniquenessPct,
            ValidityPct = @ValidityPct,
            ConsistencyPct = @ConsistencyPct,
            DuplicatePct = @DuplicatePct,
            ErrorPct = @ErrorPct,
            OverallScore = @Overall,
            Grade = @Grade,
            ThresholdResult = @ThreshResult,
            ColumnsProfiled = @Cols,
            IssueCount = @Issues
        WHERE ProfileRunId = @ProfileRunId;

        UPDATE profile.DatasetProfile
        SET
            LatestProfileRunId = @ProfileRunId,
            LatestOverallScore = @Overall,
            LatestThresholdResult = @ThreshResult,
            ProfileScope = @ProfileScope,
            ModifiedUtc = SYSUTCDATETIME()
        WHERE DatasetProfileId = @DatasetProfileId;

        DROP TABLE #Rows;
    END TRY
    BEGIN CATCH
        IF OBJECT_ID(N'tempdb..#Rows') IS NOT NULL DROP TABLE #Rows;

        UPDATE profile.ProfileRun
        SET
            Status = N'Failed',
            CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            ErrorMessage = LEFT(ERROR_MESSAGE(), 2000)
        WHERE ProfileRunId = @ProfileRunId;

        THROW;
    END CATCH;

    SELECT * FROM profile.ProfileRun WHERE ProfileRunId = @ProfileRunId;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_ProfileDueDatasets
    @MaxDatasets INT = 10
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Code NVARCHAR(64), @Done INT = 0;
    DECLARE @RunId UNIQUEIDENTIFIER;

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT TOP (@MaxDatasets) d.DatasetCode
        FROM ingest.Dataset d
        INNER JOIN profile.DatasetProfile p ON p.DatasetId = d.DatasetId AND p.IsEnabled = 1
        WHERE d.IsActive = 1
        ORDER BY ISNULL((
            SELECT MAX(r.StartedUtc) FROM profile.ProfileRun r WHERE r.DatasetId = d.DatasetId
        ), '19000101');

    OPEN c;
    FETCH NEXT FROM c INTO @Code;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @RunId = NULL;
            EXEC profile.usp_ProfileCustomerDataset
                @DatasetCode = @Code,
                @ProfileScope = N'Processed',
                @TriggerType = N'Agent',
                @ProfileRunId = @RunId OUTPUT;
            SET @Done += 1;
        END TRY
        BEGIN CATCH
            PRINT ERROR_MESSAGE();
        END CATCH;
        FETCH NEXT FROM c INTO @Code;
    END
    CLOSE c; DEALLOCATE c;

    -- Auto-register active datasets missing a profile catalog row
    INSERT INTO profile.DatasetProfile (DatasetId, ProfileScope)
    SELECT d.DatasetId, N'Processed'
    FROM ingest.Dataset d
    WHERE d.IsActive = 1
      AND NOT EXISTS (SELECT 1 FROM profile.DatasetProfile p WHERE p.DatasetId = d.DatasetId);

    SELECT @Done AS DatasetsProfiled;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetProfileRun
    @ProfileRunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        r.*,
        d.DatasetCode,
        d.DisplayName AS DatasetName
    FROM profile.ProfileRun r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    WHERE r.ProfileRunId = @ProfileRunId;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetColumnProfiles
    @ProfileRunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM profile.ColumnProfile
    WHERE ProfileRunId = @ProfileRunId
    ORDER BY ColumnName;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetQualityIssues
    @ProfileRunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM profile.QualityIssue
    WHERE ProfileRunId = @ProfileRunId
    ORDER BY
        CASE Severity WHEN N'Critical' THEN 1 WHEN N'Error' THEN 2 WHEN N'Warning' THEN 3 ELSE 4 END,
        AffectedCount DESC;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetThresholdResults
    @ProfileRunId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM profile.ThresholdResult
    WHERE ProfileRunId = @ProfileRunId
    ORDER BY Passed, MetricCode;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetQualityTrend
    @DatasetCode NVARCHAR(64),
    @FromUtc DATETIME2(3) = NULL,
    @ToUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToUtc = ISNULL(@ToUtc, SYSUTCDATETIME());
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -90, @ToUtc));

    SELECT
        r.ProfileRunId,
        d.DatasetCode,
        r.StartedUtc,
        r.OverallScore,
        r.CompletenessPct,
        r.ValidityPct,
        r.UniquenessPct,
        r.ConsistencyPct,
        r.DuplicatePct,
        r.ThresholdResult,
        r.Grade,
        LAG(r.OverallScore) OVER (ORDER BY r.StartedUtc) AS PrevOverallScore,
        LAG(r.CompletenessPct) OVER (ORDER BY r.StartedUtc) AS PrevCompletenessPct,
        LAG(r.ValidityPct) OVER (ORDER BY r.StartedUtc) AS PrevValidityPct,
        LAG(r.DuplicatePct) OVER (ORDER BY r.StartedUtc) AS PrevDuplicatePct,
        r.OverallScore - LAG(r.OverallScore) OVER (ORDER BY r.StartedUtc) AS DeltaOverallScore,
        r.CompletenessPct - LAG(r.CompletenessPct) OVER (ORDER BY r.StartedUtc) AS DeltaCompletenessPct,
        r.ValidityPct - LAG(r.ValidityPct) OVER (ORDER BY r.StartedUtc) AS DeltaValidityPct,
        r.DuplicatePct - LAG(r.DuplicatePct) OVER (ORDER BY r.StartedUtc) AS DeltaDuplicatePct
    FROM profile.ProfileRun r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    WHERE d.DatasetCode = @DatasetCode
      AND r.Status = N'Succeeded'
      AND r.StartedUtc >= @FromUtc AND r.StartedUtc < @ToUtc
    ORDER BY r.StartedUtc;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_GetLatestDatasetScore
    @DatasetCode NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (1)
        r.*,
        d.DatasetCode,
        d.DisplayName AS DatasetName
    FROM profile.ProfileRun r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    WHERE d.DatasetCode = @DatasetCode AND r.Status = N'Succeeded'
    ORDER BY r.StartedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE profile.usp_ArchiveProfileHistory
    @RetainDays INT = 180
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    DELETE FROM profile.ProfileRun
    WHERE StartedUtc < @Cutoff AND Status <> N'Running';

    SELECT @@ROWCOUNT AS RunsArchived;
END
GO

PRINT 'Profile procedures created.';
GO
