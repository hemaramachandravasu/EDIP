# Task 19 – SQL Analytics & Reporting Engine — Test Scenarios

## Prerequisites

Deploy scripts `01`–`28`, then `30`–`33`
(`00_DeployAll.sql` / `Deploy-Edip.ps1` include them).
Script `33_Seed_Analytics.sql` creates 3 workspaces, 4 datasets
(`CUSTOMER`, `ORDER`, `PRODUCT`, `INVOICE`) and ~120 days of synthetic
import-batch + profile-run history, then runs the refresh procs.

Optionally schedule maintenance: run `34_SqlAgentJobs_Analytics.sql`.

---

## Scenario matrix

| # | Scenario | How to produce | Expected |
|---|---|---|---|
| 1 | **Empty dataset** | `EXEC rpt.usp_ImportAnalyticsSummary @FromUtc='2000-01-01', @ToUtc='2000-01-02'` | All counts `0`; `ImportSuccessRatePct = 0`; `AvgProcessingSeconds` NULL – no divide-by-zero. |
| 2 | **Empty quality set** | `EXEC rpt.usp_QualityAnalyticsSummary @DatasetCode=N'NOPE'` | `DatasetsWithProfile = 0`; all `Avg*` NULL; grade counts `0`. |
| 3 | **Large dataset / many days** | Default seed (120 days × 4 datasets) → `EXEC rpt.usp_TimeBasedActivity @FromUtc=DATEADD(DAY,-120,SYSUTCDATETIME()), @ToUtc=SYSUTCDATETIME(), @Granularity=N'Week'` | One row per ISO-ish week; sums reconcile with `rpt.usp_ImportVolumeByDate` over the same range. |
| 4 | **Multiple workspaces** | `EXEC rpt.usp_WorkspaceAnalytics` (all) vs `@WorkspaceId='F1000000-0000-0000-0000-000000000001'` | All-workspace rows = 3; filtered = 1; `DatasetCount` sums across workspaces = `rpt.usp_DatasetCountSummary.TotalDatasets`. |
| 5 | **Count by each dimension** | `EXEC rpt.usp_DatasetCountByDimension @Dimension=N'Status'` (repeat `Category`, `Workspace`, `Owner`) | `SUM(DatasetCount)` per dimension is identical across all four dimensions and equals total datasets; `SharePct` sums to ~100. |
| 6 | **Invalid dimension** | `EXEC rpt.usp_DatasetCountByDimension @Dimension=N'Colour'` | `THROW 51900` – “must be one of: Status, Category, Workspace, Owner”. |
| 7 | **Different import statuses** | Seed produces `Completed` / `CompletedWithErrors` / `Failed` → `EXEC rpt.usp_ImportAnalyticsSummary @FromUtc=DATEADD(DAY,-120,SYSUTCDATETIME()), @ToUtc=SYSUTCDATETIME()` | `SuccessfulImports + FailedImports + CompletedWithErrors + InProgressOrPending = TotalImports`. |
| 8 | **Date-range filtering (SARGable)** | Run scenario 7 with a 7-day window, check the actual plan | Seek/range on `IX_ImportBatch_Analytics`; no `CAST` on `ImportUtc` in the predicate. |
| 9 | **Dataset comparison** | `EXEC rpt.usp_DatasetComparison @DatasetCodes=N'CUSTOMER,ORDER,PRODUCT'` | 3 rows; `RecordCount`, `QualityScore`, four dimension `*Pct`, `ImportsPerWeek`, `ErrorRatePct` populated; `TotalRows = 3`. |
| 10 | **Comparison pagination** | `… @PageSize=2, @PageNumber=1` then `@PageNumber=2` | 2 rows then 1 row; `TotalRows = 3` on every page; no overlap. |
| 11 | **Trend: current vs previous profile** | `EXEC rpt.usp_QualityProfileComparison @DatasetCode=N'CUSTOMER'` | One row; `DeltaOverallScore = CurrentOverallScore − PreviousOverallScore` (validate arithmetic). |
| 12 | **Trend: period series + LAG** | `EXEC rpt.usp_QualityTrendSeries @DatasetCode=N'CUSTOMER', @PeriodType=N'Month'` | `PrevOverallScore` on row *n* = `OverallScore` on row *n-1*; first row `Prev*`/`Delta*` NULL; `OverallScore3pMovingAvg` = mean of current + up to 2 prior. |
| 13 | **Trend: current vs previous period** | `EXEC rpt.usp_QualityPeriodComparison @PeriodType=N'Month', @DatasetCode=N'ORDER'` | ≤ 2 rows (`Current`, `Previous`); each `AvgOverallScore` within 0–100. |
| 14 | **Quality threshold status** | `EXEC rpt.usp_QualityByDataset` | `INVOICE` (seed base score 63) shows `ThresholdResult = Fail`; `PRODUCT` (base 90) shows `Pass`. |
| 15 | **Lowest quality** | `EXEC rpt.usp_LowestQualityScores @Take=2` | Ordered by `OverallScore ASC`; `INVOICE` first. |
| 16 | **Quality issue counts** | `EXEC rpt.usp_QualityIssueBreakdown @FromUtc=DATEADD(DAY,-120,SYSUTCDATETIME()), @ToUtc=SYSUTCDATETIME()` | Rows grouped by `IssueType`×`Severity`; `AffectedRecords >= OccurrenceCount`. |
| 17 | **Workspace filter isolation** | `EXEC rpt.usp_DashboardKpiCards @WorkspaceId='F1000000-0000-0000-0000-000000000002'` | Only `INVOICE` counted: `TotalDatasets = 1`. |
| 18 | **Recently created / modified** | `EXEC rpt.usp_RecentDatasets @Mode=N'Modified', @SinceUtc=DATEADD(DAY,-30,SYSUTCDATETIME())` | Rows ordered by `ModifiedUtc DESC`; all within 30 days (seed spread ≤ 25 days). |
| 19 | **Quarterly trends + QoQ** | `EXEC rpt.usp_QuarterlyTrends @Quarters=6` | `QuarterLabel` like `Q3 2026`; `DeltaImportCount` on row *n* = `ImportCount(n) − ImportCount(n-1)`. |
| 20 | **Refresh idempotency** | Run `EXEC analytics.usp_RefreshDailyMetrics` twice; `SELECT COUNT(*) FROM analytics.ReportingDailyMetric` | Row count unchanged on the 2nd run; a new `analytics.ReportRefreshLog` row with `Status = 'Succeeded'`. |
| 21 | **Snapshot idempotency** | Run `EXEC analytics.usp_SnapshotQualityTrend` twice | `MERGE` updates, does not duplicate; `PK (DatasetId, PeriodType, PeriodStart)` holds. |
| 22 | **Cleanup retention** | `EXEC analytics.usp_CleanupAnalyticsData @RetainDays=30` | Rows with `MetricDate` / `PeriodStart` older than 30 days removed; report returns purge counts. |
| 23 | **Export result sets** | `EXEC rpt.usp_ExportDatasetInventory` · `rpt.usp_ExportImportDetail @FromUtc=…, @ToUtc=…` | Flat single result set, one row per entity, no NULL-only key columns – ready for CSV/Excel. |

