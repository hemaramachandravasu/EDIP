-- ============================================================
-- 05_Schema_Monitoring.sql
-- Placeholder for monitoring helper objects (indexes / notes)
-- Report views are created in 07_Views_Reports.sql
-- ============================================================
USE EDIP;
GO

-- Covering indexes to support monitoring queries
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_JobExecution_DayStats' AND object_id = OBJECT_ID(N'jobs.JobExecution'))
BEGIN
    CREATE INDEX IX_JobExecution_DayStats
        ON jobs.JobExecution (StartedUtc)
        INCLUDE (Status, JobId, CompletedUtc);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ValidationLog_Day' AND object_id = OBJECT_ID(N'reg.ConnectionValidationLog'))
BEGIN
    CREATE INDEX IX_ValidationLog_Day
        ON reg.ConnectionValidationLog (ValidatedUtc)
        INCLUDE (DataSourceId, IsSuccess);
END
GO

PRINT 'Monitoring support indexes created.';
GO
