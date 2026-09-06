-- ============================================================
-- 31_Procs_Analytics.sql
-- Task 19 - SQL Analytics & Reporting Engine
-- Refresh/maintenance procs + dataset / import / quality / trend /
-- comparison / workspace / time-based / dashboard / export procedures.
-- Set-based T-SQL: CTEs, window functions, aggregations.
-- ============================================================
USE EDIP;
GO

-- ------------------------------------------------------------
-- Deterministic period bucket (Monday-based weeks; 1900-01-01 = Monday)
-- ------------------------------------------------------------
CREATE OR ALTER FUNCTION analytics.fn_PeriodStart (@d DATE, @p NVARCHAR(10))
RETURNS DATE
AS
BEGIN
    RETURN CASE @p
        WHEN N'Day'     THEN @d
        WHEN N'Week'    THEN DATEADD(DAY, -((DATEDIFF(DAY, '19000101', @d)) % 7), @d)
        WHEN N'Month'   THEN DATEFROMPARTS(YEAR(@d), MONTH(@d), 1)
        WHEN N'Quarter' THEN DATEFROMPARTS(YEAR(@d), ((DATEPART(QUARTER, @d) - 1) * 3) + 1, 1)
        ELSE @d
    END;
END
GO

-- ============================================================
-- SECTION 1 - REFRESH / MAINTENANCE
-- ============================================================

-- Incrementally rebuild analytics.ReportingDailyMetric for a date window.
-- Default window = trailing 7 days (safe for a nightly Agent run).
CREATE OR ALTER PROCEDURE analytics.usp_RefreshDailyMetrics
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ToDate   = ISNULL(@ToDate, CAST(SYSUTCDATETIME() AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -7, @ToDate));

    DECLARE @LogId BIGINT, @Start DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO analytics.ReportRefreshLog (RefreshName, StartedUtc, Status)
    VALUES (N'RefreshDailyMetrics', @Start, N'Running');
    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRAN;

        DELETE FROM analytics.ReportingDailyMetric
        WHERE MetricDate >= @FromDate AND MetricDate <= @ToDate;

        ;WITH ImportAgg AS (
            SELECT
                CAST(b.ImportUtc AS DATE)                              AS MetricDate,
                b.DatasetId,
                COUNT(*)                                               AS ImportCount,
                SUM(CASE WHEN b.Status = N'Completed' THEN 1 ELSE 0 END)             AS SuccessfulImports,
                SUM(CASE WHEN b.Status IN (N'Failed', N'Exhausted') THEN 1 ELSE 0 END) AS FailedImports,
                SUM(CASE WHEN b.Status = N'CompletedWithErrors' THEN 1 ELSE 0 END)    AS CompletedWithErrors,
                SUM(CAST(b.ProcessedRecords AS BIGINT))                AS RecordsProcessed,
                SUM(CAST(b.RejectedRecords AS BIGINT))                 AS RecordsRejected,
                SUM(CAST(b.InsertedRecords AS BIGINT))                 AS RecordsInserted,
                SUM(CAST(b.UpdatedRecords AS BIGINT))                  AS RecordsUpdated,
                AVG(NULLIF(COALESCE(b.DurationMs,
                    DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc)), 0))       AS AvgProcessingMs
            FROM ingest.ImportBatch b
            WHERE b.ImportUtc >= @FromDate
              AND b.ImportUtc <  DATEADD(DAY, 1, @ToDate)
            GROUP BY CAST(b.ImportUtc AS DATE), b.DatasetId
        ),
        ProfileAgg AS (
            SELECT
                CAST(r.StartedUtc AS DATE)                             AS MetricDate,
                r.DatasetId,
                COUNT(*)                                               AS ProfileRunCount,
                AVG(r.OverallScore)                                    AS AvgOverallScore,
                AVG(r.CompletenessPct)                                 AS AvgCompletenessPct,
                AVG(r.ValidityPct)                                     AS AvgValidityPct,
                AVG(r.UniquenessPct)                                   AS AvgUniquenessPct,
                AVG(r.ConsistencyPct)                                  AS AvgConsistencyPct,
                SUM(CASE WHEN r.ThresholdResult = N'Fail' THEN 1 ELSE 0 END) AS FailedThresholdRuns,
                SUM(r.IssueCount)                                      AS QualityIssueCount
            FROM profile.ProfileRun r
            WHERE r.Status = N'Succeeded'
              AND r.StartedUtc >= @FromDate
              AND r.StartedUtc <  DATEADD(DAY, 1, @ToDate)
            GROUP BY CAST(r.StartedUtc AS DATE), r.DatasetId
        ),
        Combined AS (
            SELECT MetricDate, DatasetId FROM ImportAgg
            UNION
            SELECT MetricDate, DatasetId FROM ProfileAgg
        )
        INSERT INTO analytics.ReportingDailyMetric
            (MetricDate, DatasetId, WorkspaceId, ImportCount, SuccessfulImports, FailedImports,
             CompletedWithErrors, RecordsProcessed, RecordsRejected, RecordsInserted, RecordsUpdated,
             AvgProcessingMs, ProfileRunCount, AvgOverallScore, AvgCompletenessPct, AvgValidityPct,
             AvgUniquenessPct, AvgConsistencyPct, FailedThresholdRuns, QualityIssueCount, RefreshedUtc)
        SELECT
            c.MetricDate,
            c.DatasetId,
            d.WorkspaceId,
            ISNULL(i.ImportCount, 0),
            ISNULL(i.SuccessfulImports, 0),
            ISNULL(i.FailedImports, 0),
            ISNULL(i.CompletedWithErrors, 0),
            ISNULL(i.RecordsProcessed, 0),
            ISNULL(i.RecordsRejected, 0),
            ISNULL(i.RecordsInserted, 0),
            ISNULL(i.RecordsUpdated, 0),
            i.AvgProcessingMs,
            ISNULL(p.ProfileRunCount, 0),
            p.AvgOverallScore,
            p.AvgCompletenessPct,
            p.AvgValidityPct,
            p.AvgUniquenessPct,
            p.AvgConsistencyPct,
            ISNULL(p.FailedThresholdRuns, 0),
            ISNULL(p.QualityIssueCount, 0),
            SYSUTCDATETIME()
        FROM Combined c
        INNER JOIN ingest.Dataset d ON d.DatasetId = c.DatasetId
        LEFT JOIN ImportAgg  i ON i.MetricDate = c.MetricDate AND i.DatasetId = c.DatasetId
        LEFT JOIN ProfileAgg p ON p.MetricDate = c.MetricDate AND p.DatasetId = c.DatasetId;

        DECLARE @Rows INT = @@ROWCOUNT;
        COMMIT TRAN;

        UPDATE analytics.ReportRefreshLog
        SET CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            RowsAffected = @Rows,
            Status = N'Succeeded',
            Message = CONCAT(N'Window ', @FromDate, N' .. ', @ToDate)
        WHERE RefreshLogId = @LogId;

        SELECT @Rows AS RowsRefreshed, @FromDate AS FromDate, @ToDate AS ToDate;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        UPDATE analytics.ReportRefreshLog
        SET CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            Status = N'Failed',
            Message = LEFT(ERROR_MESSAGE(), 2000)
        WHERE RefreshLogId = @LogId;
        THROW;
    END CATCH
END
GO

