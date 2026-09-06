# Task 19 – Sample Analytics Report Outputs

Illustrative shapes returned after deploying scripts `30`–`33`
(figures come from the synthetic 120-day seed, so exact numbers vary per
`NEWID()` run — the **columns and relationships** are the contract).

---

## KPI cards — `GET /api/analytics/dashboard/kpi-cards`

```json
{
  "totalDatasets": 4,
  "activeDatasets": 3,
  "imports30d": 41,
  "importsPrev30d": 38,
  "importSuccessRate30dPct": 79.31,
  "recordsProcessed30d": 402118,
  "recordsRejected30d": 4123,
  "avgQualityScore": 77.44,
  "datasetsFailingThreshold": 1,
  "openQualityIssues": 37
}
```

## Dataset count by dimension — `GET /api/analytics/datasets/count-by/Category`

| Dimension | DimensionValue | DatasetCount | ActiveCount | SharePct |
|---|---|---|---|---|
| Category | Master Data | 2 | 2 | 50.00 |
| Category | Transactional | 2 | 1 | 50.00 |

`GET /api/analytics/datasets/count-by/Workspace`

| Dimension | DimensionValue | DatasetCount | ActiveCount | SharePct |
|---|---|---|---|---|
| Workspace | WS-SALES | 2 | 2 | 50.00 |
| Workspace | WS-OPS | 1 | 1 | 25.00 |
| Workspace | WS-FINANCE | 1 | 0 | 25.00 |

## Import analytics summary — `GET /api/analytics/imports/summary`

```json
{
  "totalImports": 163,
  "successfulImports": 126,
  "failedImports": 17,
  "completedWithErrors": 20,
  "inProgressOrPending": 0,
  "recordsReceived": 1616540,
  "recordsProcessed": 1487002,
  "recordsRejected": 16233,
  "recordsInserted": 892201,
  "recordsUpdated": 594801,
  "errorCount": 16318,
  "importSuccessRatePct": 77.30,
  "avgProcessingSeconds": 131.482,
  "rejectRatePct": 1.0042
}
```

## Import volume by date (weekly) — `GET /api/analytics/imports/volume-by-date?granularity=Week`

| PeriodStart | Granularity | ImportCount | SuccessfulImports | FailedImports | RecordsProcessed | SuccessRatePct |
|---|---|---|---|---|---|---|
| 2026-06-01 | Week | 9 | 7 | 1 | 78 231 | 77.78 |
| 2026-06-08 | Week | 10 | 8 | 1 | 85 442 | 80.00 |
| 2026-06-15 | Week | 8 | 7 | 0 | 79 004 | 87.50 |
| … | | | | | | |

## Quality analytics summary — `GET /api/analytics/quality/summary`

```json
{
  "datasetsWithProfile": 4,
  "avgOverallScore": 77.44,
  "minOverallScore": 61.00,
  "maxOverallScore": 93.00,
  "avgCompletenessPct": 85.13,
  "avgValidityPct": 82.06,
  "avgUniquenessPct": 94.28,
  "avgConsistencyPct": 91.77,
  "thresholdPassing": 3,
  "thresholdFailing": 1,
  "thresholdUnknown": 0,
  "totalQualityIssues": 21,
  "gradeA": 1, "gradeB": 1, "gradeC": 1, "gradeD": 1, "gradeF": 0
}
```

## Quality trend series — `GET /api/analytics/quality/trend/CUSTOMER?period=Month`

| PeriodStart | OverallScore | PrevOverallScore | DeltaOverallScore | OverallScore3pMovingAvg |
|---|---|---|---|---|
| 2026-05-01 | 79.10 | *null* | *null* | 79.10 |
| 2026-06-01 | 81.44 | 79.10 | 2.34 | 80.27 |
| 2026-07-01 | 82.03 | 81.44 | 0.59 | 80.86 |
| 2026-08-01 | 84.60 | 82.03 | 2.57 | 82.69 |
| 2026-09-01 | 85.02 | 84.60 | 0.42 | 83.88 |

## Current vs previous profile — `GET /api/analytics/quality/profile-comparison/CUSTOMER`

