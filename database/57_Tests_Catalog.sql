-- ============================================================
-- 57_Tests_Catalog.sql
-- Assertion-style tests for catalog discovery, search, filters,
-- sorting, offset + keyset paging, tags, detail and reports.
-- Requires 44_Seed_Governance, 50_Seed_Sharing, 56_Seed_Catalog.
-- Re-runnable: temporary data is rolled back or removed.
-- ============================================================
USE EDIP;
GO
SET NOCOUNT ON;

IF OBJECT_ID('tempdb..#T') IS NOT NULL DROP TABLE #T;
CREATE TABLE #T (Id INT IDENTITY(1,1), TestName NVARCHAR(200), Expected NVARCHAR(200), Actual NVARCHAR(200), Passed BIT);

-- Shape of cat.usp_SearchCatalog's result set (+ Seq preserves row order)
IF OBJECT_ID('tempdb..#R') IS NOT NULL DROP TABLE #R;
CREATE TABLE #R
(
    Seq INT IDENTITY(1,1),
    DatasetId UNIQUEIDENTIFIER, DatasetCode NVARCHAR(64), DatasetName NVARCHAR(200), Description NVARCHAR(1000),
    WorkspaceId UNIQUEIDENTIFIER, WorkspaceCode NVARCHAR(64), WorkspaceName NVARCHAR(200), Category NVARCHAR(64),
    OwnerUserName NVARCHAR(128), OwnerDisplayName NVARCHAR(200), StewardUserName NVARCHAR(128), StewardDisplayName NVARCHAR(200),
    SourceTypeCode NVARCHAR(32), SourceTypeName NVARCHAR(100), ClassificationCode NVARCHAR(32), GovernanceStatusCode NVARCHAR(32),
    DatasetStatus NVARCHAR(16), CertificationStatusCode NVARCHAR(32), CurrentVersion INT, CreatedUtc DATETIME2(3),
    UpdatedUtc DATETIME2(3), QualityScore DECIMAL(5,2), LastImportUtc DATETIME2(3), Tags NVARCHAR(MAX),
    RelevanceScore INT, AccessSource NVARCHAR(32), EffectiveAccessLevel NVARCHAR(32), CanReadData BIT, CanRequestAccess BIT
);
GO

-- ============================================================
-- 1. Access-aware discovery
-- ============================================================
DECLARE @Admin UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000001';
DECLARE @Owner UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000002';
DECLARE @Analyst UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000004';
DECLARE @Viewer UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000005';
DECLARE @Outsider UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000006';

DECLARE @CurrentCount INT =
    (SELECT COUNT(*) FROM ingest.Dataset d LEFT JOIN gov.DatasetGovernance g ON g.DatasetId = d.DatasetId
     WHERE d.IsActive = 1 AND d.DatasetStatus NOT IN (N'Inactive', N'Archived') AND ISNULL(g.GovernanceStatusCode, N'Draft') <> N'Archived');

INSERT #T SELECT N'Discovery: admin sees every current dataset', CONCAT(N'', @CurrentCount), CONCAT(N'', COUNT(*)),
       IIF(COUNT(*) = @CurrentCount, 1, 0)
FROM cat.fn_DatasetDiscovery(@Admin, 1, 0);

INSERT #T SELECT N'Discovery: archived hidden by default (admin)', N'0', CONCAT(N'', COUNT(*)), IIF(COUNT(*) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Admin, 1, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'LEGACY_LEADS';

INSERT #T SELECT N'Discovery: owner sees archived with IncludeInactive', N'DatasetOwner', MAX(a.AccessSource),
       IIF(MAX(a.AccessSource) = N'DatasetOwner', 1, 0)
FROM cat.fn_DatasetDiscovery(@Owner, 0, 1) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'LEGACY_LEADS';

INSERT #T SELECT N'Discovery: viewer never sees archived (even IncludeInactive)', N'0', CONCAT(N'', COUNT(*)), IIF(COUNT(*) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Viewer, 0, 1) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'LEGACY_LEADS';

INSERT #T SELECT N'Discovery: outsider sees no WS-SALES datasets', N'0', CONCAT(N'', COUNT(*)), IIF(COUNT(*) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Outsider, 0, 1) a JOIN analytics.Workspace w ON w.WorkspaceId = a.WorkspaceId WHERE w.WorkspaceCode = N'WS-SALES';

INSERT #T SELECT N'Discovery: outsider INVOICE via workspace role', N'WorkspaceRole/Read', CONCAT(N'', MAX(a.AccessSource), N'/', MAX(a.EffectiveAccessLevel)),
       IIF(MAX(a.AccessSource) = N'WorkspaceRole' AND MAX(a.EffectiveAccessLevel) = N'Read', 1, 0)
