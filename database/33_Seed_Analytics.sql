-- ============================================================
-- 33_Seed_Analytics.sql
-- Task 19 - Workspaces, dataset governance attributes, and a
-- synthetic 120-day history of import batches + profile runs so
-- trend / comparison / dashboard reports have data to return.
-- Safe to re-run: guarded inserts + MERGE-style upserts.
-- ============================================================
USE EDIP;
GO

-- ------------------------------------------------------------
-- Workspaces
-- ------------------------------------------------------------
DECLARE @WsSales   UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000001';
DECLARE @WsFinance UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000002';
DECLARE @WsOps     UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000003';

MERGE analytics.Workspace AS t
USING (VALUES
    (@WsSales,   N'WS-SALES',   N'Sales Analytics',      N'Customer & order domain'),
    (@WsFinance, N'WS-FINANCE', N'Finance & Billing',    N'Invoice & revenue domain'),
    (@WsOps,     N'WS-OPS',     N'Operations',           N'Product & fulfilment domain')
) AS s (WorkspaceId, WorkspaceCode, DisplayName, Description)
ON t.WorkspaceId = s.WorkspaceId
WHEN MATCHED THEN UPDATE SET WorkspaceCode = s.WorkspaceCode, DisplayName = s.DisplayName,
    Description = s.Description, IsActive = 1
WHEN NOT MATCHED THEN INSERT (WorkspaceId, WorkspaceCode, DisplayName, Description)
    VALUES (s.WorkspaceId, s.WorkspaceCode, s.DisplayName, s.Description);
GO

-- ------------------------------------------------------------
-- Demo datasets (CUSTOMER already seeded in script 18)
-- ------------------------------------------------------------
DECLARE @Customer UNIQUEIDENTIFIER = '33333333-3333-3333-3333-333333333333';
DECLARE @Order    UNIQUEIDENTIFIER = 'D1000000-0000-0000-0000-000000000001';
DECLARE @Product  UNIQUEIDENTIFIER = 'D1000000-0000-0000-0000-000000000002';
DECLARE @Invoice  UNIQUEIDENTIFIER = 'D1000000-0000-0000-0000-000000000003';
DECLARE @WsSales   UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000001';
DECLARE @WsFinance UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000002';
DECLARE @WsOps     UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000003';

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Order)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable)
    VALUES (@Order, N'ORDER', N'Sales Orders', N'Order header imports', N'ingest.StagingOrder', N'ingest.SalesOrder');

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Product)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable)
    VALUES (@Product, N'PRODUCT', N'Product Catalog', N'Product master imports', N'ingest.StagingProduct', N'ingest.Product');

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Invoice)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable)
    VALUES (@Invoice, N'INVOICE', N'Customer Invoices', N'Invoice imports', N'ingest.StagingInvoice', N'ingest.Invoice');
GO

-- ------------------------------------------------------------
-- Governance attributes
-- ------------------------------------------------------------
UPDATE ingest.Dataset SET WorkspaceId = 'F1000000-0000-0000-0000-000000000001',
    DatasetStatus = N'Active', Category = N'Master Data', OwnerName = N'sbalakrishna@stratapps.com'
WHERE DatasetCode = N'CUSTOMER';

UPDATE ingest.Dataset SET WorkspaceId = 'F1000000-0000-0000-0000-000000000001',
    DatasetStatus = N'Active', Category = N'Transactional', OwnerName = N'sales.steward@stratapps.com'
WHERE DatasetCode = N'ORDER';

UPDATE ingest.Dataset SET WorkspaceId = 'F1000000-0000-0000-0000-000000000003',
    DatasetStatus = N'Active', Category = N'Master Data', OwnerName = N'ops.steward@stratapps.com'
WHERE DatasetCode = N'PRODUCT';

UPDATE ingest.Dataset SET WorkspaceId = 'F1000000-0000-0000-0000-000000000002',
    DatasetStatus = N'Draft', Category = N'Transactional', OwnerName = N'finance.steward@stratapps.com'