```json
{
  "datasetCode": "CUSTOMER",
  "currentRunId": "…", "currentUtc": "2026-09-04T02:14:07",
  "previousRunId": "…", "previousUtc": "2026-08-28T02:11:52",
  "currentOverallScore": 85.02, "previousOverallScore": 84.60, "deltaOverallScore": 0.42,
  "currentCompletenessPct": 93.11, "previousCompletenessPct": 92.40, "deltaCompletenessPct": 0.71,
  "currentGrade": "B", "previousGrade": "B",
  "currentThreshold": "Pass", "previousThreshold": "Pass",
  "currentIssueCount": 3, "previousIssueCount": 5
}
```

## Dataset comparison — `GET /api/analytics/datasets/comparison?datasetCodes=CUSTOMER,ORDER,PRODUCT,INVOICE`

| DatasetCode | RecordCount | QualityScore | CompletenessPct | ValidityPct | UniquenessPct | ConsistencyPct | ImportsPerWeek | ErrorRatePct | Grade | TotalRows |
|---|---|---|---|---|---|---|---|---|---|---|
| PRODUCT | 71 204 | 93.00 | 98.10 | 97.40 | 95.02 | 96.11 | 2.10 | 0.83 | A | 4 |
| CUSTOMER | 58 900 | 85.02 | 93.11 | 90.55 | 94.80 | 92.40 | 2.33 | 1.02 | B | 4 |
| ORDER | 120 044 | 74.10 | 82.00 | 79.90 | 93.10 | 90.00 | 2.33 | 2.41 | C | 4 |
| INVOICE | 40 220 | 61.00 | 68.20 | 66.10 | 92.00 | 88.70 | 2.10 | 3.90 | D | 4 |

## Workspace analytics — `GET /api/analytics/workspaces`

| WorkspaceCode | DatasetCount | ActiveDatasetCount | ImportVolume | DataProcessingVolume | AvgQualityScore | FailedQualityThresholds | QualityIssues |
|---|---|---|---|---|---|---|---|
| WS-SALES | 2 | 2 | 78 | 712 044 | 79.56 | 0 | 8 |
| WS-OPS | 1 | 1 | 40 | 402 100 | 93.00 | 0 | 0 |
| WS-FINANCE | 1 | 0 | 41 | 372 880 | 61.00 | 1 | 13 |

## Quality distribution — `GET /api/analytics/dashboard/quality-distribution`

| ScoreBand | BandOrder | DatasetCount | SharePct |
|---|---|---|---|
| 90-100 (A) | 1 | 1 | 25.00 |
| 80-89 (B) | 2 | 1 | 25.00 |
| 70-79 (C) | 3 | 1 | 25.00 |
| 60-69 (D) | 4 | 1 | 25.00 |
| 0-59 (F) | 5 | 0 | 0.00 |

## Quarterly trends — `GET /api/analytics/quarterly-trends?quarters=4`

| QuarterLabel | ImportCount | RecordsProcessed | AvgOverallScore | DeltaImportCount | ImportCountQoQPct |
|---|---|---|---|---|---|
| Q2 2026 | 58 | 512 004 | 74.90 | *null* | *null* |
| Q3 2026 | 91 | 861 220 | 79.10 | 33 | 56.90 |

## Export

```http
GET /api/analytics/export/dataset-inventory?format=xlsx
GET /api/analytics/export/import-detail?format=csv&fromUtc=2026-08-01&toUtc=2026-09-06
GET /api/analytics/export/quality-detail?format=xlsx&datasetCode=CUSTOMER
```

`dataset-inventory` CSV header:

```
DatasetCode,DisplayName,WorkspaceCode,Category,OwnerName,DatasetStatus,IsActive,CreatedUtc,ModifiedUtc,OverallScore,Grade,ThresholdResult,IssueCount,ProfiledUtc,TotalImports
CUSTOMER,Customer Master,WS-SALES,Master Data,sbalakrishna@stratapps.com,Active,True,2026-05-02T09:12:00,2026-08-20T00:00:00,85.02,B,Pass,3,2026-09-04T02:14:07,41
```