-- Rebuild period-grain quality trend snapshots (Day/Week/Month/Quarter)
CREATE OR ALTER PROCEDURE analytics.usp_SnapshotQualityTrend
    @FromDate DATE = NULL,
    @ToDate   DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ToDate   = ISNULL(@ToDate, CAST(SYSUTCDATETIME() AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(DAY, -400, @ToDate));

    DECLARE @LogId BIGINT, @Start DATETIME2(3) = SYSUTCDATETIME();
    INSERT INTO analytics.ReportRefreshLog (RefreshName, StartedUtc, Status)
    VALUES (N'SnapshotQualityTrend', @Start, N'Running');
    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRAN;

        ;WITH Runs AS (
            SELECT
                r.DatasetId, d.WorkspaceId, r.ProfileRunId, r.StartedUtc,
                CAST(r.StartedUtc AS DATE) AS RunDate,
                r.OverallScore, r.CompletenessPct, r.ValidityPct, r.UniquenessPct,
                r.ConsistencyPct, r.DuplicatePct, r.ThresholdResult
            FROM profile.ProfileRun r
            INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
            WHERE r.Status = N'Succeeded'
              AND r.StartedUtc >= @FromDate
              AND r.StartedUtc <  DATEADD(DAY, 1, @ToDate)
        ),
        Expanded AS (
            SELECT pt.PeriodType,
                   analytics.fn_PeriodStart(Runs.RunDate, pt.PeriodType) AS PeriodStart,
                   Runs.*
            FROM Runs
            CROSS JOIN (VALUES (N'Day'), (N'Week'), (N'Month'), (N'Quarter')) pt(PeriodType)
        ),
        Ranked AS (
            SELECT *,
                   ROW_NUMBER() OVER (PARTITION BY DatasetId, PeriodType, PeriodStart
                                      ORDER BY StartedUtc DESC) AS rn
            FROM Expanded
        ),
        Agg AS (
            SELECT
                DatasetId, PeriodType, PeriodStart,
                MAX(WorkspaceId)         AS WorkspaceId,
                COUNT(*)                 AS ProfileRunCount,
                AVG(OverallScore)        AS OverallScore,
                AVG(CompletenessPct)     AS CompletenessPct,
                AVG(ValidityPct)         AS ValidityPct,
                AVG(UniquenessPct)       AS UniquenessPct,
                AVG(ConsistencyPct)      AS ConsistencyPct,
                AVG(DuplicatePct)        AS DuplicatePct,
                SUM(CASE WHEN ThresholdResult = N'Fail' THEN 1 ELSE 0 END) AS FailedThresholdRuns
            FROM Expanded
            GROUP BY DatasetId, PeriodType, PeriodStart
        )
        MERGE analytics.QualityTrendSnapshot AS tgt
        USING (
            SELECT a.*, r.ProfileRunId AS LastProfileRunId
            FROM Agg a
            INNER JOIN Ranked r
                ON r.DatasetId = a.DatasetId AND r.PeriodType = a.PeriodType
               AND r.PeriodStart = a.PeriodStart AND r.rn = 1
        ) AS src
        ON  tgt.DatasetId = src.DatasetId
        AND tgt.PeriodType = src.PeriodType
        AND tgt.PeriodStart = src.PeriodStart
        WHEN MATCHED THEN UPDATE SET
            WorkspaceId = src.WorkspaceId,
            ProfileRunCount = src.ProfileRunCount,
            OverallScore = src.OverallScore,
            CompletenessPct = src.CompletenessPct,
            ValidityPct = src.ValidityPct,
            UniquenessPct = src.UniquenessPct,
            ConsistencyPct = src.ConsistencyPct,
            DuplicatePct = src.DuplicatePct,
            FailedThresholdRuns = src.FailedThresholdRuns,
            LastProfileRunId = src.LastProfileRunId,
            SnapshotUtc = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT
            (DatasetId, WorkspaceId, PeriodType, PeriodStart, ProfileRunCount, OverallScore,
             CompletenessPct, ValidityPct, UniquenessPct, ConsistencyPct, DuplicatePct,
             FailedThresholdRuns, LastProfileRunId, SnapshotUtc)
        VALUES
            (src.DatasetId, src.WorkspaceId, src.PeriodType, src.PeriodStart, src.ProfileRunCount,
             src.OverallScore, src.CompletenessPct, src.ValidityPct, src.UniquenessPct,
             src.ConsistencyPct, src.DuplicatePct, src.FailedThresholdRuns, src.LastProfileRunId, SYSUTCDATETIME());

        DECLARE @Rows INT = @@ROWCOUNT;
        COMMIT TRAN;

        UPDATE analytics.ReportRefreshLog
        SET CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            RowsAffected = @Rows, Status = N'Succeeded'
        WHERE RefreshLogId = @LogId;

        SELECT @Rows AS SnapshotsMerged;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRAN;
        UPDATE analytics.ReportRefreshLog
        SET CompletedUtc = SYSUTCDATETIME(),
            DurationMs = DATEDIFF(MILLISECOND, @Start, SYSUTCDATETIME()),
            Status = N'Failed', Message = LEFT(ERROR_MESSAGE(), 2000)
        WHERE RefreshLogId = @LogId;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE analytics.usp_CleanupAnalyticsData
    @RetainDays INT = 400
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @CutDate DATE = DATEADD(DAY, -@RetainDays, CAST(SYSUTCDATETIME() AS DATE));
    DECLARE @Cut DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    DELETE FROM analytics.ReportingDailyMetric WHERE MetricDate < @CutDate;
    DECLARE @Metrics INT = @@ROWCOUNT;

    DELETE FROM analytics.QualityTrendSnapshot WHERE PeriodStart < @CutDate;
    DECLARE @Snapshots INT = @@ROWCOUNT;

    DELETE FROM analytics.ReportRefreshLog WHERE StartedUtc < @Cut;
    DECLARE @Logs INT = @@ROWCOUNT;

    SELECT @Metrics AS DailyMetricsPurged, @Snapshots AS SnapshotsPurged, @Logs AS RefreshLogsPurged;
END
GO

-- ============================================================
-- SECTION 2 - DATASET ANALYTICS
-- ============================================================

CREATE OR ALTER PROCEDURE rpt.usp_DatasetCountSummary
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    SELECT
        COUNT(*)                                                                     AS TotalDatasets,
        ISNULL(SUM(CASE WHEN d.IsActive = 1 THEN 1 ELSE 0 END), 0)                    AS ActiveDatasets,
        ISNULL(SUM(CASE WHEN d.DatasetStatus = N'Active' THEN 1 ELSE 0 END), 0)       AS StatusActive,
        ISNULL(SUM(CASE WHEN d.DatasetStatus = N'Inactive' THEN 1 ELSE 0 END), 0)     AS StatusInactive,
        ISNULL(SUM(CASE WHEN d.DatasetStatus = N'Draft' THEN 1 ELSE 0 END), 0)        AS StatusDraft,
        ISNULL(SUM(CASE WHEN d.DatasetStatus = N'Archived' THEN 1 ELSE 0 END), 0)     AS StatusArchived,
        ISNULL(SUM(CASE WHEN d.DatasetStatus = N'Deprecated' THEN 1 ELSE 0 END), 0)   AS StatusDeprecated,
        COUNT(DISTINCT d.WorkspaceId)                                                 AS DistinctWorkspaces,
        COUNT(DISTINCT d.Category)                                                    AS DistinctCategories,
        COUNT(DISTINCT d.OwnerName)                                                   AS DistinctOwners,
        ISNULL(SUM(CASE WHEN d.CreatedUtc  >= DATEADD(DAY, -7,  @Now) THEN 1 ELSE 0 END), 0) AS CreatedLast7d,
        ISNULL(SUM(CASE WHEN d.CreatedUtc  >= DATEADD(DAY, -30, @Now) THEN 1 ELSE 0 END), 0) AS CreatedLast30d,
        ISNULL(SUM(CASE WHEN d.ModifiedUtc >= DATEADD(DAY, -7,  @Now) THEN 1 ELSE 0 END), 0) AS ModifiedLast7d,
        ISNULL(SUM(CASE WHEN d.ModifiedUtc >= DATEADD(DAY, -30, @Now) THEN 1 ELSE 0 END), 0) AS ModifiedLast30d
    FROM ingest.Dataset d
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId);
END
GO

