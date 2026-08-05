-- ============================================================
-- 04_Schema_Processing.sql
-- Data Processing Management tables
-- ============================================================
USE EDIP;
GO

IF OBJECT_ID(N'jobs.ProcessingJob', N'U') IS NULL
BEGIN
    CREATE TABLE jobs.ProcessingJob
    (
        JobId              UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_ProcessingJob PRIMARY KEY
                           CONSTRAINT DF_ProcessingJob_Id DEFAULT NEWSEQUENTIALID(),
        JobName            NVARCHAR(200)    NOT NULL,
        Description        NVARCHAR(1000)   NULL,
        DataSourceId       UNIQUEIDENTIFIER NOT NULL,
        JobType            NVARCHAR(64)     NOT NULL,
        IsEnabled          BIT              NOT NULL CONSTRAINT DF_Job_Enabled DEFAULT (1),
        MaxRetries         INT              NOT NULL CONSTRAINT DF_Job_MaxRetries DEFAULT (3),
        RetryDelaySeconds  INT              NOT NULL CONSTRAINT DF_Job_RetryDelay DEFAULT (60),
        CreatedUtc         DATETIME2(3)     NOT NULL CONSTRAINT DF_Job_Created DEFAULT SYSUTCDATETIME(),
        ModifiedUtc        DATETIME2(3)     NOT NULL CONSTRAINT DF_Job_Modified DEFAULT SYSUTCDATETIME(),
        CONSTRAINT FK_ProcessingJob_DataSource FOREIGN KEY (DataSourceId)
            REFERENCES reg.DataSource (DataSourceId),
        CONSTRAINT CK_Job_Type CHECK (JobType IN (N'MetadataRefresh', N'HealthCheck', N'SampleExtract')),
        CONSTRAINT CK_Job_Retries CHECK (MaxRetries >= 0 AND RetryDelaySeconds >= 0)
    );

    CREATE UNIQUE INDEX UX_ProcessingJob_Name ON jobs.ProcessingJob (JobName);
    CREATE INDEX IX_ProcessingJob_Source ON jobs.ProcessingJob (DataSourceId);
END
GO

IF OBJECT_ID(N'jobs.JobSchedule', N'U') IS NULL
BEGIN
    CREATE TABLE jobs.JobSchedule
    (
        ScheduleId       UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_JobSchedule PRIMARY KEY
                         CONSTRAINT DF_JobSchedule_Id DEFAULT NEWSEQUENTIALID(),
        JobId            UNIQUEIDENTIFIER NOT NULL,
        FrequencyCode    NVARCHAR(32)     NOT NULL CONSTRAINT DF_Schedule_Freq DEFAULT N'Hourly',
        IntervalMinutes  INT              NOT NULL CONSTRAINT DF_Schedule_Interval DEFAULT (60),
        CronExpression   NVARCHAR(100)    NULL,
        NextRunUtc       DATETIME2(3)     NULL,
        LastRunUtc       DATETIME2(3)     NULL,
        IsActive         BIT              NOT NULL CONSTRAINT DF_Schedule_Active DEFAULT (1),
        CONSTRAINT FK_JobSchedule_Job FOREIGN KEY (JobId)
            REFERENCES jobs.ProcessingJob (JobId) ON DELETE CASCADE,
        CONSTRAINT UQ_JobSchedule_Job UNIQUE (JobId),
        CONSTRAINT CK_Schedule_Freq CHECK (FrequencyCode IN (N'Minutely', N'Hourly', N'Daily', N'Weekly', N'Cron'))
    );

    CREATE INDEX IX_JobSchedule_Due
        ON jobs.JobSchedule (NextRunUtc)
        WHERE IsActive = 1;
END
GO

