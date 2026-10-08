-- ============================================================
-- 58_Perf_Catalog.sql  (manual; NOT part of the deploy)
-- Large-catalog benchmark for the catalog query layer.
-- Builds a synthetic catalog (20 workspaces, @N datasets with
-- governance, quality scores, 5 import batches each, 3 tags each)
-- inside ONE transaction, measures logical reads + elapsed time
-- per scenario, evaluates a candidate name index (rejected) and the
-- kept IX_ImportBatch_Dataset_Source, then ROLLS EVERYTHING BACK.
-- Run: sqlcmd -S localhost -E -C -I -i database\58_Perf_Catalog.sql
-- ============================================================
USE EDIP;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;

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
IF OBJECT_ID('tempdb..#S') IS NOT NULL DROP TABLE #S;
CREATE TABLE #S (TotalDiscoverable INT, ReadableCount INT, MetadataOnlyCount INT, CertifiedCount INT, UncertifiedCount INT,
                 ProfiledCount INT, AvgQualityScore DECIMAL(5,2), TaggedCount INT, WorkspaceCount INT,
                 UpdatedLast7Days INT, ImportedLast7Days INT, DeprecatedCount INT);
GO

DECLARE @N INT = 20000;
DECLARE @P TABLE (Id INT IDENTITY(1,1), Scenario NVARCHAR(100), Variant NVARCHAR(60), LogicalReads BIGINT, ElapsedMs INT, RowsReturned INT);
DECLARE @r0 BIGINT, @t0 DATETIME2(7), @c NVARCHAR(32), @m NVARCHAR(500), @Total INT, @More BIT,
        @NextVal NVARCHAR(200), @NextId UNIQUEIDENTIFIER;
DECLARE @Viewer UNIQUEIDENTIFIER = 'A1000000-0000-0000-0000-000000000005';
DECLARE @CsvSource UNIQUEIDENTIFIER = (SELECT TOP (1) ds.DataSourceId FROM reg.DataSource ds
                                       JOIN reg.DataSourceType t ON t.DataSourceTypeId = ds.DataSourceTypeId
                                       WHERE t.TypeCode = N'Csv' AND ds.IsDeleted = 0);
DECLARE @SqlSource UNIQUEIDENTIFIER = (SELECT TOP (1) ds.DataSourceId FROM reg.DataSource ds
                                       JOIN reg.DataSourceType t ON t.DataSourceTypeId = ds.DataSourceTypeId
                                       WHERE t.TypeCode = N'SqlServer' AND ds.IsDeleted = 0);
DECLARE @Build DATETIME2(7) = SYSDATETIME();

BEGIN TRANSACTION;

-- ---------------- synthetic catalog ----------------
DECLARE @Ws TABLE (n INT PRIMARY KEY, WorkspaceId UNIQUEIDENTIFIER);
INSERT @Ws SELECT n, NEWID() FROM (SELECT TOP (20) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) x;
INSERT analytics.Workspace (WorkspaceId, WorkspaceCode, DisplayName)
SELECT WorkspaceId, CONCAT(N'PERF-WS-', n), CONCAT(N'Perf Workspace ', n) FROM @Ws;

-- viewer joins one synthetic workspace (1/20 of the synthetic catalog)
INSERT gov.WorkspaceMember (WorkspaceId, UserId, RoleCode)
SELECT WorkspaceId, @Viewer, N'Analyst' FROM @Ws WHERE n = 1;

SELECT TOP (@N) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n, NEWID() AS DatasetId
INTO #Num
FROM sys.all_columns a CROSS JOIN sys.all_columns b;
CREATE UNIQUE CLUSTERED INDEX CX ON #Num (n);

INSERT ingest.Dataset (DatasetId, DatasetCode, DisplayName, Description, StagingTable, TargetTable,
                       WorkspaceId, DatasetStatus, Category, OwnerName, CreatedUtc, ModifiedUtc)
SELECT x.DatasetId,
       CONCAT(N'PERF_', RIGHT(CONCAT(N'000000', x.n), 6)),
       CONCAT(w1.Word, N' ', w2.Word, N' ', x.n),
       CONCAT(N'Synthetic ', LOWER(w1.Word), N' dataset for catalog benchmarking, batch ', x.n % 97),
       N'perf.Staging', N'perf.Target',
       ws.WorkspaceId,
       CASE WHEN x.n % 50 = 0 THEN N'Deprecated' WHEN x.n % 101 = 0 THEN N'Archived' ELSE N'Active' END,
       cg.Category,
       CONCAT(N'owner', x.n % 300, N'@perf.local'),
       DATEADD(MINUTE, -x.n * 7, SYSUTCDATETIME()),
       DATEADD(MINUTE, -((x.n * 7919) % 500000), SYSUTCDATETIME())
