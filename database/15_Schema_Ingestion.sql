-- ============================================================
-- 15_Schema_Ingestion.sql
-- Staging, import batch, error, and target dataset tables
-- ============================================================
USE EDIP;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ingest')
    EXEC(N'CREATE SCHEMA ingest AUTHORIZATION dbo;');
GO

-- ------------------------------------------------------------
-- Dataset catalog (extensible for additional staged entities)
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.Dataset', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.Dataset
    (
        DatasetId      UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_Dataset PRIMARY KEY
                       CONSTRAINT DF_Dataset_Id DEFAULT NEWSEQUENTIALID(),
        DatasetCode    NVARCHAR(64)     NOT NULL,
        DisplayName    NVARCHAR(200)    NOT NULL,
        Description    NVARCHAR(1000)   NULL,
        StagingTable   NVARCHAR(128)    NOT NULL,
        TargetTable    NVARCHAR(128)    NOT NULL,
        IsActive       BIT              NOT NULL CONSTRAINT DF_Dataset_Active DEFAULT (1),
        CreatedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_Dataset_Created DEFAULT SYSUTCDATETIME()
    );

    CREATE UNIQUE INDEX UX_Dataset_Code ON ingest.Dataset (DatasetCode);
END
GO

-- ------------------------------------------------------------
-- Import batch management
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.ImportBatch', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.ImportBatch
    (
        BatchId              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ImportBatch PRIMARY KEY
                             CONSTRAINT DF_ImportBatch_Id DEFAULT NEWSEQUENTIALID(),
        DatasetId            UNIQUEIDENTIFIER NOT NULL,
        DataSourceId         UNIQUEIDENTIFIER NULL,
        SourceInfo           NVARCHAR(500)    NULL,
        ImportUtc            DATETIME2(3)     NOT NULL CONSTRAINT DF_ImportBatch_Import DEFAULT SYSUTCDATETIME(),
        Status               NVARCHAR(32)     NOT NULL CONSTRAINT DF_ImportBatch_Status DEFAULT N'Pending',
        TotalRecords         INT              NOT NULL CONSTRAINT DF_ImportBatch_Total DEFAULT (0),
        ValidRecords         INT              NOT NULL CONSTRAINT DF_ImportBatch_Valid DEFAULT (0),
        RejectedRecords      INT              NOT NULL CONSTRAINT DF_ImportBatch_Rejected DEFAULT (0),
        ProcessedRecords     INT              NOT NULL CONSTRAINT DF_ImportBatch_Processed DEFAULT (0),
        InsertedRecords      INT              NOT NULL CONSTRAINT DF_ImportBatch_Inserted DEFAULT (0),
        UpdatedRecords       INT              NOT NULL CONSTRAINT DF_ImportBatch_Updated DEFAULT (0),
        ErrorCount           INT              NOT NULL CONSTRAINT DF_ImportBatch_Errors DEFAULT (0),
        AttemptCount         INT              NOT NULL CONSTRAINT DF_ImportBatch_Attempts DEFAULT (0),
        StartedUtc           DATETIME2(3)     NULL,
        CompletedUtc         DATETIME2(3)     NULL,
        LastErrorMessage     NVARCHAR(2000)   NULL,
        CreatedUtc           DATETIME2(3)     NOT NULL CONSTRAINT DF_ImportBatch_Created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ImportBatch_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT FK_ImportBatch_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_ImportBatch_Status CHECK (Status IN (
            N'Pending', N'Loaded', N'Validating', N'Validated', N'Processing',
            N'Completed', N'CompletedWithErrors', N'Failed', N'RetryPending'))
    );

    CREATE INDEX IX_ImportBatch_Dataset_Import
        ON ingest.ImportBatch (DatasetId, ImportUtc DESC);
    CREATE INDEX IX_ImportBatch_Status
        ON ingest.ImportBatch (Status, ImportUtc DESC)
        INCLUDE (DatasetId, TotalRecords, RejectedRecords, ErrorCount);
    CREATE INDEX IX_ImportBatch_DataSource
        ON ingest.ImportBatch (DataSourceId, ImportUtc DESC)
        WHERE DataSourceId IS NOT NULL;
END
GO