-- Dimension: Status | Category | Workspace | Owner
CREATE OR ALTER PROCEDURE rpt.usp_DatasetCountByDimension
    @Dimension   NVARCHAR(20),
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Dimension NOT IN (N'Status', N'Category', N'Workspace', N'Owner')
        THROW 51900, N'@Dimension must be one of: Status, Category, Workspace, Owner.', 1;

    ;WITH Src AS (
        SELECT
            CASE @Dimension
                WHEN N'Status'    THEN d.DatasetStatus
                WHEN N'Category'  THEN d.Category
                WHEN N'Owner'     THEN d.OwnerName
                WHEN N'Workspace' THEN COALESCE(w.WorkspaceCode, N'(none)')
            END AS DimensionValue,
            d.IsActive
        FROM ingest.Dataset d
        LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
        WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    )
    SELECT
        @Dimension                                            AS Dimension,
        DimensionValue,
        COUNT(*)                                              AS DatasetCount,
        SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END)         AS ActiveCount,
        CAST(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0) AS DECIMAL(9,2)) AS SharePct
    FROM Src
    GROUP BY DimensionValue
    ORDER BY DatasetCount DESC, DimensionValue;
END
GO

-- Mode: Created | Modified
CREATE OR ALTER PROCEDURE rpt.usp_RecentDatasets
    @Mode        NVARCHAR(10) = N'Created',
    @SinceUtc    DATETIME2(3) = NULL,
    @Take        INT = 20,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Mode NOT IN (N'Created', N'Modified') SET @Mode = N'Created';
    SET @SinceUtc = ISNULL(@SinceUtc, DATEADD(DAY, -30, SYSUTCDATETIME()));
    SET @Take = CASE WHEN @Take BETWEEN 1 AND 500 THEN @Take ELSE 20 END;

    SELECT TOP (@Take)
        d.DatasetId, d.DatasetCode, d.DisplayName, d.Category, d.OwnerName,
        d.DatasetStatus, w.WorkspaceCode, w.DisplayName AS WorkspaceName,
        d.CreatedUtc, d.ModifiedUtc
    FROM ingest.Dataset d
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
      AND ((@Mode = N'Created'  AND d.CreatedUtc  >= @SinceUtc)
        OR (@Mode = N'Modified' AND d.ModifiedUtc >= @SinceUtc))
    ORDER BY CASE WHEN @Mode = N'Created' THEN d.CreatedUtc ELSE d.ModifiedUtc END DESC;
END
GO

-- Unified dataset activity feed (imports + profile runs + ETL runs)
CREATE OR ALTER PROCEDURE rpt.usp_DatasetActivity
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL,
    @Take        INT = 500
AS
BEGIN
    SET NOCOUNT ON;
    SET @Take = CASE WHEN @Take BETWEEN 1 AND 5000 THEN @Take ELSE 500 END;

    ;WITH Act AS (
        SELECT b.DatasetId, N'Import' AS ActivityType, b.Status AS Outcome,
               b.ImportUtc AS ActivityUtc, b.BatchId AS RefId,
               CONCAT(N'records=', b.TotalRecords, N' rejected=', b.RejectedRecords) AS Detail
        FROM ingest.ImportBatch b
        UNION ALL
        SELECT r.DatasetId, N'ProfileRun', r.Status,
               r.StartedUtc, r.ProfileRunId,
               CONCAT(N'score=', r.OverallScore, N' grade=', r.Grade, N' threshold=', r.ThresholdResult)
        FROM profile.ProfileRun r
        UNION ALL
        SELECT e.DatasetId, N'EtlRun', e.Status,
               e.StartedUtc, e.RunId,
               CONCAT(N'valid=', e.ValidRecords, N' invalid=', e.InvalidRecords)
        FROM etl.EtlRun e
    )
    SELECT TOP (@Take)
        a.ActivityUtc, d.DatasetCode, d.DisplayName, w.WorkspaceCode,
        a.ActivityType, a.Outcome, a.RefId, a.Detail
    FROM Act a
    INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    WHERE a.ActivityUtc >= @FromUtc AND a.ActivityUtc < @ToUtc
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    ORDER BY a.ActivityUtc DESC;
END
GO

-- Paginated dataset inventory (detail result set, export-friendly)
CREATE OR ALTER PROCEDURE rpt.usp_DatasetInventory
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Status      NVARCHAR(16) = NULL,
    @Category    NVARCHAR(64) = NULL,
    @Owner       NVARCHAR(128) = NULL,
    @PageNumber  INT = 1,
    @PageSize    INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET @PageNumber = CASE WHEN @PageNumber >= 1 THEN @PageNumber ELSE 1 END;
    SET @PageSize   = CASE WHEN @PageSize BETWEEN 1 AND 1000 THEN @PageSize ELSE 100 END;

    ;WITH Base AS (
        SELECT
            d.DatasetId, d.DatasetCode, d.DisplayName, d.Category, d.OwnerName, d.DatasetStatus,
            d.IsActive, d.CreatedUtc, d.ModifiedUtc,
            w.WorkspaceCode, w.DisplayName AS WorkspaceName,
            p.LatestOverallScore, p.LatestThresholdResult,
            lr.StartedUtc AS LastProfiledUtc,
            (SELECT COUNT(*) FROM ingest.ImportBatch b
              WHERE b.DatasetId = d.DatasetId
                AND b.ImportUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())) AS Imports30d,
            COUNT(*) OVER () AS TotalRows
        FROM ingest.Dataset d
        LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
        LEFT JOIN profile.DatasetProfile p ON p.DatasetId = d.DatasetId
        OUTER APPLY (
            SELECT TOP (1) r.StartedUtc
            FROM profile.ProfileRun r
            WHERE r.DatasetId = d.DatasetId AND r.Status = N'Succeeded'
            ORDER BY r.StartedUtc DESC
        ) lr
        WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
          AND (@Status   IS NULL OR d.DatasetStatus = @Status)
          AND (@Category IS NULL OR d.Category = @Category)
          AND (@Owner    IS NULL OR d.OwnerName = @Owner)
    )
    SELECT *
    FROM Base
    ORDER BY DatasetCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ============================================================
-- SECTION 3 - IMPORT ANALYTICS
-- ============================================================

