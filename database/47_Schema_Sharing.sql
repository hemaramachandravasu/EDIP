-- ============================================================
-- 47_Schema_Sharing.sql
-- Data Sharing, Export & Secure Delivery Engine
-- Dataset shares (+ history), export requests (narrow header +
-- separate spec payload), status transitions, downloads, export
-- policy per classification, and exportable-column whitelist.
-- Reuses ingest.Dataset, analytics.Workspace, gov.AppUser,
-- gov.WorkspaceMember, gov.AccessLevel, gov.DatasetAccessGrant,
-- lineage.DatasetVersion and gov.GovernanceAuditEvent.
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'share')
    EXEC(N'CREATE SCHEMA share AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Reference: export formats
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportFormat', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportFormat
    (
        FormatCode   NVARCHAR(16)  NOT NULL CONSTRAINT PK_ExportFormat PRIMARY KEY,
        DisplayName  NVARCHAR(100) NOT NULL,
        MimeType     NVARCHAR(128) NOT NULL,
        FileExtension NVARCHAR(16) NOT NULL,
        IsActive     BIT           NOT NULL CONSTRAINT DF_ExportFormat_Active DEFAULT (1)
    );
END
GO

MERGE share.ExportFormat AS t
USING (VALUES
    (N'Csv',     N'CSV',          N'text/csv',                                                          N'.csv'),
    (N'Xlsx',    N'Excel',        N'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', N'.xlsx'),
    (N'Json',    N'JSON',         N'application/json',                                                  N'.json'),
    (N'Parquet', N'Parquet',      N'application/vnd.apache.parquet',                                    N'.parquet')
) AS s (FormatCode, DisplayName, MimeType, FileExtension)
ON t.FormatCode = s.FormatCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, MimeType = s.MimeType,
    FileExtension = s.FileExtension, IsActive = 1
WHEN NOT MATCHED THEN INSERT (FormatCode, DisplayName, MimeType, FileExtension)
    VALUES (s.FormatCode, s.DisplayName, s.MimeType, s.FileExtension);
GO

-- ------------------------------------------------------------
-- Reference: export status + allowed transitions
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportStatus', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportStatus
    (
        StatusCode  NVARCHAR(16)  NOT NULL CONSTRAINT PK_ExportStatus PRIMARY KEY,
        DisplayName NVARCHAR(100) NOT NULL,
        IsTerminal  BIT           NOT NULL
    );
END
GO

MERGE share.ExportStatus AS t
USING (VALUES
    (N'Pending',    N'Pending',    0),
    (N'Processing', N'Processing', 0),
    (N'Completed',  N'Completed',  1),
    (N'Failed',     N'Failed',     0),
    (N'Cancelled',  N'Cancelled',  1)
) AS s (StatusCode, DisplayName, IsTerminal)
ON t.StatusCode = s.StatusCode
WHEN MATCHED THEN UPDATE SET DisplayName = s.DisplayName, IsTerminal = s.IsTerminal
WHEN NOT MATCHED THEN INSERT (StatusCode, DisplayName, IsTerminal)
    VALUES (s.StatusCode, s.DisplayName, s.IsTerminal);
GO

IF OBJECT_ID(N'share.ExportStatusTransition', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportStatusTransition
    (
        FromStatus NVARCHAR(16) NOT NULL,
        ToStatus   NVARCHAR(16) NOT NULL,
        CONSTRAINT PK_ExportStatusTransition PRIMARY KEY (FromStatus, ToStatus),
        CONSTRAINT FK_ExportTrans_From FOREIGN KEY (FromStatus) REFERENCES share.ExportStatus (StatusCode),
        CONSTRAINT FK_ExportTrans_To FOREIGN KEY (ToStatus) REFERENCES share.ExportStatus (StatusCode)
    );
END
GO

MERGE share.ExportStatusTransition AS t
USING (VALUES
    (N'Pending',    N'Processing'),
    (N'Pending',    N'Cancelled'),
    (N'Processing', N'Completed'),
    (N'Processing', N'Failed'),
    (N'Processing', N'Cancelled'),
    (N'Failed',     N'Pending')      -- retry
) AS s (FromStatus, ToStatus)
ON t.FromStatus = s.FromStatus AND t.ToStatus = s.ToStatus
WHEN NOT MATCHED THEN INSERT (FromStatus, ToStatus) VALUES (s.FromStatus, s.ToStatus);
GO

-- ------------------------------------------------------------
-- Export policy per classification (configurable, not hard-coded)
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportPolicy', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportPolicy
    (
        ClassificationCode  NVARCHAR(32) NOT NULL CONSTRAINT PK_ExportPolicy PRIMARY KEY,
        MinAccessLevelCode  NVARCHAR(32) NOT NULL,
        RequireCertified    BIT          NOT NULL CONSTRAINT DF_ExportPolicy_Cert DEFAULT (0),
        AllowWorkspaceRoleExport BIT     NOT NULL CONSTRAINT DF_ExportPolicy_WsRole DEFAULT (0),
        ModifiedUtc         DATETIME2(3) NOT NULL CONSTRAINT DF_ExportPolicy_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ExportPolicy_Class FOREIGN KEY (ClassificationCode) REFERENCES gov.Classification (ClassificationCode),
        CONSTRAINT FK_ExportPolicy_Level FOREIGN KEY (MinAccessLevelCode) REFERENCES gov.AccessLevel (AccessLevelCode)
    );
END
GO

MERGE share.ExportPolicy AS t
USING (VALUES
    (N'Public',       N'Read',  0, 1),
    (N'Internal',     N'Read',  0, 1),
    (N'Confidential', N'Write', 1, 0),
    (N'Restricted',   N'Admin', 1, 0)
) AS s (ClassificationCode, MinAccessLevelCode, RequireCertified, AllowWorkspaceRoleExport)
ON t.ClassificationCode = s.ClassificationCode
WHEN NOT MATCHED THEN
    INSERT (ClassificationCode, MinAccessLevelCode, RequireCertified, AllowWorkspaceRoleExport)
    VALUES (s.ClassificationCode, s.MinAccessLevelCode, s.RequireCertified, s.AllowWorkspaceRoleExport);
GO

-- ------------------------------------------------------------
-- Dataset shares (current state)
-- Status is persisted as Active/Revoked/Expired; effective expiry
-- is also computed at read time (see rpt.vw_DatasetShareEffective)
-- so authorization never depends on the expiry job having run.
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.DatasetShare', N'U') IS NULL
BEGIN
    CREATE TABLE share.DatasetShare
    (
        ShareId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DatasetShare PRIMARY KEY
                         CONSTRAINT DF_DatasetShare_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        WorkspaceId      UNIQUEIDENTIFIER NULL,
        RecipientUserId  UNIQUEIDENTIFIER NOT NULL,
        AccessLevelCode  NVARCHAR(32)     NOT NULL,
        SharedByUserId   UNIQUEIDENTIFIER NOT NULL,
        SharedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetShare_Shared DEFAULT SYSUTCDATETIME(),
        ExpiresUtc       DATETIME2(3)     NULL,
        Status           NVARCHAR(16)     NOT NULL CONSTRAINT DF_DatasetShare_Status DEFAULT (N'Active'),
        RevokedByUserId  UNIQUEIDENTIFIER NULL,
        RevokedUtc       DATETIME2(3)     NULL,
        RevokeReason     NVARCHAR(1000)   NULL,
        Notes            NVARCHAR(1000)   NULL,
        ModifiedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetShare_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Share_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_Share_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_Share_Recipient FOREIGN KEY (RecipientUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_Share_SharedBy FOREIGN KEY (SharedByUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_Share_RevokedBy FOREIGN KEY (RevokedByUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_Share_Level FOREIGN KEY (AccessLevelCode) REFERENCES gov.AccessLevel (AccessLevelCode),
        CONSTRAINT CK_Share_Status CHECK (Status IN (N'Active', N'Revoked', N'Expired')),
        CONSTRAINT CK_Share_NotSelf CHECK (RecipientUserId <> SharedByUserId),
        CONSTRAINT CK_Share_Expiry CHECK (ExpiresUtc IS NULL OR ExpiresUtc > SharedUtc),
        CONSTRAINT CK_Share_Revoked CHECK (
            (Status = N'Revoked' AND RevokedUtc IS NOT NULL AND RevokedByUserId IS NOT NULL)
            OR (Status <> N'Revoked'))
    );

    -- One active share per dataset/recipient (access level is updated in place)
    CREATE UNIQUE INDEX UX_Share_ActiveRecipient
        ON share.DatasetShare (DatasetId, RecipientUserId)
        WHERE Status = N'Active';

    -- Authorization lookup: recipient + dataset, active rows only
    CREATE INDEX IX_Share_Recipient_Auth
        ON share.DatasetShare (RecipientUserId, DatasetId, Status)
        INCLUDE (AccessLevelCode, ExpiresUtc);

    CREATE INDEX IX_Share_Workspace_Status
        ON share.DatasetShare (WorkspaceId, Status, SharedUtc DESC)
        INCLUDE (DatasetId, RecipientUserId, AccessLevelCode, ExpiresUtc);

    -- Expiry scan: active shares with an expiry date
    CREATE INDEX IX_Share_Expiry
        ON share.DatasetShare (ExpiresUtc)
        INCLUDE (DatasetId, RecipientUserId, WorkspaceId)
        WHERE Status = N'Active' AND ExpiresUtc IS NOT NULL;

    CREATE INDEX IX_Share_Dataset_Status
        ON share.DatasetShare (DatasetId, Status)
        INCLUDE (RecipientUserId, AccessLevelCode, ExpiresUtc, SharedUtc);

    CREATE INDEX IX_Share_Level
        ON share.DatasetShare (AccessLevelCode, Status);
END
GO

-- ------------------------------------------------------------
-- Share history (append-only)
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.DatasetShareHistory', N'U') IS NULL
BEGIN
    CREATE TABLE share.DatasetShareHistory
    (
        ShareHistoryId    BIGINT           NOT NULL IDENTITY(1,1)
                          CONSTRAINT PK_DatasetShareHistory PRIMARY KEY,
        ShareId           UNIQUEIDENTIFIER NOT NULL,
        DatasetId         UNIQUEIDENTIFIER NOT NULL,
        RecipientUserId   UNIQUEIDENTIFIER NOT NULL,
        Action            NVARCHAR(16)     NOT NULL,
        PreviousStatus    NVARCHAR(16)     NULL,
        NewStatus         NVARCHAR(16)     NOT NULL,
        PreviousAccessLevel NVARCHAR(32)   NULL,
        NewAccessLevel    NVARCHAR(32)     NOT NULL,
        PreviousExpiresUtc DATETIME2(3)    NULL,
        NewExpiresUtc     DATETIME2(3)     NULL,
        ActorUserId       UNIQUEIDENTIFIER NULL,
        ActionUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_ShareHist_Action DEFAULT SYSUTCDATETIME(),
        Comments          NVARCHAR(1000)   NULL,
        CONSTRAINT FK_ShareHist_Share FOREIGN KEY (ShareId) REFERENCES share.DatasetShare (ShareId),
        CONSTRAINT FK_ShareHist_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_ShareHist_Recipient FOREIGN KEY (RecipientUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_ShareHist_Actor FOREIGN KEY (ActorUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT CK_ShareHist_Action CHECK (Action IN (N'Created', N'Updated', N'Revoked', N'Expired'))
    );

    CREATE INDEX IX_ShareHist_Share ON share.DatasetShareHistory (ShareId, ActionUtc DESC);
    CREATE INDEX IX_ShareHist_Dataset ON share.DatasetShareHistory (DatasetId, ActionUtc DESC)
        INCLUDE (RecipientUserId, Action, NewStatus, NewAccessLevel);
    CREATE INDEX IX_ShareHist_Recipient ON share.DatasetShareHistory (RecipientUserId, ActionUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Exportable column whitelist (drives safe dynamic column selection)
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportableColumn', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportableColumn
    (
        DatasetId     UNIQUEIDENTIFIER NOT NULL,
        ColumnName    SYSNAME          NOT NULL,
        DataTypeName  SYSNAME          NOT NULL,
        SqlTypeDeclaration NVARCHAR(128) NOT NULL,   -- e.g. nvarchar(64), decimal(18,2); used to type filter values
        OrdinalPosition INT            NOT NULL,
        IsKey         BIT              NOT NULL CONSTRAINT DF_ExpCol_Key DEFAULT (0),
        IsFilterable  BIT              NOT NULL CONSTRAINT DF_ExpCol_Filter DEFAULT (1),
        IsSortable    BIT              NOT NULL CONSTRAINT DF_ExpCol_Sort DEFAULT (1),
        IsExportable  BIT              NOT NULL CONSTRAINT DF_ExpCol_Export DEFAULT (1),
        CONSTRAINT PK_ExportableColumn PRIMARY KEY (DatasetId, ColumnName),
        CONSTRAINT FK_ExpCol_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );
END
GO

-- ------------------------------------------------------------
-- Export request header (narrow; large payloads live in ExportRequestSpec)
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportRequest', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportRequest
    (
        ExportRequestId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ExportRequest PRIMARY KEY
                          CONSTRAINT DF_ExportRequest_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId         UNIQUEIDENTIFIER NOT NULL,
        DatasetVersionId  UNIQUEIDENTIFIER NULL,
        RequestedByUserId UNIQUEIDENTIFIER NOT NULL,
        WorkspaceId       UNIQUEIDENTIFIER NULL,
        FormatCode        NVARCHAR(16)     NOT NULL,
        Status            NVARCHAR(16)     NOT NULL CONSTRAINT DF_ExportRequest_Status DEFAULT (N'Pending'),
        AccessSource      NVARCHAR(32)     NULL,        -- how authorization was satisfied at submit time
        SelectedColumnCount INT            NOT NULL CONSTRAINT DF_ExportRequest_ColCount DEFAULT (0),
        FilterCount       INT              NOT NULL CONSTRAINT DF_ExportRequest_FilterCount DEFAULT (0),
        RequestedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_ExportRequest_Requested DEFAULT SYSUTCDATETIME(),
        StartedUtc        DATETIME2(3)     NULL,
        CompletedUtc      DATETIME2(3)     NULL,
        RecordCount       BIGINT           NULL,
        FileSizeBytes     BIGINT           NULL,
        FileReference     NVARCHAR(500)    NULL,        -- blob/file key, never the file content
        FailureReason     NVARCHAR(2000)   NULL,
        AttemptCount      INT              NOT NULL CONSTRAINT DF_ExportRequest_Attempts DEFAULT (0),
        ModifiedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_ExportRequest_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ExportReq_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_ExportReq_Version FOREIGN KEY (DatasetVersionId) REFERENCES lineage.DatasetVersion (DatasetVersionId),
        CONSTRAINT FK_ExportReq_User FOREIGN KEY (RequestedByUserId) REFERENCES gov.AppUser (UserId),
        CONSTRAINT FK_ExportReq_Workspace FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_ExportReq_Format FOREIGN KEY (FormatCode) REFERENCES share.ExportFormat (FormatCode),
        CONSTRAINT FK_ExportReq_Status FOREIGN KEY (Status) REFERENCES share.ExportStatus (StatusCode),
        CONSTRAINT CK_ExportReq_RecordCount CHECK (RecordCount IS NULL OR RecordCount >= 0),
        CONSTRAINT CK_ExportReq_Dates CHECK (
            (StartedUtc IS NULL OR StartedUtc >= RequestedUtc)
            AND (CompletedUtc IS NULL OR StartedUtc IS NULL OR CompletedUtc >= StartedUtc))
    );

    -- Queue pickup: oldest pending first
    CREATE INDEX IX_ExportReq_Status_Requested
        ON share.ExportRequest (Status, RequestedUtc)
        INCLUDE (DatasetId, RequestedByUserId, FormatCode, WorkspaceId);

    CREATE INDEX IX_ExportReq_User_Requested
        ON share.ExportRequest (RequestedByUserId, RequestedUtc DESC)
        INCLUDE (DatasetId, Status, FormatCode, RecordCount);

    CREATE INDEX IX_ExportReq_Dataset_Requested
        ON share.ExportRequest (DatasetId, RequestedUtc DESC)
        INCLUDE (RequestedByUserId, Status, FormatCode, RecordCount);

    CREATE INDEX IX_ExportReq_Workspace_Requested
        ON share.ExportRequest (WorkspaceId, RequestedUtc DESC)
        INCLUDE (DatasetId, RequestedByUserId, Status, FormatCode);

    CREATE INDEX IX_ExportReq_Format_Requested
        ON share.ExportRequest (FormatCode, RequestedUtc DESC)
        INCLUDE (Status);

    CREATE INDEX IX_ExportReq_Requested
        ON share.ExportRequest (RequestedUtc DESC)
        INCLUDE (Status, FormatCode, DatasetId, RequestedByUserId, RecordCount);
END
GO

-- ------------------------------------------------------------
-- Export spec payload (1:1) — filters/sort/columns as JSON
-- Kept off the header so status/reporting scans stay narrow.
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportRequestSpec', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportRequestSpec
    (
        ExportRequestId     UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ExportRequestSpec PRIMARY KEY,
        SelectedColumnsJson NVARCHAR(4000)   NULL,
        FiltersJson         NVARCHAR(MAX)    NULL,
        SortJson            NVARCHAR(1000)   NULL,
        SpecHash            VARBINARY(32)    NULL,
        CONSTRAINT FK_ExportSpec_Request FOREIGN KEY (ExportRequestId)
            REFERENCES share.ExportRequest (ExportRequestId) ON DELETE CASCADE,
        CONSTRAINT CK_ExportSpec_ColsJson CHECK (SelectedColumnsJson IS NULL OR ISJSON(SelectedColumnsJson) = 1),
        CONSTRAINT CK_ExportSpec_FiltersJson CHECK (FiltersJson IS NULL OR ISJSON(FiltersJson) = 1),
        CONSTRAINT CK_ExportSpec_SortJson CHECK (SortJson IS NULL OR ISJSON(SortJson) = 1)
    );
END
GO

-- ------------------------------------------------------------
-- Export status history (append-only)
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportStatusHistory', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportStatusHistory
    (
        StatusHistoryId  BIGINT           NOT NULL IDENTITY(1,1)
                         CONSTRAINT PK_ExportStatusHistory PRIMARY KEY,
        ExportRequestId  UNIQUEIDENTIFIER NOT NULL,
        PreviousStatus   NVARCHAR(16)     NULL,
        NewStatus        NVARCHAR(16)     NOT NULL,
        ActorUserId      UNIQUEIDENTIFIER NULL,
        ChangedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_ExportStatusHist_Changed DEFAULT SYSUTCDATETIME(),
        Message          NVARCHAR(2000)   NULL,
        CONSTRAINT FK_ExportStatusHist_Request FOREIGN KEY (ExportRequestId) REFERENCES share.ExportRequest (ExportRequestId),
        CONSTRAINT FK_ExportStatusHist_Actor FOREIGN KEY (ActorUserId) REFERENCES gov.AppUser (UserId)
    );

    CREATE INDEX IX_ExportStatusHist_Request ON share.ExportStatusHistory (ExportRequestId, ChangedUtc);
END
GO

-- ------------------------------------------------------------
-- Download log
-- ------------------------------------------------------------
IF OBJECT_ID(N'share.ExportDownload', N'U') IS NULL
BEGIN
    CREATE TABLE share.ExportDownload
    (
        DownloadId        BIGINT           NOT NULL IDENTITY(1,1)
                          CONSTRAINT PK_ExportDownload PRIMARY KEY,
        ExportRequestId   UNIQUEIDENTIFIER NOT NULL,
        DownloadedByUserId UNIQUEIDENTIFIER NOT NULL,
        DownloadedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_ExportDownload_Utc DEFAULT SYSUTCDATETIME(),
        ClientInfo        NVARCHAR(256)    NULL,
        CONSTRAINT FK_ExportDownload_Request FOREIGN KEY (ExportRequestId) REFERENCES share.ExportRequest (ExportRequestId),
        CONSTRAINT FK_ExportDownload_User FOREIGN KEY (DownloadedByUserId) REFERENCES gov.AppUser (UserId)
    );

    CREATE INDEX IX_ExportDownload_Request ON share.ExportDownload (ExportRequestId, DownloadedUtc DESC);
    CREATE INDEX IX_ExportDownload_User ON share.ExportDownload (DownloadedByUserId, DownloadedUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Job types
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
    N'ExpireDatasetCertifications', N'ArchiveGovernanceAudit',
    N'ExpireDatasetShares', N'CleanupStaleExports'));
GO

PRINT 'Sharing/export schema objects created.';
GO
