-- ============================================================
-- 20_Schema_Etl.sql
-- Extends ingest staging for ETL; configurable transform/validation
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'etl')
    EXEC(N'CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Extend ingest.Dataset with ETL defaults
-- ------------------------------------------------------------
IF COL_LENGTH(N'ingest.Dataset', N'KeyColumn') IS NULL
    ALTER TABLE ingest.Dataset ADD KeyColumn NVARCHAR(128) NOT NULL CONSTRAINT DF_Dataset_Key DEFAULT (N'CustomerCode');
GO
IF COL_LENGTH(N'ingest.Dataset', N'DefaultLoadMode') IS NULL
    ALTER TABLE ingest.Dataset ADD DefaultLoadMode NVARCHAR(16) NOT NULL CONSTRAINT DF_Dataset_LoadMode DEFAULT (N'Incremental');
GO
IF COL_LENGTH(N'ingest.Dataset', N'DefaultDuplicateStrategy') IS NULL
    ALTER TABLE ingest.Dataset ADD DefaultDuplicateStrategy NVARCHAR(16) NOT NULL CONSTRAINT DF_Dataset_Dup DEFAULT (N'Update');
GO
IF COL_LENGTH(N'ingest.Dataset', N'MaxRetries') IS NULL
    ALTER TABLE ingest.Dataset ADD MaxRetries INT NOT NULL CONSTRAINT DF_Dataset_MaxRetries DEFAULT (3);
GO

-- ------------------------------------------------------------
-- Extend ingest.ImportBatch for ETL tracing and metrics
-- ------------------------------------------------------------
IF COL_LENGTH(N'ingest.ImportBatch', N'ImportId') IS NULL
    ALTER TABLE ingest.ImportBatch ADD ImportId UNIQUEIDENTIFIER NOT NULL CONSTRAINT DF_ImportBatch_ImportId DEFAULT NEWID();
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'SourceFile') IS NULL
    ALTER TABLE ingest.ImportBatch ADD SourceFile NVARCHAR(500) NULL;
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'LoadMode') IS NULL
    ALTER TABLE ingest.ImportBatch ADD LoadMode NVARCHAR(16) NOT NULL CONSTRAINT DF_ImportBatch_LoadMode DEFAULT (N'Incremental');
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'DuplicateStrategy') IS NULL
    ALTER TABLE ingest.ImportBatch ADD DuplicateStrategy NVARCHAR(16) NOT NULL CONSTRAINT DF_ImportBatch_Dup DEFAULT (N'Update');
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'TransformedRecords') IS NULL
    ALTER TABLE ingest.ImportBatch ADD TransformedRecords INT NOT NULL CONSTRAINT DF_ImportBatch_Xform DEFAULT (0);
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'DuplicateRecords') IS NULL
    ALTER TABLE ingest.ImportBatch ADD DuplicateRecords INT NOT NULL CONSTRAINT DF_ImportBatch_DupCnt DEFAULT (0);
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'DurationMs') IS NULL
    ALTER TABLE ingest.ImportBatch ADD DurationMs INT NULL;
GO
IF COL_LENGTH(N'ingest.ImportBatch', N'MaxRetries') IS NULL
    ALTER TABLE ingest.ImportBatch ADD MaxRetries INT NOT NULL CONSTRAINT DF_ImportBatch_MaxRetry DEFAULT (3);
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ImportBatch_Status')
    ALTER TABLE ingest.ImportBatch DROP CONSTRAINT CK_ImportBatch_Status;