CREATE OR ALTER PROCEDURE rpt.usp_ImportAnalyticsSummary
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH B AS (
        SELECT b.*
        FROM ingest.ImportBatch b
        INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
        WHERE b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
          AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
          AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    )
    SELECT
        COUNT(*)                                                                 AS TotalImports,
        ISNULL(SUM(CASE WHEN Status = N'Completed' THEN 1 ELSE 0 END), 0)         AS SuccessfulImports,
        ISNULL(SUM(CASE WHEN Status IN (N'Failed', N'Exhausted') THEN 1 ELSE 0 END), 0) AS FailedImports,
        ISNULL(SUM(CASE WHEN Status = N'CompletedWithErrors' THEN 1 ELSE 0 END), 0) AS CompletedWithErrors,
        ISNULL(SUM(CASE WHEN Status NOT IN (N'Completed', N'Failed', N'Exhausted', N'CompletedWithErrors')
                 THEN 1 ELSE 0 END), 0)                                          AS InProgressOrPending,
        ISNULL(SUM(CAST(TotalRecords AS BIGINT)), 0)                             AS RecordsReceived,
        ISNULL(SUM(CAST(ProcessedRecords AS BIGINT)), 0)                         AS RecordsProcessed,
        ISNULL(SUM(CAST(RejectedRecords AS BIGINT)), 0)                          AS RecordsRejected,
        ISNULL(SUM(CAST(InsertedRecords AS BIGINT)), 0)                          AS RecordsInserted,
        ISNULL(SUM(CAST(UpdatedRecords AS BIGINT)), 0)                           AS RecordsUpdated,
        ISNULL(SUM(CAST(ErrorCount AS BIGINT)), 0)                               AS ErrorCount,
        CAST(100.0 * SUM(CASE WHEN Status = N'Completed' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(9,2))                              AS ImportSuccessRatePct,
        CAST(AVG(NULLIF(COALESCE(DurationMs,
             DATEDIFF(MILLISECOND, StartedUtc, CompletedUtc)), 0)) / 1000.0
             AS DECIMAL(12,3))                                                   AS AvgProcessingSeconds,
        CAST(100.0 * SUM(CAST(RejectedRecords AS BIGINT))
             / NULLIF(SUM(CAST(TotalRecords AS BIGINT)), 0) AS DECIMAL(9,4))     AS RejectRatePct
    FROM B;
END
GO

-- Granularity: Day | Week | Month | Quarter
CREATE OR ALTER PROCEDURE rpt.usp_ImportVolumeByDate
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @Granularity NVARCHAR(10) = N'Day',
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Granularity NOT IN (N'Day', N'Week', N'Month', N'Quarter') SET @Granularity = N'Day';

    SELECT
        analytics.fn_PeriodStart(CAST(b.ImportUtc AS DATE), @Granularity) AS PeriodStart,
        @Granularity                                                      AS Granularity,
        COUNT(*)                                                          AS ImportCount,
        SUM(CASE WHEN b.Status = N'Completed' THEN 1 ELSE 0 END)          AS SuccessfulImports,
        SUM(CASE WHEN b.Status IN (N'Failed', N'Exhausted') THEN 1 ELSE 0 END) AS FailedImports,
        SUM(CASE WHEN b.Status = N'CompletedWithErrors' THEN 1 ELSE 0 END)   AS CompletedWithErrors,
        SUM(CAST(b.TotalRecords AS BIGINT))                              AS RecordsReceived,
        SUM(CAST(b.ProcessedRecords AS BIGINT))                          AS RecordsProcessed,
        SUM(CAST(b.RejectedRecords AS BIGINT))                           AS RecordsRejected,
        CAST(100.0 * SUM(CASE WHEN b.Status = N'Completed' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0) AS DECIMAL(9,2))                      AS SuccessRatePct
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    WHERE b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    GROUP BY analytics.fn_PeriodStart(CAST(b.ImportUtc AS DATE), @Granularity)
    ORDER BY PeriodStart;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ImportVolumeByDataset
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        d.DatasetId, d.DatasetCode, d.DisplayName, w.WorkspaceCode,
        COUNT(b.BatchId)                                                 AS ImportCount,
        ISNULL(SUM(CASE WHEN b.Status = N'Completed' THEN 1 ELSE 0 END), 0)         AS SuccessfulImports,
        ISNULL(SUM(CASE WHEN b.Status IN (N'Failed', N'Exhausted') THEN 1 ELSE 0 END), 0) AS FailedImports,
        ISNULL(SUM(CAST(b.TotalRecords AS BIGINT)), 0)                  AS RecordsReceived,
        ISNULL(SUM(CAST(b.ProcessedRecords AS BIGINT)), 0)              AS RecordsProcessed,
        ISNULL(SUM(CAST(b.RejectedRecords AS BIGINT)), 0)               AS RecordsRejected,
        CAST(100.0 * SUM(CASE WHEN b.Status = N'Completed' THEN 1 ELSE 0 END)
             / NULLIF(COUNT(b.BatchId), 0) AS DECIMAL(9,2))             AS SuccessRatePct,
        MAX(b.ImportUtc)                                                AS LastImportUtc
    FROM ingest.Dataset d
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    LEFT JOIN ingest.ImportBatch b
        ON b.DatasetId = d.DatasetId AND b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    GROUP BY d.DatasetId, d.DatasetCode, d.DisplayName, w.WorkspaceCode
    ORDER BY ImportCount DESC, d.DatasetCode;
END
GO

-- ============================================================
-- SECTION 4 - DATA QUALITY ANALYTICS
-- ============================================================

-- Latest succeeded profile run per dataset (reused by several procs)
CREATE OR ALTER VIEW rpt.vw_LatestProfileRun
AS
SELECT
    d.DatasetId, d.DatasetCode, d.DisplayName, d.WorkspaceId,
    d.Category, d.OwnerName, d.DatasetStatus,
    r.ProfileRunId, r.StartedUtc AS ProfiledUtc,
    r.OverallScore, r.Grade, r.CompletenessPct, r.ValidityPct, r.UniquenessPct,
    r.ConsistencyPct, r.DuplicatePct, r.ThresholdResult, r.IssueCount, r.TotalRecords
FROM ingest.Dataset d
OUTER APPLY (
    SELECT TOP (1) *
    FROM profile.ProfileRun pr
    WHERE pr.DatasetId = d.DatasetId AND pr.Status = N'Succeeded'
    ORDER BY pr.StartedUtc DESC
) r;
GO

CREATE OR ALTER PROCEDURE rpt.usp_QualityAnalyticsSummary
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*)                                                      AS DatasetsWithProfile,
        CAST(AVG(OverallScore) AS DECIMAL(5,2))                       AS AvgOverallScore,
        CAST(MIN(OverallScore) AS DECIMAL(5,2))                       AS MinOverallScore,
        CAST(MAX(OverallScore) AS DECIMAL(5,2))                       AS MaxOverallScore,
        CAST(AVG(CompletenessPct) AS DECIMAL(9,4))                    AS AvgCompletenessPct,
        CAST(AVG(ValidityPct) AS DECIMAL(9,4))                        AS AvgValidityPct,
        CAST(AVG(UniquenessPct) AS DECIMAL(9,4))                      AS AvgUniquenessPct,
        CAST(AVG(ConsistencyPct) AS DECIMAL(9,4))                     AS AvgConsistencyPct,
        ISNULL(SUM(CASE WHEN ThresholdResult = N'Pass' THEN 1 ELSE 0 END), 0)    AS ThresholdPassing,
        ISNULL(SUM(CASE WHEN ThresholdResult = N'Fail' THEN 1 ELSE 0 END), 0)    AS ThresholdFailing,
        ISNULL(SUM(CASE WHEN ThresholdResult = N'Unknown' OR ThresholdResult IS NULL THEN 1 ELSE 0 END), 0) AS ThresholdUnknown,
        ISNULL(SUM(CAST(ISNULL(IssueCount, 0) AS BIGINT)), 0)         AS TotalQualityIssues,
        ISNULL(SUM(CASE WHEN Grade = N'A' THEN 1 ELSE 0 END), 0)      AS GradeA,
        ISNULL(SUM(CASE WHEN Grade = N'B' THEN 1 ELSE 0 END), 0)      AS GradeB,
        ISNULL(SUM(CASE WHEN Grade = N'C' THEN 1 ELSE 0 END), 0)      AS GradeC,
        ISNULL(SUM(CASE WHEN Grade = N'D' THEN 1 ELSE 0 END), 0)      AS GradeD,
        ISNULL(SUM(CASE WHEN Grade = N'F' THEN 1 ELSE 0 END), 0)      AS GradeF
    FROM rpt.vw_LatestProfileRun
    WHERE ProfileRunId IS NOT NULL
      AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR DatasetCode = @DatasetCode);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_QualityByDataset
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        v.DatasetCode, v.DisplayName, v.Category, v.OwnerName,
        v.OverallScore, v.Grade, v.CompletenessPct, v.ValidityPct, v.UniquenessPct,
        v.ConsistencyPct, v.DuplicatePct, v.ThresholdResult, v.IssueCount, v.TotalRecords, v.ProfiledUtc,
        (SELECT COUNT(*) FROM profile.ThresholdResult tr
          WHERE tr.ProfileRunId = v.ProfileRunId AND tr.Passed = 0)  AS FailedThresholdCount
    FROM rpt.vw_LatestProfileRun v
    WHERE v.ProfileRunId IS NOT NULL
      AND (@WorkspaceId IS NULL OR v.WorkspaceId = @WorkspaceId)
    ORDER BY v.OverallScore ASC, v.IssueCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LowestQualityScores
    @Take        INT = 10,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Take = CASE WHEN @Take BETWEEN 1 AND 200 THEN @Take ELSE 10 END;

    SELECT TOP (@Take)
        v.DatasetCode, v.DisplayName, v.Category, v.OwnerName,
        v.OverallScore, v.Grade, v.CompletenessPct, v.ValidityPct, v.UniquenessPct,
        v.ConsistencyPct, v.ThresholdResult, v.IssueCount, v.ProfiledUtc
    FROM rpt.vw_LatestProfileRun v
    WHERE v.ProfileRunId IS NOT NULL
      AND (@WorkspaceId IS NULL OR v.WorkspaceId = @WorkspaceId)
    ORDER BY v.OverallScore ASC, v.IssueCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_QualityIssueBreakdown
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        i.IssueType,
        i.Severity,
        COUNT(*)                       AS OccurrenceCount,
        SUM(i.AffectedCount)           AS AffectedRecords,
        COUNT(DISTINCT i.DatasetId)    AS DatasetsAffected
    FROM profile.QualityIssue i
    INNER JOIN profile.ProfileRun r ON r.ProfileRunId = i.ProfileRunId
    INNER JOIN ingest.Dataset d ON d.DatasetId = i.DatasetId
    WHERE r.StartedUtc >= @FromUtc AND r.StartedUtc < @ToUtc
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    GROUP BY i.IssueType, i.Severity
    ORDER BY AffectedRecords DESC, OccurrenceCount DESC;
