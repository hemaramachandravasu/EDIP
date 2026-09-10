-- ============================================================
-- 35_Schema_Lineage.sql
-- SQL Lineage, Dependency & Impact Analysis Engine
-- Normalized entity graph, version traceability, relationships,
-- capture audit, and covering indexes for recursive traversal.
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'lineage')
    EXEC(N'CREATE SCHEMA lineage AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Entity type catalog
-- ------------------------------------------------------------
IF OBJECT_ID(N'lineage.EntityType', N'U') IS NULL
BEGIN
    CREATE TABLE lineage.EntityType
    (
        EntityTypeCode  NVARCHAR(32)  NOT NULL CONSTRAINT PK_EntityType PRIMARY KEY,
        DisplayName     NVARCHAR(100) NOT NULL,
        Description     NVARCHAR(500) NULL,
        SortOrder       INT           NOT NULL CONSTRAINT DF_EntityType_Sort DEFAULT (0)
    );
END
GO

MERGE lineage.EntityType AS t
USING (VALUES
    (N'DataSource',         N'Data Source',          N'Registered external or file source', 10),
    (N'Dataset',            N'Dataset',              N'Ingest dataset catalog entry', 20),
    (N'DatasetVersion',     N'Dataset Version',      N'Immutable dataset version produced by import/ETL', 30),
    (N'Import',             N'Import Batch',         N'Import batch / load event', 40),
    (N'Transformation',     N'Transformation',       N'ETL transform or pipeline step', 50),
    (N'QualityProfileRun',  N'Quality Profile Run',  N'Dataset quality profiling execution', 60),
    (N'AnalyticsAsset',     N'Analytics Asset',      N'Dashboard / aggregated reporting asset', 70),
    (N'Report',             N'Report',               N'Named reporting procedure or view', 80)
) AS s (EntityTypeCode, DisplayName, Description, SortOrder)
ON t.EntityTypeCode = s.EntityTypeCode
WHEN MATCHED THEN UPDATE SET
    DisplayName = s.DisplayName, Description = s.Description, SortOrder = s.SortOrder
WHEN NOT MATCHED THEN
    INSERT (EntityTypeCode, DisplayName, Description, SortOrder)
    VALUES (s.EntityTypeCode, s.DisplayName, s.Description, s.SortOrder);
GO

-- ------------------------------------------------------------
-- Canonical lineage entity registry (polymorphic graph nodes)
-- ------------------------------------------------------------
IF OBJECT_ID(N'lineage.LineageEntity', N'U') IS NULL
BEGIN
    CREATE TABLE lineage.LineageEntity
    (
        EntityId        UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_LineageEntity PRIMARY KEY
                        CONSTRAINT DF_LineageEntity_Id DEFAULT NEWSEQUENTIALID(),
        EntityTypeCode  NVARCHAR(32)     NOT NULL,
        ExternalKey     UNIQUEIDENTIFIER NULL,          -- source-table PK when applicable
        EntityCode      NVARCHAR(128)    NOT NULL,
        DisplayName     NVARCHAR(200)    NOT NULL,
        WorkspaceId     UNIQUEIDENTIFIER NULL,
        DatasetId       UNIQUEIDENTIFIER NULL,          -- owning dataset when relevant
        VersionNumber   INT              NULL,
        MetadataJson    NVARCHAR(MAX)    NULL,
        IsActive        BIT              NOT NULL CONSTRAINT DF_LineageEntity_Active DEFAULT (1),
        CreatedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_LineageEntity_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_LineageEntity_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_LineageEntity_Type FOREIGN KEY (EntityTypeCode)
            REFERENCES lineage.EntityType (EntityTypeCode),
        CONSTRAINT FK_LineageEntity_Workspace FOREIGN KEY (WorkspaceId)
            REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_LineageEntity_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId)
    );

    CREATE UNIQUE INDEX UX_LineageEntity_Type_External
        ON lineage.LineageEntity (EntityTypeCode, ExternalKey)
        WHERE ExternalKey IS NOT NULL;

    CREATE UNIQUE INDEX UX_LineageEntity_Type_Code_Ws
        ON lineage.LineageEntity (EntityTypeCode, EntityCode, WorkspaceId);

    CREATE INDEX IX_LineageEntity_Workspace_Type
        ON lineage.LineageEntity (WorkspaceId, EntityTypeCode)
        INCLUDE (EntityCode, DisplayName, DatasetId, VersionNumber, IsActive);

    CREATE INDEX IX_LineageEntity_Dataset
        ON lineage.LineageEntity (DatasetId, EntityTypeCode)
        INCLUDE (EntityCode, VersionNumber, WorkspaceId)
        WHERE DatasetId IS NOT NULL;