IF OBJECT_ID(N'jobs.JobExecution', N'U') IS NULL
BEGIN
    CREATE TABLE jobs.JobExecution
    (
        ExecutionId    UNIQUEIDENTIFIER NOT NULL CONSTRAINT PK_JobExecution PRIMARY KEY
                       CONSTRAINT DF_JobExecution_Id DEFAULT NEWSEQUENTIALID(),
        JobId          UNIQUEIDENTIFIER NOT NULL,
        TriggerType    NVARCHAR(16)     NOT NULL,
        Status         NVARCHAR(16)     NOT NULL,
        StartedUtc     DATETIME2(3)     NOT NULL CONSTRAINT DF_Execution_Started DEFAULT SYSUTCDATETIME(),
        CompletedUtc   DATETIME2(3)     NULL,
        ErrorMessage   NVARCHAR(MAX)    NULL,
        AttemptNumber  INT              NOT NULL CONSTRAINT DF_Execution_Attempt DEFAULT (1),
        CONSTRAINT FK_JobExecution_Job FOREIGN KEY (JobId)
            REFERENCES jobs.ProcessingJob (JobId),
        CONSTRAINT CK_Execution_Trigger CHECK (TriggerType IN (N'Manual', N'Agent', N'Retry')),
        CONSTRAINT CK_Execution_Status CHECK (Status IN (N'Pending', N'Running', N'Succeeded', N'Failed', N'Retrying', N'Cancelled'))
    );

    CREATE INDEX IX_JobExecution_Job_Started ON jobs.JobExecution (JobId, StartedUtc DESC);
    CREATE INDEX IX_JobExecution_Status ON jobs.JobExecution (Status, StartedUtc DESC);
END
GO

IF OBJECT_ID(N'jobs.JobExecutionLog', N'U') IS NULL
BEGIN
    CREATE TABLE jobs.JobExecutionLog
    (
        LogId        BIGINT           NOT NULL IDENTITY(1,1)
                     CONSTRAINT PK_JobExecutionLog PRIMARY KEY,
        ExecutionId  UNIQUEIDENTIFIER NOT NULL,
        LoggedUtc    DATETIME2(3)     NOT NULL CONSTRAINT DF_ExecLog_Utc DEFAULT SYSUTCDATETIME(),
        Level        NVARCHAR(16)     NOT NULL CONSTRAINT DF_ExecLog_Level DEFAULT N'Info',
        Message      NVARCHAR(MAX)    NOT NULL,
        CONSTRAINT FK_JobExecutionLog_Execution FOREIGN KEY (ExecutionId)
            REFERENCES jobs.JobExecution (ExecutionId) ON DELETE CASCADE
    );

    CREATE INDEX IX_JobExecutionLog_Execution ON jobs.JobExecutionLog (ExecutionId, LoggedUtc);
END
GO

IF OBJECT_ID(N'jobs.JobRetryAttempt', N'U') IS NULL
BEGIN
    CREATE TABLE jobs.JobRetryAttempt
    (
        RetryAttemptId BIGINT           NOT NULL IDENTITY(1,1)
                       CONSTRAINT PK_JobRetryAttempt PRIMARY KEY,
        ExecutionId    UNIQUEIDENTIFIER NOT NULL,
        JobId          UNIQUEIDENTIFIER NOT NULL,
        AttemptNumber  INT              NOT NULL,
        ScheduledUtc   DATETIME2(3)     NOT NULL,
        ExecutedUtc    DATETIME2(3)     NULL,
        Outcome        NVARCHAR(32)     NOT NULL CONSTRAINT DF_Retry_Outcome DEFAULT N'Pending',
        ErrorMessage   NVARCHAR(MAX)    NULL,
        CONSTRAINT FK_Retry_Execution FOREIGN KEY (ExecutionId)
            REFERENCES jobs.JobExecution (ExecutionId),
        CONSTRAINT FK_Retry_Job FOREIGN KEY (JobId)
            REFERENCES jobs.ProcessingJob (JobId),
        CONSTRAINT CK_Retry_Outcome CHECK (Outcome IN (N'Pending', N'Succeeded', N'Failed', N'Skipped'))
    );

    CREATE INDEX IX_Retry_Job_Scheduled ON jobs.JobRetryAttempt (JobId, ScheduledUtc);
END
GO

PRINT 'Processing schema objects created.';
GO
