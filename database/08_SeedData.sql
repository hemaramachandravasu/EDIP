-- ============================================================
-- 08_SeedData.sql
-- Reference data and sample registry entries
-- ============================================================
USE EDIP;
GO

MERGE reg.DataSourceType AS t
USING (VALUES
    (1, N'SqlServer',   N'SQL Server'),
    (2, N'MySql',       N'MySQL'),
    (3, N'PostgreSql',  N'PostgreSQL'),
    (4, N'Csv',         N'CSV File'),
    (5, N'Excel',       N'Excel File')
) AS s (DataSourceTypeId, TypeCode, DisplayName)
ON t.DataSourceTypeId = s.DataSourceTypeId
WHEN MATCHED THEN
    UPDATE SET TypeCode = s.TypeCode, DisplayName = s.DisplayName
WHEN NOT MATCHED THEN
    INSERT (DataSourceTypeId, TypeCode, DisplayName)
    VALUES (s.DataSourceTypeId, s.TypeCode, s.DisplayName);
GO

DECLARE @LocalSql UNIQUEIDENTIFIER = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
DECLARE @SampleCsv UNIQUEIDENTIFIER = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';
DECLARE @HealthJob UNIQUEIDENTIFIER = 'CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC';
DECLARE @RefreshJob UNIQUEIDENTIFIER = 'DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD';

IF NOT EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @LocalSql)
BEGIN
    INSERT INTO reg.DataSource (DataSourceId, Name, Description, DataSourceTypeId, Status, HealthStatus)
    VALUES (@LocalSql, N'Local EDIP Catalog', N'Self-reference SQL Server catalog for demos', 1, N'Active', N'Unknown');

    INSERT INTO reg.SqlConnectionDetail
        (DataSourceId, Host, Port, DatabaseName, AuthMode, Username, EncryptedPassword, TrustServerCertificate, ConnectionTimeoutSeconds)
    VALUES
        (@LocalSql, N'localhost', 0, N'EDIP', N'Integrated', N'sa', NULL, 1, 30);
END

IF NOT EXISTS (SELECT 1 FROM reg.DataSource WHERE DataSourceId = @SampleCsv)
BEGIN
    INSERT INTO reg.DataSource (DataSourceId, Name, Description, DataSourceTypeId, Status, HealthStatus)
    VALUES (@SampleCsv, N'Sample Customers CSV', N'Demo CSV data source', 4, N'Active', N'Unknown');

    INSERT INTO reg.FileDataSourceDetail
        (DataSourceId, FilePath, Format, Delimiter, HasHeaderRow, SheetName, EncodingName)
    VALUES
        (@SampleCsv, N'C:\EdipData\customers.csv', N'CSV', N',', 1, NULL, N'UTF-8');
END

IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @HealthJob)
BEGIN
    INSERT INTO jobs.ProcessingJob
        (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
    VALUES
        (@HealthJob, N'Daily Local SQL Health Check', N'Validates connectivity to local SQL catalog',
         @LocalSql, N'HealthCheck', 1, 3, 60);

    INSERT INTO jobs.JobSchedule
        (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
    VALUES
        (NEWID(), @HealthJob, N'Hourly', 60, DATEADD(MINUTE, 5, SYSUTCDATETIME()), 1);
END

IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobId = @RefreshJob)
BEGIN
    INSERT INTO jobs.ProcessingJob
        (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
    VALUES
        (@RefreshJob, N'Local SQL Metadata Refresh', N'Refreshes schema metadata for local catalog',
         @LocalSql, N'MetadataRefresh', 1, 2, 120);

    INSERT INTO jobs.JobSchedule
        (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
    VALUES
        (NEWID(), @RefreshJob, N'Daily', 1440, DATEADD(MINUTE, 10, SYSUTCDATETIME()), 1);
END
GO

PRINT 'Seed data applied.';
GO
