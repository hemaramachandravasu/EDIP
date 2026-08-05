-- ============================================================
-- 06_StoredProcedures.sql
-- Operational stored procedures
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER PROCEDURE rpt.usp_ProcessingSuccessFailureSummary
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;

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
    WHERE StartedUtc >= @FromUtc AND StartedUtc < @ToUtc
    GROUP BY CAST(StartedUtc AS DATE)
    ORDER BY DayUtc;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DataSourceHealthStatus
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ds.DataSourceId,
        ds.Name,
        dst.TypeCode AS DataSourceTypeCode,
        ds.Status,
        ds.HealthStatus,
        ds.LastValidatedUtc,
        ISNULL(v.FailCount, 0) AS ValidationFailures24h
    FROM reg.DataSource ds
    INNER JOIN reg.DataSourceType dst ON dst.DataSourceTypeId = ds.DataSourceTypeId
    OUTER APPLY
    (
        SELECT COUNT(*) AS FailCount
        FROM reg.ConnectionValidationLog l
        WHERE l.DataSourceId = ds.DataSourceId
          AND l.IsSuccess = 0
          AND l.ValidatedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
    ) v
    WHERE ds.IsDeleted = 0
    ORDER BY ds.Name;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_JobExecutionStatistics
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;

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
    LEFT JOIN jobs.JobExecution e
        ON e.JobId = j.JobId
       AND e.StartedUtc >= @FromUtc
       AND e.StartedUtc < @ToUtc
    GROUP BY j.JobId, j.JobName, j.JobType
    ORDER BY j.JobName;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_MetadataRefreshStatus
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        ds.DataSourceId,
        ds.Name AS DataSourceName,
        h.CompletedUtc AS LastRefreshUtc,
        h.Status AS LastStatus,
        h.ObjectsCaptured,
        h.ColumnsCaptured,
        ISNULL(c.RefreshCount30d, 0) AS RefreshCount30d
    FROM reg.DataSource ds
    OUTER APPLY
    (
        SELECT TOP (1) *
        FROM meta.MetadataRefreshHistory rh
        WHERE rh.DataSourceId = ds.DataSourceId
        ORDER BY rh.StartedUtc DESC
    ) h
    OUTER APPLY
    (
        SELECT COUNT(*) AS RefreshCount30d
        FROM meta.MetadataRefreshHistory rh2
        WHERE rh2.DataSourceId = ds.DataSourceId
          AND rh2.StartedUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
    ) c
    WHERE ds.IsDeleted = 0
    ORDER BY ds.Name;
END
GO

CREATE OR ALTER PROCEDURE jobs.usp_GetDueJobs
    @AsOfUtc DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOfUtc = ISNULL(@AsOfUtc, SYSUTCDATETIME());

    SELECT
        j.JobId,
        j.JobName,
        j.Description,
        j.DataSourceId,
        j.JobType,
        j.IsEnabled,
        j.MaxRetries,
        j.RetryDelaySeconds,
        j.CreatedUtc,
        j.ModifiedUtc,
        s.ScheduleId,
        s.FrequencyCode,
        s.IntervalMinutes,
        s.CronExpression,
        s.NextRunUtc,
        s.LastRunUtc,
        s.IsActive
    FROM jobs.ProcessingJob j
    INNER JOIN jobs.JobSchedule s ON s.JobId = j.JobId
    WHERE j.IsEnabled = 1
      AND s.IsActive = 1
      AND s.NextRunUtc IS NOT NULL
      AND s.NextRunUtc <= @AsOfUtc;
END
GO

CREATE OR ALTER PROCEDURE jobs.usp_MarkJobScheduleRun
    @JobId UNIQUEIDENTIFIER,
    @LastRunUtc DATETIME2(3),
    @NextRunUtc DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE jobs.JobSchedule
    SET LastRunUtc = @LastRunUtc,
        NextRunUtc = @NextRunUtc
    WHERE JobId = @JobId;
END
GO

PRINT 'Stored procedures created.';
GO
