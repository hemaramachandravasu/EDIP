-- ============================================================
-- 48_Procs_Sharing.sql
-- Dataset sharing, export authorization, export lifecycle,
-- safe paged export data retrieval, history, reporting, jobs.
--
-- Soft failures are returned through @StatusCode/@StatusMessage
-- OUTPUT parameters (same contract as the governance module);
-- result sets are only returned on success.
-- Audit events are written to gov.GovernanceAuditEvent via
-- gov.usp_WriteAudit (ShareId / ExportRequestId in DetailsJson).
-- ============================================================
USE EDIP;
GO

-- ============================================================
-- Core read models used by procs (views in 49 build on these)
-- ============================================================

-- Effective share status: an Active share past ExpiresUtc is reported
-- as Expired at read time, independent of the expiry job.
CREATE OR ALTER VIEW share.vw_DatasetShareEffective
AS
SELECT s.ShareId, s.DatasetId, s.WorkspaceId, s.RecipientUserId, s.AccessLevelCode,
       s.SharedByUserId, s.SharedUtc, s.ExpiresUtc,
       s.Status AS PersistedStatus,
       CAST(CASE WHEN s.Status = N'Active' AND s.ExpiresUtc IS NOT NULL AND s.ExpiresUtc <= SYSUTCDATETIME()
                 THEN N'Expired' ELSE s.Status END AS NVARCHAR(16)) AS EffectiveStatus,
       s.RevokedByUserId, s.RevokedUtc, s.RevokeReason, s.Notes, s.ModifiedUtc
FROM share.DatasetShare s;
GO

CREATE OR ALTER VIEW share.vw_DatasetShareDetail
AS
SELECT e.ShareId, e.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName,
       e.WorkspaceId, w.WorkspaceCode,
       e.RecipientUserId, ru.UserName AS RecipientUserName, ru.DisplayName AS RecipientDisplayName,
       e.AccessLevelCode,
       e.SharedByUserId, sb.UserName AS SharedByUserName,
       e.SharedUtc, e.ExpiresUtc, e.PersistedStatus, e.EffectiveStatus,
       rv.UserName AS RevokedByUserName, e.RevokedUtc, e.RevokeReason, e.Notes, e.ModifiedUtc
FROM share.vw_DatasetShareEffective e
INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
INNER JOIN gov.AppUser ru ON ru.UserId = e.RecipientUserId
INNER JOIN gov.AppUser sb ON sb.UserId = e.SharedByUserId
LEFT JOIN gov.AppUser rv ON rv.UserId = e.RevokedByUserId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = e.WorkspaceId;
GO

CREATE OR ALTER VIEW share.vw_ExportRequestDetail
AS
SELECT r.ExportRequestId, r.DatasetId, d.DatasetCode, d.DisplayName AS DatasetName,
       r.DatasetVersionId, v.VersionNumber AS DatasetVersionNumber,
       r.RequestedByUserId, u.UserName AS RequestedByUserName,
       r.WorkspaceId, w.WorkspaceCode,
       r.FormatCode, r.Status, r.AccessSource,
       r.SelectedColumnCount, r.FilterCount,
       r.RequestedUtc, r.StartedUtc, r.CompletedUtc,
       CASE WHEN r.StartedUtc IS NOT NULL AND r.CompletedUtc IS NOT NULL
            THEN DATEDIFF(SECOND, r.StartedUtc, r.CompletedUtc) END AS DurationSeconds,
       r.RecordCount, r.FileSizeBytes, r.FileReference, r.FailureReason, r.AttemptCount, r.ModifiedUtc
FROM share.ExportRequest r
INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
INNER JOIN gov.AppUser u ON u.UserId = r.RequestedByUserId
LEFT JOIN lineage.DatasetVersion v ON v.DatasetVersionId = r.DatasetVersionId
LEFT JOIN analytics.Workspace w ON w.WorkspaceId = r.WorkspaceId;
GO

-- ============================================================
-- Export authorization (inline TVF — usable from procs and views)
-- Combines: dataset/user state, governance status, classification
-- export policy, certification, workspace membership + RBAC role,
-- dataset ownership/stewardship, DatasetAccessGrant, DatasetShare.
-- ============================================================
CREATE OR ALTER FUNCTION share.fn_EvaluateExportAccess
(
    @DatasetId UNIQUEIDENTIFIER,
    @UserId    UNIQUEIDENTIFIER
)
RETURNS TABLE
AS
RETURN
WITH ctx AS (
    SELECT d.DatasetId, d.DatasetCode, d.IsActive AS DatasetIsActive,
           COALESCE(g.WorkspaceId, d.WorkspaceId) AS WorkspaceId,
           COALESCE(g.ClassificationCode, N'Internal') AS ClassificationCode,
           COALESCE(g.GovernanceStatusCode, N'Draft') AS GovernanceStatusCode,
           COALESCE(g.CertificationStatusCode, N'NotCertified') AS CertificationStatusCode,
           CAST(CASE WHEN g.OwnerUserId = u.UserId THEN 1 ELSE 0 END AS BIT) AS IsOwner,
           CAST(CASE WHEN g.StewardUserId = u.UserId THEN 1 ELSE 0 END AS BIT) AS IsSteward,
           u.UserId, u.UserName, u.IsActive AS UserIsActive, u.IsPlatformAdmin
    FROM ingest.Dataset d
    INNER JOIN gov.AppUser u ON u.UserId = @UserId
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    WHERE d.DatasetId = @DatasetId
),
parts AS (
    SELECT c.*,
           COALESCE(p.MinAccessLevelCode, N'Admin') AS RequiredAccessLevel,
           CAST(COALESCE(p.RequireCertified, 1) AS BIT) AS RequireCertified,
           CAST(COALESCE(p.AllowWorkspaceRoleExport, 0) AS BIT) AS AllowWorkspaceRoleExport,
           CAST(ISNULL(rl.RankOrder, 3) AS INT) AS RequiredRank,
           CAST(ISNULL(cl.SensitivityRank, 2) AS INT) AS SensitivityRank,
           m.RoleCode AS WorkspaceRole,
           gr.GrantLevel, CAST(ISNULL(gr.GrantRank, 0) AS INT) AS GrantRank,
           COALESCE(gs.GrantStatus, N'None') AS GrantStatus,
           sh.ShareId AS ActiveShareId, sh.ShareLevel, CAST(ISNULL(sh.ShareRank, 0) AS INT) AS ShareRank,
           COALESCE(ss.ShareStatus, N'None') AS ShareStatus, ss.ShareExpiresUtc
    FROM ctx c
    LEFT JOIN share.ExportPolicy p ON p.ClassificationCode = c.ClassificationCode
    LEFT JOIN gov.AccessLevel rl ON rl.AccessLevelCode = COALESCE(p.MinAccessLevelCode, N'Admin')
    LEFT JOIN gov.Classification cl ON cl.ClassificationCode = c.ClassificationCode
    LEFT JOIN gov.WorkspaceMember m
           ON m.WorkspaceId = c.WorkspaceId AND m.UserId = c.UserId AND m.IsActive = 1
    OUTER APPLY (
        SELECT TOP (1) ag.AccessLevelCode AS GrantLevel, al.RankOrder AS GrantRank
        FROM gov.DatasetAccessGrant ag
        INNER JOIN gov.AccessLevel al ON al.AccessLevelCode = ag.AccessLevelCode
        WHERE ag.DatasetId = c.DatasetId AND ag.UserId = c.UserId AND ag.IsActive = 1
          AND (ag.ExpiresUtc IS NULL OR ag.ExpiresUtc > SYSUTCDATETIME())
        ORDER BY al.RankOrder DESC
    ) gr
    OUTER APPLY (
        SELECT TOP (1)
               CASE WHEN ag.IsActive = 1 AND (ag.ExpiresUtc IS NULL OR ag.ExpiresUtc > SYSUTCDATETIME()) THEN N'Active'
                    WHEN ag.IsActive = 1 THEN N'Expired'
                    ELSE N'Revoked' END AS GrantStatus
        FROM gov.DatasetAccessGrant ag
        WHERE ag.DatasetId = c.DatasetId AND ag.UserId = c.UserId
        ORDER BY CASE WHEN ag.IsActive = 1 AND (ag.ExpiresUtc IS NULL OR ag.ExpiresUtc > SYSUTCDATETIME()) THEN 0 ELSE 1 END,
                 ag.GrantedUtc DESC
    ) gs
    OUTER APPLY (
        SELECT TOP (1) es.ShareId, es.AccessLevelCode AS ShareLevel, al.RankOrder AS ShareRank
        FROM share.vw_DatasetShareEffective es
        INNER JOIN gov.AccessLevel al ON al.AccessLevelCode = es.AccessLevelCode
        WHERE es.DatasetId = c.DatasetId AND es.RecipientUserId = c.UserId AND es.EffectiveStatus = N'Active'
    ) sh
    OUTER APPLY (
        SELECT TOP (1) es.EffectiveStatus AS ShareStatus, es.ExpiresUtc AS ShareExpiresUtc
        FROM share.vw_DatasetShareEffective es
        WHERE es.DatasetId = c.DatasetId AND es.RecipientUserId = c.UserId
        ORDER BY CASE es.EffectiveStatus WHEN N'Active' THEN 0 ELSE 1 END, es.SharedUtc DESC
    ) ss
),
scored AS (
    SELECT pt.*,
           CASE WHEN pt.IsPlatformAdmin = 1 OR pt.IsOwner = 1 OR pt.IsSteward = 1 THEN 3 ELSE 0 END AS PrivilegeRank,
           CASE WHEN pt.AllowWorkspaceRoleExport = 0 OR pt.WorkspaceRole IS NULL THEN 0
                WHEN pt.WorkspaceRole IN (N'WorkspaceAdmin', N'DataOwner') THEN 3
                WHEN pt.WorkspaceRole IN (N'DataSteward', N'Analyst') THEN 1
                WHEN pt.WorkspaceRole = N'Viewer' AND pt.SensitivityRank = 1 THEN 1
                ELSE 0 END AS WorkspaceRoleRank
    FROM parts pt
),
eff AS (
    SELECT s.*,
           (SELECT MAX(v) FROM (VALUES (s.PrivilegeRank), (s.GrantRank), (s.ShareRank), (s.WorkspaceRoleRank)) x (v)) AS EffectiveRank
    FROM scored s
),
decided AS (
    SELECT e.*,
           CASE
               WHEN e.DatasetIsActive = 0 THEN N'DatasetInactive'
               WHEN e.UserIsActive = 0 THEN N'UserInactive'
               WHEN e.GovernanceStatusCode = N'Archived' THEN N'DatasetArchived'
               WHEN e.IsPlatformAdmin = 0 AND e.WorkspaceId IS NOT NULL AND e.WorkspaceRole IS NULL THEN N'CrossWorkspaceDenied'
               WHEN e.IsPlatformAdmin = 0 AND e.RequireCertified = 1 AND e.CertificationStatusCode <> N'Certified' THEN N'NotCertified'
               WHEN e.EffectiveRank < e.RequiredRank THEN N'InsufficientAccess'
               ELSE N'Allowed'
           END AS DecisionCode
    FROM eff e
)
SELECT CAST(CASE WHEN x.DecisionCode = N'Allowed' THEN 1 ELSE 0 END AS BIT) AS IsAllowed,
       x.DecisionCode,
       CAST(CASE x.DecisionCode
            WHEN N'Allowed'              THEN N'Export permitted.'
            WHEN N'DatasetInactive'      THEN N'Dataset is inactive.'
            WHEN N'UserInactive'         THEN N'User is inactive.'
            WHEN N'DatasetArchived'      THEN N'Archived datasets cannot be exported.'
            WHEN N'CrossWorkspaceDenied' THEN N'User is not an active member of the dataset workspace.'
            WHEN N'NotCertified'         THEN N'Classification policy requires a certified dataset for export.'
            WHEN N'InsufficientAccess'   THEN N'Effective access level is below the export policy minimum.'
       END AS NVARCHAR(200)) AS Reason,
       x.DatasetId, x.DatasetCode, x.UserId, x.UserName, x.WorkspaceId,
       x.ClassificationCode, x.GovernanceStatusCode, x.CertificationStatusCode,
       x.RequiredAccessLevel, x.RequireCertified,
       lvl.AccessLevelCode AS EffectiveAccessLevel,
       CAST(CASE WHEN x.DecisionCode <> N'Allowed' THEN NULL
                 WHEN x.IsPlatformAdmin = 1 THEN N'PlatformAdmin'
                 WHEN x.IsOwner = 1 THEN N'DatasetOwner'
                 WHEN x.IsSteward = 1 THEN N'DatasetSteward'
                 WHEN x.GrantRank >= x.RequiredRank THEN N'AccessGrant'
                 WHEN x.ShareRank >= x.RequiredRank THEN N'DatasetShare'
                 ELSE N'WorkspaceRole' END AS NVARCHAR(32)) AS AccessSource,
       x.WorkspaceRole,
       CAST(CASE WHEN x.WorkspaceRole IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsWorkspaceMember,
       x.IsPlatformAdmin, x.IsOwner, x.IsSteward,
       x.GrantLevel, x.GrantStatus,
       x.ActiveShareId, x.ShareLevel, x.ShareStatus, x.ShareExpiresUtc
FROM decided x
OUTER APPLY (SELECT TOP (1) al.AccessLevelCode FROM gov.AccessLevel al WHERE al.RankOrder = x.EffectiveRank) lvl;
GO

-- Who may create/modify/revoke shares for a dataset
CREATE OR ALTER FUNCTION share.fn_CanManageDatasetShares
(
    @DatasetId UNIQUEIDENTIFIER,
    @UserId    UNIQUEIDENTIFIER
)
RETURNS TABLE
AS
RETURN
SELECT CAST(CASE WHEN EXISTS (
            SELECT 1 FROM gov.AppUser u
            WHERE u.UserId = @UserId AND u.IsActive = 1 AND u.IsPlatformAdmin = 1)
        OR EXISTS (
            SELECT 1 FROM gov.DatasetGovernance g
            WHERE g.DatasetId = @DatasetId AND (g.OwnerUserId = @UserId OR g.StewardUserId = @UserId))
        OR EXISTS (
            SELECT 1 FROM ingest.Dataset d
            INNER JOIN gov.WorkspaceMember m ON m.WorkspaceId = d.WorkspaceId
            WHERE d.DatasetId = @DatasetId AND m.UserId = @UserId AND m.IsActive = 1
              AND m.RoleCode IN (N'WorkspaceAdmin', N'DataOwner', N'DataSteward'))
       THEN 1 ELSE 0 END AS BIT) AS CanManage;
GO

-- ============================================================
-- Spec parsing helpers (JSON → rows). Values are never parsed
-- into SQL text; only indexes, whitelisted names and fixed
-- operator fragments reach dynamic SQL.
-- ============================================================
CREATE OR ALTER FUNCTION share.fn_ParseExportColumns (@SelectedColumnsJson NVARCHAR(4000))
RETURNS TABLE
AS
RETURN
SELECT CAST(j.[key] AS INT) AS Ord, j.[type] AS ElementType,
       CAST(CASE WHEN j.[type] = 1 THEN j.[value] END AS NVARCHAR(128)) AS ColumnName
FROM OPENJSON(CASE WHEN ISJSON(@SelectedColumnsJson) = 1 AND LEFT(LTRIM(@SelectedColumnsJson), 1) = N'['
                   THEN @SelectedColumnsJson END) j;
GO

CREATE OR ALTER FUNCTION share.fn_ParseExportFilters (@FiltersJson NVARCHAR(MAX))
RETURNS TABLE
AS
RETURN
SELECT CAST(f.[key] AS INT) AS FilterIndex, f.[type] AS ElementType,
       CAST(JSON_VALUE(CASE WHEN f.[type] = 5 THEN f.[value] END, N'$.column') AS NVARCHAR(128)) AS ColumnName,
       LOWER(CAST(JSON_VALUE(CASE WHEN f.[type] = 5 THEN f.[value] END, N'$.op') AS NVARCHAR(16))) AS Op,
       v.[type] AS ValueType,
       CASE WHEN v.[type] = 4 THEN (SELECT COUNT(*) FROM OPENJSON(v.[value])) END AS ValueCount
FROM OPENJSON(CASE WHEN ISJSON(@FiltersJson) = 1 AND LEFT(LTRIM(@FiltersJson), 1) = N'['
                   THEN @FiltersJson END) f
OUTER APPLY (
    SELECT TOP (1) jv.[type], jv.[value]
    FROM OPENJSON(CASE WHEN f.[type] = 5 THEN f.[value] END) jv
    WHERE jv.[key] = N'value'
) v;
GO

CREATE OR ALTER FUNCTION share.fn_ParseExportSort (@SortJson NVARCHAR(1000))
RETURNS TABLE
AS
RETURN
SELECT CAST(s.[key] AS INT) AS SortIndex, s.[type] AS ElementType,
       CAST(JSON_VALUE(CASE WHEN s.[type] = 5 THEN s.[value] END, N'$.column') AS NVARCHAR(128)) AS ColumnName,
       LOWER(COALESCE(CAST(JSON_VALUE(CASE WHEN s.[type] = 5 THEN s.[value] END, N'$.dir') AS NVARCHAR(8)), N'asc')) AS Dir
FROM OPENJSON(CASE WHEN ISJSON(@SortJson) = 1 AND LEFT(LTRIM(@SortJson), 1) = N'['
                   THEN @SortJson END) s;
GO

-- ============================================================
-- Exportable column whitelist
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_SyncExportableColumns
    @DatasetCode   NVARCHAR(64) = NULL,
    @ReturnSummary BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ScopeId UNIQUEIDENTIFIER = NULL;
    IF @DatasetCode IS NOT NULL
    BEGIN
        SELECT @ScopeId = DatasetId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
        IF @ScopeId IS NULL
        BEGIN
            IF @ReturnSummary = 1 SELECT CAST(0 AS INT) AS DatasetsSynced, CAST(0 AS INT) AS ColumnsSynced;
            RETURN;
        END
    END

    ;WITH pk AS (
        SELECT ic.object_id, MIN(ic.column_id) AS column_id
        FROM sys.indexes i
        INNER JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        WHERE i.is_primary_key = 1
        GROUP BY ic.object_id
        HAVING COUNT(*) = 1
    ),
    src AS (
        SELECT d.DatasetId, c.name AS ColumnName, t.name AS DataTypeName,
               CAST(CASE
                   WHEN t.name IN (N'nvarchar', N'nchar')
                       THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length / 2 AS NVARCHAR(10)) END + N')'
                   WHEN t.name IN (N'varchar', N'char', N'varbinary', N'binary')
                       THEN t.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max' ELSE CAST(c.max_length AS NVARCHAR(10)) END + N')'
                   WHEN t.name IN (N'decimal', N'numeric')
                       THEN t.name + N'(' + CAST(c.precision AS NVARCHAR(10)) + N',' + CAST(c.scale AS NVARCHAR(10)) + N')'
                   WHEN t.name IN (N'datetime2', N'time', N'datetimeoffset')
                       THEN t.name + N'(' + CAST(c.scale AS NVARCHAR(10)) + N')'
                   ELSE t.name END AS NVARCHAR(128)) AS SqlTypeDeclaration,
               c.column_id AS OrdinalPosition,
               CAST(CASE WHEN pk.column_id IS NOT NULL THEN 1 ELSE 0 END AS BIT) AS IsKey,
               CAST(CASE WHEN t.name IN (N'xml', N'image', N'text', N'ntext', N'varbinary', N'binary', N'geography',
                                         N'geometry', N'hierarchyid', N'sql_variant', N'timestamp')
                           OR c.max_length = -1 THEN 0 ELSE 1 END AS BIT) AS IsFilterable,
               CAST(CASE WHEN t.name IN (N'image', N'timestamp', N'geography', N'geometry', N'hierarchyid',
                                         N'sql_variant', N'varbinary', N'binary')
                         THEN 0 ELSE 1 END AS BIT) AS IsExportable
        FROM ingest.Dataset d
        CROSS APPLY (SELECT OBJECT_ID(d.TargetTable, N'U') AS ObjId) o
        INNER JOIN sys.columns c ON c.object_id = o.ObjId
        INNER JOIN sys.types t ON t.user_type_id = c.user_type_id
        LEFT JOIN pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        WHERE d.IsActive = 1
          AND o.ObjId IS NOT NULL
          AND (@ScopeId IS NULL OR d.DatasetId = @ScopeId)
    ),
    tgt AS (
        SELECT * FROM share.ExportableColumn
        WHERE @ScopeId IS NULL OR DatasetId = @ScopeId
    )
    MERGE tgt AS t
    USING src AS s
       ON t.DatasetId = s.DatasetId AND t.ColumnName = s.ColumnName
    WHEN MATCHED THEN UPDATE SET
        DataTypeName = s.DataTypeName,
        SqlTypeDeclaration = s.SqlTypeDeclaration,
        OrdinalPosition = s.OrdinalPosition,
        IsKey = s.IsKey,
        IsFilterable = s.IsFilterable,
        IsSortable = s.IsFilterable,
        IsExportable = CASE WHEN s.IsExportable = 0 THEN 0 ELSE t.IsExportable END
    WHEN NOT MATCHED BY TARGET THEN
        INSERT (DatasetId, ColumnName, DataTypeName, SqlTypeDeclaration, OrdinalPosition, IsKey, IsFilterable, IsSortable, IsExportable)
        VALUES (s.DatasetId, s.ColumnName, s.DataTypeName, s.SqlTypeDeclaration, s.OrdinalPosition, s.IsKey,
                s.IsFilterable, s.IsFilterable, s.IsExportable)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    IF @ReturnSummary = 1
        SELECT COUNT(DISTINCT DatasetId) AS DatasetsSynced, COUNT(*) AS ColumnsSynced
        FROM share.ExportableColumn
        WHERE @ScopeId IS NULL OR DatasetId = @ScopeId;