WHERE DatasetCode = N'INVOICE';

-- Give ModifiedUtc some spread for "recently modified" reports
UPDATE ingest.Dataset SET ModifiedUtc = DATEADD(DAY, -ABS(CHECKSUM(NEWID())) % 25, SYSUTCDATETIME())
WHERE DatasetCode IN (N'CUSTOMER', N'ORDER', N'PRODUCT', N'INVOICE');
GO

-- ------------------------------------------------------------
-- Synthetic import-batch history (120 days, ~ every 2-3 days per dataset)
-- Guard: only generate once (idempotent re-runs)
-- ------------------------------------------------------------
IF EXISTS (SELECT 1 FROM ingest.ImportBatch WHERE SourceInfo LIKE N'seed://%')
BEGIN
    PRINT 'Synthetic analytics history already present - skipping generation.';
END
ELSE
BEGIN
;WITH Nums AS (
    SELECT TOP (120) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS n
    FROM sys.all_objects
),
Ds AS (
    SELECT DatasetId, DatasetCode,
           CASE DatasetCode WHEN N'CUSTOMER' THEN 1200 WHEN N'ORDER' THEN 5000
                            WHEN N'PRODUCT' THEN 800 ELSE 2200 END AS BaseRows
    FROM ingest.Dataset
    WHERE DatasetCode IN (N'CUSTOMER', N'ORDER', N'PRODUCT', N'INVOICE')
),
Gen AS (
    SELECT
        d.DatasetId, d.DatasetCode,
        DATEADD(DAY, -n.n, DATEADD(HOUR, ABS(CHECKSUM(NEWID())) % 20, CAST(CAST(SYSUTCDATETIME() AS DATE) AS DATETIME2(3)))) AS ImportUtc,
        d.BaseRows + (ABS(CHECKSUM(NEWID())) % 400) - 200 AS TotalRecords,
        ABS(CHECKSUM(NEWID())) % 100 AS RejBase,
        ABS(CHECKSUM(NEWID())) % 100 AS RollStatus
    FROM Nums n
    CROSS JOIN Ds d
    WHERE (n.n + (ABS(CHECKSUM(d.DatasetCode)) % 3)) % 3 = 0   -- ~ every 3rd day, offset per dataset
)
INSERT INTO ingest.ImportBatch
    (DatasetId, SourceInfo, ImportUtc, Status, TotalRecords, ValidRecords, RejectedRecords,
     ProcessedRecords, InsertedRecords, UpdatedRecords, ErrorCount, AttemptCount,
     StartedUtc, CompletedUtc, DurationMs, LoadMode, DuplicateStrategy)
SELECT
    g.DatasetId,
    CONCAT(N'seed://', g.DatasetCode, N'/', CONVERT(NVARCHAR(10), CAST(g.ImportUtc AS DATE), 23), N'.csv'),
    g.ImportUtc,
    CASE WHEN g.RollStatus < 78 THEN N'Completed'
         WHEN g.RollStatus < 90 THEN N'CompletedWithErrors'
         ELSE N'Failed' END,
    g.TotalRecords,
    g.TotalRecords - (g.RejBase),
    g.RejBase,
    CASE WHEN g.RollStatus < 90 THEN g.TotalRecords - g.RejBase ELSE 0 END,
    CASE WHEN g.RollStatus < 90 THEN CAST((g.TotalRecords - g.RejBase) * 0.6 AS INT) ELSE 0 END,
    CASE WHEN g.RollStatus < 90 THEN CAST((g.TotalRecords - g.RejBase) * 0.4 AS INT) ELSE 0 END,
    CASE WHEN g.RollStatus < 78 THEN g.RejBase ELSE g.RejBase + 5 END,
    1,
    g.ImportUtc,
    CASE WHEN g.RollStatus < 90 THEN DATEADD(SECOND, 20 + ABS(CHECKSUM(NEWID())) % 240, g.ImportUtc) ELSE NULL END,
    CASE WHEN g.RollStatus < 90 THEN (20 + ABS(CHECKSUM(NEWID())) % 240) * 1000 ELSE NULL END,
    N'Incremental', N'Update'
