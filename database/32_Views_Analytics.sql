-- ============================================================
-- 32_Views_Analytics.sql
-- Task 19 - Reporting views for commonly consumed analytics datasets.
-- Views are intentionally thin (read-heavy access); heavier
-- parameterised logic stays in the stored procedures in script 31.
-- ============================================================
USE EDIP;
GO

-- ------------------------------------------------------------
-- Dataset inventory with governance attributes + latest quality
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_DatasetInventory
AS
SELECT
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName,
    d.Category,
    d.OwnerName,
    d.DatasetStatus,
    d.IsActive,
    d.CreatedUtc,
    d.ModifiedUtc,
    d.WorkspaceId,
    w.WorkspaceCode,
    w.DisplayName AS WorkspaceName,
    v.ProfileRunId AS LatestProfileRunId,
    v.OverallScore AS LatestOverallScore,
    v.Grade        AS LatestGrade,
    v.ThresholdResult AS LatestThresholdResult,
    v.IssueCount   AS LatestIssueCount,
    v.ProfiledUtc  AS LastProfiledUtc,
    v.TotalRecords AS LatestRecordCount
FROM ingest.Dataset d
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = d.WorkspaceId
LEFT JOIN rpt.vw_LatestProfileRun v ON v.DatasetId = d.DatasetId;
GO

-- ------------------------------------------------------------
-- Daily import activity (pre-aggregated -> no base-table scan)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_ImportActivityDaily
AS
SELECT
    m.MetricDate,
    m.WorkspaceId,
    w.WorkspaceCode,
    m.DatasetId,
    d.DatasetCode,
    m.ImportCount,
    m.SuccessfulImports,
    m.FailedImports,
    m.CompletedWithErrors,
    m.RecordsProcessed,
    m.RecordsRejected,
    m.RecordsInserted,
    m.RecordsUpdated,
    m.AvgProcessingMs
FROM analytics.ReportingDailyMetric m
INNER JOIN ingest.Dataset d ON d.DatasetId = m.DatasetId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = m.WorkspaceId;
GO

-- ------------------------------------------------------------
-- Monthly quality trend (from snapshot table)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_QualityTrendMonthly
AS
SELECT
    s.DatasetId,
    d.DatasetCode,
    s.WorkspaceId,
    s.PeriodStart AS MonthStart,
    s.ProfileRunCount,
    s.OverallScore,
    s.CompletenessPct,
    s.ValidityPct,
    s.UniquenessPct,
    s.ConsistencyPct,
    s.DuplicatePct,
    s.FailedThresholdRuns,
    LAG(s.OverallScore) OVER (PARTITION BY s.DatasetId ORDER BY s.PeriodStart) AS PrevOverallScore,
    s.OverallScore - LAG(s.OverallScore) OVER (PARTITION BY s.DatasetId ORDER BY s.PeriodStart) AS DeltaOverallScore
FROM analytics.QualityTrendSnapshot s
INNER JOIN ingest.Dataset d ON d.DatasetId = s.DatasetId
WHERE s.PeriodType = N'Month';
GO

-- ------------------------------------------------------------
-- Workspace roll-up (30-day import window + latest quality)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_WorkspaceSummary
AS
SELECT
    w.WorkspaceId,
    w.WorkspaceCode,
    w.DisplayName AS WorkspaceName,
    w.IsActive,
    (SELECT COUNT(*) FROM ingest.Dataset d WHERE d.WorkspaceId = w.WorkspaceId) AS DatasetCount,
    (SELECT COUNT(*) FROM ingest.Dataset d
       WHERE d.WorkspaceId = w.WorkspaceId AND d.IsActive = 1 AND d.DatasetStatus = N'Active') AS ActiveDatasetCount,
    (SELECT ISNULL(SUM(m.ImportCount), 0) FROM analytics.ReportingDailyMetric m
       WHERE m.WorkspaceId = w.WorkspaceId
         AND m.MetricDate >= DATEADD(DAY, -30, CAST(SYSUTCDATETIME() AS DATE))) AS ImportVolume30d,
    (SELECT ISNULL(SUM(m.RecordsProcessed), 0) FROM analytics.ReportingDailyMetric m
       WHERE m.WorkspaceId = w.WorkspaceId
         AND m.MetricDate >= DATEADD(DAY, -30, CAST(SYSUTCDATETIME() AS DATE))) AS DataProcessingVolume30d,
    (SELECT CAST(AVG(v.OverallScore) AS DECIMAL(5,2)) FROM rpt.vw_LatestProfileRun v
       WHERE v.WorkspaceId = w.WorkspaceId AND v.ProfileRunId IS NOT NULL) AS AvgQualityScore,
    (SELECT COUNT(*) FROM rpt.vw_LatestProfileRun v
       WHERE v.WorkspaceId = w.WorkspaceId AND v.ThresholdResult = N'Fail') AS FailedQualityThresholds,
    (SELECT ISNULL(SUM(v.IssueCount), 0) FROM rpt.vw_LatestProfileRun v
       WHERE v.WorkspaceId = w.WorkspaceId AND v.ProfileRunId IS NOT NULL) AS QualityIssues
FROM analytics.Workspace w;
GO

-- ------------------------------------------------------------
-- Dataset comparison (latest quality + trailing 30-day imports)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_DatasetComparison
AS
SELECT
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName,
    d.WorkspaceId,
    d.Category,
    d.OwnerName,
    ISNULL(v.TotalRecords, 0)  AS RecordCount,
    v.OverallScore             AS QualityScore,
    v.CompletenessPct,
    v.ValidityPct,
    v.UniquenessPct,
    v.ConsistencyPct,
    v.Grade,
    v.ThresholdResult,
    i.ImportCount30d,
    CAST(ISNULL(i.ImportCount30d, 0) / 4.285714 AS DECIMAL(9,2)) AS ImportsPerWeek,
    CAST(100.0 * ISNULL(i.RecordsRejected30d, 0)
         / NULLIF(ISNULL(i.RecordsReceived30d, 0), 0) AS DECIMAL(9,4)) AS ErrorRatePct
FROM ingest.Dataset d
LEFT JOIN rpt.vw_LatestProfileRun v ON v.DatasetId = d.DatasetId
OUTER APPLY (
    SELECT
        COUNT(*)                              AS ImportCount30d,
        SUM(CAST(b.TotalRecords AS BIGINT))   AS RecordsReceived30d,
        SUM(CAST(b.RejectedRecords AS BIGINT)) AS RecordsRejected30d
    FROM ingest.ImportBatch b
    WHERE b.DatasetId = d.DatasetId
      AND b.ImportUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
) i;
GO

-- ------------------------------------------------------------
-- Latest analytics refresh status (one row per refresh job)
-- ------------------------------------------------------------
CREATE OR ALTER VIEW rpt.vw_AnalyticsRefreshStatus
AS
SELECT
    l.RefreshName,
    l.StartedUtc,
    l.CompletedUtc,
    l.DurationMs,
    l.RowsAffected,
    l.Status,
    l.Message
FROM analytics.ReportRefreshLog l
INNER JOIN (
    SELECT RefreshName, MAX(RefreshLogId) AS RefreshLogId
    FROM analytics.ReportRefreshLog
    GROUP BY RefreshName
) latest ON latest.RefreshLogId = l.RefreshLogId;
GO

PRINT 'Analytics reporting views created.';
GO
