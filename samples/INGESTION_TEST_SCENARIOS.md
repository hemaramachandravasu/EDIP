# Ingestion Test Scenarios

Demo dataset: `CUSTOMER`  
Demo batch id (after seed): `66666666-6666-6666-6666-666666666666`

## Scenario matrix (seeded in `18_Seed_Ingestion.sql`)

| Row | CustomerCode | Expected | Rule exercised |
|-----|--------------|----------|----------------|
| 1 | CUST-001 | Valid → Processed | Happy path insert |
| 2 | CUST-002 | Valid → Processed | Happy path |
| 3 | CUST-003 | Valid → Processed | Status = Prospect |
| 4 | *(null)* | Invalid | Required CustomerCode |
| 5 | CUST-005 / ZZ | Invalid | Referential integrity (country) |
| 6 | CUST-006 | Invalid | Bad email + negative credit |
| 7 | CUST-001 (dup) | Invalid | Duplicate in batch |
| 8 | CUST-008 | Invalid | Invalid CreatedDate type |
| 9 | CUST-009 | Invalid | Invalid Status value |
| 10 | CUST-010 | Valid → Processed | Happy path |

## Manual SQL verification

```sql
-- Batch summary
EXEC ingest.usp_GetBatchStatus @BatchId = '66666666-6666-6666-6666-666666666666';

-- Errors
EXEC ingest.usp_GetErrorsByBatch @BatchId = '66666666-6666-6666-6666-666666666666';

-- Target rows
SELECT * FROM ingest.Customer ORDER BY CustomerCode;

-- Monitoring
EXEC rpt.usp_ImportSummary @FromUtc = '2020-01-01', @ToUtc = '2099-01-01';
EXEC rpt.usp_ValidationErrors @FromUtc = '2020-01-01', @ToUtc = '2099-01-01';
EXEC rpt.usp_DatasetProcessingStatistics;
```

## Retry without duplication

```sql
-- Re-run processing: already Processed rows are skipped
EXEC ingest.usp_RetryFailedBatch @BatchId = '66666666-6666-6666-6666-666666666666';

-- Customer count for CUST-001 should remain 1
SELECT CustomerCode, COUNT(*) FROM ingest.Customer GROUP BY CustomerCode;
```

## API smoke test

```http
POST /api/ingestion/batches
X-Api-Key: edip-dev-api-key
Content-Type: application/json

{
  "datasetCode": "CUSTOMER",
  "sourceInfo": "api-smoke-test",
  "records": [
    {
      "customerCode": "CUST-API-1",
      "customerName": "API Customer",
      "countryCode": "US",
      "email": "api@example.com",
      "creditLimit": "1500",
      "status": "Active",
      "createdDate": "2024-05-01"
    },
    {
      "customerCode": "CUST-API-2",
      "customerName": "Bad Country",
      "countryCode": "XX",
      "email": "bad@example.com",
      "creditLimit": "10",
      "status": "Active",
      "createdDate": "2024-05-01"
    }
  ]
}

POST /api/ingestion/batches/{batchId}/validate
POST /api/ingestion/batches/{batchId}/process
GET  /api/ingestion/batches/{batchId}/errors
GET  /api/reports/import-summary/export?format=csv
```

Expected: one customer inserted; one RI error for country `XX`; batch status `CompletedWithErrors`.