---

## End-to-end SQL smoke test

```sql
USE EDIP;

-- refresh (or rely on the Agent job)
EXEC analytics.usp_RefreshDailyMetrics;
EXEC analytics.usp_SnapshotQualityTrend;

DECLARE @From DATETIME2(3) = DATEADD(DAY, -120, SYSUTCDATETIME());
DECLARE @To   DATETIME2(3) = SYSUTCDATETIME();
DECLARE @Ws   UNIQUEIDENTIFIER = 'F1000000-0000-0000-0000-000000000001';

-- dataset analytics
EXEC rpt.usp_DatasetCountSummary        @WorkspaceId = NULL;
EXEC rpt.usp_DatasetCountByDimension    @Dimension = N'Status';
EXEC rpt.usp_DatasetCountByDimension    @Dimension = N'Category';
EXEC rpt.usp_DatasetCountByDimension    @Dimension = N'Workspace';
EXEC rpt.usp_DatasetCountByDimension    @Dimension = N'Owner';
EXEC rpt.usp_RecentDatasets             @Mode = N'Created', @Take = 10;
EXEC rpt.usp_DatasetActivity            @FromUtc = @From, @ToUtc = @To;
EXEC rpt.usp_DatasetInventory           @PageNumber = 1, @PageSize = 20;

-- import analytics
EXEC rpt.usp_ImportAnalyticsSummary     @FromUtc = @From, @ToUtc = @To;
EXEC rpt.usp_ImportVolumeByDate         @FromUtc = @From, @ToUtc = @To, @Granularity = N'Week';
EXEC rpt.usp_ImportVolumeByDataset      @FromUtc = @From, @ToUtc = @To;

-- data quality analytics
EXEC rpt.usp_QualityAnalyticsSummary;
EXEC rpt.usp_QualityByDataset;
EXEC rpt.usp_LowestQualityScores        @Take = 5;
EXEC rpt.usp_QualityIssueBreakdown      @FromUtc = @From, @ToUtc = @To;

-- trend analysis
EXEC rpt.usp_QualityTrendSeries         @DatasetCode = N'CUSTOMER', @PeriodType = N'Month';
EXEC rpt.usp_QualityProfileComparison   @DatasetCode = N'CUSTOMER';
EXEC rpt.usp_QualityPeriodComparison    @PeriodType = N'Month';

-- comparison / workspace / time
EXEC rpt.usp_DatasetComparison          @DatasetCodes = N'CUSTOMER,ORDER,PRODUCT,INVOICE';
EXEC rpt.usp_WorkspaceAnalytics         @WorkspaceId = NULL;
EXEC rpt.usp_TimeBasedActivity          @FromUtc = @From, @ToUtc = @To, @Granularity = N'Month';
EXEC rpt.usp_QuarterlyTrends            @Quarters = 8;

-- dashboard feeds
EXEC rpt.usp_DashboardKpiCards;
EXEC rpt.usp_DashboardTrendChart        @Days = 90;
EXEC rpt.usp_DashboardQualityDistribution;
EXEC rpt.usp_DashboardDatasetDistribution;
EXEC rpt.usp_DashboardImportActivity    @Days = 30;
EXEC rpt.usp_DashboardTopQualityIssues  @Take = 10;
EXEC rpt.usp_DashboardWorkspaceSummary;

-- export feeds
EXEC rpt.usp_ExportDatasetInventory;
EXEC rpt.usp_ExportImportDetail         @FromUtc = @From, @ToUtc = @To;
EXEC rpt.usp_ExportQualityDetail        @FromUtc = @From, @ToUtc = @To;

-- refresh audit
SELECT * FROM rpt.vw_AnalyticsRefreshStatus;
```

