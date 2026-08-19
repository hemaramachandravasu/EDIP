# ETL Test Scenarios

Demo batch (after `23_Seed_Etl.sql`): `77777777-AAAA-BBBB-CCCC-666666666666`  
Import id: `AAAAAAAA-1111-2222-3333-444444444444`

## Seeded row matrix

| Row | Input highlights | Expected |
|-----|------------------|----------|
| 1 | padded code, `usa`, `$12,500.00`, status `a`, `01/15/2024` | Transform + Valid + Processed (`ETL-001`, US, 12500, Active) |
| 2 | `GB` country | Transform GB→UK; Processed |
| 3 | missing CustomerCode | Invalid `REQ_CUSTOMER_CODE` |
| 4 | country `ZZ` | Invalid `RI_COUNTRY` |
| 5 | bad email + negative credit | Invalid email and `MIN_CREDIT` |
| 6 | duplicate `etl-001` | Invalid `DUP_IN_BATCH` |
| 7 | `not-a-date` | Transform warning/error + type validation |
| 8 | status `P`, date `20240601` | Transform to Prospect / ISO date; Processed |

## SQL checks

```sql
EXEC etl.usp_GetBatchStatus @BatchId = '77777777-AAAA-BBBB-CCCC-666666666666';
EXEC etl.usp_GetErrorsByBatch @BatchId = '77777777-AAAA-BBBB-CCCC-666666666666';
SELECT CustomerCode, CustomerName, CountryCode, CreditLimit, Status, CreatedDate
FROM ingest.Customer WHERE CustomerCode LIKE N'ETL-%';

EXEC rpt.usp_EtlBatchSummary @FromUtc = '2020-01-01', @ToUtc = '2099-01-01';
EXEC rpt.usp_EtlSuccessRate @FromUtc = '2020-01-01', @ToUtc = '2099-01-01';
```

## Duplicate strategies

```sql
-- Reject: existing ETL-001 should error DUP_TARGET if re-imported as Valid
-- Skip: matched keys become Skipped; target row unchanged
-- Update: MERGE refreshes name/credit on the same CustomerCode
```

## Transaction rollback

```sql
DECLARE @Bid UNIQUEIDENTIFIER;
EXEC ingest.usp_CreateImportBatch
    @DatasetCode = N'CUSTOMER', @SourceFile = N'rollback.csv',
    @LoadMode = N'Full', @DuplicateStrategy = N'Update', @BatchId = @Bid OUTPUT;
-- load at least one valid staging row, then:
EXEC ingest.usp_CompleteStagingLoad @BatchId = @Bid;
EXEC etl.usp_RunPipeline @BatchId = @Bid, @ForceFail = 1;
-- Target ingest.Customer is unchanged; batch Status = Failed; etl.EtlRun.Status = RolledBack
```

## Retry without duplication

```sql
EXEC etl.usp_RetryFailedBatch @BatchId = '77777777-AAAA-BBBB-CCCC-666666666666';
SELECT CustomerCode, COUNT(*) FROM ingest.Customer GROUP BY CustomerCode HAVING COUNT(*) > 1;
```

## Large batch

```sql
DECLARE @Large UNIQUEIDENTIFIER;
EXEC etl.usp_GenerateTestBatch @RowCount = 1000, @BatchId = @Large OUTPUT;
EXEC etl.usp_RunPipeline @BatchId = @Large, @TriggerType = N'Manual';
```

Or `POST /api/etl/generate-test-batch?rowCount=1000` then `POST /api/etl/batches/{id}/run`.

## Partial validation

Valid rows from the demo batch load while rejected rows remain in `etl.EtlError`. Batch status is `CompletedWithErrors`.
