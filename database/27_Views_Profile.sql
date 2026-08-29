-- ============================================================
-- 27_Views_Profile.sql
-- Monitoring views and dashboard-ready report procedures
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_DatasetQualitySummary
AS
SELECT
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName,
    p.LatestProfileRunId,
    p.LatestOverallScore,
    p.LatestThresholdResult,
    r.Grade,
    r.CompletenessPct,
    r.ValidityPct,
    r.UniquenessPct,
    r.ConsistencyPct,
    r.DuplicatePct,
    r.TotalRecords,
    r.IssueCount,
    r.StartedUtc AS LastProfiledUtc,
    r.DurationMs
FROM ingest.Dataset d
LEFT JOIN profile.DatasetProfile p ON p.DatasetId = d.DatasetId
LEFT JOIN profile.ProfileRun r ON r.ProfileRunId = p.LatestProfileRunId
WHERE d.IsActive = 1;
GO

CREATE OR ALTER VIEW rpt.vw_LowestQualityDatasets
AS
SELECT TOP (100)
    DatasetCode, DisplayName, LatestOverallScore, Grade, LatestThresholdResult,
    CompletenessPct, ValidityPct, UniquenessPct, IssueCount, LastProfiledUtc
FROM rpt.vw_DatasetQualitySummary
WHERE LatestOverallScore IS NOT NULL
ORDER BY LatestOverallScore ASC, IssueCount DESC;
GO

CREATE OR ALTER VIEW rpt.vw_TopDataQualityIssues
AS
SELECT
    d.DatasetCode,
    i.IssueType,
    i.ColumnName,
    i.ErrorCode,
    SUM(i.AffectedCount) AS AffectedCount,
    MAX(i.Severity) AS Severity,
    COUNT(*) AS OccurrenceCount
FROM profile.QualityIssue i
INNER JOIN profile.ProfileRun r ON r.ProfileRunId = i.ProfileRunId
INNER JOIN ingest.Dataset d ON d.DatasetId = i.DatasetId
WHERE r.StartedUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
GROUP BY d.DatasetCode, i.IssueType, i.ColumnName, i.ErrorCode;
GO

CREATE OR ALTER VIEW rpt.vw_FailedQualityThresholds
AS
SELECT
    r.ProfileRunId,
    d.DatasetCode,
    tr.MetricCode,
    tr.ActualValue,
    tr.OperatorCode,
    tr.ThresholdValue,
    r.StartedUtc,
    r.OverallScore
FROM profile.ThresholdResult tr
INNER JOIN profile.ProfileRun r ON r.ProfileRunId = tr.ProfileRunId
INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
WHERE tr.Passed = 0;
GO

CREATE OR ALTER PROCEDURE rpt.usp_DatasetQualitySummary
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM rpt.vw_DatasetQualitySummary ORDER BY DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_LowestQualityDatasets
    @Take INT = 20
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Take) *
    FROM rpt.vw_DatasetQualitySummary
    WHERE LatestOverallScore IS NOT NULL
    ORDER BY LatestOverallScore ASC, IssueCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_TopDataQualityIssues
    @Take INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP (@Take) *
    FROM rpt.vw_TopDataQualityIssues
    ORDER BY AffectedCount DESC, OccurrenceCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_QualityTrendReport
    @DatasetCode NVARCHAR(64),
    @FromUtc DATETIME2(3),
    @ToUtc DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC profile.usp_GetQualityTrend @DatasetCode = @DatasetCode, @FromUtc = @FromUtc, @ToUtc = @ToUtc;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_FailedQualityThresholds
    @FromUtc DATETIME2(3),
    @ToUtc DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT *
    FROM rpt.vw_FailedQualityThresholds
    WHERE StartedUtc >= @FromUtc AND StartedUtc < @ToUtc
    ORDER BY StartedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DatasetQualityComparison
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        DatasetCode,
        DisplayName,
        LatestOverallScore,
        Grade,
        CompletenessPct,
        ValidityPct,
        UniquenessPct,
        ConsistencyPct,
        DuplicatePct,
        TotalRecords,
        LatestThresholdResult,
        LastProfiledUtc
    FROM rpt.vw_DatasetQualitySummary
    ORDER BY LatestOverallScore DESC, DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ImportQualitySummary
    @FromUtc DATETIME2(3),
    @ToUtc DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        b.BatchId,
        b.ImportId,
        d.DatasetCode,
        b.Status AS ImportStatus,
        b.TotalRecords,
        b.ValidRecords,
        b.RejectedRecords,
        b.ErrorCount,
        r.ProfileRunId,
        r.OverallScore,
        r.CompletenessPct,
        r.ValidityPct,
        r.ThresholdResult,
        b.ImportUtc
    FROM ingest.ImportBatch b
    INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
    OUTER APPLY (
        SELECT TOP (1) *
        FROM profile.ProfileRun pr
        WHERE pr.BatchId = b.BatchId OR pr.ImportId = b.ImportId
        ORDER BY pr.StartedUtc DESC
    ) r
    WHERE b.ImportUtc >= @FromUtc AND b.ImportUtc < @ToUtc
    ORDER BY b.ImportUtc DESC;
END
GO

PRINT 'Profile monitoring views and report procedures created.';
GO