END
GO

CREATE OR ALTER PROCEDURE share.usp_GetExportableColumns
    @DatasetCode NVARCHAR(64)
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DatasetCode, e.ColumnName, e.DataTypeName, e.SqlTypeDeclaration, e.OrdinalPosition,
           e.IsKey, e.IsFilterable, e.IsSortable, e.IsExportable
    FROM share.ExportableColumn e
    INNER JOIN ingest.Dataset d ON d.DatasetId = e.DatasetId
    WHERE d.DatasetCode = @DatasetCode
    ORDER BY e.OrdinalPosition;
END
GO

-- ============================================================
-- Authorization entry points
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_EvaluateExportAccess
    @DatasetCode NVARCHAR(64),
    @UserName    NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @UserId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
    SELECT @UserId = UserId FROM gov.AppUser WHERE UserName = @UserName;

    IF @DatasetId IS NULL OR @UserId IS NULL
    BEGIN
        SELECT CAST(0 AS BIT) AS IsAllowed,
               CASE WHEN @DatasetId IS NULL THEN N'InvalidDataset' ELSE N'InvalidUser' END AS DecisionCode,
               N'Dataset or user not found.' AS Reason,
               @DatasetId AS DatasetId, @DatasetCode AS DatasetCode, @UserId AS UserId, @UserName AS UserName,
               CAST(NULL AS UNIQUEIDENTIFIER) AS WorkspaceId, CAST(NULL AS NVARCHAR(32)) AS ClassificationCode,
               CAST(NULL AS NVARCHAR(32)) AS GovernanceStatusCode, CAST(NULL AS NVARCHAR(32)) AS CertificationStatusCode,
               CAST(NULL AS NVARCHAR(32)) AS RequiredAccessLevel, CAST(0 AS BIT) AS RequireCertified,
               CAST(NULL AS NVARCHAR(32)) AS EffectiveAccessLevel, CAST(NULL AS NVARCHAR(32)) AS AccessSource,
               CAST(NULL AS NVARCHAR(32)) AS WorkspaceRole, CAST(0 AS BIT) AS IsWorkspaceMember,
               CAST(0 AS BIT) AS IsPlatformAdmin, CAST(0 AS BIT) AS IsOwner, CAST(0 AS BIT) AS IsSteward,
               CAST(NULL AS NVARCHAR(32)) AS GrantLevel, N'None' AS GrantStatus,
               CAST(NULL AS UNIQUEIDENTIFIER) AS ActiveShareId, CAST(NULL AS NVARCHAR(32)) AS ShareLevel,
               N'None' AS ShareStatus, CAST(NULL AS DATETIME2(3)) AS ShareExpiresUtc;
        RETURN;
    END

    SELECT * FROM share.fn_EvaluateExportAccess(@DatasetId, @UserId);
END
GO

-- Datasets a user may export (for pickers / pre-filtering in the UI)
CREATE OR ALTER PROCEDURE share.usp_GetExportableDatasetsForUser
    @UserName    NVARCHAR(128),
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @UserId UNIQUEIDENTIFIER = (SELECT UserId FROM gov.AppUser WHERE UserName = @UserName);
    IF @UserId IS NULL RETURN;

    SELECT a.DatasetId, a.DatasetCode, d.DisplayName AS DatasetName, a.WorkspaceId,
           a.ClassificationCode, a.GovernanceStatusCode, a.CertificationStatusCode,
           a.RequiredAccessLevel, a.EffectiveAccessLevel, a.AccessSource, a.IsAllowed, a.DecisionCode
    FROM ingest.Dataset d
    CROSS APPLY share.fn_EvaluateExportAccess(d.DatasetId, @UserId) a
    WHERE d.IsActive = 1
      AND (@WorkspaceId IS NULL OR a.WorkspaceId = @WorkspaceId)
    ORDER BY a.IsAllowed DESC, a.DatasetCode;
END
GO

