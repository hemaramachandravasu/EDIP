# Task 19 – SQL Analytics & Reporting Engine

Reusable SQL-based analytics layer that turns the operational tables
(datasets, import batches, ETL runs, quality profile runs) into
reporting metrics: aggregated KPIs, historical trends, dataset
comparisons, workspace roll-ups and dashboard-ready feeds.

**Stack:** SQL Server / T-SQL, stored procedures, CTEs, window functions,
views, ADO.NET (`Microsoft.Data.SqlClient`), SQL Server Agent, Git.

**Scripts:** `database/30_Schema_Analytics.sql` … `34_SqlAgentJobs_Analytics.sql`
**Code:** `Edip.Core/DTOs/AnalyticsDtos.cs`, `Edip.Infrastructure/Repositories/AnalyticsRepository.cs`,
`Edip.Infrastructure/Services/AnalyticsService.cs`, `Edip.Api/Controllers/AnalyticsController.cs`

---

## 1. Analytics database design

### New schema: `analytics`

| Object | Purpose |
|---|---|
| `analytics.Workspace` | Tenant / business-unit grouping (`WorkspaceCode`, `DisplayName`, `IsActive`). |
| `analytics.ReportingDailyMetric` | **Pre-aggregated fact**, grain = `MetricDate × DatasetId`. Import + quality measures rolled to one row per dataset per day. Rebuilt incrementally. |
| `analytics.QualityTrendSnapshot` | Period-grain quality snapshot, grain = `DatasetId × PeriodType × PeriodStart` (`Day`/`Week`/`Month`/`Quarter`). |
| `analytics.ReportRefreshLog` | Audit row per refresh/maintenance run (name, duration, rows, status, message). |

### Governance attributes added to `ingest.Dataset`

`WorkspaceId` (FK → `analytics.Workspace`), `DatasetStatus`
(`Active`/`Inactive`/`Draft`/`Archived`/`Deprecated`), `Category`,
`OwnerName`, `ModifiedUtc`. These make “count by status / category /
workspace / owner” and “recently created / modified” first-class.

### Why a pre-aggregated fact table

- Dashboards and time-series reads hit `ReportingDailyMetric`
  (a few thousand narrow rows) instead of scanning `ingest.ImportBatch`
  and `profile.ProfileRun` on every request.
- The heavy `GROUP BY CAST(date)` work happens once per night in
  `analytics.usp_RefreshDailyMetrics`, not per query.
- Trend maths (LAG, moving averages, QoQ %) run over the compact fact,
  so window functions stay cheap.

---

## 2. Stored-procedure architecture

All **reporting** procedures live in the existing `rpt` schema
(`rpt.usp_*`, `rpt.vw_*`) – the same surface the earlier modules use.
All **refresh/maintenance** procedures live in `analytics`.

| Group | Procedures |
|---|---|
| Refresh / maintenance | `analytics.usp_RefreshDailyMetrics`, `analytics.usp_SnapshotQualityTrend`, `analytics.usp_CleanupAnalyticsData` |
| Dataset analytics | `rpt.usp_DatasetCountSummary`, `rpt.usp_DatasetCountByDimension`, `rpt.usp_RecentDatasets`, `rpt.usp_DatasetActivity`, `rpt.usp_DatasetInventory` |
| Import analytics | `rpt.usp_ImportAnalyticsSummary`, `rpt.usp_ImportVolumeByDate`, `rpt.usp_ImportVolumeByDataset` |
| Data-quality analytics | `rpt.usp_QualityAnalyticsSummary`, `rpt.usp_QualityByDataset`, `rpt.usp_LowestQualityScores`, `rpt.usp_QualityIssueBreakdown` |
| Quality trend analysis | `rpt.usp_QualityTrendSeries`, `rpt.usp_QualityProfileComparison`, `rpt.usp_QualityPeriodComparison` |
| Dataset comparison | `rpt.usp_DatasetComparison` |
| Workspace analytics | `rpt.usp_WorkspaceAnalytics` |
| Time-based reporting | `rpt.usp_TimeBasedActivity`, `rpt.usp_QuarterlyTrends` |
| Dashboard feeds | `rpt.usp_DashboardKpiCards`, `rpt.usp_DashboardTrendChart`, `rpt.usp_DashboardQualityDistribution`, `rpt.usp_DashboardDatasetDistribution`, `rpt.usp_DashboardImportActivity`, `rpt.usp_DashboardTopQualityIssues`, `rpt.usp_DashboardWorkspaceSummary` |
| Export feeds | `rpt.usp_ExportDatasetInventory`, `rpt.usp_ExportImportDetail`, `rpt.usp_ExportQualityDetail` |

Shared building blocks:

- **`analytics.fn_PeriodStart(@date, @periodType)`** – deterministic bucket
  start (Monday-based weeks; `1900-01-01` is a Monday). Used by every
  `@Granularity` report so `Day/Week/Month/Quarter` share one code path.
- **`rpt.vw_LatestProfileRun`** – one row per dataset with its most recent
  succeeded `profile.ProfileRun` (via `OUTER APPLY … TOP (1)`), reused by
  the quality, comparison and workspace procedures.

Every procedure:

- takes optional `@WorkspaceId` (and usually `@DatasetCode`) filters,
- uses `@FromUtc/@ToUtc` (or `@FromDate/@ToDate`) with sensible defaults,
- returns a **single, flat, named result set** for easy ADO.NET mapping,
- paginates large detail sets with `OFFSET/FETCH` + a `TotalRows` window
  column (`usp_DatasetInventory`, `usp_DatasetComparison`).

### Reporting views (`32_Views_Analytics.sql`)

`rpt.vw_DatasetInventory`, `rpt.vw_ImportActivityDaily`,
`rpt.vw_QualityTrendMonthly`, `rpt.vw_WorkspaceSummary`,
`rpt.vw_DatasetComparison`, `rpt.vw_AnalyticsRefreshStatus`.

Views are deliberately thin projections for read-heavy / ad-hoc access.
Anything with parameters, pagination or branching stays in a procedure.

---

## 3. Quality metric calculations

The engine **does not recompute** completeness/validity/uniqueness/
consistency – those are produced by Task 18
(`profile.usp_ProfileCustomerDataset`, see `docs/13`). The analytics layer
**aggregates** the stored per-run values:

| Reported metric | Source | Aggregation |
|---|---|---|
| Overall Quality Score | `profile.ProfileRun.OverallScore` | `AVG` over latest run per dataset (summary) / per period (trend) |
| Completeness / Validity / Uniqueness / Consistency | matching `*Pct` columns | same |
| Quality Threshold Status | `profile.ProfileRun.ThresholdResult` (`Pass`/`Fail`/`Unknown`) | `SUM(CASE …)` counts |
| Failed thresholds (per run) | `profile.ThresholdResult.Passed = 0` | `COUNT` |
| Quality Issue Counts | `profile.QualityIssue` | `COUNT(*)`, `SUM(AffectedCount)` by `IssueType`/`Severity` |
| Datasets With Lowest Quality | `rpt.vw_LatestProfileRun` | `ORDER BY OverallScore ASC` |
| Grade distribution | `profile.ProfileRun.Grade` | banded `COUNT` |

“Latest” = most recent `Status = 'Succeeded'` run for the dataset.

---

## 4. Trend calculation methodology

1. **Snapshot** – `analytics.usp_SnapshotQualityTrend` expands every
   succeeded profile run into four period rows (`Day/Week/Month/Quarter`)
   via `CROSS JOIN (VALUES …)` + `analytics.fn_PeriodStart`, then
   `AVG`s per period and `MERGE`s into `analytics.QualityTrendSnapshot`
   (idempotent – safe to re-run).
2. **Series** – `rpt.usp_QualityTrendSeries` reads one dataset/period type
   and adds, with window functions over `PeriodStart`:
   - `LAG(metric)` → previous-period value,
   - `metric − LAG(metric)` → delta,
   - `AVG(OverallScore) OVER (… ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`
     → 3-point moving average.
3. **Current Profile vs Previous Profile** – `rpt.usp_QualityProfileComparison`
   uses `ROW_NUMBER() OVER (ORDER BY StartedUtc DESC)` to grab runs `rn=1`
   and `rn=2` and emits paired current/previous/delta columns.
4. **Current Period vs Previous Period** – `rpt.usp_QualityPeriodComparison`
   buckets runs into `Current` / `Previous` by `fn_PeriodStart` and
   aggregates each bucket.
5. **Quarterly trends** – `rpt.usp_QuarterlyTrends` rolls the daily fact to
   quarters and adds `LAG`-based QoQ deltas and percentage change.

---

## 5. Dataset comparison

`rpt.usp_DatasetComparison` (and `rpt.vw_DatasetComparison`) return one row
per dataset with the dashboard-ready comparison axes:

`RecordCount`, `QualityScore`, `CompletenessPct`, `ValidityPct`,
`UniquenessPct`, `ConsistencyPct`, `ImportCount` / `ImportsPerWeek`
(frequency over `@WindowDays`), `ErrorRatePct`
(`rejected / received` over the window), plus `Grade` / `ThresholdResult`.

Accepts a CSV `@DatasetCodes` (via `STRING_SPLIT`) or a `@WorkspaceId`
scope, and paginates.

---

## 6. Workspace analytics