END
GO

-- ============================================================
-- SECTION 5 - QUALITY TREND ANALYSIS (window functions / CTEs)
-- ============================================================

-- Period series with prev-period deltas via LAG (from snapshot table)
CREATE OR ALTER PROCEDURE rpt.usp_QualityTrendSeries
    @DatasetCode NVARCHAR(64),
    @PeriodType  NVARCHAR(10) = N'Month',
    @FromDate    DATE = NULL,
    @ToDate      DATE = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @PeriodType NOT IN (N'Day', N'Week', N'Month', N'Quarter') SET @PeriodType = N'Month';
    SET @ToDate   = ISNULL(@ToDate, CAST(SYSUTCDATETIME() AS DATE));
    SET @FromDate = ISNULL(@FromDate, DATEADD(MONTH, -12, @ToDate));

    ;WITH S AS (
        SELECT
            s.PeriodStart, s.ProfileRunCount,
            s.OverallScore, s.CompletenessPct, s.ValidityPct, s.UniquenessPct, s.ConsistencyPct,
            s.FailedThresholdRuns
        FROM analytics.QualityTrendSnapshot s
        INNER JOIN ingest.Dataset d ON d.DatasetId = s.DatasetId
        WHERE d.DatasetCode = @DatasetCode
          AND s.PeriodType = @PeriodType
          AND s.PeriodStart >= @FromDate AND s.PeriodStart <= @ToDate
    )
    SELECT
        @DatasetCode AS DatasetCode, @PeriodType AS PeriodType, PeriodStart, ProfileRunCount,
        OverallScore, CompletenessPct, ValidityPct, UniquenessPct, ConsistencyPct, FailedThresholdRuns,
        LAG(OverallScore)    OVER (ORDER BY PeriodStart) AS PrevOverallScore,
        LAG(CompletenessPct) OVER (ORDER BY PeriodStart) AS PrevCompletenessPct,
        LAG(ValidityPct)     OVER (ORDER BY PeriodStart) AS PrevValidityPct,
        LAG(UniquenessPct)   OVER (ORDER BY PeriodStart) AS PrevUniquenessPct,
        LAG(ConsistencyPct)  OVER (ORDER BY PeriodStart) AS PrevConsistencyPct,
        OverallScore    - LAG(OverallScore)    OVER (ORDER BY PeriodStart) AS DeltaOverallScore,
        CompletenessPct - LAG(CompletenessPct) OVER (ORDER BY PeriodStart) AS DeltaCompletenessPct,
        ValidityPct     - LAG(ValidityPct)     OVER (ORDER BY PeriodStart) AS DeltaValidityPct,
        UniquenessPct   - LAG(UniquenessPct)   OVER (ORDER BY PeriodStart) AS DeltaUniquenessPct,
        ConsistencyPct  - LAG(ConsistencyPct)  OVER (ORDER BY PeriodStart) AS DeltaConsistencyPct,
        AVG(OverallScore) OVER (ORDER BY PeriodStart ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS OverallScore3pMovingAvg
    FROM S
    ORDER BY PeriodStart;
END
GO

-- Current profile vs previous profile (two most recent succeeded runs)
CREATE OR ALTER PROCEDURE rpt.usp_QualityProfileComparison
    @DatasetCode NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH Runs AS (
        SELECT
            r.ProfileRunId, r.StartedUtc, r.OverallScore, r.CompletenessPct, r.ValidityPct,
            r.UniquenessPct, r.ConsistencyPct, r.DuplicatePct, r.Grade, r.ThresholdResult, r.IssueCount,
            ROW_NUMBER() OVER (ORDER BY r.StartedUtc DESC) AS rn
        FROM profile.ProfileRun r
        INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
        WHERE d.DatasetCode = @DatasetCode AND r.Status = N'Succeeded'
    )
    SELECT
        @DatasetCode AS DatasetCode,
        cur.ProfileRunId AS CurrentRunId,  cur.StartedUtc AS CurrentUtc,
        prv.ProfileRunId AS PreviousRunId, prv.StartedUtc AS PreviousUtc,
        cur.OverallScore     AS CurrentOverallScore,     prv.OverallScore     AS PreviousOverallScore,
        cur.OverallScore     - prv.OverallScore          AS DeltaOverallScore,
        cur.CompletenessPct  AS CurrentCompletenessPct,  prv.CompletenessPct  AS PreviousCompletenessPct,
        cur.CompletenessPct  - prv.CompletenessPct       AS DeltaCompletenessPct,
        cur.ValidityPct      AS CurrentValidityPct,      prv.ValidityPct      AS PreviousValidityPct,
        cur.ValidityPct      - prv.ValidityPct           AS DeltaValidityPct,
        cur.UniquenessPct    AS CurrentUniquenessPct,    prv.UniquenessPct    AS PreviousUniquenessPct,
        cur.UniquenessPct    - prv.UniquenessPct         AS DeltaUniquenessPct,
        cur.ConsistencyPct   AS CurrentConsistencyPct,   prv.ConsistencyPct   AS PreviousConsistencyPct,
        cur.ConsistencyPct   - prv.ConsistencyPct        AS DeltaConsistencyPct,
        cur.Grade AS CurrentGrade, prv.Grade AS PreviousGrade,
        cur.ThresholdResult AS CurrentThreshold, prv.ThresholdResult AS PreviousThreshold,
        cur.IssueCount AS CurrentIssueCount, prv.IssueCount AS PreviousIssueCount
    FROM (SELECT * FROM Runs WHERE rn = 1) cur
    LEFT JOIN (SELECT * FROM Runs WHERE rn = 2) prv ON 1 = 1;
END
GO

-- Current period vs previous period (aggregated), for one dataset or all
CREATE OR ALTER PROCEDURE rpt.usp_QualityPeriodComparison
    @PeriodType  NVARCHAR(10) = N'Month',
    @DatasetCode NVARCHAR(64) = NULL,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @PeriodType NOT IN (N'Day', N'Week', N'Month', N'Quarter') SET @PeriodType = N'Month';

    DECLARE @Today DATE = CAST(SYSUTCDATETIME() AS DATE);
    DECLARE @CurStart DATE = analytics.fn_PeriodStart(@Today, @PeriodType);
    DECLARE @PrevStart DATE =
        CASE @PeriodType
            WHEN N'Day'     THEN DATEADD(DAY, -1, @CurStart)
            WHEN N'Week'    THEN DATEADD(DAY, -7, @CurStart)
            WHEN N'Month'   THEN DATEADD(MONTH, -1, @CurStart)
            WHEN N'Quarter' THEN DATEADD(MONTH, -3, @CurStart)
        END;

    ;WITH R AS (
        SELECT
            CASE WHEN r.StartedUtc >= @CurStart THEN N'Current' ELSE N'Previous' END AS Bucket,
            r.OverallScore, r.CompletenessPct, r.ValidityPct, r.UniquenessPct, r.ConsistencyPct,
            r.ThresholdResult
        FROM profile.ProfileRun r
        INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
        WHERE r.Status = N'Succeeded'
          AND r.StartedUtc >= @PrevStart
          AND r.StartedUtc <  DATEADD(DAY, 1, @Today)
          AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
          AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    )
    SELECT
        Bucket,
        COUNT(*)                                       AS ProfileRunCount,
        CAST(AVG(OverallScore) AS DECIMAL(5,2))        AS AvgOverallScore,
        CAST(AVG(CompletenessPct) AS DECIMAL(9,4))     AS AvgCompletenessPct,
        CAST(AVG(ValidityPct) AS DECIMAL(9,4))         AS AvgValidityPct,
        CAST(AVG(UniquenessPct) AS DECIMAL(9,4))       AS AvgUniquenessPct,
        CAST(AVG(ConsistencyPct) AS DECIMAL(9,4))      AS AvgConsistencyPct,
        SUM(CASE WHEN ThresholdResult = N'Fail' THEN 1 ELSE 0 END) AS FailedThresholdRuns
    FROM R
    GROUP BY Bucket;
END
GO

-- ============================================================
-- SECTION 6 - DATASET COMPARISON (dashboard-ready)
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_DatasetComparison
    @DatasetCodes NVARCHAR(1000) = NULL,   -- CSV; NULL = all (optionally workspace-scoped)
    @WorkspaceId  UNIQUEIDENTIFIER = NULL,
    @WindowDays   INT = 30,
    @PageNumber   INT = 1,
    @PageSize     INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SET @WindowDays = CASE WHEN @WindowDays BETWEEN 1 AND 365 THEN @WindowDays ELSE 30 END;
    SET @PageNumber = CASE WHEN @PageNumber >= 1 THEN @PageNumber ELSE 1 END;
    SET @PageSize   = CASE WHEN @PageSize BETWEEN 1 AND 500 THEN @PageSize ELSE 50 END;

    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@WindowDays, SYSUTCDATETIME());

    ;WITH Filter AS (
        SELECT d.DatasetId, d.DatasetCode, d.DisplayName, d.WorkspaceId, d.Category, d.OwnerName
        FROM ingest.Dataset d
        WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
          AND (@DatasetCodes IS NULL
               OR d.DatasetCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DatasetCodes, N',')))
    ),
    ImportStats AS (
        SELECT b.DatasetId,
               COUNT(*)                          AS ImportCount,
               SUM(CAST(b.TotalRecords AS BIGINT))     AS RecordsReceived,
               SUM(CAST(b.RejectedRecords AS BIGINT))  AS RecordsRejected,
               SUM(CAST(b.ErrorCount AS BIGINT))       AS ErrorCount
        FROM ingest.ImportBatch b
        WHERE b.ImportUtc >= @Since
        GROUP BY b.DatasetId
    ),
    Cmp AS (
        SELECT
            f.DatasetCode, f.DisplayName, f.Category, f.OwnerName,
            ISNULL(lpr.TotalRecords, 0)                             AS RecordCount,
            lpr.OverallScore                                        AS QualityScore,
            lpr.CompletenessPct, lpr.ValidityPct, lpr.UniquenessPct, lpr.ConsistencyPct,
            lpr.Grade, lpr.ThresholdResult,
            ISNULL(i.ImportCount, 0)                                AS ImportCount,
            CAST(ISNULL(i.ImportCount, 0) * 1.0 / (@WindowDays / 7.0) AS DECIMAL(9,2)) AS ImportsPerWeek,
            CAST(100.0 * ISNULL(i.RecordsRejected, 0)
                 / NULLIF(ISNULL(i.RecordsReceived, 0), 0) AS DECIMAL(9,4)) AS ErrorRatePct,
            COUNT(*) OVER () AS TotalRows
        FROM Filter f
        LEFT JOIN rpt.vw_LatestProfileRun lpr ON lpr.DatasetId = f.DatasetId
        LEFT JOIN ImportStats i ON i.DatasetId = f.DatasetId
    )
    SELECT *
    FROM Cmp
    ORDER BY QualityScore DESC, DatasetCode
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;
END
GO