-- ============================================================
-- Sharing
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_CreateDatasetShare
    @DatasetCode       NVARCHAR(64),
    @RecipientUserName NVARCHAR(128),
    @AccessLevelCode   NVARCHAR(32),
    @SharedByUserName  NVARCHAR(128),
    @ExpiresUtc        DATETIME2(3) = NULL,
    @Notes             NVARCHAR(1000) = NULL,
    @ShareId           UNIQUEIDENTIFIER = NULL OUTPUT,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ShareId = NULL;
    SET @StatusCode = N'Created';
    SET @StatusMessage = N'Dataset shared.';

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @GovStatus NVARCHAR(32);

    SELECT @DatasetId = d.DatasetId, @WorkspaceId = d.WorkspaceId,
           @GovStatus = COALESCE(g.GovernanceStatusCode, N'Draft')
    FROM ingest.Dataset d
    LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
    WHERE d.DatasetCode = @DatasetCode AND d.IsActive = 1;

    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'InvalidDataset'; SET @StatusMessage = N'Dataset not found or inactive.'; RETURN; END
    IF @GovStatus = N'Archived'
    BEGIN SET @StatusCode = N'DatasetArchived'; SET @StatusMessage = N'Archived datasets cannot be shared.'; RETURN; END

    DECLARE @RecipientId UNIQUEIDENTIFIER, @RecipientIsAdmin BIT, @SharerId UNIQUEIDENTIFIER;
    SELECT @RecipientId = UserId, @RecipientIsAdmin = IsPlatformAdmin
    FROM gov.AppUser WHERE UserName = @RecipientUserName AND IsActive = 1;
    SELECT @SharerId = UserId FROM gov.AppUser WHERE UserName = @SharedByUserName AND IsActive = 1;

    IF @RecipientId IS NULL
    BEGIN SET @StatusCode = N'InvalidRecipient'; SET @StatusMessage = N'Recipient user not found or inactive.'; RETURN; END
    IF @SharerId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Sharing user not found or inactive.'; RETURN; END
    IF @RecipientId = @SharerId
    BEGIN SET @StatusCode = N'SelfShare'; SET @StatusMessage = N'A dataset cannot be shared with yourself.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM gov.AccessLevel WHERE AccessLevelCode = @AccessLevelCode AND IsActive = 1)
    BEGIN SET @StatusCode = N'InvalidAccessLevel'; SET @StatusMessage = N'Invalid access level.'; RETURN; END

    IF @ExpiresUtc IS NOT NULL AND @ExpiresUtc <= @Now
    BEGIN SET @StatusCode = N'InvalidExpiry'; SET @StatusMessage = N'Expiry must be in the future.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM share.fn_CanManageDatasetShares(@DatasetId, @SharerId) WHERE CanManage = 1)
    BEGIN
        SET @StatusCode = N'Unauthorized';
        SET @StatusMessage = N'Only platform admins, dataset owners/stewards, or workspace admins/owners/stewards can share this dataset.';
        RETURN;
    END

    -- Same-workspace rule: recipient must be an active member of the dataset workspace
    IF @WorkspaceId IS NOT NULL AND @RecipientIsAdmin = 0
       AND NOT EXISTS (
            SELECT 1 FROM gov.WorkspaceMember m
            WHERE m.WorkspaceId = @WorkspaceId AND m.UserId = @RecipientId AND m.IsActive = 1)
    BEGIN
        SET @StatusCode = N'CrossWorkspaceDenied';
        SET @StatusMessage = N'Recipient is not a member of the dataset workspace.';
        RETURN;
    END

    DECLARE @Lapsed TABLE (ShareId UNIQUEIDENTIFIER, AccessLevelCode NVARCHAR(32), ExpiresUtc DATETIME2(3));

    BEGIN TRANSACTION;

    -- A lapsed Active share would block the filtered unique index; persist its expiry first
    UPDATE share.DatasetShare
    SET Status = N'Expired', ModifiedUtc = @Now
    OUTPUT inserted.ShareId, inserted.AccessLevelCode, inserted.ExpiresUtc INTO @Lapsed
    WHERE DatasetId = @DatasetId AND RecipientUserId = @RecipientId
      AND Status = N'Active' AND ExpiresUtc IS NOT NULL AND ExpiresUtc <= @Now;

    INSERT INTO share.DatasetShareHistory
        (ShareId, DatasetId, RecipientUserId, Action, PreviousStatus, NewStatus,
         PreviousAccessLevel, NewAccessLevel, PreviousExpiresUtc, NewExpiresUtc, ActorUserId, Comments)
    SELECT l.ShareId, @DatasetId, @RecipientId, N'Expired', N'Active', N'Expired',
           l.AccessLevelCode, l.AccessLevelCode, l.ExpiresUtc, l.ExpiresUtc, NULL, N'Expired before re-share'
    FROM @Lapsed l;

    DECLARE @Existing UNIQUEIDENTIFIER;
    SELECT @Existing = ShareId
    FROM share.DatasetShare WITH (UPDLOCK, HOLDLOCK)
    WHERE DatasetId = @DatasetId AND RecipientUserId = @RecipientId AND Status = N'Active';

    IF @Existing IS NOT NULL
    BEGIN
        ROLLBACK TRANSACTION;
        SET @ShareId = @Existing;
        SET @StatusCode = N'DuplicateActive';
        SET @StatusMessage = N'An active share already exists for this dataset and recipient; update it instead.';
        RETURN;
    END

    SET @ShareId = NEWID();
    INSERT INTO share.DatasetShare
        (ShareId, DatasetId, WorkspaceId, RecipientUserId, AccessLevelCode, SharedByUserId, SharedUtc, ExpiresUtc, Status, Notes, ModifiedUtc)
    VALUES
        (@ShareId, @DatasetId, @WorkspaceId, @RecipientId, @AccessLevelCode, @SharerId, @Now, @ExpiresUtc, N'Active', @Notes, @Now);

    INSERT INTO share.DatasetShareHistory
        (ShareId, DatasetId, RecipientUserId, Action, PreviousStatus, NewStatus,
         PreviousAccessLevel, NewAccessLevel, PreviousExpiresUtc, NewExpiresUtc, ActorUserId, ActionUtc, Comments)
    VALUES
        (@ShareId, @DatasetId, @RecipientId, N'Created', NULL, N'Active',
         NULL, @AccessLevelCode, NULL, @ExpiresUtc, @SharerId, @Now, @Notes);

    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ShareId AS shareId, @AccessLevelCode AS accessLevel, @ExpiresUtc AS expiresUtc
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = N'ShareCreated', @DatasetId = @DatasetId,
        @UserId = @RecipientId, @ActorUserId = @SharerId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    COMMIT TRANSACTION;

    SELECT * FROM share.vw_DatasetShareDetail WHERE ShareId = @ShareId;
END
GO

CREATE OR ALTER PROCEDURE share.usp_UpdateDatasetShare
    @ShareId          UNIQUEIDENTIFIER,
    @ActorUserName    NVARCHAR(128),
    @AccessLevelCode  NVARCHAR(32) = NULL,     -- NULL = keep current
    @ExpiresUtc       DATETIME2(3) = NULL,     -- NULL = keep current (unless @ClearExpiry = 1)
    @ClearExpiry      BIT = 0,
    @Comments         NVARCHAR(1000) = NULL,
    @StatusCode       NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage    NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Updated';
    SET @StatusMessage = N'Share updated.';

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @RecipientId UNIQUEIDENTIFIER,
            @CurLevel NVARCHAR(32), @CurExpiry DATETIME2(3), @EffStatus NVARCHAR(16);

    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId, @RecipientId = RecipientUserId,
           @CurLevel = AccessLevelCode, @CurExpiry = ExpiresUtc, @EffStatus = EffectiveStatus
    FROM share.vw_DatasetShareEffective WHERE ShareId = @ShareId;

    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Share not found.'; RETURN; END
    IF @EffStatus = N'Revoked'
    BEGIN SET @StatusCode = N'ShareRevoked'; SET @StatusMessage = N'Revoked shares cannot be modified.'; RETURN; END
    IF @EffStatus = N'Expired'
    BEGIN SET @StatusCode = N'ShareExpired'; SET @StatusMessage = N'Expired shares cannot be modified; create a new share.'; RETURN; END

    DECLARE @ActorId UNIQUEIDENTIFIER =
        (SELECT UserId FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1);
    IF @ActorId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Actor not found or inactive.'; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM share.fn_CanManageDatasetShares(@DatasetId, @ActorId) WHERE CanManage = 1)
    BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Actor cannot manage shares for this dataset.'; RETURN; END

    IF @AccessLevelCode IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM gov.AccessLevel WHERE AccessLevelCode = @AccessLevelCode AND IsActive = 1)
    BEGIN SET @StatusCode = N'InvalidAccessLevel'; SET @StatusMessage = N'Invalid access level.'; RETURN; END

    IF @ExpiresUtc IS NOT NULL AND @ExpiresUtc <= @Now
    BEGIN SET @StatusCode = N'InvalidExpiry'; SET @StatusMessage = N'Expiry must be in the future.'; RETURN; END

    DECLARE @NewLevel NVARCHAR(32) = COALESCE(@AccessLevelCode, @CurLevel);
    DECLARE @NewExpiry DATETIME2(3) = CASE WHEN @ClearExpiry = 1 THEN NULL ELSE COALESCE(@ExpiresUtc, @CurExpiry) END;

    IF @NewLevel = @CurLevel
       AND ((@NewExpiry IS NULL AND @CurExpiry IS NULL) OR @NewExpiry = @CurExpiry)
    BEGIN SET @StatusCode = N'NoChange'; SET @StatusMessage = N'Share already has the requested settings.'; RETURN; END

    BEGIN TRANSACTION;

    UPDATE share.DatasetShare
    SET AccessLevelCode = @NewLevel, ExpiresUtc = @NewExpiry, ModifiedUtc = @Now
    WHERE ShareId = @ShareId AND Status = N'Active'
      AND (ExpiresUtc IS NULL OR ExpiresUtc > @Now);

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;
        SET @StatusCode = N'ConcurrencyConflict';
        SET @StatusMessage = N'Share changed state during update; reload and retry.';
        RETURN;
    END

    INSERT INTO share.DatasetShareHistory
        (ShareId, DatasetId, RecipientUserId, Action, PreviousStatus, NewStatus,
         PreviousAccessLevel, NewAccessLevel, PreviousExpiresUtc, NewExpiresUtc, ActorUserId, ActionUtc, Comments)
    VALUES
        (@ShareId, @DatasetId, @RecipientId, N'Updated', N'Active', N'Active',
         @CurLevel, @NewLevel, @CurExpiry, @NewExpiry, @ActorId, @Now, @Comments);

    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ShareId AS shareId, @CurLevel AS previousAccessLevel, @NewLevel AS accessLevel,
                @CurExpiry AS previousExpiresUtc, @NewExpiry AS expiresUtc
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = N'ShareModified', @DatasetId = @DatasetId,
        @UserId = @RecipientId, @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    COMMIT TRANSACTION;

    SELECT * FROM share.vw_DatasetShareDetail WHERE ShareId = @ShareId;
END
GO

CREATE OR ALTER PROCEDURE share.usp_RevokeDatasetShare
    @ShareId        UNIQUEIDENTIFIER,
    @ActorUserName  NVARCHAR(128),
    @RevokeReason   NVARCHAR(1000) = NULL,
    @StatusCode     NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage  NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Revoked';
    SET @StatusMessage = N'Share revoked.';

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER, @RecipientId UNIQUEIDENTIFIER,
            @Level NVARCHAR(32), @Expiry DATETIME2(3), @EffStatus NVARCHAR(16), @Persisted NVARCHAR(16);

    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId, @RecipientId = RecipientUserId,
           @Level = AccessLevelCode, @Expiry = ExpiresUtc, @EffStatus = EffectiveStatus, @Persisted = PersistedStatus
    FROM share.vw_DatasetShareEffective WHERE ShareId = @ShareId;

    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Share not found.'; RETURN; END
    IF @EffStatus = N'Revoked'
    BEGIN SET @StatusCode = N'AlreadyRevoked'; SET @StatusMessage = N'Share is already revoked.'; RETURN; END
    IF @EffStatus = N'Expired'
    BEGIN SET @StatusCode = N'AlreadyExpired'; SET @StatusMessage = N'Share has already expired.'; RETURN; END

    DECLARE @ActorId UNIQUEIDENTIFIER =
        (SELECT UserId FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1);
    IF @ActorId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Actor not found or inactive.'; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM share.fn_CanManageDatasetShares(@DatasetId, @ActorId) WHERE CanManage = 1)
    BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Actor cannot manage shares for this dataset.'; RETURN; END

    BEGIN TRANSACTION;

    UPDATE share.DatasetShare
    SET Status = N'Revoked', RevokedByUserId = @ActorId, RevokedUtc = @Now,
        RevokeReason = @RevokeReason, ModifiedUtc = @Now
    WHERE ShareId = @ShareId AND Status = N'Active';

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;
        SET @StatusCode = N'ConcurrencyConflict';
        SET @StatusMessage = N'Share changed state during revoke; reload and retry.';
        RETURN;
    END

    INSERT INTO share.DatasetShareHistory
        (ShareId, DatasetId, RecipientUserId, Action, PreviousStatus, NewStatus,
         PreviousAccessLevel, NewAccessLevel, PreviousExpiresUtc, NewExpiresUtc, ActorUserId, ActionUtc, Comments)
    VALUES
        (@ShareId, @DatasetId, @RecipientId, N'Revoked', @Persisted, N'Revoked',
         @Level, @Level, @Expiry, @Expiry, @ActorId, @Now, @RevokeReason);

    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ShareId AS shareId, @Level AS accessLevel, @RevokeReason AS reason
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = N'ShareRevoked', @DatasetId = @DatasetId,
        @UserId = @RecipientId, @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    COMMIT TRANSACTION;

    SELECT * FROM share.vw_DatasetShareDetail WHERE ShareId = @ShareId;