FROM cat.fn_DatasetDiscovery(@Outsider, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'INVOICE';

INSERT #T SELECT N'Discovery: outsider GL_JOURNAL metadata-only (Confidential)', N'WorkspaceRole/0/1',
       CONCAT(N'', MAX(a.AccessSource), N'/', MAX(CAST(a.CanReadData AS INT)), N'/', MAX(CAST(a.CanRequestAccess AS INT))),
       IIF(MAX(a.AccessSource) = N'WorkspaceRole' AND MAX(CAST(a.CanReadData AS INT)) = 0 AND MAX(CAST(a.CanRequestAccess AS INT)) = 1, 1, 0)
FROM cat.fn_DatasetDiscovery(@Outsider, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'GL_JOURNAL';

INSERT #T SELECT N'Discovery: viewer COUNTRY (Public) readable via role', N'WorkspaceRole/Read', CONCAT(N'', MAX(a.AccessSource), N'/', MAX(a.EffectiveAccessLevel)),
       IIF(MAX(a.AccessSource) = N'WorkspaceRole' AND MAX(a.EffectiveAccessLevel) = N'Read', 1, 0)
FROM cat.fn_DatasetDiscovery(@Viewer, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'COUNTRY';

INSERT #T SELECT N'Discovery: viewer CUSTOMER via active share', N'DatasetShare', MAX(a.AccessSource),
       IIF(MAX(a.AccessSource) = N'DatasetShare', 1, 0)
FROM cat.fn_DatasetDiscovery(@Viewer, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'CUSTOMER';

INSERT #T SELECT N'Discovery: viewer ORDER (Internal) metadata-only', N'CanRequestAccess=1', CONCAT(N'', N'CanRequestAccess=', MAX(CAST(a.CanRequestAccess AS INT))),
       IIF(MAX(CAST(a.CanRequestAccess AS INT)) = 1 AND MAX(CAST(a.CanReadData AS INT)) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Viewer, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'ORDER';

INSERT #T SELECT N'Discovery: analyst CUSTOMER via Write grant', N'AccessGrant/Write', CONCAT(N'', MAX(a.AccessSource), N'/', MAX(a.EffectiveAccessLevel)),
       IIF(MAX(a.AccessSource) = N'AccessGrant' AND MAX(a.EffectiveAccessLevel) = N'Write', 1, 0)
FROM cat.fn_DatasetDiscovery(@Analyst, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'CUSTOMER';

INSERT #T SELECT N'Discovery: analyst cannot see PRODUCT (other workspace)', N'0', CONCAT(N'', COUNT(*)), IIF(COUNT(*) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Analyst, 0, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.DatasetCode = N'PRODUCT';

-- Cross-workspace grant makes a dataset discoverable (rolled back)
DECLARE @X TABLE (Src NVARCHAR(32), Lvl NVARCHAR(32));
DECLARE @CountryId UNIQUEIDENTIFIER = (SELECT DatasetId FROM ingest.Dataset WHERE DatasetCode = N'COUNTRY');
BEGIN TRANSACTION;
    INSERT INTO gov.DatasetAccessGrant (DatasetId, UserId, AccessLevelCode, GrantedByUserId)
    VALUES (@CountryId, @Outsider, N'Read', @Admin);
    INSERT @X SELECT AccessSource, EffectiveAccessLevel FROM cat.fn_DatasetDiscovery(@Outsider, 0, 0) WHERE DatasetId = @CountryId;
ROLLBACK TRANSACTION;
INSERT #T SELECT N'Discovery: cross-workspace grant -> discoverable', N'AccessGrant/Read', ISNULL(MAX(CONCAT(N'', Src, N'/', Lvl)), N'<none>'),
       IIF(MAX(Src) = N'AccessGrant' AND MAX(Lvl) = N'Read', 1, 0) FROM @X;

INSERT #T SELECT N'Discovery: grant removed again (rollback)', N'0', CONCAT(N'', COUNT(*)), IIF(COUNT(*) = 0, 1, 0)
FROM cat.fn_DatasetDiscovery(@Outsider, 0, 0) WHERE DatasetId = @CountryId;
GO

-- ============================================================
-- 2. Search (partial, case-insensitive, relevance, escaping)
-- ============================================================
DECLARE @c NVARCHAR(32), @m NVARCHAR(500), @Total INT;

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.nobody', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: unknown user', N'InvalidUser', @c, IIF(@c = N'InvalidUser', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'customer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: "customer" ranks CUSTOMER first', N'CUSTOMER', (SELECT DatasetCode FROM #R WHERE Seq = 1),
       IIF((SELECT DatasetCode FROM #R WHERE Seq = 1) = N'CUSTOMER' AND @c = N'OK', 1, 0);
INSERT #T SELECT N'Search: relevance non-increasing', N'ordered', IIF(EXISTS (SELECT 1 FROM #R a JOIN #R b ON b.Seq = a.Seq + 1 WHERE b.RelevanceScore > a.RelevanceScore), N'unordered', N'ordered'),
       IIF(EXISTS (SELECT 1 FROM #R a JOIN #R b ON b.Seq = a.Seq + 1 WHERE b.RelevanceScore > a.RelevanceScore), 0, 1);
DECLARE @First NVARCHAR(MAX) = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'customer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: deterministic order across runs', @First, (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R),
       IIF(@First = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R), 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'  cUsToMeR mAsTeR ', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: case-insensitive exact name scores 1000+', N'CUSTOMER >=1000', CONCAT(N'', (SELECT DatasetCode FROM #R WHERE Seq = 1), N' ', (SELECT RelevanceScore FROM #R WHERE Seq = 1)),
       IIF((SELECT DatasetCode FROM #R WHERE Seq = 1) = N'CUSTOMER' AND (SELECT RelevanceScore FROM #R WHERE Seq = 1) >= 1000, 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'ledg', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: partial "ledg" finds GL_JOURNAL', N'GL_JOURNAL', ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF(EXISTS (SELECT 1 FROM #R WHERE DatasetCode = N'GL_JOURNAL'), 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'pii', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: tag "pii" -> CUSTOMER (tag tier)', N'CUSTOMER 500+', CONCAT(N'', (SELECT DatasetCode FROM #R WHERE Seq = 1), N' ', (SELECT RelevanceScore FROM #R WHERE Seq = 1)),
       IIF((SELECT DatasetCode FROM #R WHERE Seq = 1) = N'CUSTOMER' AND (SELECT RelevanceScore FROM #R WHERE Seq = 1) BETWEEN 500 AND 599, 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'financial close', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: description phrase', N'GL_JOURNAL', ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF((SELECT COUNT(*) FROM #R) = 1 AND EXISTS (SELECT 1 FROM #R WHERE DatasetCode = N'GL_JOURNAL'), 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'data steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: steward name matches owned datasets', N'CUSTOMER,ORDER,COUNTRY present',
       ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF((SELECT COUNT(*) FROM #R WHERE DatasetCode IN (N'CUSTOMER', N'ORDER', N'COUNTRY')) = 3, 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'csv', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: source type "csv"', N'CUSTOMER', ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF(EXISTS (SELECT 1 FROM #R WHERE DatasetCode = N'CUSTOMER' AND SourceTypeCode = N'Csv'), 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'%', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: "%" is literal (no wildcard)', N'0', CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = 0 AND @c = N'OK', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'_', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: "_" is literal', N'GL_JOURNAL only', ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF((SELECT COUNT(*) FROM #R) = 1 AND EXISTS (SELECT 1 FROM #R WHERE DatasetCode = N'GL_JOURNAL'), 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N''' OR 1=1 --', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: injection text treated as data', N'OK/0', CONCAT(N'', @c, N'/', (SELECT COUNT(*) FROM #R)),
       IIF(@c = N'OK' AND (SELECT COUNT(*) FROM #R) = 0, 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.outsider', @SearchText = N'customer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Search: outsider "customer" excludes WS-SALES', N'INVOICE', ISNULL((SELECT STRING_AGG(DatasetCode, N',') FROM #R), N'<none>'),
       IIF((SELECT COUNT(*) FROM #R) = 1 AND EXISTS (SELECT 1 FROM #R WHERE DatasetCode = N'INVOICE'), 1, 0);
GO

-- ============================================================
-- 3. Filters (optional + composable)
-- ============================================================
DECLARE @c NVARCHAR(32), @m NVARCHAR(500), @Total INT;
DECLARE @Got NVARCHAR(MAX);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @ClassificationCode = N'Confidential', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: classification Confidential', N'CUSTOMER,GL_JOURNAL', @Got, IIF(@Got = N'CUSTOMER,GL_JOURNAL', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @WorkspaceCode = N'WS-FINANCE', @ClassificationCode = N'Internal', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: workspace + classification', N'INVOICE', @Got, IIF(@Got = N'INVOICE', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @CertificationStatusCode = N'Certified', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: certification Certified', N'COUNTRY,CUSTOMER', @Got, IIF(@Got = N'COUNTRY,CUSTOMER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @OwnerUserName = N'gov.owner', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: owner user', N'COUNTRY,CUSTOMER,ORDER', @Got, IIF(@Got = N'COUNTRY,CUSTOMER,ORDER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @OwnerUserName = N'finance.steward@stratapps.com', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: legacy text owner', N'INVOICE', @Got, IIF(@Got = N'INVOICE', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @StewardUserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: steward user', N'COUNTRY,CUSTOMER,ORDER', @Got, IIF(@Got = N'COUNTRY,CUSTOMER,ORDER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @MinQualityScore = 90, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: quality >= 90', N'COUNTRY', @Got, IIF(@Got = N'COUNTRY', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @MinQualityScore = 50, @MaxQualityScore = 90, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: quality 50-90', N'CUSTOMER,GL_JOURNAL', @Got, IIF(@Got = N'CUSTOMER,GL_JOURNAL', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SourceTypeCode = N'Csv', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: source type Csv', N'CUSTOMER', @Got, IIF(@Got = N'CUSTOMER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Category = N'master data', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: category (case-insensitive)', N'CUSTOMER,PRODUCT', @Got, IIF(@Got = N'CUSTOMER,PRODUCT', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @GovernanceStatusCode = N'UnderReview', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: governance UnderReview', N'GL_JOURNAL', @Got, IIF(@Got = N'GL_JOURNAL', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @DatasetStatus = N'Archived', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Filter: DatasetStatus Archived implies include (admin)', N'LEGACY_LEADS', @Got, IIF(@Got = N'LEGACY_LEADS', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.viewer', @DatasetStatus = N'Archived', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: DatasetStatus Archived (viewer)', N'0', CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = 0, 1, 0);

DECLARE @Since DATETIME2(3) = DATEADD(DAY, -90, SYSUTCDATETIME());
DECLARE @Expect INT = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery('A1000000-0000-0000-0000-000000000001', 1, 0) a
                       JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.CreatedUtc >= @Since);
TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @CreatedFrom = @Since, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: created in last 90 days', CONCAT(N'', @Expect), CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = @Expect, 1, 0);

DECLARE @USince DATETIME2(3) = DATEADD(DAY, -10, SYSUTCDATETIME());
SET @Expect = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery('A1000000-0000-0000-0000-000000000001', 1, 0) a
               JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.ModifiedUtc >= @USince);
TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @UpdatedFrom = @USince, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: updated in last 10 days', CONCAT(N'', @Expect), CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = @Expect, 1, 0);

-- Invalid filters
TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @ClassificationCode = N'Secret', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: unknown classification', N'InvalidFilter', @c, IIF(@c = N'InvalidFilter', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @WorkspaceCode = N'WS-NOPE', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: unknown workspace', N'InvalidFilter', @c, IIF(@c = N'InvalidFilter', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @MinQualityScore = 80, @MaxQualityScore = 20, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: quality min > max', N'InvalidFilter', @c, IIF(@c = N'InvalidFilter', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N'gold', @TagMatch = N'Some', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: TagMatch invalid', N'InvalidFilter', @c, IIF(@c = N'InvalidFilter', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @StewardUserName = N'gov.nobody', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Filter: unknown steward', N'InvalidFilter', @c, IIF(@c = N'InvalidFilter', 1, 0);
INSERT #T SELECT N'Filter: invalid filters return no rows', N'0', CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = 0, 1, 0);
GO

-- ============================================================
-- 4. Tag filtering + tag maintenance
-- ============================================================
DECLARE @c NVARCHAR(32), @m NVARCHAR(500);
DECLARE @Got NVARCHAR(MAX);
DECLARE @TagOut TABLE (TagName NVARCHAR(64));

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N'gold', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Tags: single tag', N'COUNTRY,CUSTOMER', @Got, IIF(@Got = N'COUNTRY,CUSTOMER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N' PII , ledger ', @TagMatch = N'Any', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Tags: multiple Any (trim + case-insensitive)', N'CUSTOMER,GL_JOURNAL', @Got, IIF(@Got = N'CUSTOMER,GL_JOURNAL', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N'gold,pii', @TagMatch = N'All', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Tags: multiple All', N'CUSTOMER', @Got, IIF(@Got = N'CUSTOMER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N'transactional', @WorkspaceCode = N'WS-SALES', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @Got = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY DatasetCode) FROM #R);
INSERT #T SELECT N'Tags: tag + workspace filter', N'ORDER', @Got, IIF(@Got = N'ORDER', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'Customer Master', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: returned as sorted list', N'customer,gold,master-data,pii,sales', (SELECT Tags FROM #R WHERE Seq = 1),
       IIF((SELECT Tags FROM #R WHERE Seq = 1) = N'customer,gold,master-data,pii,sales', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.outsider', @Tags = N'gold', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: access-aware (outsider "gold")', N'0', CONCAT(N'', (SELECT COUNT(*) FROM #R)), IIF((SELECT COUNT(*) FROM #R) = 0, 1, 0);

INSERT @TagOut EXEC cat.usp_AddDatasetTags @DatasetCode = N'ORDER', @Tags = N'test-catalog-tag', @UserName = N'gov.viewer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: viewer cannot tag', N'Unauthorized', @c, IIF(@c = N'Unauthorized', 1, 0);

INSERT @TagOut EXEC cat.usp_AddDatasetTags @DatasetCode = N'ORDER', @Tags = N'Bad Tag!', @UserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: invalid characters', N'InvalidTag', @c, IIF(@c = N'InvalidTag', 1, 0);

DELETE @TagOut;
INSERT @TagOut EXEC cat.usp_AddDatasetTags @DatasetCode = N'ORDER', @Tags = N'Test-Catalog-Tag,sales', @UserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: steward adds (normalized lower-case)', N'Tagged', @c,
       IIF(@c = N'Tagged' AND EXISTS (SELECT 1 FROM @TagOut WHERE TagName = N'test-catalog-tag'), 1, 0);

INSERT @TagOut EXEC cat.usp_AddDatasetTags @DatasetCode = N'ORDER', @Tags = N'sales', @UserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: re-adding existing tag', N'NoChange', @c, IIF(@c = N'NoChange', 1, 0);

INSERT #T SELECT N'Tags: DatasetTagged audit written', N'>=1', CONCAT(N'', COUNT(*)), IIF(COUNT(*) >= 1, 1, 0)
FROM gov.GovernanceAuditEvent WHERE EventType = N'DatasetTagged' AND DetailsJson LIKE N'%test-catalog-tag%';

INSERT @TagOut EXEC cat.usp_RemoveDatasetTags @DatasetCode = N'ORDER', @Tags = N'test-catalog-tag', @UserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: steward removes', N'Untagged', @c, IIF(@c = N'Untagged', 1, 0);

INSERT @TagOut EXEC cat.usp_RemoveDatasetTags @DatasetCode = N'ORDER', @Tags = N'test-catalog-tag', @UserName = N'gov.steward', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: removing absent tag', N'NoChange', @c, IIF(@c = N'NoChange', 1, 0);

DECLARE @Tags TABLE (TagId INT, TagName NVARCHAR(64), Description NVARCHAR(500), DatasetCount INT);
INSERT @Tags EXEC cat.usp_GetTags @UserName = N'gov.viewer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Tags: list counts only discoverable datasets (viewer, finance)', N'0', CONCAT(N'', ISNULL(MAX(DatasetCount), 0)),
       IIF(ISNULL(MAX(DatasetCount), 0) = 0, 1, 0) FROM @Tags WHERE TagName = N'finance';
INSERT #T SELECT N'Tags: list counts gold for viewer', N'2', CONCAT(N'', ISNULL(MAX(DatasetCount), 0)),
       IIF(MAX(DatasetCount) = 2, 1, 0) FROM @Tags WHERE TagName = N'gold';

DELETE FROM cat.Tag WHERE TagName = N'test-catalog-tag'
   AND NOT EXISTS (SELECT 1 FROM cat.DatasetTag dt WHERE dt.TagId = cat.Tag.TagId);
GO

-- ============================================================
-- 5. Sorting + paging
-- ============================================================
DECLARE @c NVARCHAR(32), @m NVARCHAR(500), @Total INT, @More BIT, @NextVal NVARCHAR(200), @NextId UNIQUEIDENTIFIER,
        @SortBy NVARCHAR(32), @Dir NVARCHAR(4);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'DROP TABLE x', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: unknown field', N'InvalidSort', @c, IIF(@c = N'InvalidSort', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'Relevance', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: Relevance without search text', N'InvalidSort', @c, IIF(@c = N'InvalidSort', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'Name', @SortDirection = N'UP', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: invalid direction', N'InvalidSort', @c, IIF(@c = N'InvalidSort', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @AppliedSortBy = @SortBy OUTPUT, @AppliedSortDirection = @Dir OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: default is Name ASC', N'Name ASC', CONCAT(N'', @SortBy, N' ', @Dir), IIF(@SortBy = N'Name' AND @Dir = N'ASC', 1, 0);
INSERT #T SELECT N'Sort: Name ASC ordered', N'ordered', IIF(EXISTS (SELECT 1 FROM #R a JOIN #R b ON b.Seq = a.Seq + 1 WHERE b.DatasetName < a.DatasetName), N'unordered', N'ordered'),
       IIF(EXISTS (SELECT 1 FROM #R a JOIN #R b ON b.Seq = a.Seq + 1 WHERE b.DatasetName < a.DatasetName), 0, 1);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'QualityScore', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: QualityScore DESC first', N'COUNTRY', (SELECT DatasetCode FROM #R WHERE Seq = 1), IIF((SELECT DatasetCode FROM #R WHERE Seq = 1) = N'COUNTRY', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'Classification', @SortDirection = N'DESC', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: Classification DESC first is Restricted', N'Restricted', (SELECT ClassificationCode FROM #R WHERE Seq = 1),
       IIF((SELECT ClassificationCode FROM #R WHERE Seq = 1) = N'Restricted', 1, 0);

TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'GovernanceStatus', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: GovernanceStatus ASC first is Draft', N'Draft', (SELECT GovernanceStatusCode FROM #R WHERE Seq = 1),
       IIF((SELECT GovernanceStatusCode FROM #R WHERE Seq = 1) = N'Draft', 1, 0);

DECLARE @MaxImport NVARCHAR(64) =
    (SELECT TOP (1) d.DatasetCode
     FROM cat.fn_DatasetDiscovery('A1000000-0000-0000-0000-000000000001', 1, 0) a
     JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId
     CROSS APPLY (SELECT MAX(b.ImportUtc) AS LastImportUtc FROM ingest.ImportBatch b
                  WHERE b.DatasetId = a.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')) li
     ORDER BY li.LastImportUtc DESC, d.DisplayName, d.DatasetId);
TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'LastImportDate', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Sort: LastImportDate DESC first', @MaxImport, (SELECT DatasetCode FROM #R WHERE Seq = 1),
       IIF((SELECT DatasetCode FROM #R WHERE Seq = 1) = @MaxImport, 1, 0);

-- Offset paging: pages of 2 cover the catalog exactly once
DECLARE @All NVARCHAR(MAX), @Paged NVARCHAR(MAX) = N'', @Page INT = 1, @AllCount INT;
TRUNCATE TABLE #R;
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 200, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
SET @All = (SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R);
SET @AllCount = @Total;
INSERT #T SELECT N'Paging: TotalCount = rows', CONCAT(N'', (SELECT COUNT(*) FROM #R)), CONCAT(N'', @Total), IIF(@Total = (SELECT COUNT(*) FROM #R), 1, 0);

SET @More = 1;
WHILE @More = 1 AND @Page <= 20
BEGIN
    TRUNCATE TABLE #R;
    INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 2, @PageNumber = @Page,
         @HasMore = @More OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
    SET @Paged = @Paged + IIF(@Paged = N'', N'', N',') + ISNULL((SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R), N'');
    SET @Page += 1;
END
INSERT #T SELECT N'Paging: offset pages = full list', @All, @Paged, IIF(@All = @Paged, 1, 0);
INSERT #T SELECT N'Paging: last page HasMore = 0', N'0', CONCAT(N'', @More), IIF(@More = 0, 1, 0);

-- Keyset paging (Name ASC) yields the same sequence
DECLARE @Keyset NVARCHAR(MAX) = N'', @Guard INT = 0;
SET @NextVal = NULL; SET @NextId = NULL; SET @More = 1;
WHILE @More = 1 AND @Guard < 20
BEGIN
    TRUNCATE TABLE #R;
    INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 2, @SortBy = N'Name',
         @AfterValue = @NextVal, @AfterDatasetId = @NextId, @IncludeTotalCount = 0,
         @HasMore = @More OUTPUT, @NextAfterValue = @NextVal OUTPUT, @NextAfterDatasetId = @NextId OUTPUT,
         @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
    SET @Keyset = @Keyset + IIF(@Keyset = N'', N'', N',') + ISNULL((SELECT STRING_AGG(DatasetCode, N',') WITHIN GROUP (ORDER BY Seq) FROM #R), N'');
    SET @Guard += 1;
END
INSERT #T SELECT N'Paging: keyset Name ASC = offset list', @All, @Keyset, IIF(@All = @Keyset, 1, 0);

-- Keyset paging (UpdatedDate DESC) is ordered and complete
DECLARE @KeysetRows TABLE (Seq INT IDENTITY(1,1), DatasetCode NVARCHAR(64), UpdatedUtc DATETIME2(3));
SET @NextVal = NULL; SET @NextId = NULL; SET @More = 1; SET @Guard = 0;
WHILE @More = 1 AND @Guard < 20
BEGIN
    TRUNCATE TABLE #R;
    INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 2, @SortBy = N'UpdatedDate',
         @AfterValue = @NextVal, @AfterDatasetId = @NextId, @IncludeTotalCount = 0,
         @HasMore = @More OUTPUT, @NextAfterValue = @NextVal OUTPUT, @NextAfterDatasetId = @NextId OUTPUT,
         @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
    INSERT @KeysetRows (DatasetCode, UpdatedUtc) SELECT DatasetCode, UpdatedUtc FROM #R ORDER BY Seq;
    SET @Guard += 1;
END
INSERT #T SELECT N'Paging: keyset UpdatedDate DESC complete', CONCAT(N'', @AllCount), CONCAT(N'', COUNT(DISTINCT DatasetCode)),
       IIF(COUNT(DISTINCT DatasetCode) = @AllCount AND COUNT(*) = @AllCount, 1, 0) FROM @KeysetRows;
INSERT #T SELECT N'Paging: keyset UpdatedDate DESC ordered', N'ordered',
       IIF(EXISTS (SELECT 1 FROM @KeysetRows a JOIN @KeysetRows b ON b.Seq = a.Seq + 1 WHERE b.UpdatedUtc > a.UpdatedUtc), N'unordered', N'ordered'),
       IIF(EXISTS (SELECT 1 FROM @KeysetRows a JOIN @KeysetRows b ON b.Seq = a.Seq + 1 WHERE b.UpdatedUtc > a.UpdatedUtc), 0, 1);

TRUNCATE TABLE #R;
DECLARE @AnyId UNIQUEIDENTIFIER = NEWID();
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'QualityScore', @AfterValue = N'50', @AfterDatasetId = @AnyId,
     @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Paging: keyset on QualityScore rejected', N'InvalidPaging', @c, IIF(@c = N'InvalidPaging', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'UpdatedDate', @AfterValue = N'yesterday', @AfterDatasetId = @AnyId,
     @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Paging: keyset bad date value', N'InvalidPaging', @c, IIF(@c = N'InvalidPaging', 1, 0);
INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 5000, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Paging: PageSize clamped (OK)', N'OK', @c, IIF(@c = N'OK', 1, 0);
GO

-- ============================================================
-- 6. Dataset detail (status codes; result sets print below)
-- ============================================================
DECLARE @c NVARCHAR(32), @m NVARCHAR(500);

EXEC cat.usp_GetDatasetDetail @DatasetCode = N'CUSTOMER', @UserName = N'gov.outsider', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Detail: cross-workspace dataset hidden', N'NotFound', @c, IIF(@c = N'NotFound', 1, 0);

EXEC cat.usp_GetDatasetDetail @DatasetCode = N'NO_SUCH_DATASET', @UserName = N'gov.admin', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Detail: missing dataset', N'NotFound', @c, IIF(@c = N'NotFound', 1, 0);

EXEC cat.usp_GetDatasetDetail @DatasetCode = N'LEGACY_LEADS', @UserName = N'gov.viewer', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Detail: archived hidden from viewer', N'NotFound', @c, IIF(@c = N'NotFound', 1, 0);

EXEC cat.usp_GetDatasetDetail @DatasetCode = N'CUSTOMER', @UserName = N'gov.nobody', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Detail: unknown user', N'InvalidUser', @c, IIF(@c = N'InvalidUser', 1, 0);

PRINT '--- Detail: CUSTOMER as gov.analyst (summary, tags, 3 imports, lineage, no history) ---';
EXEC cat.usp_GetDatasetDetail @DatasetCode = N'CUSTOMER', @UserName = N'gov.analyst', @RecentImportCount = 3,
     @LineageNeighborLimit = 5, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT #T SELECT N'Detail: analyst CUSTOMER', N'OK', @c, IIF(@c = N'OK', 1, 0);
GO

-- ============================================================
-- 7. Catalog summary reports (access-aware)
-- ============================================================
DECLARE @Admin UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000001';
DECLARE @Viewer UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000005';
DECLARE @AdminTotal INT = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery(@Admin, 1, 0));
DECLARE @ViewerTotal INT = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery(@Viewer, 0, 0));

DECLARE @S TABLE (TotalDiscoverable INT, ReadableCount INT, MetadataOnlyCount INT, CertifiedCount INT, UncertifiedCount INT,
                  ProfiledCount INT, AvgQualityScore DECIMAL(5,2), TaggedCount INT, WorkspaceCount INT,
                  UpdatedLast7Days INT, ImportedLast7Days INT, DeprecatedCount INT);
INSERT @S EXEC rpt.usp_CatalogSummary @UserName = N'gov.admin';
INSERT #T SELECT N'Report: summary total (admin)', CONCAT(N'', @AdminTotal), CONCAT(N'', TotalDiscoverable),
       IIF(TotalDiscoverable = @AdminTotal AND ReadableCount + MetadataOnlyCount = TotalDiscoverable
           AND CertifiedCount + UncertifiedCount = TotalDiscoverable, 1, 0) FROM @S;
DELETE @S;
INSERT @S EXEC rpt.usp_CatalogSummary @UserName = N'gov.viewer';
INSERT #T SELECT N'Report: summary total (viewer)', CONCAT(N'', @ViewerTotal), CONCAT(N'', TotalDiscoverable),
       IIF(TotalDiscoverable = @ViewerTotal AND MetadataOnlyCount >= 1, 1, 0) FROM @S;
DELETE @S;
INSERT @S EXEC rpt.usp_CatalogSummary @UserName = N'gov.nobody';
INSERT #T SELECT N'Report: summary unknown user = 0', N'0', CONCAT(N'', TotalDiscoverable), IIF(TotalDiscoverable = 0, 1, 0) FROM @S;

DECLARE @K TABLE ([Key] NVARCHAR(64), Name NVARCHAR(100), SortOrder INT, DatasetCount INT);
INSERT @K EXEC rpt.usp_CatalogByClassification @UserName = N'gov.admin';
INSERT #T SELECT N'Report: by classification sums to total', CONCAT(N'', @AdminTotal), CONCAT(N'', SUM(DatasetCount)),
       IIF(SUM(DatasetCount) = @AdminTotal AND COUNT(*) = 4, 1, 0) FROM @K;
DELETE @K;
INSERT @K EXEC rpt.usp_CatalogByClassification @UserName = N'gov.viewer';
INSERT #T SELECT N'Report: viewer sees no Restricted', N'0', CONCAT(N'', DatasetCount), IIF(DatasetCount = 0, 1, 0) FROM @K WHERE [Key] = N'Restricted';
DELETE @K;
INSERT @K EXEC rpt.usp_CatalogByGovernanceStatus @UserName = N'gov.admin';
INSERT #T SELECT N'Report: by governance status sums to total', CONCAT(N'', @AdminTotal), CONCAT(N'', SUM(DatasetCount)),
       IIF(SUM(DatasetCount) = @AdminTotal, 1, 0) FROM @K;
DELETE @K;
INSERT @K EXEC rpt.usp_CatalogByGovernanceStatus @UserName = N'gov.admin', @WorkspaceCode = N'WS-FINANCE';
INSERT #T SELECT N'Report: workspace scope (WS-FINANCE)', N'2', CONCAT(N'', SUM(DatasetCount)), IIF(SUM(DatasetCount) = 2, 1, 0) FROM @K;

DECLARE @Cat TABLE ([Key] NVARCHAR(64), Name NVARCHAR(64), SortOrder BIGINT, DatasetCount INT, CertifiedCount INT, AvgQualityScore DECIMAL(5,2));
INSERT @Cat EXEC rpt.usp_CatalogByCategory @UserName = N'gov.admin';
INSERT #T SELECT N'Report: by category sums to total', CONCAT(N'', @AdminTotal), CONCAT(N'', SUM(DatasetCount)),
       IIF(SUM(DatasetCount) = @AdminTotal, 1, 0) FROM @Cat;

DECLARE @Cert TABLE (CertificationGroup NVARCHAR(16), [Key] NVARCHAR(32), Name NVARCHAR(100), DatasetCount INT, Pct DECIMAL(5,2));
INSERT @Cert EXEC rpt.usp_CatalogCertification @UserName = N'gov.admin';
INSERT #T SELECT N'Report: certified vs uncertified', N'2 certified', CONCAT(N'', SUM(IIF(CertificationGroup = N'Certified', DatasetCount, 0)), N' certified'),
       IIF(SUM(IIF(CertificationGroup = N'Certified', DatasetCount, 0)) = 2 AND SUM(DatasetCount) = @AdminTotal, 1, 0) FROM @Cert;

DECLARE @Q TABLE (Bucket NVARCHAR(16), MinScore DECIMAL(5,2), MaxScore DECIMAL(5,2), SortOrder INT, DatasetCount INT);
INSERT @Q EXEC rpt.usp_CatalogQualityDistribution @UserName = N'gov.admin';
INSERT #T SELECT N'Report: quality distribution', N'5 buckets / Excellent=1',
       CONCAT(N'', COUNT(*), N' buckets / Excellent=', SUM(IIF(Bucket = N'Excellent', DatasetCount, 0))),
       IIF(COUNT(*) = 5 AND SUM(DatasetCount) = @AdminTotal AND SUM(IIF(Bucket = N'Excellent', DatasetCount, 0)) = 1, 1, 0) FROM @Q;

DECLARE @Since7 DATETIME2(3) = DATEADD(DAY, -7, SYSUTCDATETIME());
DECLARE @ExpectUpd INT = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery(@Admin, 1, 0) a JOIN ingest.Dataset d ON d.DatasetId = a.DatasetId WHERE d.ModifiedUtc >= @Since7);
DECLARE @U TABLE (DatasetCode NVARCHAR(64), DatasetName NVARCHAR(200), WorkspaceCode NVARCHAR(64), Category NVARCHAR(64),
                  ClassificationCode NVARCHAR(32), GovernanceStatusCode NVARCHAR(32), CertificationStatusCode NVARCHAR(32),
                  UpdatedUtc DATETIME2(3), AccessSource NVARCHAR(32), CanReadData BIT);
INSERT @U EXEC rpt.usp_CatalogRecentlyUpdated @UserName = N'gov.admin', @Days = 7, @Top = 100;
INSERT #T SELECT N'Report: recently updated (7 days)', CONCAT(N'', @ExpectUpd), CONCAT(N'', COUNT(*)), IIF(COUNT(*) = @ExpectUpd, 1, 0) FROM @U;

DECLARE @Since60 DATETIME2(3) = DATEADD(DAY, -60, SYSUTCDATETIME());
DECLARE @ExpectImp INT = (SELECT COUNT(*) FROM cat.fn_DatasetDiscovery(@Admin, 1, 0) a
                          WHERE (SELECT MAX(b.ImportUtc) FROM ingest.ImportBatch b
                                 WHERE b.DatasetId = a.DatasetId AND b.Status IN (N'Completed', N'CompletedWithErrors')) >= @Since60);
DECLARE @I TABLE (DatasetCode NVARCHAR(64), DatasetName NVARCHAR(200), WorkspaceCode NVARCHAR(64), Category NVARCHAR(64),
                  LastImportUtc DATETIME2(3), LastImportStatus NVARCHAR(32), LastImportRecords INT, SourceTypeCode NVARCHAR(32),
                  AccessSource NVARCHAR(32), CanReadData BIT);
INSERT @I EXEC rpt.usp_CatalogRecentlyImported @UserName = N'gov.admin', @Days = 60, @Top = 100;
INSERT #T SELECT N'Report: recently imported (60 days)', CONCAT(N'', @ExpectImp), CONCAT(N'', COUNT(*)), IIF(COUNT(*) = @ExpectImp, 1, 0) FROM @I;
GO

-- ============================================================
-- Results
-- ============================================================
SELECT Id, TestName, Expected, Actual, CASE WHEN Passed = 1 THEN N'PASS' ELSE N'FAIL' END AS Result
FROM #T ORDER BY Id;

DECLARE @Total INT = (SELECT COUNT(*) FROM #T), @Pass INT = (SELECT COUNT(*) FROM #T WHERE Passed = 1);
PRINT CONCAT(N'', N'Catalog tests: ', @Pass, N'/', @Total, N' passed.');
IF @Pass < @Total
    RAISERROR(N'Catalog tests failed.', 16, 1);
GO
