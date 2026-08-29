-- ============================================================
-- 25_Schema_Profile.sql
-- Dataset quality profiling: runs, columns, metrics, issues, thresholds
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'profile')
    EXEC(N'CREATE SCHEMA profile AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Dataset profile catalog (latest pointer + defaults)
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.DatasetProfile', N'U') IS NULL
BEGIN
    CREATE TABLE profile.DatasetProfile
    (
        DatasetProfileId     UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_DatasetProfile PRIMARY KEY
                             CONSTRAINT DF_DatasetProfile_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId            UNIQUEIDENTIFIER NOT NULL,
        ProfileScope         NVARCHAR(16)     NOT NULL CONSTRAINT DF_DatasetProfile_Scope DEFAULT (N'Processed'),
        LatestProfileRunId   UNIQUEIDENTIFIER NULL,
        LatestOverallScore   DECIMAL(5,2)     NULL,
        LatestThresholdResult NVARCHAR(16)    NULL,
        IsEnabled            BIT              NOT NULL CONSTRAINT DF_DatasetProfile_Enabled DEFAULT (1),
        CreatedUtc           DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetProfile_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc          DATETIME2(3)     NOT NULL CONSTRAINT DF_DatasetProfile_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_DatasetProfile_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_DatasetProfile_Scope CHECK (ProfileScope IN (N'Processed', N'Staging', N'Both')),
        CONSTRAINT UQ_DatasetProfile_Dataset UNIQUE (DatasetId)
    );
END
GO

-- ------------------------------------------------------------
-- Profile run (unique ProfileRunId per execution)
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.ProfileRun', N'U') IS NULL
BEGIN
    CREATE TABLE profile.ProfileRun
    (
        ProfileRunId         UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ProfileRun PRIMARY KEY
                             CONSTRAINT DF_ProfileRun_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId            UNIQUEIDENTIFIER NOT NULL,
        DatasetProfileId     UNIQUEIDENTIFIER NOT NULL,
        ImportId             UNIQUEIDENTIFIER NULL,
        BatchId              UNIQUEIDENTIFIER NULL,
        ProfileScope         NVARCHAR(16)     NOT NULL,
        TriggerType          NVARCHAR(16)     NOT NULL CONSTRAINT DF_ProfileRun_Trigger DEFAULT (N'Manual'),
        Status               NVARCHAR(16)     NOT NULL CONSTRAINT DF_ProfileRun_Status DEFAULT (N'Running'),
        StartedUtc           DATETIME2(3)     NOT NULL CONSTRAINT DF_ProfileRun_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc         DATETIME2(3)     NULL,
        DurationMs           INT              NULL,
        TotalRecords         BIGINT           NOT NULL CONSTRAINT DF_ProfileRun_Total DEFAULT (0),
        ValidRecords         BIGINT           NOT NULL CONSTRAINT DF_ProfileRun_Valid DEFAULT (0),
        InvalidRecords       BIGINT           NOT NULL CONSTRAINT DF_ProfileRun_Invalid DEFAULT (0),
        DuplicateRecords     BIGINT           NOT NULL CONSTRAINT DF_ProfileRun_Dup DEFAULT (0),
        NullCellCount        BIGINT           NOT NULL CONSTRAINT DF_ProfileRun_Null DEFAULT (0),
        CompletenessPct      DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_Comp DEFAULT (0),
        UniquenessPct        DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_Uniq DEFAULT (0),
        ValidityPct          DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_Val DEFAULT (0),
        ConsistencyPct       DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_Cons DEFAULT (0),
        DuplicatePct         DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_DupPct DEFAULT (0),
        ErrorPct             DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ProfileRun_ErrPct DEFAULT (0),
        OverallScore         DECIMAL(5,2)     NOT NULL CONSTRAINT DF_ProfileRun_Score DEFAULT (0),
        Grade                NVARCHAR(8)      NOT NULL CONSTRAINT DF_ProfileRun_Grade DEFAULT (N'F'),
        ThresholdResult      NVARCHAR(16)     NOT NULL CONSTRAINT DF_ProfileRun_Thresh DEFAULT (N'Unknown'),
        ColumnsProfiled      INT              NOT NULL CONSTRAINT DF_ProfileRun_Cols DEFAULT (0),
        IssueCount           INT              NOT NULL CONSTRAINT DF_ProfileRun_Issues DEFAULT (0),
        ErrorMessage         NVARCHAR(2000)   NULL,
        CONSTRAINT FK_ProfileRun_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_ProfileRun_DatasetProfile FOREIGN KEY (DatasetProfileId)
            REFERENCES profile.DatasetProfile (DatasetProfileId),
        CONSTRAINT CK_ProfileRun_Scope CHECK (ProfileScope IN (N'Processed', N'Staging', N'Both')),
        CONSTRAINT CK_ProfileRun_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry', N'Api')),
        CONSTRAINT CK_ProfileRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed')),
        CONSTRAINT CK_ProfileRun_Thresh CHECK (ThresholdResult IN (N'Pass', N'Fail', N'Unknown'))
    );

    CREATE INDEX IX_ProfileRun_Dataset ON profile.ProfileRun (DatasetId, StartedUtc DESC);
    CREATE INDEX IX_ProfileRun_Status ON profile.ProfileRun (Status, StartedUtc DESC);
    CREATE INDEX IX_ProfileRun_Score ON profile.ProfileRun (OverallScore, StartedUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Column-level profile
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.ColumnProfile', N'U') IS NULL
BEGIN
    CREATE TABLE profile.ColumnProfile
    (
        ColumnProfileId      UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ProfileColumn PRIMARY KEY
                             CONSTRAINT DF_ProfileColumn_Id DEFAULT NEWSEQUENTIALID(),
        ProfileRunId         UNIQUEIDENTIFIER NOT NULL,
        ColumnName           NVARCHAR(128)    NOT NULL,
        DataCategory         NVARCHAR(16)     NOT NULL, -- Text | Numeric | Date | Other
        TotalRecords         BIGINT           NOT NULL,
        NonNullRecords       BIGINT           NOT NULL,
        NullRecords          BIGINT           NOT NULL,
        NullPct              DECIMAL(9,4)     NOT NULL,
        CompletenessPct      DECIMAL(9,4)     NOT NULL,
        DistinctCount        BIGINT           NOT NULL,
        DuplicateValueCount  BIGINT           NOT NULL,
        UniquePct            DECIMAL(9,4)     NOT NULL,
        DuplicatePct         DECIMAL(9,4)     NOT NULL,
        MinValue             NVARCHAR(500)    NULL,
        MaxValue             NVARCHAR(500)    NULL,
        AvgValue             DECIMAL(18,6)    NULL,
        MedianValue          DECIMAL(18,6)    NULL,
        StdDevValue          DECIMAL(18,6)    NULL,
        MinLength            INT              NULL,
        MaxLength            INT              NULL,
        AvgLength            DECIMAL(18,4)    NULL,
        MinDate              DATE             NULL,
        MaxDate              DATE             NULL,
        DistinctDateCount    BIGINT           NULL,
        InvalidCount         BIGINT           NOT NULL CONSTRAINT DF_ProfileColumn_Invalid DEFAULT (0),
        CONSTRAINT FK_ProfileColumn_Run FOREIGN KEY (ProfileRunId)
            REFERENCES profile.ProfileRun (ProfileRunId) ON DELETE CASCADE,
        CONSTRAINT CK_ProfileColumn_Cat CHECK (DataCategory IN (N'Text', N'Numeric', N'Date', N'Other'))
    );

    CREATE INDEX IX_ProfileColumn_Run ON profile.ColumnProfile (ProfileRunId, ColumnName);
END
GO

-- ------------------------------------------------------------
-- Named quality metrics (flexible / dashboard-ready)
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.QualityMetric', N'U') IS NULL
BEGIN
    CREATE TABLE profile.QualityMetric
    (
        QualityMetricId      BIGINT           NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_QualityMetric PRIMARY KEY,
        ProfileRunId         UNIQUEIDENTIFIER NOT NULL,
        MetricCode           NVARCHAR(64)     NOT NULL,
        MetricName           NVARCHAR(200)    NOT NULL,
        MetricScope          NVARCHAR(16)     NOT NULL, -- Dataset | Column | Import
        ColumnName           NVARCHAR(128)    NULL,
        MetricValue          DECIMAL(18,6)    NOT NULL,
        MetricUnit           NVARCHAR(32)     NULL,
        CONSTRAINT FK_QualityMetric_Run FOREIGN KEY (ProfileRunId)
            REFERENCES profile.ProfileRun (ProfileRunId) ON DELETE CASCADE,
        CONSTRAINT CK_QualityMetric_Scope CHECK (MetricScope IN (N'Dataset', N'Column', N'Import'))
    );

    CREATE INDEX IX_QualityMetric_Run ON profile.QualityMetric (ProfileRunId, MetricCode);
END
GO

-- ------------------------------------------------------------
-- Quality issues (summary + detail-ready)
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.QualityIssue', N'U') IS NULL
BEGIN
    CREATE TABLE profile.QualityIssue
    (
        QualityIssueId       BIGINT           NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_QualityIssue PRIMARY KEY,
        ProfileRunId         UNIQUEIDENTIFIER NOT NULL,
        DatasetId            UNIQUEIDENTIFIER NOT NULL,
        ImportId             UNIQUEIDENTIFIER NULL,
        IssueType            NVARCHAR(32)     NOT NULL,
        ColumnName           NVARCHAR(128)    NULL,
        ErrorCode            NVARCHAR(64)     NULL,
        AffectedCount        BIGINT           NOT NULL CONSTRAINT DF_QualityIssue_Count DEFAULT (0),
        SampleValue          NVARCHAR(500)    NULL,
        Description          NVARCHAR(1000)   NOT NULL,
        Severity             NVARCHAR(16)     NOT NULL CONSTRAINT DF_QualityIssue_Sev DEFAULT (N'Warning'),
        CONSTRAINT FK_QualityIssue_Run FOREIGN KEY (ProfileRunId)
            REFERENCES profile.ProfileRun (ProfileRunId) ON DELETE CASCADE,
        CONSTRAINT FK_QualityIssue_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_QualityIssue_Type CHECK (IssueType IN (
            N'MissingValue', N'DuplicateRecord', N'InvalidValue', N'ValidationFailure',
            N'DataTypeIssue', N'UnexpectedValue', N'EmptyDataset', N'ThresholdBreach')),
        CONSTRAINT CK_QualityIssue_Sev CHECK (Severity IN (N'Info', N'Warning', N'Error', N'Critical'))
    );

    CREATE INDEX IX_QualityIssue_Run ON profile.QualityIssue (ProfileRunId, IssueType);
    CREATE INDEX IX_QualityIssue_Dataset ON profile.QualityIssue (DatasetId, IssueType);
END
GO

-- ------------------------------------------------------------
-- Configurable thresholds
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.QualityThreshold', N'U') IS NULL
BEGIN
    CREATE TABLE profile.QualityThreshold
    (
        ThresholdId          INT              NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_QualityThreshold PRIMARY KEY,
        DatasetId            UNIQUEIDENTIFIER NULL, -- NULL = global default
        MetricCode           NVARCHAR(64)     NOT NULL,
        OperatorCode         NVARCHAR(8)      NOT NULL CONSTRAINT DF_Thresh_Op DEFAULT (N'>='),
        ThresholdValue       DECIMAL(18,6)    NOT NULL,
        Severity             NVARCHAR(16)     NOT NULL CONSTRAINT DF_Thresh_Sev DEFAULT (N'Error'),
        IsActive             BIT              NOT NULL CONSTRAINT DF_Thresh_Active DEFAULT (1),
        CONSTRAINT FK_Thresh_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_Thresh_Op CHECK (OperatorCode IN (N'>=', N'>', N'<=', N'<', N'=')),
        CONSTRAINT CK_Thresh_Sev CHECK (Severity IN (N'Warning', N'Error', N'Critical'))
    );

    CREATE UNIQUE INDEX UX_QualityThreshold
        ON profile.QualityThreshold (MetricCode, DatasetId)
        WHERE IsActive = 1;
END
GO

-- ------------------------------------------------------------
-- Score dimension weights (single source of truth for formula)
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.ScoreWeight', N'U') IS NULL
BEGIN
    CREATE TABLE profile.ScoreWeight
    (
        ScoreWeightId        INT              NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_ScoreWeight PRIMARY KEY,
        DatasetId            UNIQUEIDENTIFIER NULL, -- NULL = global
        DimensionCode        NVARCHAR(32)     NOT NULL,
        WeightPct            DECIMAL(5,2)     NOT NULL,
        IsActive             BIT              NOT NULL CONSTRAINT DF_ScoreWeight_Active DEFAULT (1),
        CONSTRAINT FK_ScoreWeight_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_ScoreWeight_Dim CHECK (DimensionCode IN (
            N'Completeness', N'Validity', N'Uniqueness', N'Consistency')),
        CONSTRAINT CK_ScoreWeight_Pct CHECK (WeightPct >= 0 AND WeightPct <= 100)
    );

    CREATE UNIQUE INDEX UX_ScoreWeight
        ON profile.ScoreWeight (DimensionCode, DatasetId)
        WHERE IsActive = 1;
END
GO

-- ------------------------------------------------------------
-- Threshold evaluation results per run
-- ------------------------------------------------------------
IF OBJECT_ID(N'profile.ThresholdResult', N'U') IS NULL
BEGIN
    CREATE TABLE profile.ThresholdResult
    (
        ThresholdResultId    BIGINT           NOT NULL IDENTITY(1,1)
                             CONSTRAINT PK_ThresholdResult PRIMARY KEY,
        ProfileRunId         UNIQUEIDENTIFIER NOT NULL,
        ThresholdId          INT              NOT NULL,
        MetricCode           NVARCHAR(64)     NOT NULL,
        ActualValue          DECIMAL(18,6)    NOT NULL,
        ThresholdValue       DECIMAL(18,6)    NOT NULL,
        OperatorCode         NVARCHAR(8)      NOT NULL,
        Passed               BIT              NOT NULL,
        CONSTRAINT FK_ThreshResult_Run FOREIGN KEY (ProfileRunId)
            REFERENCES profile.ProfileRun (ProfileRunId) ON DELETE CASCADE,
        CONSTRAINT FK_ThreshResult_Thresh FOREIGN KEY (ThresholdId)
            REFERENCES profile.QualityThreshold (ThresholdId)
    );

    CREATE INDEX IX_ThreshResult_Run ON profile.ThresholdResult (ProfileRunId, Passed);
END
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Job_Type')
    ALTER TABLE jobs.ProcessingJob DROP CONSTRAINT CK_Job_Type;
GO

ALTER TABLE jobs.ProcessingJob WITH CHECK ADD CONSTRAINT CK_Job_Type CHECK (JobType IN (
    N'MetadataRefresh', N'HealthCheck', N'SampleExtract',
    N'DataProfiling', N'QualityAssessment', N'MetadataSync', N'ArchiveProfilingHistory',
    N'ProcessPendingImports', N'ArchiveImportHistory',
    N'EtlProcessPending', N'EtlArchiveErrors', N'EtlQualitySnapshot', N'EtlBatchCleanup',
    N'DatasetQualityProfile', N'ArchiveProfileHistory'));
GO

PRINT 'Profile schema objects created.';
GO