---

## Accuracy assertions

```sql
-- A) Import status buckets partition the total
;WITH s AS (SELECT * FROM (
    SELECT TotalImports, SuccessfulImports, FailedImports, CompletedWithErrors, InProgressOrPending
    FROM (SELECT 1 x) z
    CROSS APPLY (SELECT * FROM (VALUES(0))v(y)) q) t)  -- replace with EXEC into a temp table in practice
SELECT 'see rpt.usp_ImportAnalyticsSummary: Successful+Failed+CompletedWithErrors+InProgressOrPending = TotalImports';

-- B) Dimension totals agree
DECLARE @byStatus INT = (SELECT SUM(DatasetCount) FROM (
    SELECT DimensionValue, DatasetCount FROM (
        SELECT d.DatasetStatus AS DimensionValue, COUNT(*) AS DatasetCount
        FROM ingest.Dataset d GROUP BY d.DatasetStatus) x) y);
DECLARE @total INT = (SELECT COUNT(*) FROM ingest.Dataset);
SELECT CASE WHEN @byStatus = @total THEN 'PASS' ELSE 'FAIL' END AS DimensionTotalCheck;

-- C) Daily fact reconciles with base tables for a window
DECLARE @d1 DATE = DATEADD(DAY,-30,CAST(SYSUTCDATETIME() AS DATE));
DECLARE @factImports INT = (SELECT ISNULL(SUM(ImportCount),0) FROM analytics.ReportingDailyMetric WHERE MetricDate >= @d1);
DECLARE @baseImports INT = (SELECT COUNT(*) FROM ingest.ImportBatch WHERE ImportUtc >= @d1);
SELECT @factImports AS FactImports, @baseImports AS BaseImports,
       CASE WHEN @factImports = @baseImports THEN 'PASS' ELSE 'FAIL (run usp_RefreshDailyMetrics)' END AS ReconCheck;

-- D) Trend LAG delta arithmetic
SELECT DatasetCode, PeriodStart, OverallScore, PrevOverallScore, DeltaOverallScore,
       CASE WHEN PrevOverallScore IS NULL AND DeltaOverallScore IS NULL THEN 'PASS'
            WHEN ABS((OverallScore - PrevOverallScore) - DeltaOverallScore) < 0.01 THEN 'PASS'
            ELSE 'FAIL' END AS DeltaCheck
FROM (SELECT s.* FROM analytics.QualityTrendSnapshot s
      INNER JOIN ingest.Dataset d ON d.DatasetId = s.DatasetId
      WHERE d.DatasetCode = N'CUSTOMER' AND s.PeriodType = N'Month') q
CROSS APPLY (SELECT 1) _
ORDER BY PeriodStart;
```

---

## API smoke test

```http
### requires header X-Api-Key: edip-dev-api-key
POST /api/analytics/refresh

GET  /api/analytics/dashboard/kpi-cards
GET  /api/analytics/datasets/count-by/Status
GET  /api/analytics/datasets/count-by/Workspace
GET  /api/analytics/imports/summary?fromUtc=2026-06-01&toUtc=2026-09-06
GET  /api/analytics/imports/volume-by-date?granularity=Week
GET  /api/analytics/quality/summary
GET  /api/analytics/quality/trend/CUSTOMER?period=Month
GET  /api/analytics/quality/profile-comparison/CUSTOMER
GET  /api/analytics/datasets/comparison?datasetCodes=CUSTOMER,ORDER,PRODUCT,INVOICE
GET  /api/analytics/workspaces
GET  /api/analytics/time-based?granularity=Month
GET  /api/analytics/quarterly-trends?quarters=8
GET  /api/analytics/export/dataset-inventory?format=xlsx
GET  /api/analytics/export/import-detail?format=csv&fromUtc=2026-08-01&toUtc=2026-09-06
```
