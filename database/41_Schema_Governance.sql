-- ============================================================
-- 41_Schema_Governance.sql
-- Data Governance, Classification & Access Policy Engine
-- Users/roles/workspace membership (foundation), dataset
-- governance attributes, certification history, access requests,
-- grants, and governance audit events.
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'gov')
    EXEC(N'CREATE SCHEMA gov AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Reference: Classification
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.Classification', N'U') IS NULL
BEGIN
    CREATE TABLE gov.Classification
    (
        ClassificationCode NVARCHAR(32)  NOT NULL CONSTRAINT PK_Classification PRIMARY KEY,
        DisplayName        NVARCHAR(100) NOT NULL,
        SensitivityRank    TINYINT       NOT NULL, -- higher = more sensitive
        Description        NVARCHAR(500) NULL,
        IsActive           BIT           NOT NULL CONSTRAINT DF_Classification_Active DEFAULT (1),
        CONSTRAINT CK_Classification_Rank CHECK (SensitivityRank BETWEEN 1 AND 10)
    );
END
GO

MERGE gov.Classification AS t
USING (VALUES
    (N'Public',       N'Public',       1, N'Freely shareable'),
    (N'Internal',     N'Internal',     2, N'Internal use only'),
    (N'Confidential', N'Confidential', 3, N'Limited business audience'),
    (N'Restricted',   N'Restricted',   4, N'Highest sensitivity / regulated')
) AS s (ClassificationCode, DisplayName, SensitivityRank, Description)
ON t.ClassificationCode = s.ClassificationCode
WHEN MATCHED THEN UPDATE SET
    DisplayName = s.DisplayName, SensitivityRank = s.SensitivityRank,
    Description = s.Description, IsActive = 1
WHEN NOT MATCHED THEN
    INSERT (ClassificationCode, DisplayName, SensitivityRank, Description)
    VALUES (s.ClassificationCode, s.DisplayName, s.SensitivityRank, s.Description);
GO

-- ------------------------------------------------------------
-- Reference: Governance lifecycle status
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.GovernanceStatus', N'U') IS NULL
BEGIN
    CREATE TABLE gov.GovernanceStatus
    (
        StatusCode  NVARCHAR(32)  NOT NULL CONSTRAINT PK_GovernanceStatus PRIMARY KEY,
        DisplayName NVARCHAR(100) NOT NULL,
        SortOrder   INT           NOT NULL CONSTRAINT DF_GovStatus_Sort DEFAULT (0),
        IsActive    BIT           NOT NULL CONSTRAINT DF_GovStatus_Active DEFAULT (1)
    );
END
GO

MERGE gov.GovernanceStatus AS t
USING (VALUES
    (N'Draft',       N'Draft',        10),
    (N'UnderReview', N'Under Review', 20),
    (N'Certified',   N'Certified',    30),
    (N'Expired',     N'Expired',      40),
    (N'Archived',    N'Archived',     50)
) AS s (StatusCode, DisplayName, SortOrder)
ON t.StatusCode = s.StatusCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, SortOrder = s.SortOrder, IsActive = 1
WHEN NOT MATCHED THEN INSERT (StatusCode, DisplayName, SortOrder) VALUES (s.StatusCode, s.DisplayName, s.SortOrder);
GO

-- ------------------------------------------------------------
-- Reference: Certification status
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.CertificationStatus', N'U') IS NULL
BEGIN
    CREATE TABLE gov.CertificationStatus
    (
        StatusCode  NVARCHAR(32)  NOT NULL CONSTRAINT PK_CertificationStatus PRIMARY KEY,
        DisplayName NVARCHAR(100) NOT NULL,
        IsActive    BIT           NOT NULL CONSTRAINT DF_CertStatus_Active DEFAULT (1)
    );
END
GO

MERGE gov.CertificationStatus AS t
USING (VALUES
    (N'NotCertified', N'Not Certified'),
    (N'Certified',    N'Certified'),
    (N'Expired',      N'Expired'),
    (N'Revoked',      N'Revoked')
) AS s (StatusCode, DisplayName)
ON t.StatusCode = s.StatusCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, IsActive = 1
WHEN NOT MATCHED THEN INSERT (StatusCode, DisplayName) VALUES (s.StatusCode, s.DisplayName);
GO

-- ------------------------------------------------------------
-- Reference: Access level
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.AccessLevel', N'U') IS NULL
BEGIN
    CREATE TABLE gov.AccessLevel
    (
        AccessLevelCode NVARCHAR(32)  NOT NULL CONSTRAINT PK_AccessLevel PRIMARY KEY,
        DisplayName     NVARCHAR(100) NOT NULL,
        RankOrder       TINYINT       NOT NULL,
        IsActive        BIT           NOT NULL CONSTRAINT DF_AccessLevel_Active DEFAULT (1)
    );
END
GO

MERGE gov.AccessLevel AS t
USING (VALUES
    (N'Read',  N'Read',  1),
    (N'Write', N'Write', 2),
    (N'Admin', N'Admin', 3)
) AS s (AccessLevelCode, DisplayName, RankOrder)
ON t.AccessLevelCode = s.AccessLevelCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, RankOrder = s.RankOrder, IsActive = 1
WHEN NOT MATCHED THEN INSERT (AccessLevelCode, DisplayName, RankOrder) VALUES (s.AccessLevelCode, s.DisplayName, s.RankOrder);
GO

-- ------------------------------------------------------------
-- Platform users (foundation — no prior User table existed)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.AppUser', N'U') IS NULL
BEGIN
    CREATE TABLE gov.AppUser
    (
        UserId       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AppUser PRIMARY KEY
                     CONSTRAINT DF_AppUser_Id DEFAULT NEWSEQUENTIALID(),
        UserName     NVARCHAR(128)    NOT NULL,
        DisplayName  NVARCHAR(200)    NOT NULL,
        Email        NVARCHAR(256)    NULL,
        IsActive     BIT              NOT NULL CONSTRAINT DF_AppUser_Active DEFAULT (1),
        IsPlatformAdmin BIT           NOT NULL CONSTRAINT DF_AppUser_PlatformAdmin DEFAULT (0),
        CreatedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_AppUser_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc  DATETIME2(3)     NOT NULL CONSTRAINT DF_AppUser_Modified DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_AppUser_UserName ON gov.AppUser (UserName);
    CREATE INDEX IX_AppUser_Active ON gov.AppUser (IsActive) INCLUDE (UserName, DisplayName, IsPlatformAdmin);
END
GO

-- ------------------------------------------------------------
-- Roles + user-role assignments
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.Role', N'U') IS NULL
BEGIN
    CREATE TABLE gov.Role
    (
        RoleCode    NVARCHAR(32)  NOT NULL CONSTRAINT PK_GovRole PRIMARY KEY,
        DisplayName NVARCHAR(100) NOT NULL,
        Description NVARCHAR(500) NULL,
        IsActive    BIT           NOT NULL CONSTRAINT DF_GovRole_Active DEFAULT (1)
    );
END
GO

MERGE gov.Role AS t
USING (VALUES
    (N'PlatformAdmin',  N'Platform Admin',  N'Full cross-workspace governance rights'),
    (N'WorkspaceAdmin', N'Workspace Admin', N'Administer datasets in a workspace'),
    (N'DataOwner',      N'Data Owner',      N'Owns dataset governance decisions'),
    (N'DataSteward',    N'Data Steward',    N'Stewards classification and reviews'),
    (N'Analyst',        N'Analyst',         N'Read/analyze granted datasets'),
    (N'Viewer',         N'Viewer',          N'Read-only granted datasets')
) AS s (RoleCode, DisplayName, Description)
ON t.RoleCode = s.RoleCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, Description = s.Description, IsActive = 1
WHEN NOT MATCHED THEN INSERT (RoleCode, DisplayName, Description) VALUES (s.RoleCode, s.DisplayName, s.Description);
GO

IF OBJECT_ID(N'gov.UserRole', N'U') IS NULL
BEGIN
    CREATE TABLE gov.UserRole
    (
        UserId     UNIQUEIDENTIFIER NOT NULL,
        RoleCode   NVARCHAR(32)     NOT NULL,
        AssignedUtc DATETIME2(3)    NOT NULL CONSTRAINT DF_UserRole_Assigned DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_UserRole PRIMARY KEY (UserId, RoleCode),
        CONSTRAINT FK_UserRole_User FOREIGN KEY (UserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_UserRole_Role FOREIGN KEY (RoleCode) REFERENCES gov.Role (RoleCode)
    );
END
GO

-- ------------------------------------------------------------
-- Workspace membership (complements analytics.Workspace catalog)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.WorkspaceMember', N'U') IS NULL
BEGIN
    CREATE TABLE gov.WorkspaceMember
    (
        WorkspaceId UNIQUEIDENTIFIER NOT NULL,
        UserId      UNIQUEIDENTIFIER NOT NULL,
        RoleCode    NVARCHAR(32)     NOT NULL CONSTRAINT DF_WsMember_Role DEFAULT (N'Viewer'),
        IsActive    BIT              NOT NULL CONSTRAINT DF_WsMember_Active DEFAULT (1),
        JoinedUtc   DATETIME2(3)     NOT NULL CONSTRAINT DF_WsMember_Joined DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_WorkspaceMember PRIMARY KEY (WorkspaceId, UserId),
        CONSTRAINT FK_WsMember_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_WsMember_User FOREIGN KEY (UserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_WsMember_Role FOREIGN KEY (RoleCode) REFERENCES gov.Role (RoleCode)
    );

    CREATE INDEX IX_WsMember_User ON gov.WorkspaceMember (UserId, IsActive)
        INCLUDE (WorkspaceId, RoleCode);
    CREATE INDEX IX_WsMember_Workspace_Role ON gov.WorkspaceMember (WorkspaceId, RoleCode, IsActive);
END
GO

-- ------------------------------------------------------------
-- Dataset governance (1:1 with ingest.Dataset — no duplication of catalog)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.DatasetGovernance', N'U') IS NULL
BEGIN
    CREATE TABLE gov.DatasetGovernance
    (
        DatasetId            UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DatasetGovernance PRIMARY KEY,
        WorkspaceId          UNIQUEIDENTIFIER NULL,
        ClassificationCode   NVARCHAR(32)     NOT NULL CONSTRAINT DF_DG_Class DEFAULT (N'Internal'),
        GovernanceStatusCode NVARCHAR(32)     NOT NULL CONSTRAINT DF_DG_GovStatus DEFAULT (N'Draft'),
        CertificationStatusCode NVARCHAR(32)  NOT NULL CONSTRAINT DF_DG_CertStatus DEFAULT (N'NotCertified'),
        OwnerUserId          UNIQUEIDENTIFIER NULL,
        StewardUserId        UNIQUEIDENTIFIER NULL,
        ReviewDueUtc         DATETIME2(3)     NULL,
        CertifiedUtc         DATETIME2(3)     NULL,
        CertificationExpiryUtc DATETIME2(3)   NULL,
        Notes                NVARCHAR(2000)   NULL,
        CreatedUtc           DATETIME2(3)     NOT NULL CONSTRAINT DF_DG_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc          DATETIME2(3)     NOT NULL CONSTRAINT DF_DG_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DG_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_DG_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_DG_Classification FOREIGN KEY (ClassificationCode) REFERENCES gov.Classification (ClassificationCode),
        CONSTRAINT FK_DG_GovStatus FOREIGN KEY (GovernanceStatusCode) REFERENCES gov.GovernanceStatus (StatusCode),
        CONSTRAINT FK_DG_CertStatus FOREIGN KEY (CertificationStatusCode) REFERENCES gov.CertificationStatus (StatusCode),
        CONSTRAINT FK_DG_Owner FOREIGN KEY (OwnerUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_DG_Steward FOREIGN KEY (StewardUserId) REFERENCES gov.AppUser (UserId)
    );

    CREATE INDEX IX_DG_Workspace_Class ON gov.DatasetGovernance (WorkspaceId, ClassificationCode)
        INCLUDE (GovernanceStatusCode, CertificationStatusCode, ReviewDueUtc, CertificationExpiryUtc);
    CREATE INDEX IX_DG_GovStatus ON gov.DatasetGovernance (GovernanceStatusCode)
        INCLUDE (DatasetId, WorkspaceId, ClassificationCode);
    CREATE INDEX IX_DG_CertStatus_Expiry ON gov.DatasetGovernance (CertificationStatusCode, CertificationExpiryUtc)
        INCLUDE (DatasetId, WorkspaceId);
    CREATE INDEX IX_DG_Owner ON gov.DatasetGovernance (OwnerUserId) WHERE OwnerUserId IS NOT NULL;
    CREATE INDEX IX_DG_Steward ON gov.DatasetGovernance (StewardUserId) WHERE StewardUserId IS NOT NULL;
    CREATE INDEX IX_DG_ReviewDue ON gov.DatasetGovernance (ReviewDueUtc)
        WHERE ReviewDueUtc IS NOT NULL;
END
GO

-- ------------------------------------------------------------
-- Certification / review history (append-only)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.CertificationHistory', N'U') IS NULL
BEGIN
    CREATE TABLE gov.CertificationHistory
    (
        HistoryId            BIGINT           NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_CertificationHistory PRIMARY KEY,
        DatasetId            UNIQUEIDENTIFIER NOT NULL,
        PreviousGovStatus    NVARCHAR(32)     NULL,
        NewGovStatus         NVARCHAR(32)     NOT NULL,
        PreviousCertStatus   NVARCHAR(32)     NULL,
        NewCertStatus        NVARCHAR(32)     NOT NULL,
        ActionedByUserId     UNIQUEIDENTIFIER NULL,
        ActionUtc            DATETIME2(3)     NOT NULL CONSTRAINT DF_CertHist_Action DEFAULT SYSUTCDATETIME(),
        ReviewDueUtc         DATETIME2(3)     NULL,
        CertificationExpiryUtc DATETIME2(3)   NULL,
        Comments             NVARCHAR(2000)   NULL,
        CONSTRAINT FK_CertHist_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_CertHist_User FOREIGN KEY (ActionedByUserId) REFERENCES gov.AppUser (UserId)
    );

    CREATE INDEX IX_CertHist_Dataset_Action ON gov.CertificationHistory (DatasetId, ActionUtc DESC)
        INCLUDE (NewGovStatus, NewCertStatus, ActionedByUserId);
END
GO

-- ------------------------------------------------------------
-- Access requests
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.AccessRequest', N'U') IS NULL
BEGIN
    CREATE TABLE gov.AccessRequest
    (
        AccessRequestId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_AccessRequest PRIMARY KEY
                           CONSTRAINT DF_AccessRequest_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId          UNIQUEIDENTIFIER NOT NULL,
        RequestingUserId   UNIQUEIDENTIFIER NOT NULL,
        AccessLevelCode    NVARCHAR(32)     NOT NULL,
        BusinessJustification NVARCHAR(2000) NOT NULL,
        Status             NVARCHAR(16)     NOT NULL CONSTRAINT DF_AccessRequest_Status DEFAULT (N'Pending'),
        RequestedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_AccessRequest_Req DEFAULT SYSUTCDATETIME(),
        ReviewerUserId     UNIQUEIDENTIFIER NULL,
        ReviewComments     NVARCHAR(2000)   NULL,
        DecisionUtc        DATETIME2(3)     NULL,
        WorkspaceId        UNIQUEIDENTIFIER NULL,
        CreatedUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_AccessRequest_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_AccessRequest_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_AccessReq_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_AccessReq_Requester FOREIGN KEY (RequestingUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_AccessReq_Reviewer FOREIGN KEY (ReviewerUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_AccessReq_Level FOREIGN KEY (AccessLevelCode) REFERENCES gov.AccessLevel (AccessLevelCode),
        CONSTRAINT FK_AccessReq_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT CK_AccessReq_Status CHECK (Status IN (N'Pending', N'Approved', N'Rejected', N'Revoked'))
    );

    -- One pending request per user/dataset/access-level
    CREATE UNIQUE INDEX UX_AccessReq_Pending
        ON gov.AccessRequest (DatasetId, RequestingUserId, AccessLevelCode)
        WHERE Status = N'Pending';

    CREATE INDEX IX_AccessReq_Status_Requested
        ON gov.AccessRequest (Status, RequestedUtc DESC)
        INCLUDE (DatasetId, RequestingUserId, AccessLevelCode, WorkspaceId);
    CREATE INDEX IX_AccessReq_Workspace_Status
        ON gov.AccessRequest (WorkspaceId, Status, RequestedUtc DESC);
    CREATE INDEX IX_AccessReq_User
        ON gov.AccessRequest (RequestingUserId, Status, RequestedUtc DESC);
    CREATE INDEX IX_AccessReq_Dataset
        ON gov.AccessRequest (DatasetId, Status, RequestedUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Effective grants (materialized from approvals; revoked when access revoked)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.DatasetAccessGrant', N'U') IS NULL
BEGIN
    CREATE TABLE gov.DatasetAccessGrant
    (
        GrantId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DatasetAccessGrant PRIMARY KEY
                         CONSTRAINT DF_AccessGrant_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        UserId           UNIQUEIDENTIFIER NOT NULL,
        AccessLevelCode  NVARCHAR(32)     NOT NULL,
        AccessRequestId  UNIQUEIDENTIFIER NULL,
        GrantedByUserId  UNIQUEIDENTIFIER NULL,
        GrantedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_AccessGrant_Granted DEFAULT SYSUTCDATETIME(),
        ExpiresUtc       DATETIME2(3)     NULL,
        IsActive         BIT              NOT NULL CONSTRAINT DF_AccessGrant_Active DEFAULT (1),
        RevokedUtc       DATETIME2(3)     NULL,
        RevokedByUserId  UNIQUEIDENTIFIER NULL,
        RevokeReason     NVARCHAR(1000)   NULL,
        CONSTRAINT FK_AccessGrant_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_AccessGrant_User FOREIGN KEY (UserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_AccessGrant_Level FOREIGN KEY (AccessLevelCode) REFERENCES gov.AccessLevel (AccessLevelCode),
        CONSTRAINT FK_AccessGrant_Request FOREIGN KEY (AccessRequestId) REFERENCES gov.AccessRequest (AccessRequestId),
        CONSTRAINT FK_AccessGrant_GrantedBy FOREIGN KEY (GrantedByUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_AccessGrant_RevokedBy FOREIGN KEY (RevokedByUserId) REFERENCES gov.AppUser (UserId)
    );

    CREATE UNIQUE INDEX UX_AccessGrant_Active
        ON gov.DatasetAccessGrant (DatasetId, UserId, AccessLevelCode)
        WHERE IsActive = 1;

    CREATE INDEX IX_AccessGrant_User_Active
        ON gov.DatasetAccessGrant (UserId, IsActive)
        INCLUDE (DatasetId, AccessLevelCode, ExpiresUtc);
    CREATE INDEX IX_AccessGrant_Dataset_Active
        ON gov.DatasetAccessGrant (DatasetId, IsActive)
        INCLUDE (UserId, AccessLevelCode);
END
GO

-- ------------------------------------------------------------
-- Governance audit (existing platform has no central audit for these events)
-- ------------------------------------------------------------
IF OBJECT_ID(N'gov.GovernanceAuditEvent', N'U') IS NULL
BEGIN
    CREATE TABLE gov.GovernanceAuditEvent
    (
        AuditEventId   BIGINT           NOT NULL IDENTITY(1,1)
                       CONSTRAINT PK_GovernanceAuditEvent PRIMARY KEY,
        EventType      NVARCHAR(64)     NOT NULL,
        DatasetId      UNIQUEIDENTIFIER NULL,
        UserId         UNIQUEIDENTIFIER NULL,
        ActorUserId    UNIQUEIDENTIFIER NULL,
        WorkspaceId    UNIQUEIDENTIFIER NULL,
        AccessRequestId UNIQUEIDENTIFIER NULL,
        DetailsJson    NVARCHAR(MAX)    NULL,
        EventUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_GovAudit_Event DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_GovAudit_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_GovAudit_User FOREIGN KEY (UserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_GovAudit_Actor FOREIGN KEY (ActorUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_GovAudit_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId)
    );

    CREATE INDEX IX_GovAudit_EventUtc ON gov.GovernanceAuditEvent (EventUtc DESC)
        INCLUDE (EventType, DatasetId, ActorUserId);
    CREATE INDEX IX_GovAudit_Dataset ON gov.GovernanceAuditEvent (DatasetId, EventUtc DESC)
        WHERE DatasetId IS NOT NULL;
    CREATE INDEX IX_GovAudit_Type ON gov.GovernanceAuditEvent (EventType, EventUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Job types for scheduled certification expiry
-- ------------------------------------------------------------
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Job_Type')
    ALTER TABLE jobs.ProcessingJob DROP CONSTRAINT CK_Job_Type;
GO
ALTER TABLE jobs.ProcessingJob WITH CHECK ADD CONSTRAINT CK_Job_Type CHECK (JobType IN (
    N'MetadataRefresh', N'HealthCheck', N'SampleExtract',
    N'DataProfiling', N'QualityAssessment', N'MetadataSync', N'ArchiveProfilingHistory',
    N'ProcessPendingImports', N'ArchiveImportHistory',
    N'EtlProcessPending', N'EtlArchiveErrors', N'EtlQualitySnapshot', N'EtlBatchCleanup',
    N'DatasetQualityProfile', N'ArchiveProfileHistory',
    N'RefreshAnalyticsSummary', N'SnapshotQualityTrend', N'CleanupAnalyticsData',
    N'SyncPlatformLineage', N'ArchiveLineageHistory',
    N'ExpireDatasetCertifications', N'ArchiveGovernanceAudit'));
GO

PRINT 'Governance schema objects created.';
GO