-- ============================================================
-- SECTION 7 - WORKSPACE ANALYTICS
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_WorkspaceAnalytics
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @ToUtc   = ISNULL(@ToUtc, SYSUTCDATETIME());
    SET @FromUtc = ISNULL(@FromUtc, DATEADD(DAY, -30, @ToUtc));

    ;WITH Ws AS (
        SELECT w.WorkspaceId, w.WorkspaceCode, w.DisplayName
        FROM analytics.Workspace w
        WHERE (@WorkspaceId IS NULL OR w.WorkspaceId = @WorkspaceId)
    ),
    DsAgg AS (
        SELECT d.WorkspaceId,
               COUNT(*)                                        AS DatasetCount,
               SUM(CASE WHEN d.IsActive = 1 AND d.DatasetStatus = N'Active' THEN 1 ELSE 0 END) AS ActiveDatasetCount
        FROM ingest.Dataset d
        GROUP BY d.WorkspaceId
    ),
    ImpAgg AS (
        SELECT d.WorkspaceId,
               COUNT(b.BatchId)                                AS ImportVolume,
               SUM(CAST(b.ProcessedRecords AS BIGINT))         AS DataProcessingVolume,
               SUM(CAST(b.RejectedRecords AS BIGINT))          AS RecordsRejected
        FROM ingest.Dataset d
        LEFT JOIN ingest.ImportBatch b
            ON b.DatasetId = d.DatasetId AND b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
        GROUP BY d.WorkspaceId
    ),
    QualAgg AS (
        SELECT v.WorkspaceId,
               CAST(AVG(v.OverallScore) AS DECIMAL(5,2))       AS AvgQualityScore,
               SUM(CASE WHEN v.ThresholdResult = N'Fail' THEN 1 ELSE 0 END) AS FailedQualityThresholds,
               SUM(CAST(ISNULL(v.IssueCount, 0) AS BIGINT))    AS QualityIssues
        FROM rpt.vw_LatestProfileRun v
        WHERE v.ProfileRunId IS NOT NULL
        GROUP BY v.WorkspaceId
    )
    SELECT
        w.WorkspaceId, w.WorkspaceCode, w.DisplayName AS WorkspaceName,
        ISNULL(ds.DatasetCount, 0)          AS DatasetCount,
        ISNULL(ds.ActiveDatasetCount, 0)    AS ActiveDatasetCount,
        ISNULL(im.ImportVolume, 0)          AS ImportVolume,
        ISNULL(im.DataProcessingVolume, 0)  AS DataProcessingVolume,
        ISNULL(im.RecordsRejected, 0)       AS RecordsRejected,
        q.AvgQualityScore,
        ISNULL(q.FailedQualityThresholds, 0) AS FailedQualityThresholds,
        ISNULL(q.QualityIssues, 0)          AS QualityIssues
    FROM Ws w
    LEFT JOIN DsAgg   ds ON ds.WorkspaceId = w.WorkspaceId
    LEFT JOIN ImpAgg  im ON im.WorkspaceId = w.WorkspaceId
    LEFT JOIN QualAgg q  ON q.WorkspaceId  = w.WorkspaceId
    ORDER BY w.WorkspaceCode;
