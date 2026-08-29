# Dataset Quality Profiling — Test Scenarios

## Prerequisites
Deploy scripts `25`–`28`. Ensure `ingest.Customer` has rows (from ingestion/ETL seeds).

## Scenario matrix

| Scenario | How to produce | Expected |
|----------|----------------|----------|
| Completely valid curated set | Profile `CUSTOMER` / `Processed` after clean ETL loads | High Completeness/Validity/Uniqueness; few or no MissingValue issues |
| Missing values | Stage rows with null CustomerName/Email; profile `Staging` | Column NullPct > 0; `MissingValue` issues |
| Duplicate-heavy | Insert two `ingest.Customer` rows with same CustomerCode (or stage dupes) | DuplicateRecords > 0; UniquenessPct drops; `DuplicateRecord` issue |
| Invalid records | Profile with recent `etl.EtlError` rows | ValidationFailure / DataTypeIssue / UnexpectedValue issues; Validity may drop for Staging scope |
| Mixed quality | Use seeded ETL demo data + processed customers | Score mid/high; threshold Pass or Fail per seed rules |
| Empty dataset | Truncate target temporarily / profile empty Staging batch | `EmptyDataset` Critical issue; Completeness treated as 100 on zero cells; Overall still computed |
| Large dataset | `POST /api/etl/generate-test-batch?rowCount=5000` then ETL run, then profile | Completes with DurationMs logged; ColumnsProfiled = 7 |
| Threshold pass | Overall ≥ 75 (CUSTOMER override) and dimension rules met | `ThresholdResult = Pass` |
| Threshold fail | Lower `OVERALL_SCORE` threshold or degrade data | `ThresholdResult = Fail`; `ThresholdBreach` issues; `failed-quality-thresholds` report rows |

## SQL smoke test

```sql
DECLARE @RunId UNIQUEIDENTIFIER;
EXEC profile.usp_ProfileCustomerDataset
    @DatasetCode = N'CUSTOMER',
    @ProfileScope = N'Processed',
    @TriggerType = N'Manual',
    @ProfileRunId = @RunId OUTPUT;

EXEC profile.usp_GetProfileRun @ProfileRunId = @RunId;
EXEC profile.usp_GetColumnProfiles @ProfileRunId = @RunId;
EXEC profile.usp_GetQualityIssues @ProfileRunId = @RunId;
EXEC profile.usp_GetThresholdResults @ProfileRunId = @RunId;
EXEC profile.usp_GetQualityTrend @DatasetCode = N'CUSTOMER';

EXEC rpt.usp_DatasetQualitySummary;
EXEC rpt.usp_LowestQualityDatasets @Take = 5;
EXEC rpt.usp_TopDataQualityIssues @Take = 20;
```

## API smoke test

```http
POST /api/dataset-profile/CUSTOMER?scope=Processed
X-Api-Key: edip-dev-api-key

GET /api/dataset-profile/CUSTOMER/score
GET /api/dataset-profile/runs/{profileRunId}/columns
GET /api/dataset-profile/runs/{profileRunId}/issues
GET /api/dataset-profile/runs/{profileRunId}/thresholds
GET /api/dataset-profile/CUSTOMER/trend
GET /api/reports/dataset-quality-summary
GET /api/reports/failed-quality-thresholds/export?format=csv
```

## Historical comparison
Run profiling twice (optionally change data between runs). Trend query should populate `Prev*` and `Delta*` columns on the second run.