`rpt.usp_WorkspaceAnalytics` / `rpt.vw_WorkspaceSummary` – filterable by
`@WorkspaceId`:

`DatasetCount`, `ActiveDatasetCount`, `ImportVolume`,
`DataProcessingVolume` (records processed in window),
`AvgQualityScore`, `FailedQualityThresholds`, `QualityIssues`,
`RecordsRejected`.

Intended for authorised application consumers – the API exposes it as
`GET /api/analytics/workspaces` and `…/dashboard/workspace-summary`.

---

## 7. Time-based reporting

`rpt.usp_TimeBasedActivity` – `@FromUtc`, `@ToUtc`, `@Granularity`
(`Day/Week/Month/Quarter`), `@WorkspaceId`, `@DatasetCode`.
Reads the **pre-aggregated** `analytics.ReportingDailyMetric` and buckets
with `fn_PeriodStart`, so no base-table scan. `@FromUtc/@ToUtc` map to a
half-open `MetricDate` range (SARGable against `IX_RDM_*`).

`rpt.usp_QuarterlyTrends` – last *N* quarters with QoQ deltas.

---

## 8. Indexing strategy & query optimisation

Documented decisions (see `30_Schema_Analytics.sql`):

| Index | Rationale |
|---|---|
| `IX_Dataset_Analytics` on `ingest.Dataset(WorkspaceId, DatasetStatus)` INCLUDE (`DatasetCode, DisplayName, Category, OwnerName, IsActive, CreatedUtc, ModifiedUtc`) | Covering index for “count by dimension” and inventory – no key lookups. |
| `IX_Dataset_Created` / `IX_Dataset_Modified` | Ordered scans for “recently created / modified” (`TOP … ORDER BY … DESC`). |
| `PK_ReportingDailyMetric (MetricDate, DatasetId)` | Date-leading so range scans over a reporting window are a seek + range. |
| `IX_RDM_Dataset_Date` / `IX_RDM_Workspace_Date` (covering) | Dataset drill-down and workspace roll-ups read only the index. |
| `PK_QualityTrendSnapshot (DatasetId, PeriodType, PeriodStart)` + `IX_QTS_Period` | Series-per-dataset seek; period-wide scans covered. |
| `IX_ImportBatch_Analytics` on `ingest.ImportBatch(DatasetId, ImportUtc)` INCLUDE (status/record columns) | Live import summary/volume procs run as covered range scans. |
| `IX_ProfileRun_Analytics` on `profile.ProfileRun(DatasetId, Status, StartedUtc)` INCLUDE (score columns) | `rpt.vw_LatestProfileRun`’s `OUTER APPLY TOP (1)` becomes a covered seek. |

Other choices:

- **Aggregate once, read many** – daily fact + period snapshot remove
  repeated `GROUP BY` scans from the request path.
- **Half-open date ranges** (`>= @From AND < @To`) everywhere – SARGable,
  no `CAST` on the indexed column in `WHERE` (only in `GROUP BY`).
- **`OFFSET/FETCH` pagination** with a `COUNT(*) OVER ()` `TotalRows`
  column – one round trip for page + total.
- **Set-based only** – the sole cursor is in the seed script; runtime
  procedures are pure set operations.
- **Known cost:** `GROUP BY analytics.fn_PeriodStart(...)` is a scalar-UDF
  compute over the already-filtered/aggregated set. Acceptable at this
  grain; inline the date expression if the fact grows past a few M rows.

---

## 9. ADO.NET integration

`AnalyticsRepository` (registered `AddScoped<IAnalyticsRepository, AnalyticsRepository>()`):

- **Parameterised** – every input is a `SqlParameter` (`AddWithValue` /
  `AddNullable`); `@DatasetCodes` CSV is split server-side by `STRING_SPLIT`
  (no string building).
- **Connection management** – `await using var conn = factory.CreateConnection();`
  a fresh connection per call, returned to the pool on dispose.
- **Async** – `OpenAsync`, `ExecuteReaderAsync`, `ReadAsync`, all threading
  the `CancellationToken`.
- **Command timeouts** – `60 s` for reads, `300 s` for the refresh procs
  (`RefreshTimeoutSeconds`).
- **Exception handling** – SQL errors bubble as `SqlException`; the service
  translates bad arguments to `ArgumentException`; the controller maps that
  to `400`. A missing single-row result returns `new T()` /​ `null`
  (→ `404` for profile comparison).
- One generic `QueryAsync<T>(proc, bind, map, timeout, ct)` helper keeps the
  ~25 feeds consistent.

`AnalyticsService` normalises granularity/period tokens, clamps
`take`/`page`/`days`, defaults date ranges, and drives CSV/XLSX export
through the shared `IExportService` (CsvHelper / ClosedXML).

