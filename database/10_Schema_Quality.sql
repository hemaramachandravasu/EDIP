-- ============================================================
-- 10_Schema_Quality.sql
-- Data Profiling, Quality Assessment, Schema Sync tables
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dq')
    EXEC(N'CREATE SCHEMA dq AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'dq.ProfilingRun', N'U') IS NULL
BEGIN
    CREATE TABLE dq.ProfilingRun
    (
        ProfilingRunId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ProfilingRun PRIMARY KEY
                         CONSTRAINT DF_ProfilingRun_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId     UNIQUEIDENTIFIER NOT NULL,
        TriggerType      NVARCHAR(16)     NOT NULL CONSTRAINT DF_Profiling_Trigger DEFAULT N'Manual',
        Status           NVARCHAR(16)     NOT NULL CONSTRAINT DF_Profiling_Status DEFAULT N'Running',
        StartedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_Profiling_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc     DATETIME2(3)     NULL,
        TablesProfiled   INT              NOT NULL CONSTRAINT DF_Profiling_Tables DEFAULT (0),
        ColumnsProfiled  INT              NOT NULL CONSTRAINT DF_Profiling_Columns DEFAULT (0),
        ErrorMessage     NVARCHAR(MAX)    NULL,
        CONSTRAINT FK_ProfilingRun_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_Profiling_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry')),
        CONSTRAINT CK_Profiling_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed'))
    );
    CREATE INDEX IX_ProfilingRun_Source ON dq.ProfilingRun (DataSourceId, StartedUtc DESC);
END
GO

IF OBJECT_ID(N'dq.TableProfile', N'U') IS NULL
BEGIN
    CREATE TABLE dq.TableProfile
    (
        TableProfileId     UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_TableProfile PRIMARY KEY
                           CONSTRAINT DF_TableProfile_Id DEFAULT NEWSEQUENTIALID(),
        ProfilingRunId     UNIQUEIDENTIFIER NOT NULL,
        SchemaName         NVARCHAR(128)    NOT NULL,
        ObjectName         NVARCHAR(256)    NOT NULL,
        ObjectType         NVARCHAR(16)     NOT NULL CONSTRAINT DF_TableProfile_Type DEFAULT N'Table',
        RowCountValue      BIGINT           NOT NULL CONSTRAINT DF_TableProfile_Rows DEFAULT (0),
        DuplicateRowCount  BIGINT           NOT NULL CONSTRAINT DF_TableProfile_Dupes DEFAULT (0),
        IsEmpty            BIT              NOT NULL CONSTRAINT DF_TableProfile_Empty DEFAULT (0),
        LastDataChangeUtc  DATETIME2(3)     NULL,
        CONSTRAINT FK_TableProfile_Run FOREIGN KEY (ProfilingRunId)
            REFERENCES dq.ProfilingRun (ProfilingRunId) ON DELETE CASCADE
    );
    CREATE INDEX IX_TableProfile_Run ON dq.TableProfile (ProfilingRunId);
END
GO

IF OBJECT_ID(N'dq.ColumnProfile', N'U') IS NULL
BEGIN
    CREATE TABLE dq.ColumnProfile
    (
        ColumnProfileId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ColumnProfile PRIMARY KEY
                           CONSTRAINT DF_ColumnProfile_Id DEFAULT NEWSEQUENTIALID(),
        TableProfileId     UNIQUEIDENTIFIER NOT NULL,
        ColumnName         NVARCHAR(256)    NOT NULL,
        DataType           NVARCHAR(128)    NOT NULL,
        NullCount          BIGINT           NOT NULL CONSTRAINT DF_ColProfile_Nulls DEFAULT (0),
        NullPct            DECIMAL(9,4)     NOT NULL CONSTRAINT DF_ColProfile_NullPct DEFAULT (0),
        DistinctCount      BIGINT           NOT NULL CONSTRAINT DF_ColProfile_Distinct DEFAULT (0),
        MinValue           NVARCHAR(500)    NULL,
        MaxValue           NVARCHAR(500)    NULL,
        SampleInvalidCount BIGINT           NOT NULL CONSTRAINT DF_ColProfile_Invalid DEFAULT (0),
        CONSTRAINT FK_ColumnProfile_Table FOREIGN KEY (TableProfileId)
            REFERENCES dq.TableProfile (TableProfileId) ON DELETE CASCADE
    );
    CREATE INDEX IX_ColumnProfile_Table ON dq.ColumnProfile (TableProfileId);
END
GO

IF OBJECT_ID(N'dq.QualityAssessment', N'U') IS NULL
BEGIN
    CREATE TABLE dq.QualityAssessment
    (
        AssessmentId       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_QualityAssessment PRIMARY KEY
                           CONSTRAINT DF_QualityAssessment_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId       UNIQUEIDENTIFIER NOT NULL,
        ProfilingRunId     UNIQUEIDENTIFIER NULL,
        OverallScore       DECIMAL(5,2)     NOT NULL,
        Grade              NVARCHAR(8)      NOT NULL,
        MissingScore       DECIMAL(5,2)     NOT NULL,
        DuplicateScore     DECIMAL(5,2)     NOT NULL,
        TypeScore          DECIMAL(5,2)     NOT NULL,
        ReferentialScore   DECIMAL(5,2)     NOT NULL,
        EmptyTableScore    DECIMAL(5,2)     NOT NULL,
        FreshnessScore     DECIMAL(5,2)     NOT NULL,
        AssessedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_Quality_Assessed DEFAULT SYSUTCDATETIME(),
        Summary            NVARCHAR(2000)   NULL,
        CONSTRAINT FK_QualityAssessment_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT FK_QualityAssessment_Run FOREIGN KEY (ProfilingRunId)
            REFERENCES dq.ProfilingRun (ProfilingRunId)
    );
    CREATE INDEX IX_QualityAssessment_Source ON dq.QualityAssessment (DataSourceId, AssessedUtc DESC);
END
GO

IF OBJECT_ID(N'dq.QualityCheckResult', N'U') IS NULL
BEGIN
    CREATE TABLE dq.QualityCheckResult
    (
        CheckResultId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_QualityCheckResult PRIMARY KEY
                         CONSTRAINT DF_QualityCheckResult_Id DEFAULT NEWSEQUENTIALID(),
        AssessmentId     UNIQUEIDENTIFIER NOT NULL,
        CheckCode        NVARCHAR(64)     NOT NULL,
        CheckName        NVARCHAR(200)    NOT NULL,
        Severity         NVARCHAR(16)     NOT NULL,
        Passed           BIT              NOT NULL,
        AffectedCount    BIGINT           NOT NULL CONSTRAINT DF_QualityCheck_Count DEFAULT (0),
        Details          NVARCHAR(2000)   NULL,
        CONSTRAINT FK_QualityCheck_Assessment FOREIGN KEY (AssessmentId)
            REFERENCES dq.QualityAssessment (AssessmentId) ON DELETE CASCADE
    );
    CREATE INDEX IX_QualityCheck_Assessment ON dq.QualityCheckResult (AssessmentId);
END
GO

IF OBJECT_ID(N'dq.SchemaChangeEvent', N'U') IS NULL
BEGIN
    CREATE TABLE dq.SchemaChangeEvent
    (
        SchemaChangeId   UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_SchemaChangeEvent PRIMARY KEY
                         CONSTRAINT DF_SchemaChange_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId     UNIQUEIDENTIFIER NOT NULL,
        SyncLogId        UNIQUEIDENTIFIER NULL,
        ChangeType       NVARCHAR(32)     NOT NULL,
        SchemaName       NVARCHAR(128)    NOT NULL,
        ObjectName       NVARCHAR(256)    NOT NULL,
        ColumnName       NVARCHAR(256)    NULL,
        OldValue         NVARCHAR(500)    NULL,
        NewValue         NVARCHAR(500)    NULL,
        DetectedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_SchemaChange_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_SchemaChange_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_SchemaChange_Type CHECK (ChangeType IN (
            N'ObjectAdded', N'ObjectRemoved', N'ColumnAdded', N'ColumnRemoved', N'ColumnTypeChanged'))
    );
    CREATE INDEX IX_SchemaChange_Source ON dq.SchemaChangeEvent (DataSourceId, DetectedUtc DESC);
END
GO

IF OBJECT_ID(N'dq.MetadataSyncLog', N'U') IS NULL
BEGIN
    CREATE TABLE dq.MetadataSyncLog
    (
        SyncLogId        UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_MetadataSyncLog PRIMARY KEY
                         CONSTRAINT DF_MetadataSyncLog_Id DEFAULT NEWSEQUENTIALID(),
        DataSourceId     UNIQUEIDENTIFIER NOT NULL,
        TriggerType      NVARCHAR(16)     NOT NULL,
        Status           NVARCHAR(16)     NOT NULL,
        StartedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_SyncLog_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc     DATETIME2(3)     NULL,
        ObjectsAdded     INT              NOT NULL CONSTRAINT DF_Sync_Added DEFAULT (0),
        ObjectsRemoved   INT              NOT NULL CONSTRAINT DF_Sync_Removed DEFAULT (0),
        ColumnsChanged   INT              NOT NULL CONSTRAINT DF_Sync_Cols DEFAULT (0),
        ErrorMessage     NVARCHAR(MAX)    NULL,
        CONSTRAINT FK_MetadataSyncLog_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_Sync_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry')),
        CONSTRAINT CK_Sync_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed'))
    );
    CREATE INDEX IX_MetadataSyncLog_Source ON dq.MetadataSyncLog (DataSourceId, StartedUtc DESC);
END
GO

-- Extend job type constraint for new DQ job kinds
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Job_Type')
BEGIN
    ALTER TABLE jobs.ProcessingJob DROP CONSTRAINT CK_Job_Type;
END
GO

ALTER TABLE jobs.ProcessingJob WITH CHECK ADD CONSTRAINT CK_Job_Type CHECK (JobType IN (
    N'MetadataRefresh', N'HealthCheck', N'SampleExtract',
    N'DataProfiling', N'QualityAssessment', N'MetadataSync', N'ArchiveProfilingHistory'));
GO

PRINT 'Quality / profiling schema created.';
GO