-- ------------------------------------------------------------
-- Batch processing attempt history (retry traceability)
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.BatchProcessAttempt', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.BatchProcessAttempt
    (
        AttemptId        BIGINT           NOT NULL IDENTITY(1,1)
                         CONSTRAINT PK_BatchProcessAttempt PRIMARY KEY,
        BatchId          UNIQUEIDENTIFIER NOT NULL,
        AttemptNumber    INT              NOT NULL,
        TriggerType      NVARCHAR(16)     NOT NULL CONSTRAINT DF_BatchAttempt_Trigger DEFAULT N'Manual',
        Status           NVARCHAR(32)     NOT NULL,
        StartedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_BatchAttempt_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc     DATETIME2(3)     NULL,
        ProcessedCount   INT              NOT NULL CONSTRAINT DF_BatchAttempt_Processed DEFAULT (0),
        InsertedCount    INT              NOT NULL CONSTRAINT DF_BatchAttempt_Inserted DEFAULT (0),
        UpdatedCount     INT              NOT NULL CONSTRAINT DF_BatchAttempt_Updated DEFAULT (0),
        ErrorMessage     NVARCHAR(2000)   NULL,
        CONSTRAINT FK_BatchAttempt_Batch FOREIGN KEY (BatchId)
            REFERENCES ingest.ImportBatch (BatchId) ON DELETE CASCADE,
        CONSTRAINT CK_BatchAttempt_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry', N'Api')),
        CONSTRAINT CK_BatchAttempt_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed', N'Partial'))
    );

    CREATE INDEX IX_BatchAttempt_Batch ON ingest.BatchProcessAttempt (BatchId, AttemptNumber DESC);
END
GO

-- ------------------------------------------------------------
-- Structured validation / processing errors
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.ImportError', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.ImportError
    (
        ErrorId          BIGINT           NOT NULL IDENTITY(1,1)
                         CONSTRAINT PK_ImportError PRIMARY KEY,
        BatchId          UNIQUEIDENTIFIER NOT NULL,
        DatasetId        UNIQUEIDENTIFIER NOT NULL,
        StagingRowId     BIGINT           NULL,
        RowReference     NVARCHAR(128)    NULL,
        ColumnName       NVARCHAR(128)    NULL,
        InvalidValue     NVARCHAR(500)    NULL,
        ErrorCode        NVARCHAR(64)     NOT NULL,
        ErrorDescription NVARCHAR(1000)   NOT NULL,
        Severity         NVARCHAR(16)     NOT NULL CONSTRAINT DF_ImportError_Severity DEFAULT N'Error',
        ErrorUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_ImportError_Utc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ImportError_Batch FOREIGN KEY (BatchId)
            REFERENCES ingest.ImportBatch (BatchId) ON DELETE CASCADE,
        CONSTRAINT FK_ImportError_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_ImportError_Severity CHECK (Severity IN (N'Error', N'Warning', N'Info'))
    );

    CREATE INDEX IX_ImportError_Batch ON ingest.ImportError (BatchId, ErrorUtc);
    CREATE INDEX IX_ImportError_Dataset ON ingest.ImportError (DatasetId, ErrorUtc DESC);
    CREATE INDEX IX_ImportError_Code ON ingest.ImportError (ErrorCode, ErrorUtc DESC);
END
GO

-- ------------------------------------------------------------
-- Reference data for RI validation (demo)
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.Country', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.Country
    (
        CountryCode  NCHAR(2)      NOT NULL CONSTRAINT PK_Country PRIMARY KEY,
        CountryName  NVARCHAR(100) NOT NULL,
        IsActive     BIT           NOT NULL CONSTRAINT DF_Country_Active DEFAULT (1)
    );
END
GO

-- ------------------------------------------------------------
-- Final / curated customer dataset
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.Customer', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.Customer
    (
        CustomerId       BIGINT           NOT NULL IDENTITY(1,1)
                         CONSTRAINT PK_Customer PRIMARY KEY,
        CustomerCode     NVARCHAR(32)     NOT NULL,
        CustomerName     NVARCHAR(200)    NOT NULL,
        CountryCode      NCHAR(2)         NOT NULL,
        Email            NVARCHAR(256)    NULL,
        CreditLimit      DECIMAL(18,2)    NOT NULL CONSTRAINT DF_Customer_Credit DEFAULT (0),
        Status           NVARCHAR(16)     NOT NULL CONSTRAINT DF_Customer_Status DEFAULT N'Active',
        CreatedDate      DATE             NOT NULL,
        SourceBatchId    UNIQUEIDENTIFIER NULL,
        CreatedUtc       DATETIME2(3)     NOT NULL CONSTRAINT DF_Customer_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc      DATETIME2(3)     NOT NULL CONSTRAINT DF_Customer_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_Customer_Country FOREIGN KEY (CountryCode)
            REFERENCES ingest.Country (CountryCode),
        CONSTRAINT CK_Customer_Status CHECK (Status IN (N'Active', N'Inactive', N'Prospect')),
        CONSTRAINT CK_Customer_Credit CHECK (CreditLimit >= 0)
    );

    CREATE UNIQUE INDEX UX_Customer_Code ON ingest.Customer (CustomerCode);
    CREATE INDEX IX_Customer_Country ON ingest.Customer (CountryCode);
    CREATE INDEX IX_Customer_SourceBatch ON ingest.Customer (SourceBatchId)
        WHERE SourceBatchId IS NOT NULL;
