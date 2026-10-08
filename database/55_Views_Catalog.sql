-- ============================================================
-- 55_Views_Catalog.sql
-- Platform-wide catalog views for administration / internal
-- reporting. User-facing discovery must go through the
-- access-aware procedures (cat.usp_SearchCatalog etc.).
-- ============================================================
USE EDIP;
GO

-- One catalog row per dataset (no access filtering)
CREATE OR ALTER VIEW cat.vw_DatasetCatalog
AS
SELECT d.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName, d.Description,
       COALESCE(g.WorkspaceId, d.WorkspaceId) AS WorkspaceId, w.WorkspaceCode, w.DisplayName AS WorkspaceName,
       d.Category,
       ou.UserName AS OwnerUserName, COALESCE(ou.DisplayName, d.OwnerName) AS OwnerDisplayName,
       su.UserName AS StewardUserName, su.DisplayName AS StewardDisplayName,
       src.TypeCode AS SourceTypeCode,
       COALESCE(g.ClassificationCode, N'Internal') AS ClassificationCode,
       COALESCE(g.GovernanceStatusCode, N'Draft') AS GovernanceStatusCode,
       d.DatasetStatus, d.IsActive,
       COALESCE(g.CertificationStatusCode, N'NotCertified') AS CertificationStatusCode,
       ver.VersionNumber AS CurrentVersion,
       d.CreatedUtc, d.ModifiedUtc AS UpdatedUtc,
       dp.LatestOverallScore AS QualityScore,
       li.LastImportUtc,
       tg.Tags
FROM ingest.Dataset d
LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
LEFT JOIN gov.AppUser ou ON ou.UserId = g.OwnerUserId
LEFT JOIN gov.AppUser su ON su.UserId = g.StewardUserId
LEFT JOIN profile.DatasetProfile dp ON dp.DatasetId = d.DatasetId
OUTER APPLY (SELECT TOP (1) v.VersionNumber FROM lineage.DatasetVersion v
             WHERE v.DatasetId = d.DatasetId ORDER BY v.VersionNumber DESC) ver
OUTER APPLY (SELECT TOP (1) b.ImportUtc AS LastImportUtc FROM ingest.ImportBatch b
             WHERE b.DatasetId = d.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')
             ORDER BY b.ImportUtc DESC) li
OUTER APPLY (SELECT TOP (1) st.TypeCode FROM ingest.ImportBatch b
             INNER JOIN reg.DataSource ds ON ds.DataSourceId = b.DataSourceId
             INNER JOIN reg.DataSourceType st ON st.DataSourceTypeId = ds.DataSourceTypeId
             WHERE b.DatasetId = d.DatasetId AND b.DataSourceId IS NOT NULL
             ORDER BY b.ImportUtc DESC) src
OUTER APPLY (SELECT STRING_AGG(t.TagName, N',') WITHIN GROUP (ORDER BY t.TagName) AS Tags
             FROM cat.DatasetTag dt INNER JOIN cat.Tag t ON t.TagId = dt.TagId AND t.IsActive = 1
             WHERE dt.DatasetId = d.DatasetId) tg;
GO

-- Tag usage across the whole platform
CREATE OR ALTER VIEW cat.vw_TagUsage
AS
SELECT t.TagId, t.TagName, t.Description, t.IsActive, t.CreatedUtc,
       COUNT(dt.DatasetId) AS DatasetCount,
       MAX(dt.TaggedUtc) AS LastTaggedUtc
FROM cat.Tag t
LEFT JOIN cat.DatasetTag dt ON dt.TagId = t.TagId
GROUP BY t.TagId, t.TagName, t.Description, t.IsActive, t.CreatedUtc;
GO

-- Discovery matrix: which active user can discover which dataset and how
-- (admin review of cat.fn_DatasetDiscovery decisions)
CREATE OR ALTER VIEW rpt.vw_UserDatasetDiscovery
AS
SELECT u.UserName, d.DatasetCode, d.DisplayName AS DatasetName, w.WorkspaceCode,
       a.ClassificationCode, a.GovernanceStatusCode, a.WorkspaceRole,
       a.AccessSource, a.EffectiveAccessLevel, a.CanReadData, a.CanRequestAccess
FROM gov.AppUser u
CROSS APPLY cat.fn_DatasetDiscovery(u.UserId, u.IsPlatformAdmin, 0) a
INNER JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = a.WorkspaceId
WHERE u.IsActive = 1;
GO

PRINT 'Catalog views ready.';
GO
