-- ============================================================
-- 11_Procs_Quality.sql
-- Profiling archive + DQ reporting procedures
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER PROCEDURE dq.usp_ArchiveProfilingHistory
    @RetainDays INT = 90
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Cutoff DATETIME2(3) = DATEADD(DAY, -@RetainDays, SYSUTCDATETIME());

    DELETE FROM dq.QualityCheckResult
    WHERE AssessmentId IN (
        SELECT AssessmentId FROM dq.QualityAssessment
        WHERE AssessedUtc < @Cutoff);

    DELETE FROM dq.QualityAssessment WHERE AssessedUtc < @Cutoff;

    -- Cascades remove TableProfile / ColumnProfile
    DELETE FROM dq.ProfilingRun WHERE StartedUtc < @Cutoff AND Status <> N'Running';

    DELETE FROM dq.SchemaChangeEvent WHERE DetectedUtc < @Cutoff;
    DELETE FROM dq.MetadataSyncLog WHERE StartedUtc < @Cutoff AND Status <> N'Running';

    SELECT @@ROWCOUNT AS RowsAffectedHint;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DataQualitySummary
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ds.DataSourceId,
        ds.Name AS DataSourceName,
        a.AssessmentId,
        a.OverallScore,
        a.Grade,
        a.MissingScore,
        a.DuplicateScore,
        a.TypeScore,
        a.ReferentialScore,
        a.EmptyTableScore,
        a.FreshnessScore,
        a.AssessedUtc
    FROM dq.QualityAssessment a
    INNER JOIN reg.DataSource ds ON ds.DataSourceId = a.DataSourceId
    WHERE a.AssessedUtc >= @FromUtc AND a.AssessedUtc < @ToUtc
      AND ds.IsDeleted = 0
    ORDER BY a.AssessedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_DatasetHealthStatus
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ds.DataSourceId,
        ds.Name AS DataSourceName,
        ds.HealthStatus AS ConnectionHealth,
        qa.OverallScore AS LatestQualityScore,
        qa.Grade AS LatestGrade,
        qa.AssessedUtc AS LastAssessedUtc,
        pr.StartedUtc AS LastProfiledUtc,
        pr.Status AS LastProfileStatus,
        CASE
            WHEN qa.OverallScore IS NULL THEN N'Unknown'
            WHEN qa.OverallScore >= 80 THEN N'Healthy'
            WHEN qa.OverallScore >= 60 THEN N'Degraded'
            ELSE N'Unhealthy'
        END AS DatasetHealth
    FROM reg.DataSource ds
    OUTER APPLY (
        SELECT TOP (1) * FROM dq.QualityAssessment q
        WHERE q.DataSourceId = ds.DataSourceId
        ORDER BY q.AssessedUtc DESC
    ) qa
    OUTER APPLY (
        SELECT TOP (1) * FROM dq.ProfilingRun r
        WHERE r.DataSourceId = ds.DataSourceId
        ORDER BY r.StartedUtc DESC
    ) pr
    WHERE ds.IsDeleted = 0
    ORDER BY ds.Name;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_SchemaChangeHistory
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        e.SchemaChangeId,
        e.DataSourceId,
        ds.Name AS DataSourceName,
        e.ChangeType,
        e.SchemaName,
        e.ObjectName,
        e.ColumnName,
        e.OldValue,
        e.NewValue,
        e.DetectedUtc
    FROM dq.SchemaChangeEvent e
    INNER JOIN reg.DataSource ds ON ds.DataSourceId = e.DataSourceId
    WHERE e.DetectedUtc >= @FromUtc AND e.DetectedUtc < @ToUtc
    ORDER BY e.DetectedUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_MetadataSyncStatus
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        ds.DataSourceId,
        ds.Name AS DataSourceName,
        s.SyncLogId,
        s.Status AS LastSyncStatus,
        s.StartedUtc AS LastSyncUtc,
        s.ObjectsAdded,
        s.ObjectsRemoved,
        s.ColumnsChanged,
        (
            SELECT COUNT(*) FROM dq.MetadataSyncLog l
            WHERE l.DataSourceId = ds.DataSourceId
              AND l.StartedUtc >= DATEADD(DAY, -30, SYSUTCDATETIME())
        ) AS SyncCount30d
    FROM reg.DataSource ds
    OUTER APPLY (
        SELECT TOP (1) * FROM dq.MetadataSyncLog x
        WHERE x.DataSourceId = ds.DataSourceId
        ORDER BY x.StartedUtc DESC
    ) s
    WHERE ds.IsDeleted = 0
    ORDER BY ds.Name;
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_QualityTrendAnalysis
    @FromUtc DATETIME2(3),
    @ToUtc   DATETIME2(3)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT
        CAST(a.AssessedUtc AS DATE) AS DayUtc,
        ds.DataSourceId,
        ds.Name AS DataSourceName,
        AVG(a.OverallScore) AS AvgOverallScore,
        MIN(a.OverallScore) AS MinOverallScore,
        MAX(a.OverallScore) AS MaxOverallScore,
        COUNT(*) AS AssessmentCount
    FROM dq.QualityAssessment a
    INNER JOIN reg.DataSource ds ON ds.DataSourceId = a.DataSourceId
    WHERE a.AssessedUtc >= @FromUtc AND a.AssessedUtc < @ToUtc
    GROUP BY CAST(a.AssessedUtc AS DATE), ds.DataSourceId, ds.Name
    ORDER BY DayUtc, ds.Name;
END
GO

PRINT 'Quality reporting procedures created.';
GO