END
GO

-- ------------------------------------------------------------
-- Staging layer for customer imports
-- ------------------------------------------------------------
IF OBJECT_ID(N'ingest.StagingCustomer', N'U') IS NULL
BEGIN
    CREATE TABLE ingest.StagingCustomer
    (
        StagingRowId       BIGINT           NOT NULL IDENTITY(1,1)
                           CONSTRAINT PK_StagingCustomer PRIMARY KEY,
        BatchId            UNIQUEIDENTIFIER NOT NULL,
        DatasetId          UNIQUEIDENTIFIER NOT NULL,
        RowNumber          INT              NOT NULL,
        -- Raw (as imported) for error reporting
        RawCustomerCode    NVARCHAR(100)    NULL,
        RawCustomerName    NVARCHAR(300)    NULL,
        RawCountryCode     NVARCHAR(20)     NULL,
        RawEmail           NVARCHAR(300)    NULL,
        RawCreditLimit     NVARCHAR(50)     NULL,
        RawStatus          NVARCHAR(50)     NULL,
        RawCreatedDate     NVARCHAR(50)     NULL,
        -- Parsed / typed values after validation
        CustomerCode       NVARCHAR(32)     NULL,
        CustomerName       NVARCHAR(200)    NULL,
        CountryCode        NCHAR(2)         NULL,
        Email              NVARCHAR(256)    NULL,
        CreditLimit        DECIMAL(18,2)    NULL,
        Status             NVARCHAR(16)     NULL,
        CreatedDate        DATE             NULL,
        -- Processing state
        RowStatus          NVARCHAR(16)     NOT NULL CONSTRAINT DF_StagingCust_Status DEFAULT N'Pending',
        IsDuplicateInBatch BIT              NOT NULL CONSTRAINT DF_StagingCust_Dup DEFAULT (0),
        ProcessedUtc       DATETIME2(3)     NULL,
        ImportUtc          DATETIME2(3)     NOT NULL CONSTRAINT DF_StagingCust_Import DEFAULT SYSUTCDATETIME(),
        SourceInfo         NVARCHAR(500)    NULL,
        CONSTRAINT FK_StagingCust_Batch FOREIGN KEY (BatchId)
            REFERENCES ingest.ImportBatch (BatchId) ON DELETE CASCADE,
        CONSTRAINT FK_StagingCust_Dataset FOREIGN KEY (DatasetId)
            REFERENCES ingest.Dataset (DatasetId),
        CONSTRAINT CK_StagingCust_Status CHECK (RowStatus IN (
            N'Pending', N'Valid', N'Invalid', N'Processed', N'Skipped'))
    );

    CREATE INDEX IX_StagingCust_Batch_Status
        ON ingest.StagingCustomer (BatchId, RowStatus)
        INCLUDE (CustomerCode, RowNumber);
    CREATE INDEX IX_StagingCust_Batch_Code
        ON ingest.StagingCustomer (BatchId, CustomerCode)
        WHERE CustomerCode IS NOT NULL;
    CREATE UNIQUE INDEX UX_StagingCust_Batch_Row
        ON ingest.StagingCustomer (BatchId, RowNumber);
END
GO

-- Extend job types for scheduled ingestion
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Job_Type')
BEGIN
    ALTER TABLE jobs.ProcessingJob DROP CONSTRAINT CK_Job_Type;
END
GO

ALTER TABLE jobs.ProcessingJob WITH CHECK ADD CONSTRAINT CK_Job_Type CHECK (JobType IN (
    N'MetadataRefresh', N'HealthCheck', N'SampleExtract',
    N'DataProfiling', N'QualityAssessment', N'MetadataSync', N'ArchiveProfilingHistory',
    N'ProcessPendingImports', N'ArchiveImportHistory'));
GO

PRINT 'Ingestion schema objects created.';
GO