FROM #Num x
INNER JOIN @Ws ws ON ws.n = (x.n % 20) + 1
CROSS APPLY (SELECT CHOOSE((x.n % 20) + 1, N'Sales', N'Ledger', N'Customer', N'Inventory', N'Shipment', N'Payroll', N'Marketing',
                          N'Claims', N'Policy', N'Supplier', N'Returns', N'Pricing', N'Forecast', N'Budget', N'Campaign',
                          N'Asset', N'Vendor', N'Order', N'Invoice', N'Product') AS Word) w1
CROSS APPLY (SELECT CHOOSE(((x.n / 20) % 5) + 1, N'Daily', N'Snapshot', N'History', N'Master', N'Feed') AS Word) w2
CROSS APPLY (SELECT CHOOSE((x.n % 8) + 1, N'Transactional', N'Master Data', N'Reference Data', N'Financial',
                          N'Marketing', N'Operational', N'Analytics', N'Compliance') AS Category) cg;

INSERT gov.DatasetGovernance (DatasetId, WorkspaceId, ClassificationCode, GovernanceStatusCode, CertificationStatusCode, OwnerUserId, StewardUserId)
SELECT x.DatasetId, ws.WorkspaceId,
       CHOOSE((x.n % 4) + 1, N'Public', N'Internal', N'Confidential', N'Restricted'),
       CHOOSE((x.n % 5) + 1, N'Draft', N'UnderReview', N'Certified', N'Certified', N'Expired'),
       CASE WHEN x.n % 5 IN (2, 3) THEN N'Certified' ELSE N'NotCertified' END,
       CASE WHEN x.n % 10 = 0 THEN 'A1000000-0000-0000-0000-000000000002' END,
       CASE WHEN x.n % 10 = 5 THEN 'A1000000-0000-0000-0000-000000000003' END
FROM #Num x INNER JOIN @Ws ws ON ws.n = (x.n % 20) + 1;

INSERT profile.DatasetProfile (DatasetId, LatestOverallScore, LatestThresholdResult, IsEnabled)
SELECT x.DatasetId, CAST((x.n * 37) % 10000 / 100.0 AS DECIMAL(5,2)), N'Unknown', 0
FROM #Num x WHERE x.n % 10 < 7;

-- 5 batches per dataset; only every 5th dataset has a registered source,
-- on its OLDEST batch (worst case for the source-type lookup)
INSERT ingest.ImportBatch (DatasetId, DataSourceId, ImportUtc, Status, TotalRecords, ValidRecords)
SELECT x.DatasetId,
       CASE WHEN k.k = 1 AND x.n % 5 = 0 THEN IIF(x.n % 10 = 0, @CsvSource, @SqlSource) END,
       DATEADD(HOUR, k.k * 24 - (x.n % 2000), SYSUTCDATETIME()),
       CASE WHEN (x.n + k.k) % 7 = 0 THEN N'Failed' ELSE N'Completed' END,
       1000 + x.n % 500, 990 + x.n % 500
FROM #Num x CROSS JOIN (VALUES (1), (2), (3), (4), (5)) k (k);

INSERT cat.Tag (TagName)
SELECT CONCAT(N'perf-tag-', RIGHT(CONCAT(N'0', n), 2)) FROM (SELECT TOP (50) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) t;

INSERT cat.DatasetTag (DatasetId, TagId)
SELECT DISTINCT x.DatasetId, t.TagId
FROM #Num x
CROSS APPLY (VALUES (x.n % 50 + 1), ((x.n * 7) % 50 + 1), ((x.n * 13) % 50 + 1)) v (k)
INNER JOIN cat.Tag t ON t.TagName = CONCAT(N'perf-tag-', RIGHT(CONCAT(N'0', v.k), 2));

UPDATE STATISTICS ingest.Dataset;
UPDATE STATISTICS gov.DatasetGovernance;
UPDATE STATISTICS ingest.ImportBatch;
UPDATE STATISTICS cat.DatasetTag;

PRINT CONCAT(N'Synthetic catalog built: ', @N, N' datasets, ', @N * 5, N' batches in ',
             DATEDIFF(MILLISECOND, @Build, SYSDATETIME()), N' ms.');

-- warm-up (compile, buffer pool)
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;

