-- ============================================================
-- 37_Views_Lineage.sql
-- Reporting views for lineage dashboards
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_LineageRelationshipSummary
AS
SELECT
    r.RelationshipId,
    r.RelationshipType,
    r.ProcessType,
    r.ProcessReference,
    r.WorkspaceId,
    w.WorkspaceCode,
    r.IsActive,
    r.CreatedUtc,
    r.CreatedBy,
    s.EntityId AS SourceEntityId,
    s.EntityTypeCode AS SourceEntityType,
    s.EntityCode AS SourceEntityCode,
    s.DisplayName AS SourceEntityName,
    s.VersionNumber AS SourceVersionNumber,
    t.EntityId AS TargetEntityId,
    t.EntityTypeCode AS TargetEntityType,
    t.EntityCode AS TargetEntityCode,
    t.DisplayName AS TargetEntityName,
    t.VersionNumber AS TargetVersionNumber
FROM lineage.LineageRelationship r
INNER JOIN lineage.LineageEntity s ON s.EntityId = r.SourceEntityId
INNER JOIN lineage.LineageEntity t ON t.EntityId = r.TargetEntityId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = r.WorkspaceId;
GO

CREATE OR ALTER VIEW rpt.vw_DatasetVersionHistory
AS
SELECT
    v.DatasetVersionId,
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName AS DatasetName,
    d.WorkspaceId,
    w.WorkspaceCode,
    v.VersionNumber,
    v.EntityId,
    v.ImportBatchId,
    v.ImportId,
    v.EtlRunId,
    v.ProfileRunId,
    v.DataSourceId,
    ds.Name AS DataSourceName,
    v.ProducedUtc,
    v.ProducedBy,
    v.Notes,
    v.CreatedUtc
FROM lineage.DatasetVersion v
INNER JOIN ingest.Dataset d ON d.DatasetId = v.DatasetId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = v.WorkspaceId
LEFT JOIN reg.DataSource ds ON ds.DataSourceId = v.DataSourceId;
GO

CREATE OR ALTER VIEW rpt.vw_LineageEntityCatalog
AS
SELECT
    e.EntityId,
    e.EntityTypeCode,
    et.DisplayName AS EntityTypeName,
    e.EntityCode,
    e.DisplayName AS EntityName,
    e.ExternalKey,
    e.WorkspaceId,
    w.WorkspaceCode,
    e.DatasetId,
    d.DatasetCode,
    e.VersionNumber,
    e.IsActive,
    e.CreatedUtc,
    e.ModifiedUtc,
    (SELECT COUNT(*) FROM lineage.LineageRelationship r WHERE r.TargetEntityId = e.EntityId AND r.IsActive = 1) AS UpstreamEdgeCount,
    (SELECT COUNT(*) FROM lineage.LineageRelationship r WHERE r.SourceEntityId = e.EntityId AND r.IsActive = 1) AS DownstreamEdgeCount
FROM lineage.LineageEntity e
INNER JOIN lineage.EntityType et ON et.EntityTypeCode = e.EntityTypeCode
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = e.WorkspaceId
LEFT JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId;
GO

PRINT 'Lineage views created.';
GO
