-- ============================================================
-- 17_Views_Ingestion.sql
-- Monitoring views + export-ready report procedures
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_ImportSuccessRate
AS
SELECT
    CAST(b.ImportUtc AS DATE) AS DayUtc,
    d.DatasetCode,
    COUNT(*) AS TotalBatches,
    SUM(CASE WHEN b.Status IN (N'Completed', N'CompletedWithErrors') THEN 1 ELSE 0 END) AS SuccessfulBatches,
    SUM(CASE WHEN b.Status = N'Failed' THEN 1 ELSE 0 END) AS FailedBatches,
    CAST(
        100.0 * SUM(CASE WHEN b.Status IN (N'Completed', N'CompletedWithErrors') THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0)
        AS DECIMAL(9,2)
    ) AS SuccessRatePct,
    SUM(b.TotalRecords) AS TotalRecords,
    SUM(b.ProcessedRecords) AS ProcessedRecords,
    SUM(b.RejectedRecords) AS RejectedRecords
FROM ingest.ImportBatch b
INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId
GROUP BY CAST(b.ImportUtc AS DATE), d.DatasetCode;
GO

CREATE OR ALTER VIEW rpt.vw_BatchProcessingHistory
AS
SELECT
    b.BatchId,
    d.DatasetCode,
    d.DisplayName AS DatasetName,
    b.SourceInfo,
    b.Status,
    b.TotalRecords,
    b.ValidRecords,
    b.RejectedRecords,
    b.ProcessedRecords,
    b.InsertedRecords,
    b.UpdatedRecords,
    b.ErrorCount,
    b.AttemptCount,
    b.ImportUtc,
    b.StartedUtc,
    b.CompletedUtc,
    CASE
        WHEN b.StartedUtc IS NOT NULL AND b.CompletedUtc IS NOT NULL
            THEN DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc) / 1000.0
        ELSE NULL
    END AS DurationSeconds,
    b.LastErrorMessage
FROM ingest.ImportBatch b
INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId;
GO

CREATE OR ALTER VIEW rpt.vw_ValidationErrorSummary
AS
SELECT
    e.ErrorId,
    e.BatchId,
    d.DatasetCode,
    e.RowReference,
    e.ColumnName,
    e.InvalidValue,
    e.ErrorCode,
    e.ErrorDescription,
    e.Severity,
    e.ErrorUtc
FROM ingest.ImportError e
INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId;
GO

CREATE OR ALTER VIEW rpt.vw_DatasetProcessingStatistics
AS
SELECT
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName,
    COUNT(b.BatchId) AS BatchCount,
    ISNULL(SUM(b.TotalRecords), 0) AS TotalRecords,
    ISNULL(SUM(b.ProcessedRecords), 0) AS ProcessedRecords,
    ISNULL(SUM(b.RejectedRecords), 0) AS RejectedRecords,
    ISNULL(SUM(b.InsertedRecords), 0) AS InsertedRecords,
    ISNULL(SUM(b.UpdatedRecords), 0) AS UpdatedRecords,
    ISNULL(SUM(b.ErrorCount), 0) AS ErrorCount,
    AVG(
        CASE
            WHEN b.StartedUtc IS NOT NULL AND b.CompletedUtc IS NOT NULL
                THEN DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc) / 1000.0
            ELSE NULL
        END
    ) AS AvgDurationSeconds,
    MAX(b.ImportUtc) AS LastImportUtc,
    MAX(CASE WHEN b.Status IN (N'Completed', N'CompletedWithErrors') THEN b.CompletedUtc END) AS LastSuccessUtc
FROM ingest.Dataset d
LEFT JOIN ingest.ImportBatch b ON b.DatasetId = d.DatasetId
WHERE d.IsActive = 1
GROUP BY d.DatasetId, d.DatasetCode, d.DisplayName;
GO

CREATE OR ALTER VIEW rpt.vw_ImportErrorTrends
AS
SELECT
    CAST(e.ErrorUtc AS DATE) AS DayUtc,
    d.DatasetCode,
    e.ErrorCode,
    COUNT(*) AS ErrorCount
FROM ingest.ImportError e
INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
GROUP BY CAST(e.ErrorUtc AS DATE), d.DatasetCode, e.ErrorCode;
GO