END
GO

-- ============================================================
-- SECTION 8 - TIME-BASED REPORTING
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_TimeBasedActivity
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @Granularity NVARCHAR(10) = N'Day',
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Granularity NOT IN (N'Day', N'Week', N'Month', N'Quarter') SET @Granularity = N'Day';

    -- Reads the pre-aggregated daily table -> no base-table scan
    SELECT
        analytics.fn_PeriodStart(m.MetricDate, @Granularity)  AS PeriodStart,
        @Granularity                                          AS Granularity,
        SUM(m.ImportCount)                                     AS ImportCount,
        SUM(m.SuccessfulImports)                               AS SuccessfulImports,
        SUM(m.FailedImports)                                   AS FailedImports,
        SUM(m.CompletedWithErrors)                             AS CompletedWithErrors,
        SUM(m.RecordsProcessed)                                AS RecordsProcessed,
        SUM(m.RecordsRejected)                                 AS RecordsRejected,
        SUM(m.ProfileRunCount)                                 AS ProfileRunCount,
        CAST(AVG(NULLIF(m.AvgOverallScore, 0)) AS DECIMAL(5,2)) AS AvgOverallScore,
        SUM(m.FailedThresholdRuns)                             AS FailedThresholdRuns,
        SUM(m.QualityIssueCount)                               AS QualityIssueCount
    FROM analytics.ReportingDailyMetric m
    INNER JOIN ingest.Dataset d ON d.DatasetId = m.DatasetId
    WHERE m.MetricDate >= CAST(@FromUtc AS DATE) AND m.MetricDate < CAST(@ToUtc AS DATE)
      AND (@WorkspaceId IS NULL OR m.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    GROUP BY analytics.fn_PeriodStart(m.MetricDate, @Granularity)
    ORDER BY PeriodStart;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_QuarterlyTrends
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Quarters    INT = 8
AS
BEGIN
    SET NOCOUNT ON;
    SET @Quarters = CASE WHEN @Quarters BETWEEN 1 AND 40 THEN @Quarters ELSE 8 END;
    DECLARE @Since DATE = analytics.fn_PeriodStart(
        DATEADD(MONTH, -3 * (@Quarters - 1), CAST(SYSUTCDATETIME() AS DATE)), N'Quarter');

    ;WITH Q AS (
        SELECT
            analytics.fn_PeriodStart(m.MetricDate, N'Quarter') AS QuarterStart,
            SUM(m.ImportCount)        AS ImportCount,
            SUM(m.SuccessfulImports)  AS SuccessfulImports,
            SUM(m.FailedImports)      AS FailedImports,
            SUM(m.RecordsProcessed)   AS RecordsProcessed,
            SUM(m.RecordsRejected)    AS RecordsRejected,
            SUM(m.ProfileRunCount)    AS ProfileRunCount,
            CAST(AVG(NULLIF(m.AvgOverallScore, 0)) AS DECIMAL(5,2)) AS AvgOverallScore,
            SUM(m.QualityIssueCount)  AS QualityIssueCount
        FROM analytics.ReportingDailyMetric m
        WHERE m.MetricDate >= @Since
          AND (@WorkspaceId IS NULL OR m.WorkspaceId = @WorkspaceId)
        GROUP BY analytics.fn_PeriodStart(m.MetricDate, N'Quarter')
    )
    SELECT
        QuarterStart,
        CONCAT(N'Q', DATEPART(QUARTER, QuarterStart), N' ', YEAR(QuarterStart)) AS QuarterLabel,
        ImportCount, SuccessfulImports, FailedImports, RecordsProcessed, RecordsRejected,
        ProfileRunCount, AvgOverallScore, QualityIssueCount,
        ImportCount    - LAG(ImportCount)    OVER (ORDER BY QuarterStart) AS DeltaImportCount,
        AvgOverallScore - LAG(AvgOverallScore) OVER (ORDER BY QuarterStart) AS DeltaAvgOverallScore,
        CAST(100.0 * (ImportCount - LAG(ImportCount) OVER (ORDER BY QuarterStart))
             / NULLIF(LAG(ImportCount) OVER (ORDER BY QuarterStart), 0) AS DECIMAL(9,2)) AS ImportCountQoQPct
    FROM Q
    ORDER BY QuarterStart;
END
GO

-- ============================================================
-- SECTION 9 - DASHBOARD FEED PROCEDURES
-- ============================================================

CREATE OR ALTER PROCEDURE rpt.usp_DashboardKpiCards
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @D30 DATETIME2(3) = DATEADD(DAY, -30, @Now);
    DECLARE @D60 DATETIME2(3) = DATEADD(DAY, -60, @Now);

    ;WITH Ds AS (
        SELECT * FROM ingest.Dataset d WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    ),
    Imp AS (
        SELECT b.Status, b.ImportUtc, b.ProcessedRecords, b.RejectedRecords
        FROM ingest.ImportBatch b
        INNER JOIN Ds d ON d.DatasetId = b.DatasetId
    ),
    Qual AS (
        SELECT v.OverallScore, v.ThresholdResult, v.IssueCount
        FROM rpt.vw_LatestProfileRun v
        WHERE v.ProfileRunId IS NOT NULL
          AND (@WorkspaceId IS NULL OR v.WorkspaceId = @WorkspaceId)
    )
    SELECT
        (SELECT COUNT(*) FROM Ds)                                                        AS TotalDatasets,
        (SELECT COUNT(*) FROM Ds WHERE IsActive = 1 AND DatasetStatus = N'Active')       AS ActiveDatasets,
        (SELECT COUNT(*) FROM Imp WHERE ImportUtc >= @D30)                               AS Imports30d,
        (SELECT COUNT(*) FROM Imp WHERE ImportUtc >= @D60 AND ImportUtc < @D30)          AS ImportsPrev30d,
        (SELECT CAST(100.0 * SUM(CASE WHEN Status = N'Completed' THEN 1 ELSE 0 END)
                / NULLIF(COUNT(*), 0) AS DECIMAL(9,2)) FROM Imp WHERE ImportUtc >= @D30) AS ImportSuccessRate30dPct,
        (SELECT ISNULL(SUM(CAST(ProcessedRecords AS BIGINT)), 0) FROM Imp WHERE ImportUtc >= @D30) AS RecordsProcessed30d,
        (SELECT ISNULL(SUM(CAST(RejectedRecords AS BIGINT)), 0) FROM Imp WHERE ImportUtc >= @D30)  AS RecordsRejected30d,
        (SELECT CAST(AVG(OverallScore) AS DECIMAL(5,2)) FROM Qual)                       AS AvgQualityScore,
        (SELECT COUNT(*) FROM Qual WHERE ThresholdResult = N'Fail')                      AS DatasetsFailingThreshold,
        (SELECT ISNULL(SUM(CAST(IssueCount AS BIGINT)), 0) FROM Qual)                    AS OpenQualityIssues;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardTrendChart
    @DatasetCode NVARCHAR(64) = NULL,
    @Days        INT = 90,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Days = CASE WHEN @Days BETWEEN 1 AND 730 THEN @Days ELSE 90 END;
    DECLARE @Since DATE = DATEADD(DAY, -@Days, CAST(SYSUTCDATETIME() AS DATE));

    SELECT
        m.MetricDate,
        SUM(m.ImportCount)                                      AS ImportCount,
        SUM(m.RecordsProcessed)                                 AS RecordsProcessed,
        SUM(m.RecordsRejected)                                  AS RecordsRejected,
        CAST(AVG(NULLIF(m.AvgOverallScore, 0)) AS DECIMAL(5,2)) AS AvgOverallScore,
        CAST(AVG(NULLIF(m.AvgCompletenessPct, 0)) AS DECIMAL(9,4)) AS AvgCompletenessPct,
        CAST(AVG(NULLIF(m.AvgValidityPct, 0)) AS DECIMAL(9,4))    AS AvgValidityPct,
        SUM(m.QualityIssueCount)                                AS QualityIssueCount
    FROM analytics.ReportingDailyMetric m
    INNER JOIN ingest.Dataset d ON d.DatasetId = m.DatasetId
    WHERE m.MetricDate >= @Since
      AND (@WorkspaceId IS NULL OR m.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    GROUP BY m.MetricDate
    ORDER BY m.MetricDate;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardQualityDistribution
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH V AS (
        SELECT
            OverallScore,
            CASE
                WHEN OverallScore >= 90 THEN N'90-100 (A)'
                WHEN OverallScore >= 80 THEN N'80-89 (B)'
                WHEN OverallScore >= 70 THEN N'70-79 (C)'
                WHEN OverallScore >= 60 THEN N'60-69 (D)'
                ELSE N'0-59 (F)'
            END AS ScoreBand,
            CASE
                WHEN OverallScore >= 90 THEN 1
                WHEN OverallScore >= 80 THEN 2
                WHEN OverallScore >= 70 THEN 3
                WHEN OverallScore >= 60 THEN 4
                ELSE 5
            END AS BandOrder
        FROM rpt.vw_LatestProfileRun
        WHERE ProfileRunId IS NOT NULL
          AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
    ),
    Bands AS (
        SELECT ScoreBand, BandOrder FROM (VALUES
            (N'90-100 (A)', 1), (N'80-89 (B)', 2), (N'70-79 (C)', 3),
            (N'60-69 (D)', 4), (N'0-59 (F)', 5)) x(ScoreBand, BandOrder)
    )
    SELECT
        b.ScoreBand, b.BandOrder,
        COUNT(v.OverallScore) AS DatasetCount,
        CAST(100.0 * COUNT(v.OverallScore) / NULLIF((SELECT COUNT(*) FROM V), 0) AS DECIMAL(9,2)) AS SharePct
    FROM Bands b
    LEFT JOIN V v ON v.BandOrder = b.BandOrder
    GROUP BY b.ScoreBand, b.BandOrder
    ORDER BY b.BandOrder;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardDatasetDistribution
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT N'Status' AS Dimension, d.DatasetStatus AS DimensionValue, COUNT(*) AS DatasetCount
    FROM ingest.Dataset d
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    GROUP BY d.DatasetStatus
    UNION ALL
    SELECT N'Category', d.Category, COUNT(*)
    FROM ingest.Dataset d
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    GROUP BY d.Category
    ORDER BY Dimension, DatasetCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardImportActivity
    @Days        INT = 30,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @Days = CASE WHEN @Days BETWEEN 1 AND 365 THEN @Days ELSE 30 END;
    DECLARE @Since DATE = DATEADD(DAY, -@Days, CAST(SYSUTCDATETIME() AS DATE));

    SELECT
        m.MetricDate,
        SUM(m.ImportCount)          AS ImportCount,
        SUM(m.SuccessfulImports)    AS SuccessfulImports,
        SUM(m.FailedImports)        AS FailedImports,
        SUM(m.CompletedWithErrors)  AS CompletedWithErrors,
        SUM(m.RecordsProcessed)     AS RecordsProcessed,
        SUM(m.RecordsRejected)      AS RecordsRejected
    FROM analytics.ReportingDailyMetric m
    WHERE m.MetricDate >= @Since
      AND (@WorkspaceId IS NULL OR m.WorkspaceId = @WorkspaceId)
    GROUP BY m.MetricDate
    ORDER BY m.MetricDate;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardTopQualityIssues
    @Take        INT = 10,
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Days        INT = 30
AS
BEGIN
    SET NOCOUNT ON;
    SET @Take = CASE WHEN @Take BETWEEN 1 AND 100 THEN @Take ELSE 10 END;
    SET @Days = CASE WHEN @Days BETWEEN 1 AND 365 THEN @Days ELSE 30 END;
    DECLARE @Since DATETIME2(3) = DATEADD(DAY, -@Days, SYSUTCDATETIME());

    SELECT TOP (@Take)
        d.DatasetCode, i.IssueType, i.ColumnName, i.ErrorCode,
        MAX(i.Severity)          AS Severity,
        SUM(i.AffectedCount)     AS AffectedCount,
        COUNT(*)                 AS OccurrenceCount
    FROM profile.QualityIssue i
    INNER JOIN profile.ProfileRun r ON r.ProfileRunId = i.ProfileRunId
    INNER JOIN ingest.Dataset d ON d.DatasetId = i.DatasetId
    WHERE r.StartedUtc >= @Since
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    GROUP BY d.DatasetCode, i.IssueType, i.ColumnName, i.ErrorCode
    ORDER BY AffectedCount DESC, OccurrenceCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DashboardWorkspaceSummary
AS
BEGIN
    SET NOCOUNT ON;
    EXEC rpt.usp_WorkspaceAnalytics @WorkspaceId = NULL;
END
GO

-- ============================================================
-- SECTION 10 - EXPORT FEEDS (clean summary + detail result sets)
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_ExportDatasetInventory
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        d.DatasetCode, d.DisplayName, w.WorkspaceCode, d.Category, d.OwnerName, d.DatasetStatus,
        d.IsActive, d.CreatedUtc, d.ModifiedUtc,
        v.OverallScore, v.Grade, v.ThresholdResult, v.IssueCount, v.ProfiledUtc,
        (SELECT COUNT(*) FROM ingest.ImportBatch b WHERE b.DatasetId = d.DatasetId) AS TotalImports
    FROM ingest.Dataset d
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    LEFT JOIN rpt.vw_LatestProfileRun v ON v.DatasetId = d.DatasetId
    WHERE (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
    ORDER BY d.DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportImportDetail
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        b.BatchId, b.ImportId, d.DatasetCode, w.WorkspaceCode, b.Status,
        b.TotalRecords, b.ValidRecords, b.ProcessedRecords, b.RejectedRecords,
        b.InsertedRecords, b.UpdatedRecords, b.ErrorCount, b.AttemptCount,
        b.ImportUtc, b.StartedUtc, b.CompletedUtc,
        COALESCE(b.DurationMs, DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc)) AS DurationMs,
        b.SourceInfo, b.SourceFile
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    WHERE b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    ORDER BY b.ImportUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportQualityDetail
    @FromUtc     DATETIME2(3),
    @ToUtc       DATETIME2(3),
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @DatasetCode NVARCHAR(64) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        r.ProfileRunId, d.DatasetCode, w.WorkspaceCode, r.StartedUtc AS ProfiledUtc,
        r.Status, r.OverallScore, r.Grade, r.CompletenessPct, r.ValidityPct, r.UniquenessPct,
        r.ConsistencyPct, r.DuplicatePct, r.ThresholdResult, r.IssueCount, r.TotalRecords,
        r.ValidRecords, r.InvalidRecords, r.DuplicateRecords, r.DurationMs
    FROM profile.ProfileRun r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
    WHERE r.StartedUtc >= @FromUtc AND r.StartedUtc < @ToUtc
      AND (@WorkspaceId IS NULL OR d.WorkspaceId = @WorkspaceId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
    ORDER BY r.StartedUtc DESC;
END
GO

PRINT 'Analytics procedures created.';
GO
