-- ============================================================
-- 22_Views_Etl.sql
-- ETL monitoring views and export-ready report procedures
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_EtlBatchSummary
AS
SELECT
    r.RunId,
    r.BatchId,
    r.ImportId,
    d.DatasetCode,
    r.TriggerType,
    r.Status,
    r.AttemptNumber,
    r.StartedUtc,
    r.CompletedUtc,
    r.DurationMs,
    r.TotalRecords,
    r.TransformedRecords,
    r.ValidRecords,
    r.InvalidRecords,
    r.DuplicateRecords,
    r.InsertedRecords,
    r.UpdatedRecords,
    r.SkippedRecords,
    r.ProcessingErrors,
    CAST(100.0 * r.ValidRecords / NULLIF(r.TotalRecords, 0) AS DECIMAL(9,2)) AS ValidRatePct
FROM etl.EtlRun r
INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId;
GO

CREATE OR ALTER VIEW rpt.vw_EtlSuccessRate
AS
SELECT
    CAST(r.StartedUtc AS DATE) AS DayUtc,
    d.DatasetCode,
    COUNT(*) AS RunCount,
    SUM(CASE WHEN r.Status IN (N'Succeeded', N'Partial') THEN 1 ELSE 0 END) AS SuccessfulRuns,
    SUM(CASE WHEN r.Status IN (N'Failed', N'RolledBack') THEN 1 ELSE 0 END) AS FailedRuns,
    CAST(100.0 * SUM(CASE WHEN r.Status IN (N'Succeeded', N'Partial') THEN 1 ELSE 0 END)
         / NULLIF(COUNT(*), 0) AS DECIMAL(9,2)) AS SuccessRatePct,
    CAST(AVG(r.DurationMs) AS INT) AS AvgDurationMs,
    SUM(r.TotalRecords) AS TotalRecords,
    SUM(r.ValidRecords) AS ValidRecords,
    SUM(r.InvalidRecords) AS InvalidRecords
FROM etl.EtlRun r
INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
GROUP BY CAST(r.StartedUtc AS DATE), d.DatasetCode;
GO

CREATE OR ALTER VIEW rpt.vw_EtlFailedBatches
AS
SELECT
    b.BatchId,
    b.ImportId,
    d.DatasetCode,
    b.SourceFile,
    b.LoadMode,
    b.DuplicateStrategy,
    b.Status,
    b.AttemptCount,
    b.MaxRetries,
    b.TotalRecords,
    b.RejectedRecords,
    b.ErrorCount,
    b.ImportUtc,
    b.CompletedUtc,
    b.DurationMs,
    b.LastErrorMessage
FROM ingest.ImportBatch b
INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
WHERE b.Status IN (N'Failed', N'Exhausted', N'CompletedWithErrors');
GO

CREATE OR ALTER VIEW rpt.vw_EtlValidationErrorSummary
AS
SELECT
    CAST(e.ErrorUtc AS DATE) AS DayUtc,
    d.DatasetCode,
    e.Phase,
    e.ErrorCode,
    COUNT(*) AS ErrorCount
FROM etl.EtlError e
INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
GROUP BY CAST(e.ErrorUtc AS DATE), d.DatasetCode, e.Phase, e.ErrorCode;
GO

CREATE OR ALTER PROCEDURE rpt.usp_EtlBatchSummary
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM rpt.vw_EtlBatchSummary
    WHERE StartedUtc >= @FromUtc AND StartedUtc < @ToUtc
    ORDER BY StartedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_EtlSuccessRate
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM rpt.vw_EtlSuccessRate
    WHERE DayUtc >= CAST(@FromUtc AS DATE) AND DayUtc < CAST(@ToUtc AS DATE)
    ORDER BY DayUtc DESC, DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_EtlFailedBatches
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM rpt.vw_EtlFailedBatches
    WHERE ImportUtc >= @FromUtc AND ImportUtc < @ToUtc
    ORDER BY ImportUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_EtlValidationErrorSummary
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM rpt.vw_EtlValidationErrorSummary
    WHERE DayUtc >= CAST(@FromUtc AS DATE) AND DayUtc < CAST(@ToUtc AS DATE)
    ORDER BY DayUtc DESC, ErrorCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_EtlDatasetHistory
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        d.DatasetId,
        d.DatasetCode,
        d.DisplayName,
        COUNT(r.RunId) AS RunCount,
        ISNULL(SUM(r.TotalRecords), 0) AS TotalRecords,
        ISNULL(SUM(r.ValidRecords), 0) AS ValidRecords,
        ISNULL(SUM(r.InvalidRecords), 0) AS InvalidRecords,
        ISNULL(SUM(r.TransformedRecords), 0) AS TransformedRecords,
        ISNULL(SUM(r.DuplicateRecords), 0) AS DuplicateRecords,
        CAST(AVG(r.DurationMs) AS INT) AS AvgDurationMs,
        MAX(r.StartedUtc) AS LastRunUtc
    FROM ingest.Dataset d
    LEFT JOIN etl.EtlRun r ON r.DatasetId = d.DatasetId
    WHERE d.IsActive = 1
    GROUP BY d.DatasetId, d.DatasetCode, d.DisplayName
    ORDER BY d.DatasetCode;
END
GO

PRINT 'ETL monitoring views and report procedures created.';
GO