FROM Gen g;
END
GO

-- ------------------------------------------------------------
-- Synthetic profile-run history (120 days, ~ weekly per dataset)
-- Score drifts upward over time + noise; thresholds fail on low scores.
-- Guard: only generate once (idempotent re-runs)
-- ------------------------------------------------------------
IF EXISTS (
    SELECT 1 FROM profile.ProfileRun r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    WHERE d.DatasetCode IN (N'ORDER', N'PRODUCT', N'INVOICE') AND r.TriggerType = N'Agent'
)
BEGIN
    PRINT 'Synthetic profile-run history already present - skipping generation.';
END
ELSE
BEGIN
DECLARE @dsId UNIQUEIDENTIFIER, @dsCode NVARCHAR(64), @profId UNIQUEIDENTIFIER, @base DECIMAL(5,2);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT DatasetId, DatasetCode,
           CASE DatasetCode WHEN N'CUSTOMER' THEN 82.0 WHEN N'ORDER' THEN 74.0
                            WHEN N'PRODUCT' THEN 90.0 ELSE 63.0 END
    FROM ingest.Dataset
    WHERE DatasetCode IN (N'CUSTOMER', N'ORDER', N'PRODUCT', N'INVOICE');

OPEN cur;
FETCH NEXT FROM cur INTO @dsId, @dsCode, @base;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC profile.usp_EnsureDatasetProfile @DatasetId = @dsId, @DatasetProfileId = @profId OUTPUT;

    ;WITH Weeks AS (
        SELECT TOP (18) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS w
        FROM sys.all_objects
    ),
    R AS (
        SELECT
            DATEADD(DAY, -(w * 7) - (ABS(CHECKSUM(NEWID())) % 3), SYSUTCDATETIME()) AS StartedUtc,
            -- drift: older weeks lower, recent weeks near base+3, plus +/-4 noise
            CAST(@base - (w * 0.55) + 3.0 + ((ABS(CHECKSUM(NEWID())) % 80) / 10.0) - 4.0 AS DECIMAL(5,2)) AS Score,
            18000 + ABS(CHECKSUM(NEWID())) % 90000 AS Rows
        FROM Weeks
    )
    INSERT INTO profile.ProfileRun
        (DatasetId, DatasetProfileId, ProfileScope, TriggerType, Status, StartedUtc, CompletedUtc,
         DurationMs, TotalRecords, ValidRecords, InvalidRecords, DuplicateRecords, NullCellCount,
         CompletenessPct, UniquenessPct, ValidityPct, ConsistencyPct, DuplicatePct, ErrorPct,
         OverallScore, Grade, ThresholdResult, ColumnsProfiled, IssueCount)
    SELECT
        @dsId, @profId, N'Processed', N'Agent', N'Succeeded', r.StartedUtc,
        DATEADD(SECOND, 3 + ABS(CHECKSUM(NEWID())) % 40, r.StartedUtc),
        (3 + ABS(CHECKSUM(NEWID())) % 40) * 1000,
        r.Rows,
        CAST(r.Rows * 0.97 AS BIGINT),
        CAST(r.Rows * 0.03 AS BIGINT),
        ABS(CHECKSUM(NEWID())) % 40,
        CAST(r.Rows * 0.02 AS BIGINT),
        CASE WHEN r.Score > 100 THEN 99.5 WHEN r.Score < 40 THEN 55.0
             ELSE CAST(r.Score + 8.0 AS DECIMAL(9,4)) END,                       -- CompletenessPct
        CAST(90.0 + ((ABS(CHECKSUM(NEWID())) % 90) / 10.0) AS DECIMAL(9,4)),     -- UniquenessPct
        CASE WHEN r.Score > 100 THEN 99.0 ELSE CAST(r.Score + 5.0 AS DECIMAL(9,4)) END, -- ValidityPct
        CAST(85.0 + ((ABS(CHECKSUM(NEWID())) % 140) / 10.0) AS DECIMAL(9,4)),    -- ConsistencyPct
        CAST((ABS(CHECKSUM(NEWID())) % 50) / 10.0 AS DECIMAL(9,4)),              -- DuplicatePct
        CAST((ABS(CHECKSUM(NEWID())) % 40) / 10.0 AS DECIMAL(9,4)),              -- ErrorPct
        CASE WHEN r.Score > 100 THEN 99.00 WHEN r.Score < 40 THEN 41.00 ELSE r.Score END,
        CASE WHEN r.Score >= 90 THEN N'A' WHEN r.Score >= 80 THEN N'B'
             WHEN r.Score >= 70 THEN N'C' WHEN r.Score >= 60 THEN N'D' ELSE N'F' END,
        CASE WHEN r.Score >= 70 THEN N'Pass' ELSE N'Fail' END,
        7,
        ABS(CHECKSUM(NEWID())) % 12
    FROM R;

    FETCH NEXT FROM cur INTO @dsId, @dsCode, @base;