### HTTP surface (`/api/analytics`, requires `X-Api-Key`)

```
POST /api/analytics/refresh
GET  /api/analytics/datasets/count-summary
GET  /api/analytics/datasets/count-by/{Status|Category|Workspace|Owner}
GET  /api/analytics/datasets/recent?mode=Created|Modified&days=&take=
GET  /api/analytics/datasets/activity
GET  /api/analytics/datasets/comparison?datasetCodes=CUSTOMER,ORDER&pageNumber=&pageSize=
GET  /api/analytics/imports/summary
GET  /api/analytics/imports/volume-by-date?granularity=Day|Week|Month|Quarter
GET  /api/analytics/imports/volume-by-dataset
GET  /api/analytics/quality/summary
GET  /api/analytics/quality/by-dataset
GET  /api/analytics/quality/lowest-scores?take=
GET  /api/analytics/quality/issue-breakdown
GET  /api/analytics/quality/trend/{datasetCode}?period=Month
GET  /api/analytics/quality/profile-comparison/{datasetCode}
GET  /api/analytics/quality/period-comparison?period=Month
GET  /api/analytics/workspaces?workspaceId=
GET  /api/analytics/time-based?granularity=Day&fromUtc=&toUtc=
GET  /api/analytics/quarterly-trends?quarters=8
GET  /api/analytics/dashboard/kpi-cards
GET  /api/analytics/dashboard/trend-chart
GET  /api/analytics/dashboard/quality-distribution
GET  /api/analytics/dashboard/dataset-distribution
GET  /api/analytics/dashboard/import-activity
GET  /api/analytics/dashboard/top-quality-issues
GET  /api/analytics/dashboard/workspace-summary
GET  /api/analytics/export/{dataset-inventory|import-detail|quality-detail}?format=csv|xlsx
```

---

## 10. SQL Server Agent jobs

`database/34_SqlAgentJobs_Analytics.sql` (TSQL subsystem – no Worker exe):

| Job | Schedule | Steps |
|---|---|---|
| `EDIP_RefreshAnalyticsSummary` | daily 02:15 | 1) `usp_RefreshDailyMetrics` trailing 10 days · 2) `usp_SnapshotQualityTrend` trailing 120 days |
| `EDIP_AnalyticsCleanup` | Sunday 03:00 | `usp_CleanupAnalyticsData @RetainDays = 400` |

Scheduling approach:

- The refresh window is **trailing 10 days**, not just “yesterday”, so a
  late-arriving or back-dated import batch is still picked up.
- `usp_RefreshDailyMetrics` deletes + reinserts only its window inside a
  transaction (`SET XACT_ABORT ON`), so a re-run is safe and cheap.
- The snapshot `MERGE` is idempotent; re-running only updates changed
  periods.
- Retention (400 days) keeps > 4 quarters for QoQ reporting plus headroom.
- Every run writes an `analytics.ReportRefreshLog` row
  (`rpt.vw_AnalyticsRefreshStatus` shows the latest per job).

---

## 11. Testing

`samples/ANALYTICS_TEST_SCENARIOS.md` – runnable T-SQL covering empty
datasets, large/multi-workspace data, varying scores and import statuses,
date-range filtering, dataset comparison and trend-delta accuracy, plus
expected-result assertions.

`database/33_Seed_Analytics.sql` builds a **120-day synthetic history**
(import batches ~every 3 days, profile runs ~weekly, drifting scores,
seeded quality issues) across 4 datasets / 3 workspaces so every report
returns meaningful data immediately after deployment.

---

## 12. Known limitations

- **`CUSTOMER`-shaped profiling.** Task 18’s profiler only physically
  profiles the customer dataset; `ORDER` / `PRODUCT` / `INVOICE` quality
  history in the demo is synthetic (seed script). Real deployments would
  register a profiler per dataset.
- **Weeks are Monday-based** and independent of `SET DATEFIRST` (chosen for
  determinism); adjust `fn_PeriodStart` if ISO week or a different anchor
  is required.
- **`fn_PeriodStart` in `GROUP BY`** prevents an index from satisfying the
  grouping directly – fine at the daily-fact grain, revisit if the fact
  grows very large (inline the arithmetic).
- **No row-level security.** `@WorkspaceId` is a filter, not an
  authorisation boundary; enforce tenant isolation in the API/app layer.
- **Snapshot latency.** Trend reports read `QualityTrendSnapshot`, which is
  as fresh as the last Agent run (or manual `POST /api/analytics/refresh`).
- **`ReportingDailyMetric` is import + quality only.** Metadata-refresh and
  connection-health activity are covered by the Task 1–4 reports, not this
  fact table.