-- ---------------- scenarios (with catalog indexes) ----------------
-- 1. admin, first page by name (no total count: infinite-scroll pattern)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'1 Admin browse, page 1 (Name)', N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 1b. same page plus total count (count = full discoverable set)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'1b Admin browse, page 1 + total (', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 2. admin, deep page by OFFSET (page 400 → offset 9,975)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @PageNumber = 400, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'2 Admin deep page 400 (OFFSET)', N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 3. same depth by KEYSET (cursor taken from the row before page 400)
SELECT @NextVal = DatasetName, @NextId = DatasetId FROM #R WHERE Seq = 1;
DECLARE @KeyVal NVARCHAR(200), @KeyId UNIQUEIDENTIFIER;
SELECT TOP (1) @KeyVal = d.DisplayName, @KeyId = d.DatasetId
FROM ingest.Dataset d
WHERE d.DisplayName < @NextVal OR (d.DisplayName = @NextVal AND d.DatasetId < @NextId)
ORDER BY d.DisplayName DESC, d.DatasetId DESC;
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @SortBy = N'Name', @AfterValue = @KeyVal, @AfterDatasetId = @KeyId, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'3 Admin deep page (KEYSET, same rows)', N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 4. non-admin (candidate pruning: own workspaces + grants/shares)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.viewer', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'4 Viewer browse page 1 (total ', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 5. text search (leading-wildcard LIKE + relevance)
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'ledger snapshot', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'5 Admin search "ledger snapshot" (total ', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 6. tag filter
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @Tags = N'perf-tag-07,perf-tag-43', @TagMatch = N'All', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'6 Admin tags All (total ', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 7. composite filters
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @WorkspaceCode = N'PERF-WS-3', @ClassificationCode = N'Confidential', @MinQualityScore = 50, @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'7 Admin workspace+class+quality (total ', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 8. sort by last import
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SortBy = N'LastImportDate', @PageSize = 25, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'8 Admin sort LastImportDate', N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 9. source-type filter
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SourceTypeCode = N'Csv', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'9 Admin source type Csv (total ', @Total, N')'), N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

-- 10. summary report
SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #S; INSERT #S EXEC rpt.usp_CatalogSummary @UserName = N'gov.admin';
INSERT @P SELECT N'10 Catalog summary report (admin)', N'with indexes', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT TotalDiscoverable FROM #S);

-- ---------------- index evaluation (inside the transaction) ----------------
-- Candidate index (rejected): covering name index on ingest.Dataset
CREATE INDEX IX_Dataset_DisplayName ON ingest.Dataset (DisplayName, DatasetId)
    INCLUDE (DatasetCode, WorkspaceId, DatasetStatus, IsActive, Category, CreatedUtc, ModifiedUtc);

SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'1 Admin browse, page 1 (Name)', N'with candidate IX_Dataset_DisplayName', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @PageSize = 25, @SortBy = N'Name', @AfterValue = @KeyVal, @AfterDatasetId = @KeyId, @IncludeTotalCount = 0, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT N'3 Admin deep page (KEYSET, same rows)', N'with candidate IX_Dataset_DisplayName', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

DROP INDEX IX_Dataset_DisplayName ON ingest.Dataset;

-- Kept index: drop it to show its benefit
DROP INDEX IX_ImportBatch_Dataset_Source ON ingest.ImportBatch;

SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SearchText = N'ledger snapshot', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'5 Admin search "ledger snapshot" (total ', @Total, N')'), N'without IX_ImportBatch_Dataset_Source', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID; SET @t0 = SYSDATETIME();
TRUNCATE TABLE #R; INSERT #R EXEC cat.usp_SearchCatalog @UserName = N'gov.admin', @SourceTypeCode = N'Csv', @PageSize = 25, @TotalCount = @Total OUTPUT, @StatusCode = @c OUTPUT, @StatusMessage = @m OUTPUT;
INSERT @P SELECT CONCAT(N'9 Admin source type Csv (total ', @Total, N')'), N'without IX_ImportBatch_Dataset_Source', (SELECT logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID) - @r0, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()), (SELECT COUNT(*) FROM #R);

ROLLBACK TRANSACTION;
DROP TABLE IF EXISTS #Num;

SELECT Scenario, Variant, LogicalReads, ElapsedMs, RowsReturned FROM @P ORDER BY Scenario, Id;

DECLARE @After INT = (SELECT COUNT(*) FROM ingest.Dataset);
DECLARE @Ix2 NVARCHAR(3) = IIF(EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ImportBatch_Dataset_Source'), N'yes', N'no');
PRINT CONCAT(N'Rolled back. Datasets now: ', @After, N'; IX_ImportBatch_Dataset_Source present: ', @Ix2);
GO