END
GO

CREATE OR ALTER PROCEDURE share.usp_GetShare
    @ShareId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM share.vw_DatasetShareDetail WHERE ShareId = @ShareId;
END
GO

CREATE OR ALTER PROCEDURE share.usp_GetActiveShares
    @DatasetCode       NVARCHAR(64) = NULL,
    @RecipientUserName NVARCHAR(128) = NULL,
    @WorkspaceId       UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT *
    FROM share.vw_DatasetShareDetail
    WHERE PersistedStatus = N'Active'
      AND EffectiveStatus = N'Active'
      AND (@DatasetCode IS NULL OR DatasetCode = @DatasetCode)
      AND (@RecipientUserName IS NULL OR RecipientUserName = @RecipientUserName)
      AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
    ORDER BY DatasetCode, RecipientUserName
    OPTION (RECOMPILE);
END
GO

-- Paged share listing with effective-status filter (Active / Expired / Revoked)
CREATE OR ALTER PROCEDURE share.usp_GetShares
    @DatasetCode       NVARCHAR(64) = NULL,
    @RecipientUserName NVARCHAR(128) = NULL,
    @WorkspaceId       UNIQUEIDENTIFIER = NULL,
    @EffectiveStatus   NVARCHAR(16) = NULL,
    @PageNumber        INT = 1,
    @PageSize          INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;

    SELECT *, COUNT(*) OVER () AS TotalCount
    FROM share.vw_DatasetShareDetail
    WHERE (@DatasetCode IS NULL OR DatasetCode = @DatasetCode)
      AND (@RecipientUserName IS NULL OR RecipientUserName = @RecipientUserName)
      AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
      AND (@EffectiveStatus IS NULL OR EffectiveStatus = @EffectiveStatus)
    ORDER BY SharedUtc DESC, ShareId
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);
END
GO

-- Shares whose expiry has passed; IsMarked = 0 means the expiry job has not persisted it yet
CREATE OR ALTER PROCEDURE share.usp_GetExpiredShares
    @WorkspaceId  UNIQUEIDENTIFIER = NULL,
    @OnlyUnmarked BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SELECT *, CAST(CASE WHEN PersistedStatus = N'Expired' THEN 1 ELSE 0 END AS BIT) AS IsMarked
    FROM share.vw_DatasetShareDetail
    WHERE EffectiveStatus = N'Expired'
      AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
      AND (@OnlyUnmarked = 0 OR PersistedStatus = N'Active')
    ORDER BY ExpiresUtc DESC;
END
GO

CREATE OR ALTER PROCEDURE share.usp_GetShareHistory
    @ShareId           UNIQUEIDENTIFIER = NULL,
    @DatasetCode       NVARCHAR(64) = NULL,
    @RecipientUserName NVARCHAR(128) = NULL,
    @Take              INT = 100
AS
BEGIN
    SET NOCOUNT ON;
    IF @Take IS NULL OR @Take < 1 SET @Take = 100;
    IF @Take > 1000 SET @Take = 1000;

    SELECT TOP (@Take)
           h.ShareHistoryId, h.ShareId, d.DatasetCode, ru.UserName AS RecipientUserName,
           h.Action, h.PreviousStatus, h.NewStatus, h.PreviousAccessLevel, h.NewAccessLevel,
           h.PreviousExpiresUtc, h.NewExpiresUtc, au.UserName AS ActorUserName, h.ActionUtc, h.Comments
    FROM share.DatasetShareHistory h
    INNER JOIN ingest.Dataset d ON d.DatasetId = h.DatasetId
    INNER JOIN gov.AppUser ru ON ru.UserId = h.RecipientUserId
    LEFT JOIN gov.AppUser au ON au.UserId = h.ActorUserId
    WHERE (@ShareId IS NULL OR h.ShareId = @ShareId)
      AND (@DatasetCode IS NULL OR d.DatasetCode = @DatasetCode)
      AND (@RecipientUserName IS NULL OR ru.UserName = @RecipientUserName)
    ORDER BY h.ActionUtc DESC, h.ShareHistoryId DESC
    OPTION (RECOMPILE);
END
GO

-- Scheduled: persist Expired status for lapsed shares (reads never depend on this)
CREATE OR ALTER PROCEDURE share.usp_ExpireDatasetShares
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Expired TABLE (ShareId UNIQUEIDENTIFIER, DatasetId UNIQUEIDENTIFIER, RecipientUserId UNIQUEIDENTIFIER,
                            WorkspaceId UNIQUEIDENTIFIER, AccessLevelCode NVARCHAR(32), ExpiresUtc DATETIME2(3));

    BEGIN TRANSACTION;

    UPDATE share.DatasetShare
    SET Status = N'Expired', ModifiedUtc = @Now
    OUTPUT inserted.ShareId, inserted.DatasetId, inserted.RecipientUserId, inserted.WorkspaceId,
           inserted.AccessLevelCode, inserted.ExpiresUtc
    INTO @Expired
    WHERE Status = N'Active' AND ExpiresUtc IS NOT NULL AND ExpiresUtc <= @Now;

    INSERT INTO share.DatasetShareHistory
        (ShareId, DatasetId, RecipientUserId, Action, PreviousStatus, NewStatus,
         PreviousAccessLevel, NewAccessLevel, PreviousExpiresUtc, NewExpiresUtc, ActorUserId, ActionUtc, Comments)
    SELECT ShareId, DatasetId, RecipientUserId, N'Expired', N'Active', N'Expired',
           AccessLevelCode, AccessLevelCode, ExpiresUtc, ExpiresUtc, NULL, @Now, N'Auto-expired by scheduled job'
    FROM @Expired;

    INSERT INTO gov.GovernanceAuditEvent (EventType, DatasetId, UserId, WorkspaceId, DetailsJson)
    SELECT N'ShareExpired', e.DatasetId, e.RecipientUserId, e.WorkspaceId,
           (SELECT e.ShareId AS shareId, e.ExpiresUtc AS expiresUtc, N'ExpireDatasetShares' AS source
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM @Expired e;

    COMMIT TRANSACTION;

    SELECT COUNT(*) AS ExpiredCount FROM @Expired;
END
GO

-- ============================================================
-- Export spec validation (no result sets)
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_ValidateExportSpec
    @DatasetId           UNIQUEIDENTIFIER,
    @SelectedColumnsJson NVARCHAR(4000) = NULL,
    @FiltersJson         NVARCHAR(MAX) = NULL,
    @SortJson            NVARCHAR(1000) = NULL,
    @SelectedColumnCount INT = NULL OUTPUT,
    @FilterCount         INT = NULL OUTPUT,
    @StatusCode          NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage       NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @StatusCode = N'Valid';
    SET @StatusMessage = N'Export specification is valid.';
    SET @SelectedColumnCount = 0;
    SET @FilterCount = 0;

    IF NOT EXISTS (SELECT 1 FROM share.ExportableColumn WHERE DatasetId = @DatasetId AND IsExportable = 1)
    BEGIN SET @StatusCode = N'NoExportableColumns'; SET @StatusMessage = N'Dataset has no exportable columns (target table missing?).'; RETURN; END

    DECLARE @Bad NVARCHAR(128);

    -- Columns
    IF NULLIF(LTRIM(@SelectedColumnsJson), N'') IS NOT NULL
    BEGIN
        IF ISJSON(@SelectedColumnsJson) = 0 OR LEFT(LTRIM(@SelectedColumnsJson), 1) <> N'['
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'SelectedColumns must be a JSON array of column names.'; RETURN; END
        IF EXISTS (SELECT 1 FROM share.fn_ParseExportColumns(@SelectedColumnsJson) WHERE ElementType <> 1)
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'SelectedColumns must contain only strings.'; RETURN; END
        IF EXISTS (SELECT ColumnName FROM share.fn_ParseExportColumns(@SelectedColumnsJson) GROUP BY ColumnName HAVING COUNT(*) > 1)
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'SelectedColumns contains duplicates.'; RETURN; END

        SELECT TOP (1) @Bad = c.ColumnName
        FROM share.fn_ParseExportColumns(@SelectedColumnsJson) c
        WHERE NOT EXISTS (SELECT 1 FROM share.ExportableColumn e
                          WHERE e.DatasetId = @DatasetId AND e.ColumnName = c.ColumnName AND e.IsExportable = 1);
        IF @Bad IS NOT NULL
        BEGIN SET @StatusCode = N'InvalidColumn'; SET @StatusMessage = CONCAT(N'Column not exportable: ', @Bad); RETURN; END

        SELECT @SelectedColumnCount = COUNT(*) FROM share.fn_ParseExportColumns(@SelectedColumnsJson);
    END
    ELSE
        SELECT @SelectedColumnCount = COUNT(*) FROM share.ExportableColumn WHERE DatasetId = @DatasetId AND IsExportable = 1;

    -- Filters
    IF NULLIF(LTRIM(@FiltersJson), N'') IS NOT NULL
    BEGIN
        IF ISJSON(@FiltersJson) = 0 OR LEFT(LTRIM(@FiltersJson), 1) <> N'['
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'Filters must be a JSON array of {column, op, value}.'; RETURN; END

        DECLARE @F TABLE (FilterIndex INT, ElementType INT, ColumnName NVARCHAR(128), Op NVARCHAR(16),
                          ValueType INT, ValueCount INT, SqlType NVARCHAR(128), DataTypeName SYSNAME NULL, IsFilterable BIT NULL);
        INSERT INTO @F
        SELECT f.FilterIndex, f.ElementType, f.ColumnName, f.Op, f.ValueType, f.ValueCount,
               e.SqlTypeDeclaration, e.DataTypeName, e.IsFilterable
        FROM share.fn_ParseExportFilters(@FiltersJson) f
        LEFT JOIN share.ExportableColumn e ON e.DatasetId = @DatasetId AND e.ColumnName = f.ColumnName;

        SELECT @FilterCount = COUNT(*) FROM @F;
        IF @FilterCount > 20
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'At most 20 filters are allowed.'; RETURN; END
        IF EXISTS (SELECT 1 FROM @F WHERE ElementType <> 5 OR ColumnName IS NULL OR Op IS NULL)
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'Each filter must be an object with column and op.'; RETURN; END

        SELECT TOP (1) @Bad = ColumnName FROM @F WHERE IsFilterable IS NULL OR IsFilterable = 0;
        IF @Bad IS NOT NULL
        BEGIN SET @StatusCode = N'InvalidColumn'; SET @StatusMessage = CONCAT(N'Column not filterable: ', @Bad); RETURN; END

        SELECT TOP (1) @Bad = Op FROM @F
        WHERE Op NOT IN (N'eq', N'ne', N'gt', N'ge', N'lt', N'le', N'like', N'in', N'between', N'isnull', N'notnull');
        IF @Bad IS NOT NULL
        BEGIN SET @StatusCode = N'InvalidOperator'; SET @StatusMessage = CONCAT(N'Unsupported filter operator: ', @Bad); RETURN; END

        IF EXISTS (SELECT 1 FROM @F WHERE Op IN (N'eq', N'ne', N'gt', N'ge', N'lt', N'le', N'like')
                                     AND (ValueType IS NULL OR ValueType NOT IN (1, 2, 3)))
        BEGIN SET @StatusCode = N'InvalidFilterValue'; SET @StatusMessage = N'Comparison filters require a scalar value.'; RETURN; END
        IF EXISTS (SELECT 1 FROM @F WHERE Op = N'in' AND (ValueType <> 4 OR ValueCount NOT BETWEEN 1 AND 1000))
        BEGIN SET @StatusCode = N'InvalidFilterValue'; SET @StatusMessage = N'"in" requires an array of 1-1000 values.'; RETURN; END
        IF EXISTS (SELECT 1 FROM @F WHERE Op = N'between' AND (ValueType <> 4 OR ValueCount <> 2))
        BEGIN SET @StatusCode = N'InvalidFilterValue'; SET @StatusMessage = N'"between" requires an array of exactly 2 values.'; RETURN; END
        IF EXISTS (SELECT 1 FROM @F WHERE Op = N'like' AND DataTypeName NOT IN (N'nvarchar', N'varchar', N'nchar', N'char'))
        BEGIN SET @StatusCode = N'InvalidOperator'; SET @StatusMessage = N'"like" is only supported on character columns.'; RETURN; END

        -- Values must convert to the column type (typed via catalog-derived declarations)
        DECLARE @Check NVARCHAR(MAX);
        SELECT @Check = N'SELECT @BadOut = 0 + ' + STRING_AGG(CAST(
            CASE
                WHEN Op IN (N'eq', N'ne', N'gt', N'ge', N'lt', N'le')
                    THEN N'CASE WHEN TRY_CONVERT(' + SqlType + N', JSON_VALUE(@FiltersJson, N''$[' + CAST(FilterIndex AS NVARCHAR(10)) + N'].value'')) IS NULL THEN 1 ELSE 0 END'
                WHEN Op IN (N'in', N'between')
                    THEN N'(SELECT COUNT(*) FROM OPENJSON(@FiltersJson, N''$[' + CAST(FilterIndex AS NVARCHAR(10)) + N'].value'') j WHERE TRY_CONVERT(' + SqlType + N', j.[value]) IS NULL)'
                ELSE N'0'
            END AS NVARCHAR(MAX)), N' + ') + N';'
        FROM @F;

        DECLARE @BadCount INT = 0;
        EXEC sys.sp_executesql @Check, N'@FiltersJson NVARCHAR(MAX), @BadOut INT OUTPUT',
            @FiltersJson = @FiltersJson, @BadOut = @BadCount OUTPUT;
        IF @BadCount > 0
        BEGIN SET @StatusCode = N'InvalidFilterValue'; SET @StatusMessage = N'One or more filter values do not match the column data type.'; RETURN; END
    END

    -- Sort
    IF NULLIF(LTRIM(@SortJson), N'') IS NOT NULL
    BEGIN
        IF ISJSON(@SortJson) = 0 OR LEFT(LTRIM(@SortJson), 1) <> N'['
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'Sort must be a JSON array of {column, dir}.'; RETURN; END
        IF (SELECT COUNT(*) FROM share.fn_ParseExportSort(@SortJson)) > 5
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'At most 5 sort columns are allowed.'; RETURN; END
        IF EXISTS (SELECT 1 FROM share.fn_ParseExportSort(@SortJson) WHERE ElementType <> 5 OR ColumnName IS NULL OR Dir NOT IN (N'asc', N'desc'))
        BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'Each sort entry needs a column and dir asc|desc.'; RETURN; END

        SELECT TOP (1) @Bad = s.ColumnName
        FROM share.fn_ParseExportSort(@SortJson) s
        WHERE NOT EXISTS (SELECT 1 FROM share.ExportableColumn e
                          WHERE e.DatasetId = @DatasetId AND e.ColumnName = s.ColumnName AND e.IsSortable = 1);
        IF @Bad IS NOT NULL
        BEGIN SET @StatusCode = N'InvalidColumn'; SET @StatusMessage = CONCAT(N'Column not sortable: ', @Bad); RETURN; END
    END
END
GO

-- ============================================================
-- Export requests
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_SubmitExportRequest
    @DatasetCode         NVARCHAR(64),
    @UserName            NVARCHAR(128),
    @FormatCode          NVARCHAR(16),
    @DatasetVersionId    UNIQUEIDENTIFIER = NULL,   -- NULL = latest recorded version (if any)
    @SelectedColumnsJson NVARCHAR(4000) = NULL,     -- ["CustomerId","CustomerName"]
    @FiltersJson         NVARCHAR(MAX) = NULL,      -- [{"column":"CountryCode","op":"eq","value":"US"}]
    @SortJson            NVARCHAR(1000) = NULL,     -- [{"column":"CustomerName","dir":"asc"}]
    @ExportRequestId     UNIQUEIDENTIFIER = NULL OUTPUT,
    @StatusCode          NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage       NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @ExportRequestId = NULL;
    SET @StatusCode = N'Created';
    SET @StatusMessage = N'Export request queued.';

    DECLARE @DatasetId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER;
    SELECT @DatasetId = DatasetId, @WorkspaceId = WorkspaceId
    FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'InvalidDataset'; SET @StatusMessage = N'Dataset not found.'; RETURN; END

    DECLARE @UserId UNIQUEIDENTIFIER = (SELECT UserId FROM gov.AppUser WHERE UserName = @UserName);
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM share.ExportFormat WHERE FormatCode = @FormatCode AND IsActive = 1)
    BEGIN SET @StatusCode = N'InvalidFormat'; SET @StatusMessage = N'Unsupported export format.'; RETURN; END

    IF @DatasetVersionId IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM lineage.DatasetVersion WHERE DatasetVersionId = @DatasetVersionId AND DatasetId = @DatasetId)
    BEGIN SET @StatusCode = N'InvalidVersion'; SET @StatusMessage = N'Dataset version does not belong to this dataset.'; RETURN; END

    IF @DatasetVersionId IS NULL
        SELECT TOP (1) @DatasetVersionId = DatasetVersionId
        FROM lineage.DatasetVersion WHERE DatasetId = @DatasetId
        ORDER BY VersionNumber DESC;

    -- Authorization (database-side complement to application authorization)
    DECLARE @Allowed BIT, @Decision NVARCHAR(32), @Reason NVARCHAR(200), @Source NVARCHAR(32);
    SELECT @Allowed = IsAllowed, @Decision = DecisionCode, @Reason = Reason, @Source = AccessSource
    FROM share.fn_EvaluateExportAccess(@DatasetId, @UserId);

    IF ISNULL(@Allowed, 0) = 0
    BEGIN
        DECLARE @DenyDetails NVARCHAR(MAX) =
            (SELECT @Decision AS decision, @FormatCode AS format FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC gov.usp_WriteAudit @EventType = N'ExportDenied', @DatasetId = @DatasetId,
            @UserId = @UserId, @ActorUserId = @UserId, @WorkspaceId = @WorkspaceId, @DetailsJson = @DenyDetails;
        SET @StatusCode = N'AccessDenied';
        SET @StatusMessage = CONCAT(@Decision, N': ', @Reason);
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM share.ExportableColumn WHERE DatasetId = @DatasetId)
        EXEC share.usp_SyncExportableColumns @DatasetCode = @DatasetCode, @ReturnSummary = 0;

    DECLARE @ColCount INT, @FilterCount INT, @VCode NVARCHAR(32), @VMsg NVARCHAR(500);
    EXEC share.usp_ValidateExportSpec
        @DatasetId = @DatasetId,
        @SelectedColumnsJson = @SelectedColumnsJson,
        @FiltersJson = @FiltersJson,
        @SortJson = @SortJson,
        @SelectedColumnCount = @ColCount OUTPUT,
        @FilterCount = @FilterCount OUTPUT,
        @StatusCode = @VCode OUTPUT,
        @StatusMessage = @VMsg OUTPUT;
    IF @VCode <> N'Valid'
    BEGIN SET @StatusCode = @VCode; SET @StatusMessage = @VMsg; RETURN; END

    DECLARE @SpecHash VARBINARY(32) = HASHBYTES(N'SHA2_256',
        CONCAT(@FormatCode, N'|', @DatasetVersionId, N'|', @SelectedColumnsJson, N'|', @FiltersJson, N'|', @SortJson));

    -- Prevent identical in-flight requests from the same user
    DECLARE @Dup UNIQUEIDENTIFIER;
    SELECT TOP (1) @Dup = r.ExportRequestId
    FROM share.ExportRequest r
    INNER JOIN share.ExportRequestSpec s ON s.ExportRequestId = r.ExportRequestId
    WHERE r.RequestedByUserId = @UserId AND r.DatasetId = @DatasetId
      AND r.Status IN (N'Pending', N'Processing') AND s.SpecHash = @SpecHash;
    IF @Dup IS NOT NULL
    BEGIN
        SET @ExportRequestId = @Dup;
        SET @StatusCode = N'DuplicateInFlight';
        SET @StatusMessage = N'An identical export request is already pending or processing.';
        RETURN;
    END

    SET @ExportRequestId = NEWID();
    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();

    BEGIN TRANSACTION;

    INSERT INTO share.ExportRequest
        (ExportRequestId, DatasetId, DatasetVersionId, RequestedByUserId, WorkspaceId, FormatCode, Status,
         AccessSource, SelectedColumnCount, FilterCount, RequestedUtc, ModifiedUtc)
    VALUES
        (@ExportRequestId, @DatasetId, @DatasetVersionId, @UserId, @WorkspaceId, @FormatCode, N'Pending',
         @Source, @ColCount, @FilterCount, @Now, @Now);

    INSERT INTO share.ExportRequestSpec (ExportRequestId, SelectedColumnsJson, FiltersJson, SortJson, SpecHash)
    VALUES (@ExportRequestId, NULLIF(LTRIM(@SelectedColumnsJson), N''), NULLIF(LTRIM(@FiltersJson), N''),
            NULLIF(LTRIM(@SortJson), N''), @SpecHash);

    INSERT INTO share.ExportStatusHistory (ExportRequestId, PreviousStatus, NewStatus, ActorUserId, ChangedUtc, Message)
    VALUES (@ExportRequestId, NULL, N'Pending', @UserId, @Now, N'Submitted');

    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ExportRequestId AS exportRequestId, @FormatCode AS format, @Source AS accessSource,
                @ColCount AS columns, @FilterCount AS filters
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = N'ExportRequested', @DatasetId = @DatasetId,
        @UserId = @UserId, @ActorUserId = @UserId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    COMMIT TRANSACTION;

    SELECT * FROM share.vw_ExportRequestDetail WHERE ExportRequestId = @ExportRequestId;
