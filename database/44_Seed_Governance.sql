-- ============================================================
-- 44_Seed_Governance.sql
-- Users, workspace membership, dataset governance, demo
-- access-request flow, scheduled jobs.
-- ============================================================
USE EDIP;
GO

DECLARE @Admin UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000001';
DECLARE @Owner UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000002';
DECLARE @Steward UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000003';
DECLARE @Analyst UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000004';
DECLARE @Viewer UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000005';
DECLARE @Outsider UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000006';

MERGE gov.AppUser AS t
USING (VALUES
    (@Admin,    N'gov.admin',    N'Platform Admin',   N'admin@edip.local',    1, 1),
    (@Owner,    N'gov.owner',    N'Customer Owner',   N'owner@edip.local',    1, 0),
    (@Steward,  N'gov.steward',  N'Data Steward',     N'steward@edip.local',  1, 0),
    (@Analyst,  N'gov.analyst',  N'Sales Analyst',    N'analyst@edip.local',  1, 0),
    (@Viewer,   N'gov.viewer',   N'Read Viewer',      N'viewer@edip.local',   1, 0),
    (@Outsider, N'gov.outsider', N'Other Workspace',  N'outsider@edip.local', 1, 0)
) AS s (UserId, UserName, DisplayName, Email, IsActive, IsPlatformAdmin)
ON t.UserId = s.UserId
WHEN MATCHED THEN UPDATE SET
    UserName = s.UserName, DisplayName = s.DisplayName, Email = s.Email,
    IsActive = s.IsActive, IsPlatformAdmin = s.IsPlatformAdmin, ModifiedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
    INSERT (UserId, UserName, DisplayName, Email, IsActive, IsPlatformAdmin)
    VALUES (s.UserId, s.UserName, s.DisplayName, s.Email, s.IsActive, s.IsPlatformAdmin);

MERGE gov.UserRole AS t
USING (VALUES
    (@Admin, N'PlatformAdmin'),
    (@Owner, N'DataOwner'),
    (@Steward, N'DataSteward'),
    (@Analyst, N'Analyst'),
    (@Viewer, N'Viewer')
) AS s (UserId, RoleCode)
ON t.UserId = s.UserId AND t.RoleCode = s.RoleCode
WHEN NOT MATCHED THEN INSERT (UserId, RoleCode) VALUES (s.UserId, s.RoleCode);

DECLARE @WsSales UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000001';
DECLARE @WsFinance UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000002';

MERGE gov.WorkspaceMember AS t
USING (VALUES
    (@WsSales, @Owner, N'DataOwner'),
    (@WsSales, @Steward, N'DataSteward'),
    (@WsSales, @Analyst, N'Analyst'),
    (@WsSales, @Viewer, N'Viewer'),
    (@WsFinance, @Outsider, N'Analyst')
) AS s (WorkspaceId, UserId, RoleCode)
ON t.WorkspaceId = s.WorkspaceId AND t.UserId = s.UserId
WHEN MATCHED THEN UPDATE SET RoleCode = s.RoleCode, IsActive = 1
WHEN NOT MATCHED THEN INSERT (WorkspaceId, UserId, RoleCode) VALUES (s.WorkspaceId, s.UserId, s.RoleCode);

-- Bootstrap governance rows for all active datasets
INSERT INTO gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode)
SELECT d.DatasetId, d.WorkspaceId, N'Internal', N'Draft', N'NotCertified'
FROM ingest.Dataset d
WHERE d.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM gov.DatasetGovernance g WHERE g.DatasetId = d.DatasetId);

-- Classify / own CUSTOMER
IF EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'CUSTOMER')
BEGIN
    DECLARE @Review1 DATETIME2(3) = DATEADD(DAY, 30, SYSUTCDATETIME());
    DECLARE @Review2 DATETIME2(3) = DATEADD(DAY, 14, SYSUTCDATETIME());
    DECLARE @Expiry DATETIME2(3) = DATEADD(DAY, 180, SYSUTCDATETIME());
    DECLARE @Review3 DATETIME2(3) = DATEADD(DAY, 150, SYSUTCDATETIME());

    EXEC gov.usp_UpsertDatasetGovernance
        @DatasetCode = N'CUSTOMER',
        @ClassificationCode = N'Confidential',
        @GovernanceStatusCode = N'Draft',
        @OwnerUserName = N'gov.owner',
        @StewardUserName = N'gov.steward',
        @ReviewDueUtc = @Review1,
        @Notes = N'Seeded confidential customer master',
        @ActorUserName = N'gov.admin';

    EXEC gov.usp_SubmitForReview
        @DatasetCode = N'CUSTOMER',
        @ActorUserName = N'gov.steward',
        @ReviewDueUtc = @Review2,
        @Comments = N'Ready for certification review';

    EXEC gov.usp_CertifyDataset
        @DatasetCode = N'CUSTOMER',
        @ActorUserName = N'gov.owner',
        @CertificationExpiryUtc = @Expiry,
        @ReviewDueUtc = @Review3,
        @Comments = N'Certified for Sales analytics use';