GO
ALTER TABLE ingest.ImportBatch WITH CHECK ADD CONSTRAINT CK_ImportBatch_Status CHECK (Status IN (
    N'Pending', N'Loaded', N'Transforming', N'Transformed', N'Validating', N'Validated',
    N'Processing', N'Completed', N'CompletedWithErrors', N'Failed', N'RetryPending', N'Exhausted'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ImportBatch_LoadMode')
    ALTER TABLE ingest.ImportBatch WITH CHECK ADD CONSTRAINT CK_ImportBatch_LoadMode
        CHECK (LoadMode IN (N'Incremental', N'Full'));
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ImportBatch_DupStrategy')
    ALTER TABLE ingest.ImportBatch WITH CHECK ADD CONSTRAINT CK_ImportBatch_DupStrategy
        CHECK (DuplicateStrategy IN (N'Skip', N'Update', N'Reject'));
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ImportBatch_ImportId')
    CREATE INDEX IX_ImportBatch_ImportId ON ingest.ImportBatch (ImportId);
GO

-- ------------------------------------------------------------
-- Extend staging with ImportId / SourceFile / transform flags
-- ------------------------------------------------------------
IF COL_LENGTH(N'ingest.StagingCustomer', N'ImportId') IS NULL
    ALTER TABLE ingest.StagingCustomer ADD ImportId UNIQUEIDENTIFIER NULL;
GO
IF COL_LENGTH(N'ingest.StagingCustomer', N'SourceFile') IS NULL
    ALTER TABLE ingest.StagingCustomer ADD SourceFile NVARCHAR(500) NULL;
GO
IF COL_LENGTH(N'ingest.StagingCustomer', N'IsTransformed') IS NULL
    ALTER TABLE ingest.StagingCustomer ADD IsTransformed BIT NOT NULL CONSTRAINT DF_StagingCust_Xform DEFAULT (0);
GO
IF COL_LENGTH(N'ingest.StagingCustomer', N'IsDuplicateVsTarget') IS NULL
    ALTER TABLE ingest.StagingCustomer ADD IsDuplicateVsTarget BIT NOT NULL CONSTRAINT DF_StagingCust_DupTgt DEFAULT (0);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_StagingCust_ImportId')
    CREATE INDEX IX_StagingCust_ImportId ON ingest.StagingCustomer (ImportId, RowNumber)
        WHERE ImportId IS NOT NULL;
GO

-- ------------------------------------------------------------
-- Dataset ETL configuration
-- ------------------------------------------------------------
IF OBJECT_ID(N'etl.DatasetConfig', N'U') IS NULL
BEGIN
    CREATE TABLE etl.DatasetConfig
    (
        DatasetId          UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_EtlDatasetConfig PRIMARY KEY,
        KeyColumn          NVARCHAR(128)    NOT NULL CONSTRAINT DF_EtlCfg_Key DEFAULT (N'CustomerCode'),
        LoadMode           NVARCHAR(16)     NOT NULL CONSTRAINT DF_EtlCfg_Load DEFAULT (N'Incremental'),
        DuplicateStrategy  NVARCHAR(16)     NOT NULL CONSTRAINT DF_EtlCfg_Dup DEFAULT (N'Update'),
        MaxRetries         INT              NOT NULL CONSTRAINT DF_EtlCfg_Retry DEFAULT (3),
        IsEnabled          BIT              NOT NULL CONSTRAINT DF_EtlCfg_Enabled DEFAULT (1),
        CONSTRAINT FK_EtlCfg_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_EtlCfg_Load CHECK (LoadMode IN (N'Incremental', N'Full')),
        CONSTRAINT CK_EtlCfg_Dup CHECK (DuplicateStrategy IN (N'Skip', N'Update', N'Reject')),
        CONSTRAINT CK_EtlCfg_Retry CHECK (MaxRetries >= 0 AND MaxRetries <= 20)
    );
END
GO

-- ------------------------------------------------------------
-- Reusable transformation rules
-- ------------------------------------------------------------
IF OBJECT_ID(N'etl.TransformRule', N'U') IS NULL
BEGIN
    CREATE TABLE etl.TransformRule
    (
        TransformRuleId  INT            NOT NULL IDENTITY(1,1) CONSTRAINT PK_TransformRule PRIMARY KEY,
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        ColumnName       NVARCHAR(128)  NOT NULL,
        StepOrder        INT            NOT NULL CONSTRAINT DF_Xform_Step DEFAULT (1),
        TransformType    NVARCHAR(32)   NOT NULL,
        Param1           NVARCHAR(200)  NULL,
        Param2           NVARCHAR(200)  NULL,
        IsActive         BIT            NOT NULL CONSTRAINT DF_Xform_Active DEFAULT (1),
        CONSTRAINT FK_Xform_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_Xform_Type CHECK (TransformType IN (
            N'Trim', N'Upper', N'Lower', N'NullDefault', N'Replace',
            N'Standardize', N'DateNormalize', N'NumericNormalize'))
    );
    CREATE INDEX IX_TransformRule_Dataset ON etl.TransformRule (DatasetId, StepOrder)
        INCLUDE (ColumnName, TransformType) WHERE IsActive = 1;
END
GO

IF OBJECT_ID(N'etl.StandardizationMap', N'U') IS NULL
BEGIN
    CREATE TABLE etl.StandardizationMap
    (
        MapId        INT              NOT NULL IDENTITY(1,1) CONSTRAINT PK_StandardizationMap PRIMARY KEY,
        DatasetId    UNIQUEIDENTIFIER NOT NULL,
        ColumnName   NVARCHAR(128)    NOT NULL,
        SourceValue  NVARCHAR(100)    NOT NULL,
        TargetValue  NVARCHAR(100)    NOT NULL,
        CONSTRAINT FK_StdMap_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );
    CREATE UNIQUE INDEX UX_StdMap ON etl.StandardizationMap (DatasetId, ColumnName, SourceValue);
END
GO

-- ------------------------------------------------------------
-- Configurable validation rules
-- ------------------------------------------------------------
IF OBJECT_ID(N'etl.ValidationRule', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ValidationRule
    (
        ValidationRuleId INT              NOT NULL IDENTITY(1,1) CONSTRAINT PK_ValidationRule PRIMARY KEY,
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        ColumnName       NVARCHAR(128)    NOT NULL,
        RuleType         NVARCHAR(32)     NOT NULL,
        Param1           NVARCHAR(200)    NULL,
        Param2           NVARCHAR(200)    NULL,
        ErrorCode        NVARCHAR(64)     NOT NULL,
        ErrorMessage     NVARCHAR(500)    NOT NULL,
        Severity         NVARCHAR(16)     NOT NULL CONSTRAINT DF_ValRule_Sev DEFAULT (N'Error'),
        IsActive         BIT              NOT NULL CONSTRAINT DF_ValRule_Active DEFAULT (1),
        CONSTRAINT FK_ValRule_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_ValRule_Type CHECK (RuleType IN (
            N'Required', N'DataType', N'MinLength', N'MaxLength',
            N'MinValue', N'MaxValue', N'DateMin', N'DateMax',
            N'AllowedValues', N'Referential', N'Regex')),
        CONSTRAINT CK_ValRule_Sev CHECK (Severity IN (N'Error', N'Warning'))
    );
    CREATE INDEX IX_ValidationRule_Dataset ON etl.ValidationRule (DatasetId)
        INCLUDE (ColumnName, RuleType) WHERE IsActive = 1;
END
GO

IF OBJECT_ID(N'etl.AllowedValue', N'U') IS NULL
BEGIN
    CREATE TABLE etl.AllowedValue
    (
        AllowedValueId INT              NOT NULL IDENTITY(1,1) CONSTRAINT PK_AllowedValue PRIMARY KEY,
        DatasetId      UNIQUEIDENTIFIER NOT NULL,
        ColumnName     NVARCHAR(128)    NOT NULL,
        AllowedValue   NVARCHAR(100)    NOT NULL,
        CONSTRAINT FK_Allowed_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );
    CREATE UNIQUE INDEX UX_AllowedValue ON etl.AllowedValue (DatasetId, ColumnName, AllowedValue);
END
GO

IF OBJECT_ID(N'etl.ReferentialRule', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ReferentialRule
    (
        ReferentialRuleId INT              NOT NULL IDENTITY(1,1) CONSTRAINT PK_ReferentialRule PRIMARY KEY,
        DatasetId         UNIQUEIDENTIFIER NOT NULL,
        ColumnName        NVARCHAR(128)    NOT NULL,
        RefSchema         NVARCHAR(128)    NOT NULL,
        RefTable          NVARCHAR(128)    NOT NULL,
        RefColumn         NVARCHAR(128)    NOT NULL,
        CONSTRAINT FK_RefRule_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );
END
GO

-- ------------------------------------------------------------
-- ETL run + dedicated error structure
-- ------------------------------------------------------------
IF OBJECT_ID(N'etl.EtlRun', N'U') IS NULL
BEGIN
    CREATE TABLE etl.EtlRun
    (
        RunId              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_EtlRun PRIMARY KEY
                           CONSTRAINT DF_EtlRun_Id DEFAULT NEWSEQUENTIALID(),
        BatchId            UNIQUEIDENTIFIER NOT NULL,
        DatasetId          UNIQUEIDENTIFIER NOT NULL,
        ImportId           UNIQUEIDENTIFIER NOT NULL,
        TriggerType        NVARCHAR(16)     NOT NULL CONSTRAINT DF_EtlRun_Trigger DEFAULT (N'Manual'),
        Status             NVARCHAR(32)     NOT NULL,
        AttemptNumber      INT              NOT NULL CONSTRAINT DF_EtlRun_Attempt DEFAULT (1),
        StartedUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_EtlRun_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc       DATETIME2(3)     NULL,
        DurationMs         INT              NULL,
        TotalRecords       INT              NOT NULL CONSTRAINT DF_EtlRun_Total DEFAULT (0),
        TransformedRecords INT              NOT NULL CONSTRAINT DF_EtlRun_Xform DEFAULT (0),
        ValidRecords       INT              NOT NULL CONSTRAINT DF_EtlRun_Valid DEFAULT (0),
        InvalidRecords     INT              NOT NULL CONSTRAINT DF_EtlRun_Invalid DEFAULT (0),
        DuplicateRecords   INT              NOT NULL CONSTRAINT DF_EtlRun_Dup DEFAULT (0),
        InsertedRecords    INT              NOT NULL CONSTRAINT DF_EtlRun_Ins DEFAULT (0),
        UpdatedRecords     INT              NOT NULL CONSTRAINT DF_EtlRun_Upd DEFAULT (0),
        SkippedRecords     INT              NOT NULL CONSTRAINT DF_EtlRun_Skip DEFAULT (0),
        ProcessingErrors   INT              NOT NULL CONSTRAINT DF_EtlRun_Err DEFAULT (0),
        ErrorMessage       NVARCHAR(2000)   NULL,
        CONSTRAINT FK_EtlRun_Batch FOREIGN KEY (BatchId) REFERENCES ingest.ImportBatch (BatchId) ON DELETE CASCADE,
        CONSTRAINT FK_EtlRun_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_EtlRun_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry', N'Api')),
        CONSTRAINT CK_EtlRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Partial', N'Failed', N'RolledBack'))
    );
    CREATE INDEX IX_EtlRun_Batch ON etl.EtlRun (BatchId, StartedUtc DESC);
    CREATE INDEX IX_EtlRun_Dataset ON etl.EtlRun (DatasetId, StartedUtc DESC);
    CREATE INDEX IX_EtlRun_Status ON etl.EtlRun (Status, StartedUtc DESC);
END
GO

IF OBJECT_ID(N'etl.EtlError', N'U') IS NULL
BEGIN
    CREATE TABLE etl.EtlError
    (
        ErrorId          BIGINT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_EtlError PRIMARY KEY,
        RunId            UNIQUEIDENTIFIER NULL,
        BatchId          UNIQUEIDENTIFIER NOT NULL,
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        ImportId         UNIQUEIDENTIFIER NULL,
        StagingRowId     BIGINT           NULL,
        RowNumber        INT              NULL,
        ColumnName       NVARCHAR(128)    NULL,
        InvalidValue     NVARCHAR(500)    NULL,
        ErrorCode        NVARCHAR(64)     NOT NULL,
        ErrorDescription NVARCHAR(1000)   NOT NULL,
        Phase            NVARCHAR(16)     NOT NULL,
        Severity         NVARCHAR(16)     NOT NULL CONSTRAINT DF_EtlError_Sev DEFAULT (N'Error'),
        ErrorUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_EtlError_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_EtlError_Batch FOREIGN KEY (BatchId)
            REFERENCES ingest.ImportBatch (BatchId) ON DELETE CASCADE,
        CONSTRAINT FK_EtlError_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_EtlError_Phase CHECK (Phase IN (N'Transform', N'Validate', N'Load', N'Retry')),
        CONSTRAINT CK_EtlError_Sev CHECK (Severity IN (N'Error', N'Warning', N'Info'))
    );
    CREATE INDEX IX_EtlError_Batch ON etl.EtlError (BatchId, ErrorUtc);
    CREATE INDEX IX_EtlError_Dataset ON etl.EtlError (DatasetId, ErrorUtc DESC);
    CREATE INDEX IX_EtlError_Code ON etl.EtlError (ErrorCode, ErrorUtc DESC);
END
GO

IF OBJECT_ID(N'etl.EtlErrorArchive', N'U') IS NULL
BEGIN
    CREATE TABLE etl.EtlErrorArchive
    (
        ErrorId          BIGINT           NOT NULL,
        RunId            UNIQUEIDENTIFIER NULL,
        BatchId          UNIQUEIDENTIFIER NOT NULL,
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        ImportId         UNIQUEIDENTIFIER NULL,
        StagingRowId     BIGINT           NULL,
        RowNumber        INT              NULL,
        ColumnName       NVARCHAR(128)    NULL,
        InvalidValue     NVARCHAR(500)    NULL,
        ErrorCode        NVARCHAR(64)     NOT NULL,
        ErrorDescription NVARCHAR(1000)   NOT NULL,
        Phase            NVARCHAR(16)     NOT NULL,
        Severity         NVARCHAR(16)     NOT NULL,
        ErrorUtc         DATETIME2(3)     NOT NULL,
        ArchivedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_EtlErrArch_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_EtlErrorArchive PRIMARY KEY (ErrorId, ArchivedUtc)
    );
    CREATE INDEX IX_EtlErrArch_Utc ON etl.EtlErrorArchive (ErrorUtc);
END
GO

IF OBJECT_ID(N'etl.QualitySnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE etl.QualitySnapshot
    (
        SnapshotId         BIGINT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_QualitySnapshot PRIMARY KEY,
        DatasetId          UNIQUEIDENTIFIER NOT NULL,
        SnapshotUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_QSnap_Utc DEFAULT SYSUTCDATETIME(),
        BatchCount30d      INT              NOT NULL,
        TotalRecords30d    INT              NOT NULL,
        ValidRecords30d    INT              NOT NULL,
        InvalidRecords30d  INT              NOT NULL,
        SuccessRatePct     DECIMAL(9,2)     NOT NULL,
        AvgDurationMs      INT              NULL,
        CONSTRAINT FK_QSnap_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );
    CREATE INDEX IX_QSnap_Dataset ON etl.QualitySnapshot (DatasetId, SnapshotUtc DESC);
END
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Job_Type')
    ALTER TABLE jobs.ProcessingJob DROP CONSTRAINT CK_Job_Type;
GO

ALTER TABLE jobs.ProcessingJob WITH CHECK ADD CONSTRAINT CK_Job_Type CHECK (JobType IN (
    N'MetadataRefresh', N'HealthCheck', N'SampleExtract',
    N'DataProfiling', N'QualityAssessment', N'MetadataSync', N'ArchiveProfilingHistory',
    N'ProcessPendingImports', N'ArchiveImportHistory',
    N'EtlProcessPending', N'EtlArchiveErrors', N'EtlQualitySnapshot', N'EtlBatchCleanup'));
GO

PRINT 'ETL schema objects created.';
GO
