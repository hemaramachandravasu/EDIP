-- ============================================================
-- 40_Tests_Lineage.sql
-- Validation scenarios for lineage engine
-- ============================================================
USE EDIP;
GO

PRINT '=== 1. Simple / multi-level upstream for DEMO_DATASET_C ===';
EXEC lineage.usp_GetUpstreamLineage @DatasetCode = N'DEMO_DATASET_C', @MaxDepth = 10;

PRINT '=== 2. Downstream / impact from DEMO_DATASET_A ===';
EXEC lineage.usp_ImpactAnalysis @DatasetCode = N'DEMO_DATASET_A', @ChangeType = N'Dataset', @MaxDepth = 10;

PRINT '=== 3. Circular detection ===';
EXEC lineage.usp_DetectCircularDependencies;

PRINT '=== 4. Version lineage for CUSTOMER (if versions exist) ===';
EXEC lineage.usp_GetVersionLineage @DatasetCode = N'CUSTOMER';

PRINT '=== 5. Workspace filter (DEFAULT only) ===';
DECLARE @Ws UNIQUEIDENTIFIER = (SELECT TOP 1 WorkspaceId FROM analytics.Workspace WHERE WorkspaceCode = N'WS-SALES');
IF @Ws IS NULL SELECT TOP 1 @Ws = WorkspaceId FROM analytics.Workspace;
EXEC lineage.usp_GetDownstreamLineage @DatasetCode = N'DEMO_DATASET_A', @WorkspaceId = @Ws, @MaxDepth = 10;

PRINT '=== 6. Analytics feeds ===';
EXEC rpt.usp_LineageMostConnected @Take = 10;
EXEC rpt.usp_LineageRelationshipCounts;
EXEC rpt.usp_LineageDatasetToReport;
EXEC rpt.usp_LineageDependencyDepth;

PRINT '=== 7. Empty lineage (unknown dataset) ===';
EXEC lineage.usp_GetUpstreamLineage @DatasetCode = N'__NONE__';

PRINT 'Lineage tests complete.';
GO