END

-- ORDER as Internal draft
IF EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'ORDER')
    EXEC gov.usp_UpsertDatasetGovernance
        @DatasetCode = N'ORDER',
        @ClassificationCode = N'Internal',
        @OwnerUserName = N'gov.owner',
        @StewardUserName = N'gov.steward',
        @ActorUserName = N'gov.admin';

-- Restricted PRODUCT in Ops workspace if present
IF EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetCode = N'PRODUCT')
    EXEC gov.usp_UpsertDatasetGovernance
        @DatasetCode = N'PRODUCT',
        @ClassificationCode = N'Restricted',
        @GovernanceStatusCode = N'Draft',
        @ActorUserName = N'gov.admin';

-- Access request demo: analyst requests Write on CUSTOMER
DECLARE @ReqId UNIQUEIDENTIFIER, @Code NVARCHAR(32), @Msg NVARCHAR(500);
EXEC gov.usp_SubmitAccessRequest
    @DatasetCode = N'CUSTOMER',
    @RequestingUserName = N'gov.analyst',
    @AccessLevelCode = N'Write',
    @BusinessJustification = N'Need write access for monthly customer enrichment.',
    @AccessRequestId = @ReqId OUTPUT,
    @StatusCode = @Code OUTPUT,
    @StatusMessage = @Msg OUTPUT;

IF @Code = N'Created' AND @ReqId IS NOT NULL
    EXEC gov.usp_ApproveAccessRequest
        @AccessRequestId = @ReqId,
        @ReviewerUserName = N'gov.owner',
        @ReviewComments = N'Approved for enrichment cycle',
        @StatusCode = @Code OUTPUT,
        @StatusMessage = @Msg OUTPUT;

-- Pending request from viewer
EXEC gov.usp_SubmitAccessRequest
    @DatasetCode = N'CUSTOMER',
    @RequestingUserName = N'gov.viewer',
    @AccessLevelCode = N'Read',
    @BusinessJustification = N'Read access for quarterly dashboard.',
    @AccessRequestId = @ReqId OUTPUT,
    @StatusCode = @Code OUTPUT,
    @StatusMessage = @Msg OUTPUT;

-- Cross-workspace denied sample (outsider on CUSTOMER / Sales)
EXEC gov.usp_SubmitAccessRequest
    @DatasetCode = N'CUSTOMER',
    @RequestingUserName = N'gov.outsider',
    @AccessLevelCode = N'Read',
    @BusinessJustification = N'Trying cross-workspace access.',
    @AccessRequestId = @ReqId OUTPUT,
    @StatusCode = @Code OUTPUT,
    @StatusMessage = @Msg OUTPUT;
PRINT CONCAT('Cross-workspace request status (expected CrossWorkspaceDenied): ', @Code);

-- Jobs
DECLARE @SampleCsv UNIQUEIDENTIFIER =
    (SELECT TOP (1) DataSourceId FROM reg.DataSource WHERE IsDeleted = 0 ORDER BY CreatedUtc);

IF @SampleCsv IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Expire Dataset Certifications')
    BEGIN
        DECLARE @Job1 UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@Job1, N'Expire Dataset Certifications',
                N'Marks certified datasets past expiry as Expired and writes history/audit.',
                @SampleCsv, N'ExpireDatasetCertifications', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @Job1, N'Daily', 1440, DATEADD(HOUR, 2, SYSUTCDATETIME()), 1);
    END

    IF NOT EXISTS (SELECT 1 FROM jobs.ProcessingJob WHERE JobName = N'Archive Governance Audit')
    BEGIN
        DECLARE @Job2 UNIQUEIDENTIFIER = NEWID();
        INSERT INTO jobs.ProcessingJob (JobId, JobName, Description, DataSourceId, JobType, IsEnabled, MaxRetries, RetryDelaySeconds)
        VALUES (@Job2, N'Archive Governance Audit',
                N'Purges aged governance audit events.',
                @SampleCsv, N'ArchiveGovernanceAudit', 1, 1, 60);
        INSERT INTO jobs.JobSchedule (ScheduleId, JobId, FrequencyCode, IntervalMinutes, NextRunUtc, IsActive)
        VALUES (NEWID(), @Job2, N'Weekly', 10080, DATEADD(DAY, 7, SYSUTCDATETIME()), 1);
    END
END
GO

PRINT 'Governance seed complete.';
GO