END
GO

-- ------------------------------------------------------------
-- Dataset version traceability (historical, never overwritten)
-- ------------------------------------------------------------
IF OBJECT_ID(N'lineage.DatasetVersion', N'U') IS NULL
BEGIN
    CREATE TABLE lineage.DatasetVersion
    (
        DatasetVersionId UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DatasetVersion PRIMARY KEY
                         CONSTRAINT DF_DatasetVersion_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        VersionNumber    INT              NOT NULL,
        EntityId         UNIQUEIDENTIFIER NOT NULL,   -- lineage.LineageEntity of type DatasetVersion
        WorkspaceId      UNIQUEIDENTIFIER NULL,
        ImportBatchId    UNIQUEIDENTIFIER NULL,
        ImportId         UNIQUEIDENTIFIER NULL,
        EtlRunId         UNIQUEIDENTIFIER NULL,
        ProfileRunId     UNIQUEIDENTIFIER NULL,
        DataSourceId     UNIQUEIDENTIFIER NULL,
        ProducedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetVersion_Produced DEFAULT SYSUTCDATETIME(),
        ProducedBy       NVARCHAR(128)    NOT NULL CONSTRAINT DF_DatasetVersion_By DEFAULT N'system',
        Notes            NVARCHAR(1000)   NULL,
        CreatedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetVersion_Created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DatasetVersion_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_DatasetVersion_Entity FOREIGN KEY (EntityId)
            REFERENCES lineage.LineageEntity (EntityId),
        CONSTRAINT FK_DatasetVersion_Workspace FOREIGN KEY (WorkspaceId)
            REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_DatasetVersion_Batch FOREIGN KEY (ImportBatchId)
            REFERENCES ingest.ImportBatch (BatchId),
        CONSTRAINT FK_DatasetVersion_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_DatasetVersion_Number CHECK (VersionNumber >= 1)
    );

    CREATE UNIQUE INDEX UX_DatasetVersion_Dataset_Number
        ON lineage.DatasetVersion (DatasetId, VersionNumber);

    CREATE UNIQUE INDEX UX_DatasetVersion_Entity
        ON lineage.DatasetVersion (EntityId);

    CREATE INDEX IX_DatasetVersion_Workspace
        ON lineage.DatasetVersion (WorkspaceId, ProducedUtc DESC)
        INCLUDE (DatasetId, VersionNumber, ImportBatchId, EtlRunId);

    CREATE INDEX IX_DatasetVersion_Import
        ON lineage.DatasetVersion (ImportBatchId)
        WHERE ImportBatchId IS NOT NULL;

    CREATE INDEX IX_DatasetVersion_ImportId
        ON lineage.DatasetVersion (ImportId)
        WHERE ImportId IS NOT NULL;
END
GO

