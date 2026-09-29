-- ============================================================
-- 49_Views_Sharing.sql
-- Reporting / authorization views for sharing and exports.
-- Core read models (share.vw_DatasetShareEffective,
-- share.vw_DatasetShareDetail, share.vw_ExportRequestDetail)
-- live in 48 because procedures depend on them.
-- ============================================================
USE EDIP;
GO

CREATE OR ALTER VIEW rpt.vw_ActiveDatasetShares
AS
SELECT ShareId, DatasetCode, DatasetName, WorkspaceCode, RecipientUserName, RecipientDisplayName,
       AccessLevelCode, SharedByUserName, SharedUtc, ExpiresUtc,
       CASE WHEN ExpiresUtc IS NULL THEN NULL
            ELSE DATEDIFF(HOUR, SYSUTCDATETIME(), ExpiresUtc) END AS HoursUntilExpiry
FROM share.vw_DatasetShareDetail
WHERE EffectiveStatus = N'Active';
GO

CREATE OR ALTER VIEW rpt.vw_DatasetShareStatus
AS
SELECT ShareId, DatasetCode, WorkspaceCode, RecipientUserName, AccessLevelCode,
       SharedByUserName, SharedUtc, ExpiresUtc, PersistedStatus, EffectiveStatus,
       CAST(CASE WHEN EffectiveStatus <> PersistedStatus THEN 1 ELSE 0 END AS BIT) AS PendingExpiryMark,
       RevokedByUserName, RevokedUtc, RevokeReason
FROM share.vw_DatasetShareDetail;
GO

CREATE OR ALTER VIEW rpt.vw_PendingExportQueue
AS
SELECT ExportRequestId, DatasetCode, RequestedByUserName, WorkspaceCode, FormatCode, Status,
       RequestedUtc, StartedUtc, AttemptCount,
       DATEDIFF(MINUTE, RequestedUtc, SYSUTCDATETIME()) AS MinutesInQueue
FROM share.vw_ExportRequestDetail
WHERE Status IN (N'Pending', N'Processing');
GO

CREATE OR ALTER VIEW rpt.vw_FailedExports
AS
SELECT ExportRequestId, DatasetCode, RequestedByUserName, WorkspaceCode, FormatCode,
       RequestedUtc, StartedUtc, CompletedUtc, AttemptCount, FailureReason
FROM share.vw_ExportRequestDetail
WHERE Status = N'Failed';
GO

CREATE OR ALTER VIEW rpt.vw_ExportDailyActivity
AS
SELECT CAST(r.RequestedUtc AS DATE) AS ActivityDate, r.WorkspaceId, r.FormatCode,
       COUNT_BIG(*) AS Requested,
       SUM(CASE WHEN r.Status = N'Completed' THEN 1 ELSE 0 END) AS Completed,
       SUM(CASE WHEN r.Status = N'Failed' THEN 1 ELSE 0 END) AS Failed,
       SUM(CASE WHEN r.Status = N'Cancelled' THEN 1 ELSE 0 END) AS Cancelled,
       SUM(CASE WHEN r.Status IN (N'Pending', N'Processing') THEN 1 ELSE 0 END) AS InFlight,
       SUM(CASE WHEN r.Status = N'Completed' THEN ISNULL(r.RecordCount, 0) ELSE 0 END) AS RecordsExported
FROM share.ExportRequest r
GROUP BY CAST(r.RequestedUtc AS DATE), r.WorkspaceId, r.FormatCode;
GO

-- Export authorization matrix for active workspace members and datasets in their workspace
-- (plus platform admins). Intended for admin review / reporting, not per-request checks.
CREATE OR ALTER VIEW rpt.vw_UserDatasetExportAccess
AS
SELECT a.DatasetCode, a.UserName, a.WorkspaceId, a.ClassificationCode, a.GovernanceStatusCode,
       a.CertificationStatusCode, a.RequiredAccessLevel, a.EffectiveAccessLevel,
       a.IsAllowed, a.DecisionCode, a.AccessSource, a.WorkspaceRole,
       a.GrantLevel, a.GrantStatus, a.ShareLevel, a.ShareStatus, a.ShareExpiresUtc
FROM ingest.Dataset d
INNER JOIN gov.AppUser u
        ON u.IsActive = 1
       AND (u.IsPlatformAdmin = 1
            OR EXISTS (SELECT 1 FROM gov.WorkspaceMember m
                       WHERE m.UserId = u.UserId AND m.WorkspaceId = d.WorkspaceId AND m.IsActive = 1)
            OR EXISTS (SELECT 1 FROM share.DatasetShare s
                       WHERE s.DatasetId = d.DatasetId AND s.RecipientUserId = u.UserId))
CROSS APPLY share.fn_EvaluateExportAccess(d.DatasetId, u.UserId) a
WHERE d.IsActive = 1;
GO

PRINT 'Sharing/export views created.';
GO