END
GO

-- Single state machine entry point; transitions validated against share.ExportStatusTransition
CREATE OR ALTER PROCEDURE share.usp_TransitionExportStatus
    @ExportRequestId UNIQUEIDENTIFIER,
    @NewStatus       NVARCHAR(16),
    @ActorUserName   NVARCHAR(128) = NULL,   -- NULL = system/worker
    @RecordCount     BIGINT = NULL,
    @FileSizeBytes   BIGINT = NULL,
    @FileReference   NVARCHAR(500) = NULL,
    @FailureReason   NVARCHAR(2000) = NULL,
    @StatusCode      NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage   NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = @NewStatus;
    SET @StatusMessage = CONCAT(N'Export moved to ', @NewStatus, N'.');

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Current NVARCHAR(16), @DatasetId UNIQUEIDENTIFIER, @RequesterId UNIQUEIDENTIFIER,
            @WorkspaceId UNIQUEIDENTIFIER, @Attempts INT, @Format NVARCHAR(16);

    SELECT @Current = Status, @DatasetId = DatasetId, @RequesterId = RequestedByUserId,
           @WorkspaceId = WorkspaceId, @Attempts = AttemptCount, @Format = FormatCode
    FROM share.ExportRequest WHERE ExportRequestId = @ExportRequestId;

    IF @Current IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Export request not found.'; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM share.ExportStatus WHERE StatusCode = @NewStatus)
    BEGIN SET @StatusCode = N'InvalidStatus'; SET @StatusMessage = N'Unknown export status.'; RETURN; END
    IF NOT EXISTS (SELECT 1 FROM share.ExportStatusTransition WHERE FromStatus = @Current AND ToStatus = @NewStatus)
    BEGIN
        SET @StatusCode = N'InvalidTransition';
        SET @StatusMessage = CONCAT(N'Cannot move export from ', @Current, N' to ', @NewStatus, N'.');
        RETURN;
    END

    DECLARE @ActorId UNIQUEIDENTIFIER = NULL, @ActorIsAdmin BIT = 0;
    IF @ActorUserName IS NOT NULL
    BEGIN
        SELECT @ActorId = UserId, @ActorIsAdmin = IsPlatformAdmin
        FROM gov.AppUser WHERE UserName = @ActorUserName AND IsActive = 1;
        IF @ActorId IS NULL
        BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'Actor not found or inactive.'; RETURN; END
        IF @ActorId <> @RequesterId AND @ActorIsAdmin = 0
        BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Only the requester, a platform admin, or the export worker can change this request.'; RETURN; END
    END

    IF @NewStatus = N'Completed' AND (@RecordCount IS NULL OR @RecordCount < 0)
    BEGIN SET @StatusCode = N'RecordCountRequired'; SET @StatusMessage = N'Completed exports require a non-negative RecordCount.'; RETURN; END
    IF @NewStatus = N'Failed' AND NULLIF(LTRIM(@FailureReason), N'') IS NULL
    BEGIN SET @StatusCode = N'FailureReasonRequired'; SET @StatusMessage = N'Failed exports require a FailureReason.'; RETURN; END
    IF @NewStatus = N'Pending' AND @Attempts >= 3
    BEGIN SET @StatusCode = N'RetryLimitReached'; SET @StatusMessage = N'Maximum retry attempts reached.'; RETURN; END

    -- Re-authorize the requester when processing starts: access may have been revoked since submit
    IF @NewStatus = N'Processing'
       AND NOT EXISTS (SELECT 1 FROM share.fn_EvaluateExportAccess(@DatasetId, @RequesterId) WHERE IsAllowed = 1)
    BEGIN
        DECLARE @Deny NVARCHAR(200) =
            (SELECT CONCAT(DecisionCode, N': ', Reason) FROM share.fn_EvaluateExportAccess(@DatasetId, @RequesterId));
        SET @Deny = COALESCE(@Deny, N'Access no longer permitted.');

        BEGIN TRANSACTION;
        UPDATE share.ExportRequest
        SET Status = N'Cancelled', CompletedUtc = @Now, FailureReason = @Deny, ModifiedUtc = @Now
        WHERE ExportRequestId = @ExportRequestId AND Status = @Current;

        INSERT INTO share.ExportStatusHistory (ExportRequestId, PreviousStatus, NewStatus, ActorUserId, ChangedUtc, Message)
        VALUES (@ExportRequestId, @Current, N'Cancelled', @ActorId, @Now, @Deny);

        DECLARE @CancelDetails NVARCHAR(MAX) =
            (SELECT @ExportRequestId AS exportRequestId, @Deny AS reason FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC gov.usp_WriteAudit @EventType = N'ExportCancelled', @DatasetId = @DatasetId,
            @UserId = @RequesterId, @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId, @DetailsJson = @CancelDetails;
        COMMIT TRANSACTION;

        SET @StatusCode = N'AccessDenied';
        SET @StatusMessage = CONCAT(N'Export cancelled: ', @Deny);
        RETURN;
    END

    BEGIN TRANSACTION;

    UPDATE share.ExportRequest
    SET Status = @NewStatus,
        StartedUtc    = CASE WHEN @NewStatus = N'Processing' THEN @Now
                             WHEN @NewStatus = N'Pending' THEN NULL ELSE StartedUtc END,
        CompletedUtc  = CASE WHEN @NewStatus IN (N'Completed', N'Failed', N'Cancelled') THEN @Now
                             WHEN @NewStatus IN (N'Pending', N'Processing') THEN NULL ELSE CompletedUtc END,
        AttemptCount  = CASE WHEN @NewStatus = N'Processing' THEN AttemptCount + 1 ELSE AttemptCount END,
        RecordCount   = CASE WHEN @NewStatus = N'Completed' THEN @RecordCount
                             WHEN @NewStatus = N'Pending' THEN NULL ELSE COALESCE(@RecordCount, RecordCount) END,
        FileSizeBytes = CASE WHEN @NewStatus = N'Completed' THEN @FileSizeBytes
                             WHEN @NewStatus = N'Pending' THEN NULL ELSE FileSizeBytes END,
        FileReference = CASE WHEN @NewStatus = N'Completed' THEN @FileReference
                             WHEN @NewStatus = N'Pending' THEN NULL ELSE FileReference END,
        FailureReason = CASE WHEN @NewStatus IN (N'Failed', N'Cancelled') THEN @FailureReason
                             WHEN @NewStatus IN (N'Pending', N'Processing', N'Completed') THEN NULL ELSE FailureReason END,
        ModifiedUtc   = @Now
    WHERE ExportRequestId = @ExportRequestId AND Status = @Current;

    IF @@ROWCOUNT = 0
    BEGIN
        ROLLBACK TRANSACTION;
        SET @StatusCode = N'ConcurrencyConflict';
        SET @StatusMessage = N'Export request changed state concurrently; reload and retry.';
        RETURN;
    END

    INSERT INTO share.ExportStatusHistory (ExportRequestId, PreviousStatus, NewStatus, ActorUserId, ChangedUtc, Message)
    VALUES (@ExportRequestId, @Current, @NewStatus, @ActorId, @Now, @FailureReason);

    DECLARE @EventType NVARCHAR(64) = CASE @NewStatus
        WHEN N'Processing' THEN N'ExportStarted'
        WHEN N'Completed'  THEN N'ExportCompleted'
        WHEN N'Failed'     THEN N'ExportFailed'
        WHEN N'Cancelled'  THEN N'ExportCancelled'
        WHEN N'Pending'    THEN N'ExportRetried' END;
    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ExportRequestId AS exportRequestId, @Current AS fromStatus, @NewStatus AS toStatus,
                @Format AS format, @RecordCount AS recordCount, @FailureReason AS failureReason
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = @EventType, @DatasetId = @DatasetId,
        @UserId = @RequesterId, @ActorUserId = @ActorId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    COMMIT TRANSACTION;

    SELECT * FROM share.vw_ExportRequestDetail WHERE ExportRequestId = @ExportRequestId;
END
GO

-- Worker queue pickup: oldest pending request, skipping rows locked by other workers
CREATE OR ALTER PROCEDURE share.usp_ClaimNextExportRequest
    @StatusCode    NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Id UNIQUEIDENTIFIER;

    BEGIN TRANSACTION;
    SELECT TOP (1) @Id = ExportRequestId
    FROM share.ExportRequest WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE Status = N'Pending'
    ORDER BY RequestedUtc;

    IF @Id IS NULL
    BEGIN
        COMMIT TRANSACTION;
        SET @StatusCode = N'QueueEmpty';
        SET @StatusMessage = N'No pending export requests.';
        RETURN;
    END

    EXEC share.usp_TransitionExportStatus
        @ExportRequestId = @Id, @NewStatus = N'Processing',
        @StatusCode = @StatusCode OUTPUT, @StatusMessage = @StatusMessage OUTPUT;
    IF @@TRANCOUNT > 0 COMMIT TRANSACTION;
END
GO

CREATE OR ALTER PROCEDURE share.usp_GetExportRequest
    @ExportRequestId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    SELECT r.*, s.SelectedColumnsJson, s.FiltersJson, s.SortJson
    FROM share.vw_ExportRequestDetail r
    LEFT JOIN share.ExportRequestSpec s ON s.ExportRequestId = r.ExportRequestId
    WHERE r.ExportRequestId = @ExportRequestId;

    SELECT h.StatusHistoryId, h.PreviousStatus, h.NewStatus, u.UserName AS ActorUserName, h.ChangedUtc, h.Message
    FROM share.ExportStatusHistory h
    LEFT JOIN gov.AppUser u ON u.UserId = h.ActorUserId
    WHERE h.ExportRequestId = @ExportRequestId
    ORDER BY h.ChangedUtc, h.StatusHistoryId;

    SELECT dl.DownloadId, u.UserName AS DownloadedByUserName, dl.DownloadedUtc, dl.ClientInfo
    FROM share.ExportDownload dl
    INNER JOIN gov.AppUser u ON u.UserId = dl.DownloadedByUserId
    WHERE dl.ExportRequestId = @ExportRequestId
    ORDER BY dl.DownloadedUtc DESC;
END
GO

-- ============================================================
-- Paged export data (server-side filtering, column selection,
-- keyset paging on single-column PK, OFFSET/FETCH otherwise)
-- Result set 1: data rows. Result set 2: paging metadata.
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_GetExportData
    @ExportRequestId   UNIQUEIDENTIFIER,
    @UserName          NVARCHAR(128) = NULL,   -- NULL = system/worker
    @PageSize          INT = 5000,
    @PageNumber        INT = 1,                -- OFFSET mode only
    @AfterKey          NVARCHAR(100) = NULL,   -- KEYSET mode only (last key of previous page)
    @IncludeTotalCount BIT = 0,
    @StatusCode        NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage     NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @StatusCode = N'OK';
    SET @StatusMessage = N'Page returned.';
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 5000;
    IF @PageSize > 50000 SET @PageSize = 50000;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    DECLARE @DatasetId UNIQUEIDENTIFIER, @RequesterId UNIQUEIDENTIFIER, @Status NVARCHAR(16),
            @ColsJson NVARCHAR(4000), @FiltersJson NVARCHAR(MAX), @SortJson NVARCHAR(1000), @Target NVARCHAR(256);

    SELECT @DatasetId = r.DatasetId, @RequesterId = r.RequestedByUserId, @Status = r.Status,
           @ColsJson = s.SelectedColumnsJson, @FiltersJson = s.FiltersJson, @SortJson = s.SortJson,
           @Target = d.TargetTable
    FROM share.ExportRequest r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    LEFT JOIN share.ExportRequestSpec s ON s.ExportRequestId = r.ExportRequestId
    WHERE r.ExportRequestId = @ExportRequestId;

    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Export request not found.'; RETURN; END

    IF @UserName IS NOT NULL
    BEGIN
        DECLARE @CallerId UNIQUEIDENTIFIER, @CallerIsAdmin BIT;
        SELECT @CallerId = UserId, @CallerIsAdmin = IsPlatformAdmin
        FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
        IF @CallerId IS NULL
        BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END
        IF @CallerId <> @RequesterId AND @CallerIsAdmin = 0
        BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Only the requester or a platform admin can read export data.'; RETURN; END
    END

    IF @Status <> N'Processing'
    BEGIN SET @StatusCode = N'InvalidState'; SET @StatusMessage = N'Export data can only be read while the request is Processing.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM share.fn_EvaluateExportAccess(@DatasetId, @RequesterId) WHERE IsAllowed = 1)
    BEGIN SET @StatusCode = N'AccessDenied'; SET @StatusMessage = N'Requester no longer has export access to this dataset.'; RETURN; END

    DECLARE @ObjId INT = OBJECT_ID(@Target, N'U');
    IF @ObjId IS NULL
    BEGIN SET @StatusCode = N'TargetMissing'; SET @StatusMessage = N'Dataset target table does not exist.'; RETURN; END

    DECLARE @From NVARCHAR(300) = QUOTENAME(OBJECT_SCHEMA_NAME(@ObjId)) + N'.' + QUOTENAME(OBJECT_NAME(@ObjId));

    -- Column list (whitelisted names only)
    DECLARE @ColList NVARCHAR(MAX);
    IF EXISTS (SELECT 1 FROM share.fn_ParseExportColumns(@ColsJson))
        SELECT @ColList = STRING_AGG(CAST(QUOTENAME(e.ColumnName) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.Ord)
        FROM share.fn_ParseExportColumns(@ColsJson) c
        INNER JOIN share.ExportableColumn e
                ON e.DatasetId = @DatasetId AND e.ColumnName = c.ColumnName AND e.IsExportable = 1;
    ELSE
        SELECT @ColList = STRING_AGG(CAST(QUOTENAME(ColumnName) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY OrdinalPosition)
        FROM share.ExportableColumn WHERE DatasetId = @DatasetId AND IsExportable = 1;

    IF @ColList IS NULL
    BEGIN SET @StatusCode = N'NoExportableColumns'; SET @StatusMessage = N'No exportable columns resolved.'; RETURN; END

    -- Filters → typed local variables + fixed operator fragments
    DECLARE @F TABLE (FilterIndex INT, Col NVARCHAR(300), Op NVARCHAR(16), SqlType NVARCHAR(128));
    INSERT INTO @F
    SELECT f.FilterIndex, QUOTENAME(e.ColumnName), f.Op, e.SqlTypeDeclaration
    FROM share.fn_ParseExportFilters(@FiltersJson) f
    INNER JOIN share.ExportableColumn e
            ON e.DatasetId = @DatasetId AND e.ColumnName = f.ColumnName AND e.IsFilterable = 1
    WHERE f.Op IN (N'eq', N'ne', N'gt', N'ge', N'lt', N'le', N'like', N'in', N'between', N'isnull', N'notnull');

    IF (SELECT COUNT(*) FROM @F) <> (SELECT COUNT(*) FROM share.fn_ParseExportFilters(@FiltersJson))
    BEGIN SET @StatusCode = N'InvalidSpec'; SET @StatusMessage = N'Stored filter specification no longer matches exportable columns.'; RETURN; END

    DECLARE @Declares NVARCHAR(MAX) = N'', @Where NVARCHAR(MAX) = N'';

    SELECT @Declares = ISNULL(STRING_AGG(CAST(
        CASE
            WHEN Op IN (N'eq', N'ne', N'gt', N'ge', N'lt', N'le')
                THEN N'DECLARE @v' + i + N' ' + SqlType + N' = TRY_CONVERT(' + SqlType + N', JSON_VALUE(@FiltersJson, N''$[' + i + N'].value''));'
            WHEN Op = N'like'
                THEN N'DECLARE @v' + i + N' NVARCHAR(4000) = JSON_VALUE(@FiltersJson, N''$[' + i + N'].value'');'
            WHEN Op = N'between'
                THEN N'DECLARE @v' + i + N'a ' + SqlType + N' = TRY_CONVERT(' + SqlType + N', JSON_VALUE(@FiltersJson, N''$[' + i + N'].value[0]''));'
                   + N' DECLARE @v' + i + N'b ' + SqlType + N' = TRY_CONVERT(' + SqlType + N', JSON_VALUE(@FiltersJson, N''$[' + i + N'].value[1]''));'
        END AS NVARCHAR(MAX)), NCHAR(10)) WITHIN GROUP (ORDER BY FilterIndex), N''),
           @Where = ISNULL(STRING_AGG(CAST(N' AND ' +
        CASE Op
            WHEN N'eq'      THEN Col + N' = @v' + i
            WHEN N'ne'      THEN Col + N' <> @v' + i
            WHEN N'gt'      THEN Col + N' > @v' + i
            WHEN N'ge'      THEN Col + N' >= @v' + i
            WHEN N'lt'      THEN Col + N' < @v' + i
            WHEN N'le'      THEN Col + N' <= @v' + i
            WHEN N'like'    THEN Col + N' LIKE @v' + i
            WHEN N'between' THEN Col + N' BETWEEN @v' + i + N'a AND @v' + i + N'b'
            WHEN N'in'      THEN Col + N' IN (SELECT TRY_CONVERT(' + SqlType + N', j.[value]) FROM OPENJSON(@FiltersJson, N''$[' + i + N'].value'') j)'
            WHEN N'isnull'  THEN Col + N' IS NULL'
            WHEN N'notnull' THEN Col + N' IS NOT NULL'
        END AS NVARCHAR(MAX)), N'') WITHIN GROUP (ORDER BY FilterIndex), N'')
    FROM (SELECT *, CAST(FilterIndex AS NVARCHAR(10)) AS i FROM @F) x;

    -- Key + ordering
    DECLARE @KeyCol NVARCHAR(300), @KeyType NVARCHAR(128);
    SELECT TOP (1) @KeyCol = QUOTENAME(ColumnName), @KeyType = SqlTypeDeclaration
    FROM share.ExportableColumn WHERE DatasetId = @DatasetId AND IsKey = 1;

    DECLARE @S TABLE (SortIndex INT, Col NVARCHAR(300), Dir NVARCHAR(4));
    INSERT INTO @S
    SELECT s.SortIndex, QUOTENAME(e.ColumnName), UPPER(s.Dir)
    FROM share.fn_ParseExportSort(@SortJson) s
    INNER JOIN share.ExportableColumn e
            ON e.DatasetId = @DatasetId AND e.ColumnName = s.ColumnName AND e.IsSortable = 1
    WHERE s.Dir IN (N'asc', N'desc');

    DECLARE @Mode NVARCHAR(8) =
        CASE WHEN @KeyCol IS NOT NULL
                  AND NOT EXISTS (SELECT 1 FROM @S WHERE NOT (Col = @KeyCol AND Dir = N'ASC'))
             THEN N'Keyset' ELSE N'Offset' END;

    DECLARE @OrderBy NVARCHAR(MAX);
    IF @Mode = N'Keyset'
        SET @OrderBy = @KeyCol + N' ASC';
    ELSE
    BEGIN
        SELECT @OrderBy = STRING_AGG(CAST(Col + N' ' + Dir AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY SortIndex) FROM @S;
        IF @KeyCol IS NOT NULL AND NOT EXISTS (SELECT 1 FROM @S WHERE Col = @KeyCol)
            SET @OrderBy = CONCAT(@OrderBy + N', ', @KeyCol + N' ASC');
        IF @OrderBy IS NULL
            SELECT TOP (1) @OrderBy = QUOTENAME(ColumnName) + N' ASC'
            FROM share.ExportableColumn WHERE DatasetId = @DatasetId AND IsSortable = 1 ORDER BY OrdinalPosition;
    END

    DECLARE @KeyPred NVARCHAR(MAX) = N'';
    IF @Mode = N'Keyset' AND @AfterKey IS NOT NULL
    BEGIN
        DECLARE @KeyOk BIT = 0;
        DECLARE @KeyCheck NVARCHAR(MAX) =
            N'SET @Ok = CASE WHEN TRY_CONVERT(' + @KeyType + N', @AfterKey) IS NULL THEN 0 ELSE 1 END;';
        EXEC sys.sp_executesql @KeyCheck, N'@AfterKey NVARCHAR(100), @Ok BIT OUTPUT', @AfterKey = @AfterKey, @Ok = @KeyOk OUTPUT;
        IF @KeyOk = 0
        BEGIN SET @StatusCode = N'InvalidAfterKey'; SET @StatusMessage = N'AfterKey does not match the key column type.'; RETURN; END

        SET @Declares = @Declares + NCHAR(10) + N'DECLARE @k ' + @KeyType + N' = TRY_CONVERT(' + @KeyType + N', @AfterKey);';
        SET @KeyPred = N' AND ' + @KeyCol + N' > @k';
    END

    DECLARE @Base NVARCHAR(MAX) = N' FROM ' + @From + N' WHERE 1 = 1' + @Where;
    DECLARE @Sql NVARCHAR(MAX) = @Declares + NCHAR(10);

    IF @Mode = N'Keyset'
    BEGIN
        SET @Sql = @Sql
            + N'SELECT TOP (@PageSize) ' + @ColList + @Base + @KeyPred + N' ORDER BY ' + @OrderBy + N';' + NCHAR(10)
            + N'SET @RowsOut = @@ROWCOUNT;' + NCHAR(10)
            + N'SELECT @NextOut = CONVERT(NVARCHAR(100), MAX(x.k)) FROM (SELECT TOP (@PageSize) ' + @KeyCol + N' AS k'
            + @Base + @KeyPred + N' ORDER BY ' + @OrderBy + N') x;' + NCHAR(10)
            + N'SET @HasMoreOut = CASE WHEN @NextOut IS NOT NULL AND EXISTS (SELECT 1' + @Base
            + N' AND ' + @KeyCol + N' > TRY_CONVERT(' + @KeyType + N', @NextOut)) THEN 1 ELSE 0 END;' + NCHAR(10);
    END
    ELSE
    BEGIN
        SET @Sql = @Sql
            + N'SELECT ' + @ColList + @Base + N' ORDER BY ' + @OrderBy
            + N' OFFSET (CAST(@PageNumber AS BIGINT) - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;' + NCHAR(10)
            + N'SET @RowsOut = @@ROWCOUNT;' + NCHAR(10)
            + N'SET @HasMoreOut = CASE WHEN EXISTS (SELECT 1 AS x' + @Base + N' ORDER BY ' + @OrderBy
            + N' OFFSET CAST(@PageNumber AS BIGINT) * @PageSize ROWS FETCH NEXT 1 ROWS ONLY) THEN 1 ELSE 0 END;' + NCHAR(10);
    END

    SET @Sql = @Sql + N'IF @IncludeTotalCount = 1 SELECT @TotalOut = COUNT_BIG(*)' + @Base + N';';

    DECLARE @Rows INT, @Next NVARCHAR(100), @HasMore BIT, @Total BIGINT;
    EXEC sys.sp_executesql @Sql,
        N'@FiltersJson NVARCHAR(MAX), @PageSize INT, @PageNumber INT, @AfterKey NVARCHAR(100), @IncludeTotalCount BIT,
          @RowsOut INT OUTPUT, @NextOut NVARCHAR(100) OUTPUT, @HasMoreOut BIT OUTPUT, @TotalOut BIGINT OUTPUT',
        @FiltersJson = @FiltersJson, @PageSize = @PageSize, @PageNumber = @PageNumber, @AfterKey = @AfterKey,
        @IncludeTotalCount = @IncludeTotalCount,
        @RowsOut = @Rows OUTPUT, @NextOut = @Next OUTPUT, @HasMoreOut = @HasMore OUTPUT, @TotalOut = @Total OUTPUT;

    SELECT @Mode AS PagingMode, PARSENAME(@KeyCol, 1) AS KeyColumn, @PageSize AS PageSize,
           CASE WHEN @Mode = N'Offset' THEN @PageNumber END AS PageNumber,
           @AfterKey AS AfterKey, ISNULL(@Rows, 0) AS RowsReturned,
           CASE WHEN @Mode = N'Keyset' THEN @Next END AS NextAfterKey,
           ISNULL(@HasMore, 0) AS HasMore, @Total AS TotalCount;
END
GO

CREATE OR ALTER PROCEDURE share.usp_RecordExportDownload
    @ExportRequestId UNIQUEIDENTIFIER,
    @UserName        NVARCHAR(128),
    @ClientInfo      NVARCHAR(256) = NULL,
    @StatusCode      NVARCHAR(32) = NULL OUTPUT,
    @StatusMessage   NVARCHAR(500) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @StatusCode = N'Downloaded';
    SET @StatusMessage = N'Download recorded.';

    DECLARE @DatasetId UNIQUEIDENTIFIER, @RequesterId UNIQUEIDENTIFIER, @WorkspaceId UNIQUEIDENTIFIER,
            @Status NVARCHAR(16), @FileRef NVARCHAR(500);
    SELECT @DatasetId = DatasetId, @RequesterId = RequestedByUserId, @WorkspaceId = WorkspaceId,
           @Status = Status, @FileRef = FileReference
    FROM share.ExportRequest WHERE ExportRequestId = @ExportRequestId;

    IF @DatasetId IS NULL
    BEGIN SET @StatusCode = N'NotFound'; SET @StatusMessage = N'Export request not found.'; RETURN; END
    IF @Status <> N'Completed'
    BEGIN SET @StatusCode = N'NotCompleted'; SET @StatusMessage = N'Only completed exports can be downloaded.'; RETURN; END

    DECLARE @UserId UNIQUEIDENTIFIER, @IsAdmin BIT;
    SELECT @UserId = UserId, @IsAdmin = IsPlatformAdmin FROM gov.AppUser WHERE UserName = @UserName AND IsActive = 1;
    IF @UserId IS NULL
    BEGIN SET @StatusCode = N'InvalidUser'; SET @StatusMessage = N'User not found or inactive.'; RETURN; END
    IF @UserId <> @RequesterId AND @IsAdmin = 0
    BEGIN SET @StatusCode = N'Unauthorized'; SET @StatusMessage = N'Only the requester or a platform admin can download this export.'; RETURN; END

    -- Access is re-checked at download time (share/grant may have been revoked or expired)
    IF NOT EXISTS (SELECT 1 FROM share.fn_EvaluateExportAccess(@DatasetId, @UserId) WHERE IsAllowed = 1)
    BEGIN
        DECLARE @DenyDetails NVARCHAR(MAX) =
            (SELECT @ExportRequestId AS exportRequestId, N'download' AS stage FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC gov.usp_WriteAudit @EventType = N'ExportDenied', @DatasetId = @DatasetId,
            @UserId = @UserId, @ActorUserId = @UserId, @WorkspaceId = @WorkspaceId, @DetailsJson = @DenyDetails;
        SET @StatusCode = N'AccessDenied';
        SET @StatusMessage = N'User no longer has export access to this dataset.';
        RETURN;
    END

    INSERT INTO share.ExportDownload (ExportRequestId, DownloadedByUserId, ClientInfo)
    VALUES (@ExportRequestId, @UserId, @ClientInfo);

    DECLARE @Details NVARCHAR(MAX) =
        (SELECT @ExportRequestId AS exportRequestId, @FileRef AS fileReference, @ClientInfo AS clientInfo
         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    EXEC gov.usp_WriteAudit @EventType = N'ExportDownloaded', @DatasetId = @DatasetId,
        @UserId = @RequesterId, @ActorUserId = @UserId, @WorkspaceId = @WorkspaceId, @DetailsJson = @Details;

    SELECT r.ExportRequestId, r.DatasetCode, r.FormatCode, f.MimeType, f.FileExtension,
           r.FileReference, r.FileSizeBytes, r.RecordCount, r.CompletedUtc
    FROM share.vw_ExportRequestDetail r
    INNER JOIN share.ExportFormat f ON f.FormatCode = r.FormatCode
    WHERE r.ExportRequestId = @ExportRequestId;
END
GO

-- ============================================================
-- Export history (paged, filterable)
-- ============================================================
CREATE OR ALTER PROCEDURE share.usp_GetExportHistory
    @UserName    NVARCHAR(128) = NULL,
    @DatasetCode NVARCHAR(64) = NULL,
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @Status      NVARCHAR(16) = NULL,
    @FormatCode  NVARCHAR(16) = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL,
    @PageNumber  INT = 1,
    @PageSize    INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 50;
    IF @PageSize > 500 SET @PageSize = 500;

    DECLARE @UserId UNIQUEIDENTIFIER = NULL, @DatasetId UNIQUEIDENTIFIER = NULL;
    IF @UserName IS NOT NULL
    BEGIN
        SELECT @UserId = UserId FROM gov.AppUser WHERE UserName = @UserName;
        IF @UserId IS NULL SET @UserId = '00000000-0000-0000-0000-000000000000';
    END
    IF @DatasetCode IS NOT NULL
    BEGIN
        SELECT @DatasetId = DatasetId FROM ingest.Dataset WHERE DatasetCode = @DatasetCode;
        IF @DatasetId IS NULL SET @DatasetId = '00000000-0000-0000-0000-000000000000';
    END

    -- Page keys on the narrow header first, then join display columns
    ;WITH page AS (
        SELECT r.ExportRequestId, r.RequestedUtc, COUNT(*) OVER () AS TotalCount
        FROM share.ExportRequest r
        WHERE (@UserId IS NULL OR r.RequestedByUserId = @UserId)
          AND (@DatasetId IS NULL OR r.DatasetId = @DatasetId)
          AND (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
          AND (@Status IS NULL OR r.Status = @Status)
          AND (@FormatCode IS NULL OR r.FormatCode = @FormatCode)
          AND (@FromUtc IS NULL OR r.RequestedUtc >= @FromUtc)
          AND (@ToUtc IS NULL OR r.RequestedUtc < @ToUtc)
        ORDER BY r.RequestedUtc DESC, r.ExportRequestId
        OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY
    )
    SELECT v.*, p.TotalCount,
           (SELECT COUNT(*) FROM share.ExportDownload dl WHERE dl.ExportRequestId = v.ExportRequestId) AS DownloadCount
    FROM page p
    INNER JOIN share.vw_ExportRequestDetail v ON v.ExportRequestId = p.ExportRequestId
    ORDER BY p.RequestedUtc DESC, p.ExportRequestId
    OPTION (RECOMPILE);
END
GO

-- Scheduled: fail stuck Processing requests and cancel abandoned Pending ones
CREATE OR ALTER PROCEDURE share.usp_CleanupStaleExports
    @ProcessingTimeoutMinutes INT = 120,
    @PendingTimeoutHours      INT = 72
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ProcessingTimeoutMinutes IS NULL OR @ProcessingTimeoutMinutes < 5 SET @ProcessingTimeoutMinutes = 5;
    IF @PendingTimeoutHours IS NULL OR @PendingTimeoutHours < 1 SET @PendingTimeoutHours = 1;

    DECLARE @Now DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @Changed TABLE (ExportRequestId UNIQUEIDENTIFIER, DatasetId UNIQUEIDENTIFIER, RequestedByUserId UNIQUEIDENTIFIER,
                            WorkspaceId UNIQUEIDENTIFIER, PrevStatus NVARCHAR(16), NewStatus NVARCHAR(16), Reason NVARCHAR(2000));

    BEGIN TRANSACTION;

    UPDATE share.ExportRequest
    SET Status = N'Failed', CompletedUtc = @Now, ModifiedUtc = @Now,
        FailureReason = N'Timed out while processing'
    OUTPUT inserted.ExportRequestId, inserted.DatasetId, inserted.RequestedByUserId, inserted.WorkspaceId,
           deleted.Status, inserted.Status, inserted.FailureReason
    INTO @Changed
    WHERE Status = N'Processing' AND StartedUtc < DATEADD(MINUTE, -@ProcessingTimeoutMinutes, @Now);

    UPDATE share.ExportRequest
    SET Status = N'Cancelled', CompletedUtc = @Now, ModifiedUtc = @Now,
        FailureReason = N'Abandoned in queue'
    OUTPUT inserted.ExportRequestId, inserted.DatasetId, inserted.RequestedByUserId, inserted.WorkspaceId,
           deleted.Status, inserted.Status, inserted.FailureReason
    INTO @Changed
    WHERE Status = N'Pending' AND RequestedUtc < DATEADD(HOUR, -@PendingTimeoutHours, @Now);

    INSERT INTO share.ExportStatusHistory (ExportRequestId, PreviousStatus, NewStatus, ActorUserId, ChangedUtc, Message)
    SELECT ExportRequestId, PrevStatus, NewStatus, NULL, @Now, Reason FROM @Changed;

    INSERT INTO gov.GovernanceAuditEvent (EventType, DatasetId, UserId, WorkspaceId, DetailsJson)
    SELECT CASE NewStatus WHEN N'Failed' THEN N'ExportFailed' ELSE N'ExportCancelled' END,
           c.DatasetId, c.RequestedByUserId, c.WorkspaceId,
           (SELECT c.ExportRequestId AS exportRequestId, c.Reason AS reason, N'CleanupStaleExports' AS source
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM @Changed c;

    COMMIT TRANSACTION;

    SELECT SUM(CASE WHEN NewStatus = N'Failed' THEN 1 ELSE 0 END) AS TimedOutCount,
           SUM(CASE WHEN NewStatus = N'Cancelled' THEN 1 ELSE 0 END) AS AbandonedCount
    FROM @Changed;
END
GO

-- ============================================================
-- Reporting
-- ============================================================
CREATE OR ALTER PROCEDURE rpt.usp_ExportSummary
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS TotalExports,
           SUM(CASE WHEN r.Status = N'Completed'  THEN 1 ELSE 0 END) AS CompletedExports,
           SUM(CASE WHEN r.Status = N'Failed'     THEN 1 ELSE 0 END) AS FailedExports,
           SUM(CASE WHEN r.Status = N'Pending'    THEN 1 ELSE 0 END) AS PendingExports,
           SUM(CASE WHEN r.Status = N'Processing' THEN 1 ELSE 0 END) AS ProcessingExports,
           SUM(CASE WHEN r.Status = N'Cancelled'  THEN 1 ELSE 0 END) AS CancelledExports,
           ISNULL(SUM(CASE WHEN r.Status = N'Completed' THEN r.RecordCount END), 0) AS TotalRecordsExported,
           AVG(CASE WHEN r.Status = N'Completed' AND r.StartedUtc IS NOT NULL
                    THEN CAST(DATEDIFF(SECOND, r.StartedUtc, r.CompletedUtc) AS DECIMAL(18, 2)) END) AS AvgDurationSeconds,
           COUNT(DISTINCT r.RequestedByUserId) AS DistinctRequesters,
           COUNT(DISTINCT r.DatasetId) AS DistinctDatasets,
           (SELECT COUNT(*) FROM share.ExportDownload dl
            INNER JOIN share.ExportRequest r2 ON r2.ExportRequestId = dl.ExportRequestId
            WHERE (@WorkspaceId IS NULL OR r2.WorkspaceId = @WorkspaceId)
              AND (@FromUtc IS NULL OR dl.DownloadedUtc >= @FromUtc)
              AND (@ToUtc IS NULL OR dl.DownloadedUtc < @ToUtc)) AS TotalDownloads,
           (SELECT COUNT(*) FROM share.vw_DatasetShareEffective s
            WHERE s.EffectiveStatus = N'Active' AND (@WorkspaceId IS NULL OR s.WorkspaceId = @WorkspaceId)) AS ActiveShares,
           (SELECT COUNT(*) FROM share.vw_DatasetShareEffective s
            WHERE s.EffectiveStatus = N'Expired' AND (@WorkspaceId IS NULL OR s.WorkspaceId = @WorkspaceId)) AS ExpiredShares,
           (SELECT COUNT(*) FROM share.vw_DatasetShareEffective s
            WHERE s.EffectiveStatus = N'Revoked' AND (@WorkspaceId IS NULL OR s.WorkspaceId = @WorkspaceId)) AS RevokedShares
    FROM share.ExportRequest r
    WHERE (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
      AND (@FromUtc IS NULL OR r.RequestedUtc >= @FromUtc)
      AND (@ToUtc IS NULL OR r.RequestedUtc < @ToUtc)
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportsByFormat
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.FormatCode, f.DisplayName,
           COUNT(r.ExportRequestId) AS TotalExports,
           SUM(CASE WHEN r.Status = N'Completed' THEN 1 ELSE 0 END) AS CompletedExports,
           SUM(CASE WHEN r.Status = N'Failed' THEN 1 ELSE 0 END) AS FailedExports,
           SUM(CASE WHEN r.Status IN (N'Pending', N'Processing') THEN 1 ELSE 0 END) AS InFlightExports,
           ISNULL(SUM(CASE WHEN r.Status = N'Completed' THEN r.RecordCount END), 0) AS RecordsExported
    FROM share.ExportFormat f
    LEFT JOIN share.ExportRequest r
           ON r.FormatCode = f.FormatCode
          AND (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
          AND (@FromUtc IS NULL OR r.RequestedUtc >= @FromUtc)
          AND (@ToUtc IS NULL OR r.RequestedUtc < @ToUtc)
    GROUP BY f.FormatCode, f.DisplayName
    ORDER BY TotalExports DESC, f.FormatCode
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportsByDataset
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL,
    @Top         INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;

    SELECT TOP (@Top) d.DatasetCode, d.DisplayName AS DatasetName, r.WorkspaceId,
           COUNT(*) AS TotalExports,
           SUM(CASE WHEN r.Status = N'Completed' THEN 1 ELSE 0 END) AS CompletedExports,
           SUM(CASE WHEN r.Status = N'Failed' THEN 1 ELSE 0 END) AS FailedExports,
           SUM(CASE WHEN r.Status IN (N'Pending', N'Processing') THEN 1 ELSE 0 END) AS InFlightExports,
           ISNULL(SUM(CASE WHEN r.Status = N'Completed' THEN r.RecordCount END), 0) AS RecordsExported,
           COUNT(DISTINCT r.RequestedByUserId) AS DistinctRequesters,
           MAX(r.RequestedUtc) AS LastRequestedUtc
    FROM share.ExportRequest r
    INNER JOIN ingest.Dataset d ON d.DatasetId = r.DatasetId
    WHERE (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
      AND (@FromUtc IS NULL OR r.RequestedUtc >= @FromUtc)
      AND (@ToUtc IS NULL OR r.RequestedUtc < @ToUtc)
    GROUP BY d.DatasetCode, d.DisplayName, r.WorkspaceId
    ORDER BY TotalExports DESC, d.DatasetCode
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportsByUser
    @WorkspaceId UNIQUEIDENTIFIER = NULL,
    @FromUtc     DATETIME2(3) = NULL,
    @ToUtc       DATETIME2(3) = NULL,
    @Top         INT = 50
AS
BEGIN
    SET NOCOUNT ON;
    IF @Top IS NULL OR @Top < 1 SET @Top = 50;

    SELECT TOP (@Top) u.UserName, u.DisplayName,
           COUNT(*) AS TotalExports,
           SUM(CASE WHEN r.Status = N'Completed' THEN 1 ELSE 0 END) AS CompletedExports,
           SUM(CASE WHEN r.Status = N'Failed' THEN 1 ELSE 0 END) AS FailedExports,
           SUM(CASE WHEN r.Status = N'Cancelled' THEN 1 ELSE 0 END) AS CancelledExports,
           ISNULL(SUM(CASE WHEN r.Status = N'Completed' THEN r.RecordCount END), 0) AS RecordsExported,
           COUNT(DISTINCT r.DatasetId) AS DistinctDatasets,
           MAX(r.RequestedUtc) AS LastRequestedUtc
    FROM share.ExportRequest r
    INNER JOIN gov.AppUser u ON u.UserId = r.RequestedByUserId
    WHERE (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
      AND (@FromUtc IS NULL OR r.RequestedUtc >= @FromUtc)
      AND (@ToUtc IS NULL OR r.RequestedUtc < @ToUtc)
    GROUP BY u.UserName, u.DisplayName
    ORDER BY TotalExports DESC, u.UserName
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ExportActivityByDate
    @Days        INT = 30,
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @Days IS NULL OR @Days < 1 SET @Days = 30;
    IF @Days > 366 SET @Days = 366;

    DECLARE @From DATETIME2(3) = CAST(DATEADD(DAY, 1 - @Days, CAST(SYSUTCDATETIME() AS DATE)) AS DATETIME2(3));

    ;WITH days AS (
        SELECT TOP (@Days) CAST(DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @From) AS DATE) AS ActivityDate
        FROM sys.all_objects
    ),
    ex AS (
        SELECT CAST(RequestedUtc AS DATE) AS ActivityDate,
               COUNT(*) AS Requested,
               SUM(CASE WHEN Status = N'Completed' THEN 1 ELSE 0 END) AS Completed,
               SUM(CASE WHEN Status = N'Failed' THEN 1 ELSE 0 END) AS Failed,
               SUM(CASE WHEN Status = N'Cancelled' THEN 1 ELSE 0 END) AS Cancelled,
               SUM(CASE WHEN Status IN (N'Pending', N'Processing') THEN 1 ELSE 0 END) AS InFlight,
               ISNULL(SUM(CASE WHEN Status = N'Completed' THEN RecordCount END), 0) AS RecordsExported
        FROM share.ExportRequest
        WHERE RequestedUtc >= @From
          AND (@WorkspaceId IS NULL OR WorkspaceId = @WorkspaceId)
        GROUP BY CAST(RequestedUtc AS DATE)
    ),
    dl AS (
        SELECT CAST(dl.DownloadedUtc AS DATE) AS ActivityDate, COUNT(*) AS Downloads
        FROM share.ExportDownload dl
        INNER JOIN share.ExportRequest r ON r.ExportRequestId = dl.ExportRequestId
        WHERE dl.DownloadedUtc >= @From
          AND (@WorkspaceId IS NULL OR r.WorkspaceId = @WorkspaceId)
        GROUP BY CAST(dl.DownloadedUtc AS DATE)
    )
    SELECT d.ActivityDate,
           ISNULL(ex.Requested, 0) AS Requested, ISNULL(ex.Completed, 0) AS Completed,
           ISNULL(ex.Failed, 0) AS Failed, ISNULL(ex.Cancelled, 0) AS Cancelled,
           ISNULL(ex.InFlight, 0) AS InFlight, ISNULL(ex.RecordsExported, 0) AS RecordsExported,
           ISNULL(dl.Downloads, 0) AS Downloads
    FROM days d
    LEFT JOIN ex ON ex.ActivityDate = d.ActivityDate
    LEFT JOIN dl ON dl.ActivityDate = d.ActivityDate
    ORDER BY d.ActivityDate DESC
    OPTION (RECOMPILE);
END
GO

CREATE OR ALTER PROCEDURE rpt.usp_ShareStatusSummary
    @WorkspaceId UNIQUEIDENTIFIER = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT d.DatasetCode, d.DisplayName AS DatasetName, s.WorkspaceId,
           SUM(CASE WHEN s.EffectiveStatus = N'Active' THEN 1 ELSE 0 END) AS ActiveShares,
           SUM(CASE WHEN s.EffectiveStatus = N'Expired' THEN 1 ELSE 0 END) AS ExpiredShares,
           SUM(CASE WHEN s.EffectiveStatus = N'Revoked' THEN 1 ELSE 0 END) AS RevokedShares,
           SUM(CASE WHEN s.EffectiveStatus = N'Active' AND s.ExpiresUtc IS NOT NULL
                         AND s.ExpiresUtc <= DATEADD(DAY, 7, SYSUTCDATETIME()) THEN 1 ELSE 0 END) AS ExpiringWithin7Days,
           SUM(CASE WHEN s.EffectiveStatus = N'Expired' AND s.PersistedStatus = N'Active' THEN 1 ELSE 0 END) AS ExpiredNotYetMarked
    FROM share.vw_DatasetShareEffective s
    INNER JOIN ingest.Dataset d ON d.DatasetId = s.DatasetId
    WHERE (@WorkspaceId IS NULL OR s.WorkspaceId = @WorkspaceId)
    GROUP BY d.DatasetCode, d.DisplayName, s.WorkspaceId
    ORDER BY d.DatasetCode;
END
GO

PRINT 'Sharing/export procedures created.';
GO