-- ------------------------------------------------------------
-- Directed lineage relationships (edges)
-- SourceEntity --[RelationshipType]--> TargetEntity
-- ------------------------------------------------------------
IF OBJECT_ID(N'lineage.LineageRelationship', N'U') IS NULL
BEGIN
    CREATE TABLE lineage.LineageRelationship
    (
        RelationshipId     UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_LineageRelationship PRIMARY KEY
                           CONSTRAINT DF_LineageRel_Id DEFAULT NEWSEQUENTIALID(),
        SourceEntityId     UNIQUEIDENTIFIER NOT NULL,
        TargetEntityId     UNIQUEIDENTIFIER NOT NULL,
        RelationshipType   NVARCHAR(64)     NOT NULL,
        WorkspaceId        UNIQUEIDENTIFIER NULL,
        SourceVersionId    UNIQUEIDENTIFIER NULL,   -- lineage.DatasetVersion
        TargetVersionId    UNIQUEIDENTIFIER NULL,
        ProcessReference   NVARCHAR(64)     NULL,   -- ImportId / RunId / ProfileRunId text
        ProcessType        NVARCHAR(32)     NULL,   -- Import / Etl / Profile / Analytics / Manual
        IsActive           BIT              NOT NULL CONSTRAINT DF_LineageRel_Active DEFAULT (1),
        CreatedUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_LineageRel_Created DEFAULT SYSUTCDATETIME(),
        CreatedBy          NVARCHAR(128)    NOT NULL CONSTRAINT DF_LineageRel_CreatedBy DEFAULT N'system',
        ModifiedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_LineageRel_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_LineageRel_Source FOREIGN KEY (SourceEntityId)
            REFERENCES lineage.LineageEntity (EntityId),
        CONSTRAINT FK_LineageRel_Target FOREIGN KEY (TargetEntityId)
            REFERENCES lineage.LineageEntity (EntityId),
        CONSTRAINT FK_LineageRel_Workspace FOREIGN KEY (WorkspaceId)
            REFERENCES analytics.Workspace (WorkspaceId),
        CONSTRAINT FK_LineageRel_SourceVer FOREIGN KEY (SourceVersionId)
            REFERENCES lineage.DatasetVersion (DatasetVersionId),
        CONSTRAINT FK_LineageRel_TargetVer FOREIGN KEY (TargetVersionId)
            REFERENCES lineage.DatasetVersion (DatasetVersionId),
        CONSTRAINT CK_LineageRel_Type CHECK (RelationshipType IN (
            N'Feeds', N'ImportsInto', N'TransformsTo', N'Profiles',
            N'ReportsOn', N'DependsOn', N'DerivedFrom', N'Produces')),
        CONSTRAINT CK_LineageRel_ProcessType CHECK (ProcessType IS NULL OR ProcessType IN (
            N'Import', N'Etl', N'Profile', N'Analytics', N'Manual', N'Sync')),
        CONSTRAINT CK_LineageRel_NotSelf CHECK (SourceEntityId <> TargetEntityId)
    );

    -- Prevent duplicate active edges (same ends + type + version context + process ref)
    CREATE UNIQUE INDEX UX_LineageRel_UniqueEdge
        ON lineage.LineageRelationship (
            SourceEntityId, TargetEntityId, RelationshipType,
            SourceVersionId, TargetVersionId, ProcessReference)
        WHERE IsActive = 1;

    -- Traversal: walk upstream (incoming to node) and downstream (outgoing from node)
    CREATE INDEX IX_LineageRel_Source_Active
        ON lineage.LineageRelationship (SourceEntityId, IsActive)
        INCLUDE (TargetEntityId, RelationshipType, WorkspaceId, SourceVersionId, TargetVersionId, ProcessType);

    CREATE INDEX IX_LineageRel_Target_Active
        ON lineage.LineageRelationship (TargetEntityId, IsActive)
        INCLUDE (SourceEntityId, RelationshipType, WorkspaceId, SourceVersionId, TargetVersionId, ProcessType);

    CREATE INDEX IX_LineageRel_Workspace_Type
        ON lineage.LineageRelationship (WorkspaceId, RelationshipType, IsActive)
        INCLUDE (SourceEntityId, TargetEntityId);

    CREATE INDEX IX_LineageRel_Type
        ON lineage.LineageRelationship (RelationshipType, IsActive)
        INCLUDE (SourceEntityId, TargetEntityId, WorkspaceId);
END
GO

-- ------------------------------------------------------------
-- Capture / sync audit
-- ------------------------------------------------------------
IF OBJECT_ID(N'lineage.LineageCaptureLog', N'U') IS NULL
BEGIN
    CREATE TABLE lineage.LineageCaptureLog
    (
        CaptureLogId   BIGINT           NOT NULL IDENTITY(1,1)
                       CONSTRAINT PK_LineageCaptureLog PRIMARY KEY,
        CaptureType    NVARCHAR(64)     NOT NULL,
        Status         NVARCHAR(16)     NOT NULL CONSTRAINT DF_LineageCapture_Status DEFAULT N'Succeeded',
        RelationshipsAdded INT          NOT NULL CONSTRAINT DF_LineageCapture_Added DEFAULT (0),
        EntitiesAdded  INT              NOT NULL CONSTRAINT DF_LineageCapture_Ent DEFAULT (0),
        Message        NVARCHAR(2000)   NULL,
        StartedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_LineageCapture_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc   DATETIME2(3)     NULL,
        CONSTRAINT CK_LineageCapture_Status CHECK (Status IN (N'Succeeded', N'Failed', N'Partial'))
    );

    CREATE INDEX IX_LineageCapture_Started
        ON lineage.LineageCaptureLog (StartedUtc DESC)
        INCLUDE (CaptureType, Status, RelationshipsAdded);
END
GO

-- ------------------------------------------------------------
-- Extend job types for scheduled lineage sync
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
    N'SyncPlatformLineage', N'ArchiveLineageHistory'));
GO

PRINT 'Lineage schema objects created.';
GO
