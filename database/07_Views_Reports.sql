-- ============================================================
-- 07_Views_Reports.sql
-- Monitoring & reporting views
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_ProcessingSuccessFailureSummary
AS
SELECT
    CAST(StartedUtc AS DATE) AS DayUtc,
    COUNT(*) AS TotalExecutions,
    SUM(CASE WHEN Status = N'Succeeded' THEN 1 ELSE 0 END) AS Succeeded,
    SUM(CASE WHEN Status = N'Failed' THEN 1 ELSE 0 END) AS Failed,
    SUM(CASE WHEN Status = N'Retrying' THEN 1 ELSE 0 END) AS Retrying,
    CAST(
        100.0 * SUM(CASE WHEN Status = N'Succeeded' THEN 1 ELSE 0 END)
        / NULLIF(COUNT(*), 0) AS DECIMAL(9,2)
    ) AS SuccessRatePct
FROM jobs.JobExecution
GROUP BY CAST(StartedUtc AS DATE);
GO

CREATE OR ALTER VIEW rpt.vw_DataSourceHealthStatus
AS
SELECT
    ds.DataSourceId,
    ds.Name,
    dst.TypeCode AS DataSourceTypeCode,
    ds.Status,
    ds.HealthStatus,
    ds.LastValidatedUtc,
    (
        SELECT COUNT(*)
        FROM reg.ConnectionValidationLog l
        WHERE l.DataSourceId = ds.DataSourceId
          AND l.IsSuccess = 0
          AND l.ValidatedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    ) AS ValidationFailures24h
FROM reg.DataSource ds
INNER JOIN reg.DataSourceType dst ON dst.DataSourceTypeId = ds.DataSourceTypeId
WHERE ds.IsDeleted = 0;
GO

CREATE OR ALTER VIEW rpt.vw_JobExecutionStatistics
AS
SELECT
    j.JobId,
    j.JobName,
    j.JobType,
    COUNT(e.ExecutionId) AS TotalRuns,
    SUM(CASE WHEN e.Status = N'Succeeded' THEN 1 ELSE 0 END) AS Succeeded,
    SUM(CASE WHEN e.Status = N'Failed' THEN 1 ELSE 0 END) AS Failed,
    AVG(CASE
            WHEN e.CompletedUtc IS NOT NULL
            THEN DATEDIFF(SECOND, e.StartedUtc, e.CompletedUtc) * 1.0
            ELSE NULL
        END) AS AvgDurationSeconds,
    MAX(e.StartedUtc) AS LastRunUtc
FROM jobs.ProcessingJob j
LEFT JOIN jobs.JobExecution e ON e.JobId = j.JobId
GROUP BY j.JobId, j.JobName, j.JobType;
GO

CREATE OR ALTER VIEW rpt.vw_MetadataRefreshStatus
AS
SELECT
    ds.DataSourceId,
    ds.Name AS DataSourceName,
    h.CompletedUtc AS LastRefreshUtc,
    h.Status AS LastStatus,
    h.ObjectsCaptured,
    h.ColumnsCaptured,
    (
        SELECT COUNT(*)
        FROM meta.MetadataRefreshHistory rh2
        WHERE rh2.DataSourceId = ds.DataSourceId
          AND rh2.StartedUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
    ) AS RefreshCount30d
FROM reg.DataSource ds
OUTER APPLY
(
    SELECT TOP (1) *
    FROM meta.MetadataRefreshHistory rh
    WHERE rh.DataSourceId = ds.DataSourceId
    ORDER BY rh.StartedUtc DESC
) h
WHERE ds.IsDeleted = 0;
GO

PRINT 'Report views created.';
GO
