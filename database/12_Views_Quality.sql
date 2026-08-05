-- ============================================================
-- 12_Views_Quality.sql
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_DataQualitySummary
AS
SELECT TOP (1000)
    ds.DataSourceId, ds.Name AS DataSourceName, a.AssessmentId, a.OverallScore, a.Grade,
    a.MissingScore, a.DuplicateScore, a.TypeScore, a.ReferentialScore,
    a.EmptyTableScore, a.FreshnessScore, a.AssessedUtc
FROM dq.QualityAssessment a
INNER JOIN reg.DataSource ds ON ds.DataSourceId = a.DataSourceId
WHERE ds.IsDeleted = 0
ORDER BY a.AssessedUtc DESC;
GO

CREATE OR ALTER VIEW rpt.vw_DatasetHealthStatus
AS
SELECT
    ds.DataSourceId,
    ds.Name AS DataSourceName,
    ds.HealthStatus AS ConnectionHealth,
    qa.OverallScore AS LatestQualityScore,
    qa.Grade AS LatestGrade,
    qa.AssessedUtc AS LastAssessedUtc,
    CASE
        WHEN qa.OverallScore IS NULL THEN N'Unknown'
        WHEN qa.OverallScore >= 80 THEN N'Healthy'
        WHEN qa.OverallScore >= 60 THEN N'Degraded'
        ELSE N'Unhealthy'
    END AS DatasetHealth
FROM reg.DataSource ds
OUTER APPLY (
    SELECT TOP (1) * FROM dq.QualityAssessment q
    WHERE q.DataSourceId = ds.DataSourceId ORDER BY q.AssessedUtc DESC
) qa
WHERE ds.IsDeleted = 0;
GO

CREATE OR ALTER VIEW rpt.vw_SchemaChangeHistory
AS
SELECT e.SchemaChangeId, e.DataSourceId, ds.Name AS DataSourceName, e.ChangeType,
       e.SchemaName, e.ObjectName, e.ColumnName, e.OldValue, e.NewValue, e.DetectedUtc
FROM dq.SchemaChangeEvent e
INNER JOIN reg.DataSource ds ON ds.DataSourceId = e.DataSourceId;
GO

CREATE OR ALTER VIEW rpt.vw_MetadataSyncStatus
AS
SELECT
    ds.DataSourceId, ds.Name AS DataSourceName, s.Status AS LastSyncStatus,
    s.StartedUtc AS LastSyncUtc, s.ObjectsAdded, s.ObjectsRemoved, s.ColumnsChanged
FROM reg.DataSource ds
OUTER APPLY (
    SELECT TOP (1) * FROM dq.MetadataSyncLog x
    WHERE x.DataSourceId = ds.DataSourceId ORDER BY x.StartedUtc DESC
) s
WHERE ds.IsDeleted = 0;
GO

PRINT 'Quality report views created.';
GO
