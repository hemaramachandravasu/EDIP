-- ============================================================
-- 56_Seed_Catalog.sql
-- Demo catalog data: three extra catalog datasets covering
-- Public / cross-workspace Confidential / archived cases, quality
-- scores, and tags on every dataset. Idempotent.
-- ============================================================
USE EDIP;
GO

SET NOCOUNT ON;

DECLARE @WsSales   UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = N'WS-SALES');
DECLARE @WsFinance UNIQUEIDENTIFIER = (SELECT WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = N'WS-FINANCE');
DECLARE @Owner     UNIQUEIDENTIFIER = (SELECT UserId FROM gov.AppUser WHERE UserName = N'gov.owner');
DECLARE @Steward   UNIQUEIDENTIFIER = (SELECT UserId FROM gov.AppUser WHERE UserName = N'gov.steward');

IF @WsSales IS NULL OR @WsFinance IS NULL OR @Owner IS NULL OR @Steward IS NULL
BEGIN
    PRINT 'Catalog seed skipped: governance/analytics seed data missing.';
    RETURN;
END

DECLARE @Country UNIQUEIDENTIFIER = 'C2000000-0000-0000-0000-000000000001';
DECLARE @Ledger  UNIQUEIDENTIFIER = 'C2000000-0000-0000-0000-000000000002';
DECLARE @Leads   UNIQUEIDENTIFIER = 'C2000000-0000-0000-0000-000000000003';

-- Catalog datasets ------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Country)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable,
                                WorkspaceId, DatasetStatus, Category, OwnerName, CreatedUtc, ModifiedUtc)
    VALUES (@Country, N'COUNTRY', N'Country Reference', N'ISO country codes and names used to validate customer addresses',
            N'ingest.Country', N'ingest.Country', @WsSales, N'Active', N'Reference Data', N'Customer Owner',
            DATEADD(DAY, -120, SYSUTCDATETIME()), DATEADD(DAY, -2, SYSUTCDATETIME()));

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Ledger)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable,
                                WorkspaceId, DatasetStatus, Category, OwnerName, CreatedUtc, ModifiedUtc)
    VALUES (@Ledger, N'GL_JOURNAL', N'General Ledger Journal', N'Posted journal lines for financial close and audit',
            N'ingest.StagingGlJournal', N'ingest.GlJournal', @WsFinance, N'Active', N'Financial', N'finance.controller@stratapps.com',
            DATEADD(DAY, -60, SYSUTCDATETIME()), DATEADD(DAY, -5, SYSUTCDATETIME()));

IF NOT EXISTS (SELECT 1 FROM ingest.Dataset WHERE DatasetId = @Leads)
    INSERT INTO ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable,
                                WorkspaceId, DatasetStatus, Category, OwnerName, IsActive, CreatedUtc, ModifiedUtc)
    VALUES (@Leads, N'LEGACY_LEADS', N'Legacy Marketing Leads', N'Retired lead list kept for reference; superseded by CRM feed',
            N'ingest.StagingLeads', N'ingest.Leads', @WsSales, N'Archived', N'Marketing', N'Customer Owner', 1,
            DATEADD(DAY, -400, SYSUTCDATETIME()), DATEADD(DAY, -90, SYSUTCDATETIME()));

-- Governance ------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @Country)
    INSERT INTO gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode,
                                       OwnerUserId, StewardUserId, CertifiedUtc, CertificationExpiryUtc)
    VALUES (@Country, @WsSales, N'Public', N'Certified', N'Certified', @Owner, @Steward,
            DATEADD(DAY, -30, SYSUTCDATETIME()), DATEADD(DAY, 335, SYSUTCDATETIME()));

IF NOT EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @Ledger)
    INSERT INTO gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode)
    VALUES (@Ledger, @WsFinance, N'Confidential', N'UnderReview', N'NotCertified');

IF NOT EXISTS (SELECT 1 FROM gov.DatasetGovernance WHERE DatasetId = @Leads)
    INSERT INTO gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode,
                                       OwnerUserId, StewardUserId)
    VALUES (@Leads, @WsSales, N'Internal', N'Archived', N'Expired', @Owner, @Steward);

-- Quality scores (profiling disabled: catalog demo values only) -----
IF NOT EXISTS (SELECT 1 FROM profile.DatasetProfile WHERE DatasetId = @Country)
    INSERT INTO profile.DatasetProfile (DatasetId, LatestOverallScore, LatestThresholdResult, IsEnabled)
    VALUES (@Country, 96.50, N'Pass', 0);
IF NOT EXISTS (SELECT 1 FROM profile.DatasetProfile WHERE DatasetId = @Ledger)
    INSERT INTO profile.DatasetProfile (DatasetId, LatestOverallScore, LatestThresholdResult, IsEnabled)
    VALUES (@Ledger, 62.00, N'Fail', 0);
IF NOT EXISTS (SELECT 1 FROM profile.DatasetProfile WHERE DatasetId = @Leads)
    INSERT INTO profile.DatasetProfile (DatasetId, LatestOverallScore, LatestThresholdResult, IsEnabled)
    VALUES (@Leads, 41.00, N'Fail', 0);
GO

-- Tags (through the tagging procedure so audit events are written once)
DECLARE @c NVARCHAR(32), @m NVARCHAR(500);
DECLARE @Tagging TABLE (DatasetCode NVARCHAR(64), Tags NVARCHAR(400));
INSERT INTO @Tagging VALUES
    (N'CUSTOMER',     N'customer,pii,master-data,gold,sales'),
    (N'ORDER',        N'sales,orders,transactional,daily'),
    (N'INVOICE',      N'finance,billing,transactional'),
    (N'PRODUCT',      N'product,master-data,operations'),
    (N'COUNTRY',      N'reference,master-data,gold,geography'),
    (N'GL_JOURNAL',   N'finance,ledger,sox'),
    (N'LEGACY_LEADS', N'marketing,legacy');

DECLARE @Code NVARCHAR(64), @Tags NVARCHAR(400);
DECLARE @Out TABLE (TagName NVARCHAR(64));
DECLARE tag_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.DatasetCode, t.Tags FROM @Tagging t
    WHERE EXISTS (SELECT 1 FROM ingest.Dataset d WHERE d.DatasetCode = t.DatasetCode);
OPEN tag_cur;
FETCH NEXT FROM tag_cur INTO @Code, @Tags;
WHILE @@FETCH_STATUS = 0
BEGIN
    INSERT INTO @Out
    EXEC cat.usp_AddDatasetTags @DatasetCode = @Code, @Tags = @Tags, @UserName = N'gov.admin',
         @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
    PRINT CONCAT(@Code, N': ', @c);
    FETCH NEXT FROM tag_cur INTO @Code, @Tags;
END
CLOSE tag_cur;
DEALLOCATE tag_cur;

UPDATE cat.Tag SET Description = v.Description
FROM cat.Tag t
INNER JOIN (VALUES
    (N'pii',         N'Contains personally identifiable information'),
    (N'gold',        N'Curated, certified, recommended source'),
    (N'master-data', N'Golden record / master entity'),
    (N'sox',         N'In scope for SOX financial controls'),
    (N'legacy',      N'Retired or superseded dataset')
) v (TagName, Description) ON v.TagName = t.TagName
WHERE t.Description IS NULL;
GO

PRINT 'Catalog seed complete.';
GO