CREATE OR ALTER VIEW rpt.vw_RecordsProcessedPerBatch
AS
SELECT
    b.BatchId,
    d.DatasetCode,
    b.Status,
    b.TotalRecords,
    b.ProcessedRecords,
    b.RejectedRecords,
    CAST(
        100.0 * b.ProcessedRecords / NULLIF(b.TotalRecords, 0)
        AS DECIMAL(9,2)
    ) AS ProcessRatePct,
    CASE
        WHEN b.StartedUtc IS NOT NULL AND b.CompletedUtc IS NOT NULL
            THEN DATEDIFF(MILLISECOND, b.StartedUtc, b.CompletedUtc) / 1000.0
        ELSE NULL
    END AS DurationSeconds,
    b.ImportUtc
FROM ingest.ImportBatch b
INNER JOIN ingest.Dataset d ON d.DatasetId = b.DatasetId;
GO

-- ------------------------------------------------------------
-- Report procedures (API / Excel / CSV export)
-- ------------------------------------------------------------
CREATE OR ALTER PROCEDURE rpt.usp_ImportSummary
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        DayUtc,
        DatasetCode,
        TotalBatches,
        SuccessfulBatches,
        FailedBatches,
        SuccessRatePct,
        TotalRecords,
        ProcessedRecords,
        RejectedRecords
    FROM rpt.vw_ImportSuccessRate
    WHERE DayUtc >= CAST(@FromUtc AS DATE)
      AND DayUtc < CAST(@ToUtc AS DATE)
    ORDER BY DayUtc DESC, DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_BatchProcessingHistory
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        BatchId,
        DatasetCode,
        DatasetName,
        SourceInfo,
        Status,
        TotalRecords,
        ValidRecords,
        RejectedRecords,
        ProcessedRecords,
        InsertedRecords,
        UpdatedRecords,
        ErrorCount,
        AttemptCount,
        ImportUtc,
        StartedUtc,
        CompletedUtc,
        DurationSeconds,
        LastErrorMessage
    FROM rpt.vw_BatchProcessingHistory
    WHERE ImportUtc >= @FromUtc AND ImportUtc < @ToUtc
    ORDER BY ImportUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ValidationErrors
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ErrorId,
        BatchId,
        DatasetCode,
        RowReference,
        ColumnName,
        InvalidValue,
        ErrorCode,
        ErrorDescription,
        Severity,
        ErrorUtc
    FROM rpt.vw_ValidationErrorSummary
    WHERE ErrorUtc >= @FromUtc AND ErrorUtc < @ToUtc
    ORDER BY ErrorUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DatasetProcessingStatistics
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        DatasetId,
        DatasetCode,
        DisplayName,
        BatchCount,
        TotalRecords,
        ProcessedRecords,
        RejectedRecords,
        InsertedRecords,
        UpdatedRecords,
        ErrorCount,
        AvgDurationSeconds,
        LastImportUtc,
        LastSuccessUtc
    FROM rpt.vw_DatasetProcessingStatistics
    ORDER BY DatasetCode;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ImportErrorTrends
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        DayUtc,
        DatasetCode,
        ErrorCode,
        ErrorCount
    FROM rpt.vw_ImportErrorTrends
    WHERE DayUtc >= CAST(@FromUtc AS DATE)
      AND DayUtc < CAST(@ToUtc AS DATE)
    ORDER BY DayUtc DESC, DatasetCode, ErrorCount DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_FailedImports
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        BatchId,
        DatasetCode,
        DatasetName,
        SourceInfo,
        Status,
        TotalRecords,
        ValidRecords,
        RejectedRecords,
        ProcessedRecords,
        InsertedRecords,
        UpdatedRecords,
        ErrorCount,
        AttemptCount,
        ImportUtc,
        StartedUtc,
        CompletedUtc,
        DurationSeconds,
        LastErrorMessage
    FROM rpt.vw_BatchProcessingHistory
    WHERE ImportUtc >= @FromUtc AND ImportUtc < @ToUtc
      AND Status IN (N'Failed', N'CompletedWithErrors')
    ORDER BY ImportUtc DESC;
END
GO

PRINT 'Ingestion monitoring views and report procedures created.';
GO
