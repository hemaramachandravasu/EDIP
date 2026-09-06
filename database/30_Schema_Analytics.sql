-- ============================================================
-- 30_Schema_Analytics.sql
-- Task 19 - SQL Analytics & Reporting Engine
-- Workspace catalog, dataset governance attributes, pre-aggregated
-- reporting summary tables, trend snapshots, refresh audit log,
-- and covering indexes for read-heavy analytics.
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'analytics')
    EXEC(N'CREATE SCHEMA analytics AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Workspace catalog (tenant / business-unit grouping)
-- ------------------------------------------------------------
IF OBJECT_ID(N'analytics.Workspace', N'U') IS NULL
BEGIN
    CREATE TABLE analytics.Workspace
    (
        WorkspaceId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Workspace PRIMARY KEY
                       CONSTRAINT DF_Workspace_Id DEFAULT NEWSEQUENTIALID(),
        WorkspaceCode  NVARCHAR(64)     NOT NULL,
        DisplayName    NVARCHAR(200)    NOT NULL,
        Description    NVARCHAR(1000)   NULL,
        IsActive       BIT              NOT NULL CONSTRAINT DF_Workspace_Active DEFAULT (1),
        CreatedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_Workspace_Created DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_Workspace_Code ON analytics.Workspace (WorkspaceCode);
END
GO

-- ------------------------------------------------------------
-- Governance attributes on ingest.Dataset used by dataset analytics
-- (Status / Category / Owner / Workspace / ModifiedUtc)
-- ------------------------------------------------------------
IF COL_LENGTH(N'ingest.Dataset', N'WorkspaceId') IS NULL
    ALTER TABLE ingest.Dataset ADD WorkspaceId UNIQUEIDENTIFIER NULL;
GO
IF COL_LENGTH(N'ingest.Dataset', N'DatasetStatus') IS NULL
    ALTER TABLE ingest.Dataset ADD DatasetStatus NVARCHAR(16) NOT NULL
        CONSTRAINT DF_Dataset_Status DEFAULT (N'Active');
GO
IF COL_LENGTH(N'ingest.Dataset', N'Category') IS NULL
    ALTER TABLE ingest.Dataset ADD Category NVARCHAR(64) NOT NULL
        CONSTRAINT DF_Dataset_Category DEFAULT (N'Uncategorized');
GO
IF COL_LENGTH(N'ingest.Dataset', N'OwnerName') IS NULL
    ALTER TABLE ingest.Dataset ADD OwnerName NVARCHAR(128) NOT NULL
        CONSTRAINT DF_Dataset_Owner DEFAULT (N'unassigned');
GO
IF COL_LENGTH(N'ingest.Dataset', N'ModifiedUtc') IS NULL
    ALTER TABLE ingest.Dataset ADD ModifiedUtc DATETIME2(3) NOT NULL
        CONSTRAINT DF_Dataset_Modified DEFAULT SYSUTCDATETIME();
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = N'FK_Dataset_Workspace')
    ALTER TABLE ingest.Dataset WITH NOCHECK ADD CONSTRAINT FK_Dataset_Workspace
        FOREIGN KEY (WorkspaceId) REFERENCES analytics.Workspace (WorkspaceId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Dataset_Status')
    ALTER TABLE ingest.Dataset WITH NOCHECK ADD CONSTRAINT CK_Dataset_Status
        CHECK (DatasetStatus IN (N'Active', N'Inactive', N'Draft', N'Archived', N'Deprecated'));
GO

-- Covering index for "count by dimension" and "recent" queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Dataset_Analytics')
    CREATE INDEX IX_Dataset_Analytics
        ON ingest.Dataset (WorkspaceId, DatasetStatus)
        INCLUDE (DatasetCode, DisplayName, Category, OwnerName, IsActive, CreatedUtc, ModifiedUtc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Dataset_Created')
    CREATE INDEX IX_Dataset_Created ON ingest.Dataset (CreatedUtc DESC) INCLUDE (DatasetCode, WorkspaceId);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Dataset_Modified')
    CREATE INDEX IX_Dataset_Modified ON ingest.Dataset (ModifiedUtc DESC) INCLUDE (DatasetCode, WorkspaceId);
GO

-- ------------------------------------------------------------
-- Pre-aggregated daily reporting metric (grain: MetricDate x DatasetId)
-- Refreshed incrementally by analytics.usp_RefreshDailyMetrics.
-- ------------------------------------------------------------
IF OBJECT_ID(N'analytics.ReportingDailyMetric', N'U') IS NULL
BEGIN
    CREATE TABLE analytics.ReportingDailyMetric
    (
        MetricDate            DATE             NOT NULL,
        DatasetId             UNIQUEIDENTIFIER NOT NULL,
        WorkspaceId           UNIQUEIDENTIFIER NULL,
        -- Import activity
        ImportCount           INT              NOT NULL CONSTRAINT DF_RDM_ImportCount DEFAULT (0),
        SuccessfulImports     INT              NOT NULL CONSTRAINT DF_RDM_Success DEFAULT (0),
        FailedImports         INT              NOT NULL CONSTRAINT DF_RDM_Failed DEFAULT (0),
        CompletedWithErrors   INT              NOT NULL CONSTRAINT DF_RDM_CompletedErr DEFAULT (0),
        RecordsProcessed      BIGINT           NOT NULL CONSTRAINT DF_RDM_RecProc DEFAULT (0),
        RecordsRejected       BIGINT           NOT NULL CONSTRAINT DF_RDM_RecRej DEFAULT (0),
        RecordsInserted       BIGINT           NOT NULL CONSTRAINT DF_RDM_RecIns DEFAULT (0),
        RecordsUpdated        BIGINT           NOT NULL CONSTRAINT DF_RDM_RecUpd DEFAULT (0),
        AvgProcessingMs       INT              NULL,
        -- Quality activity
        ProfileRunCount       INT              NOT NULL CONSTRAINT DF_RDM_ProfRuns DEFAULT (0),
        AvgOverallScore       DECIMAL(5,2)     NULL,
        AvgCompletenessPct    DECIMAL(9,4)     NULL,
        AvgValidityPct        DECIMAL(9,4)     NULL,
        AvgUniquenessPct      DECIMAL(9,4)     NULL,
        AvgConsistencyPct     DECIMAL(9,4)     NULL,
        FailedThresholdRuns   INT              NOT NULL CONSTRAINT DF_RDM_FailThresh DEFAULT (0),
        QualityIssueCount     INT              NOT NULL CONSTRAINT DF_RDM_Issues DEFAULT (0),
        RefreshedUtc          DATETIME2(3)     NOT NULL CONSTRAINT DF_RDM_Refreshed DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_ReportingDailyMetric PRIMARY KEY (MetricDate, DatasetId),
        CONSTRAINT FK_RDM_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId)
    );

    -- Dataset drill-down over a date window
    CREATE INDEX IX_RDM_Dataset_Date
        ON analytics.ReportingDailyMetric (DatasetId, MetricDate)
        INCLUDE (ImportCount, SuccessfulImports, FailedImports, RecordsProcessed, RecordsRejected,
                 ProfileRunCount, AvgOverallScore, QualityIssueCount);

    -- Workspace roll-ups over a date window
    CREATE INDEX IX_RDM_Workspace_Date
        ON analytics.ReportingDailyMetric (WorkspaceId, MetricDate)
        INCLUDE (DatasetId, ImportCount, SuccessfulImports, FailedImports, RecordsProcessed,
                 RecordsRejected, ProfileRunCount, AvgOverallScore, FailedThresholdRuns, QualityIssueCount);
END
GO

-- ------------------------------------------------------------
-- Period-grain quality trend snapshot (Daily / Weekly / Monthly / Quarterly)
-- Populated from profile.ProfileRun by analytics.usp_SnapshotQualityTrend.
-- ------------------------------------------------------------
IF OBJECT_ID(N'analytics.QualityTrendSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE analytics.QualityTrendSnapshot
    (
        DatasetId          UNIQUEIDENTIFIER NOT NULL,
        WorkspaceId        UNIQUEIDENTIFIER NULL,
        PeriodType         NVARCHAR(10)     NOT NULL,       -- Day | Week | Month | Quarter
        PeriodStart        DATE             NOT NULL,
        ProfileRunCount    INT              NOT NULL CONSTRAINT DF_QTS_Runs DEFAULT (0),
        OverallScore       DECIMAL(5,2)     NULL,
        CompletenessPct    DECIMAL(9,4)     NULL,
        ValidityPct        DECIMAL(9,4)     NULL,
        UniquenessPct      DECIMAL(9,4)     NULL,
        ConsistencyPct     DECIMAL(9,4)     NULL,
        DuplicatePct       DECIMAL(9,4)     NULL,
        FailedThresholdRuns INT             NOT NULL CONSTRAINT DF_QTS_FailThresh DEFAULT (0),
        LastProfileRunId   UNIQUEIDENTIFIER NULL,
        SnapshotUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_QTS_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_QualityTrendSnapshot PRIMARY KEY (DatasetId, PeriodType, PeriodStart),
        CONSTRAINT FK_QTS_Dataset FOREIGN KEY (DatasetId) REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_QTS_PeriodType CHECK (PeriodType IN (N'Day', N'Week', N'Month', N'Quarter'))
    );

    CREATE INDEX IX_QTS_Period
        ON analytics.QualityTrendSnapshot (PeriodType, PeriodStart)
        INCLUDE (DatasetId, WorkspaceId, OverallScore, CompletenessPct, ValidityPct, UniquenessPct, ConsistencyPct);
END
GO

-- ------------------------------------------------------------
-- Refresh / maintenance audit log
-- ------------------------------------------------------------
IF OBJECT_ID(N'analytics.ReportRefreshLog', N'U') IS NULL
BEGIN
    CREATE TABLE analytics.ReportRefreshLog
    (
        RefreshLogId  BIGINT        NOT NULL IDENTITY(1,1) CONSTRAINT PK_ReportRefreshLog PRIMARY KEY,
        RefreshName   NVARCHAR(128) NOT NULL,
        StartedUtc    DATETIME2(3)  NOT NULL CONSTRAINT DF_RRL_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc  DATETIME2(3)  NULL,
        DurationMs    INT           NULL,
        RowsAffected  INT           NULL,
        Status        NVARCHAR(16)  NOT NULL CONSTRAINT DF_RRL_Status DEFAULT (N'Running'),
        Message       NVARCHAR(2000) NULL,
        CONSTRAINT CK_RRL_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed'))
    );
    CREATE INDEX IX_RRL_Name_Started ON analytics.ReportRefreshLog (RefreshName, StartedUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Supporting covering indexes on source tables for live procs
-- (dashboard feeds that read straight from base tables)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ImportBatch_Analytics')
    CREATE INDEX IX_ImportBatch_Analytics
        ON ingest.ImportBatch (DatasetId, ImportUtc)
        INCLUDE (Status, TotalRecords, ValidRecords, ProcessedRecords, RejectedRecords,
                 InsertedRecords, UpdatedRecords, ErrorCount, DurationMs, StartedUtc, CompletedUtc);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ProfileRun_Analytics')
    CREATE INDEX IX_ProfileRun_Analytics
        ON profile.ProfileRun (DatasetId, Status, StartedUtc)
        INCLUDE (OverallScore, CompletenessPct, ValidityPct, UniquenessPct, ConsistencyPct,
                 DuplicatePct, ThresholdResult, IssueCount, Grade);
GO

-- ------------------------------------------------------------
-- Extend job types for scheduled analytics maintenance
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
    N'RefreshAnalyticsSummary', N'SnapshotQualityTrend', N'CleanupAnalyticsData'));
GO

PRINT 'Analytics schema objects created.';
GO