END
CLOSE cur; DEALLOCATE cur;
END
GO

-- Point each DatasetProfile at its most recent run
UPDATE p
SET LatestProfileRunId = lr.ProfileRunId,
    LatestOverallScore  = lr.OverallScore,
    LatestThresholdResult = lr.ThresholdResult,
    ModifiedUtc = SYSUTCDATETIME()
FROM profile.DatasetProfile p
CROSS APPLY (
    SELECT TOP (1) r.ProfileRunId, r.OverallScore, r.ThresholdResult
    FROM profile.ProfileRun r
    WHERE r.DatasetId = p.DatasetId AND r.Status = N'Succeeded'
    ORDER BY r.StartedUtc DESC
) lr;
GO

-- Some quality issues for the lowest-scoring recent runs (issue-breakdown / top-issues reports)
INSERT INTO profile.QualityIssue
    (ProfileRunId, DatasetId, IssueType, ColumnName, ErrorCode, AffectedCount, Description, Severity)
SELECT TOP (60)
    r.ProfileRunId, r.DatasetId,
    CASE ABS(CHECKSUM(NEWID())) % 4
        WHEN 0 THEN N'MissingValue' WHEN 1 THEN N'DuplicateRecord'
        WHEN 2 THEN N'InvalidValue' ELSE N'ValidationFailure' END,
    CASE ABS(CHECKSUM(NEWID())) % 3 WHEN 0 THEN N'Email' WHEN 1 THEN N'CountryCode' ELSE N'Status' END,
    CONCAT(N'SEED_', ABS(CHECKSUM(NEWID())) % 9),
    10 + ABS(CHECKSUM(NEWID())) % 400,
    N'Seeded quality issue for analytics reporting.',
    CASE ABS(CHECKSUM(NEWID())) % 3 WHEN 0 THEN N'Warning' WHEN 1 THEN N'Error' ELSE N'Info' END
FROM profile.ProfileRun r
WHERE r.Status = N'Succeeded' AND r.OverallScore < 75
  AND NOT EXISTS (SELECT 1 FROM profile.QualityIssue qi WHERE qi.ProfileRunId = r.ProfileRunId)
ORDER BY r.StartedUtc DESC;
GO

-- ------------------------------------------------------------
-- Build the pre-aggregated reporting tables
-- ------------------------------------------------------------
EXEC analytics.usp_RefreshDailyMetrics @FromDate = NULL, @ToDate = NULL;   -- default trailing 7d
DECLARE @From DATE = DATEADD(DAY, -140, CAST(SYSUTCDATETIME() AS DATE));
EXEC analytics.usp_RefreshDailyMetrics @FromDate = @From, @ToDate = NULL;   -- full backfill
EXEC analytics.usp_SnapshotQualityTrend @FromDate = @From, @ToDate = NULL;
GO

PRINT 'Analytics seed data + 120-day synthetic history applied.';
GO
