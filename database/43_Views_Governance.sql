-- ============================================================
-- 43_Views_Governance.sql
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_DatasetGovernance
AS
SELECT
    d.DatasetId,
    d.DatasetCode,
    d.DisplayName AS DatasetName,
    d.IsActive,
    COALESCE(g.WorkspaceId, d.WorkspaceId) AS WorkspaceId,
    w.WorkspaceCode,
    COALESCE(g.ClassificationCode, N'Internal') AS ClassificationCode,
    c.DisplayName AS ClassificationName,
    c.SensitivityRank,
    COALESCE(g.GovernanceStatusCode, N'Draft') AS GovernanceStatusCode,
    COALESCE(g.CertificationStatusCode, N'NotCertified') AS CertificationStatusCode,
    ou.UserName AS OwnerUserName,
    ou.DisplayName AS OwnerDisplayName,
    su.UserName AS StewardUserName,
    su.DisplayName AS StewardDisplayName,
    g.ReviewDueUtc,
    g.CertifiedUtc,
    g.CertificationExpiryUtc,
    g.Notes,
    g.CreatedUtc AS GovernanceCreatedUtc,
    g.ModifiedUtc AS GovernanceModifiedUtc
FROM ingest.Dataset d
LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = COALESCE(g.WorkspaceId, d.WorkspaceId)
LEFT JOIN gov.Classification c ON c.ClassificationCode = COALESCE(g.ClassificationCode, N'Internal')
LEFT JOIN gov.AppUser ou ON ou.UserId = g.OwnerUserId
LEFT JOIN gov.AppUser su ON su.UserId = g.StewardUserId;
GO

CREATE OR ALTER VIEW rpt.vw_PendingAccessRequests
AS
SELECT
    ar.AccessRequestId,
    d.DatasetCode,
    d.DisplayName AS DatasetName,
    u.UserName AS RequestingUserName,
    u.DisplayName AS RequestingDisplayName,
    ar.AccessLevelCode,
    ar.BusinessJustification,
    ar.Status,
    ar.RequestedUtc,
    ar.WorkspaceId,
    w.WorkspaceCode
FROM gov.AccessRequest ar
INNER JOIN ingest.Dataset d ON d.DatasetId = ar.DatasetId
INNER JOIN gov.AppUser u ON u.UserId = ar.RequestingUserId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = ar.WorkspaceId
WHERE ar.Status = N'Pending';
GO

CREATE OR ALTER VIEW rpt.vw_ActiveDatasetGrants
AS
SELECT
    g.GrantId,
    d.DatasetCode,
    u.UserName,
    g.AccessLevelCode,
    g.GrantedUtc,
    g.ExpiresUtc,
    gb.UserName AS GrantedByUserName,
    g.AccessRequestId
FROM gov.DatasetAccessGrant g
INNER JOIN ingest.Dataset d ON d.DatasetId = g.DatasetId
INNER JOIN gov.AppUser u ON u.UserId = g.UserId
LEFT JOIN gov.AppUser gb ON gb.UserId = g.GrantedByUserId
WHERE g.IsActive = 1
  AND (g.ExpiresUtc IS NULL OR g.ExpiresUtc > SYSUTCDATETIME());
GO

PRINT 'Governance views created.';
GO
