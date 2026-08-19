# Enterprise Data Intelligence Platform

Centralized **Data Source Registry**, **Metadata Repository**, and **Data Processing Management** built on SQL Server, T-SQL, ADO.NET, SQL Server Agent, and ASP.NET Core Web API.

## Solution structure

```
database/          SQL deploy scripts (schemas, procs, views, seed, Agent job)
docs/              Technical documentation
src/Edip.Api       ASP.NET Core Web API
src/Edip.Core      Models, DTOs, interfaces
src/Edip.Infrastructure  ADO.NET repos, probes, encryption, exporters
src/Edip.Worker    Console worker for Agent / manual runs
```

> Targets **.NET 10** (SDK installed in this environment). Projects use ADO.NET only (no EF Core).

## Prerequisites
- .NET 10 SDK
- SQL Server (Developer/Express/Standard) with SQL Server Agent for scheduled jobs
- Optional: MySQL / PostgreSQL instances when validating those connectors

## Database deployment

In SSMS or `sqlcmd`, run scripts in order (or use `00_DeployAll.sql` with SQLCMD mode):

1. `database/01_CreateDatabase.sql`
2. `database/02_Schema_Registry.sql`
3. `database/03_Schema_Metadata.sql`
4. `database/04_Schema_Processing.sql`
5. `database/05_Schema_Monitoring.sql`
6. `database/06_StoredProcedures.sql`
7. `database/07_Views_Reports.sql`
8. `database/08_SeedData.sql`
9. After publishing the Worker, update the path in `database/09_SqlAgentJobs.sql` and execute it

Example:

```powershell
sqlcmd -S localhost -E -C -I -i "database\01_CreateDatabase.sql"
sqlcmd -S localhost -E -C -I -i "database\02_Schema_Registry.sql"
# ... continue through 08
```

Flags:
- `-C` — trust server certificate (required for ODBC Driver 18 / local SSL)
- `-I` — `QUOTED_IDENTIFIER ON` (required for filtered indexes)

## Configure & run API

Edit `src/Edip.Api/appsettings.json`:

```json
"Edip": {
  "ConnectionString": "Server=localhost;Database=EDIP;Trusted_Connection=True;TrustServerCertificate=True;",
  "ApiKey": "edip-dev-api-key",
  "DataProtectionKeysPath": "dp-keys"
}
```

```powershell
dotnet run --project src/Edip.Api
```

- Swagger UI: `https://localhost:<port>/swagger`
- Health: `GET /health` (no API key)
- All `/api/*` routes require header `X-Api-Key: edip-dev-api-key`

## Sample API calls

```http
GET /api/datasources
X-Api-Key: edip-dev-api-key

POST /api/datasources
X-Api-Key: edip-dev-api-key
Content-Type: application/json

{
  "name": "Warehouse MySQL",
  "dataSourceTypeCode": "MySql",
  "sqlConnection": {
    "host": "localhost",
    "port": 3306,
    "databaseName": "sales",
    "authMode": "SqlPassword",
    "username": "readonly",
    "password": "secret",
    "trustServerCertificate": true,
    "connectionTimeoutSeconds": 30
  }
}

POST /api/datasources/{id}/validate
POST /api/metadata/refresh/{id}
POST /api/jobs/{id}/execute
GET  /api/reports/datasource-health
GET  /api/reports/processing-summary/export?format=xlsx
GET  /api/reports/job-stats/export?format=csv
```

### Report names
| Name | Description |
|------|-------------|
| `processing-summary` | Daily success/failure rates |
| `datasource-health` | Source health + 24h validation failures |
| `job-stats` | Per-job execution statistics |
| `metadata-refresh` | Last refresh status per source |

## Worker (Agent / CLI)

```powershell
dotnet run --project src/Edip.Worker -- --due
dotnet run --project src/Edip.Worker -- --jobId <guid>
```

Publish for Agent:

```powershell
dotnet publish src/Edip.Worker -c Release -o C:\Edip\Edip.Worker
```

Then run `database/09_SqlAgentJobs.sql` (set `@WorkerPath` to the published exe).

## Documentation
- [Metadata Repository Design](docs/01-Metadata-Repository-Design.md)
- [Data Processing Architecture](docs/02-Data-Processing-Architecture.md)
- [Job Scheduling Strategy](docs/03-Job-Scheduling-Strategy.md)
- [Database Design](docs/04-Database-Design.md)
- [Future Scalability](docs/05-Future-Scalability.md)
- [Profiling Methodology](docs/06-Profiling-Methodology.md)
- [Quality Scoring Approach](docs/07-Quality-Scoring-Approach.md)
- [Metadata Synchronization Design](docs/08-Metadata-Synchronization-Design.md)
- [Automation Strategy](docs/09-Automation-Strategy.md)
- [Future Enhancement Recommendations](docs/10-Future-Enhancement-Recommendations.md)
- [Data Ingestion Pipeline](docs/11-Data-Ingestion-Pipeline.md)
- [ETL Pipeline](docs/12-ETL-Pipeline.md)

## Data Quality module (profiling / scoring / sync)

```http
POST /api/metadata-sync/{dataSourceId}
POST /api/profiling/{dataSourceId}
POST /api/quality/{dataSourceId}/assess
GET  /api/reports/data-quality
GET  /api/reports/dataset-health
GET  /api/reports/schema-changes
GET  /api/reports/metadata-sync
GET  /api/reports/quality-trend/export?format=xlsx
```

Local catalog demo id: `AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA`

## Data Ingestion module (staging / validation / monitoring)

```http
POST /api/ingestion/batches
POST /api/ingestion/batches/{batchId}/validate
POST /api/ingestion/batches/{batchId}/process
POST /api/ingestion/batches/{batchId}/retry
GET  /api/ingestion/batches/{batchId}/errors
GET  /api/reports/import-summary/export?format=xlsx
GET  /api/reports/batch-history/export?format=csv
GET  /api/reports/validation-errors
GET  /api/reports/dataset-processing
GET  /api/reports/failed-imports
```

Deploy SQL scripts `15`–`18` (included in `00_DeployAll.sql` / `Deploy-Edip.ps1`), then optionally `19_SqlAgentJobs_Ingestion.sql`.  
See [Data Ingestion Pipeline](docs/11-Data-Ingestion-Pipeline.md) and [test scenarios](samples/INGESTION_TEST_SCENARIOS.md).

## ETL module (transform / validate / load)

```http
POST /api/etl/batches
POST /api/etl/batches/{batchId}/run
POST /api/etl/batches/{batchId}/retry
GET  /api/etl/batches/{batchId}/errors
POST /api/etl/generate-test-batch?rowCount=1000
GET  /api/reports/etl-batch-summary/export?format=xlsx
GET  /api/reports/etl-success-rate
GET  /api/reports/etl-failed-batches
GET  /api/reports/etl-validation-errors
GET  /api/reports/etl-dataset-history
```

Deploy SQL scripts `20`–`23`, then optionally `24_SqlAgentJobs_Etl.sql`.  
See [ETL Pipeline](docs/12-ETL-Pipeline.md) and [ETL test scenarios](samples/ETL_TEST_SCENARIOS.md).

## Capabilities covered
1. Data source registry (SQL Server, MySQL, PostgreSQL, CSV, Excel) with validation & health
2. Metadata repository (tables, views, columns, types, relationships, refresh history)
3. Processing jobs (register, schedule, manual run, history, failure logs, retries)
4. Monitoring reports (T-SQL views/procs + API)
5. Excel/CSV export
6. Technical documentation
7. Data profiling, quality scoring, metadata sync with schema-change history
8. SQL Agent automation for profiling / sync / archive jobs
9. Staging ingestion, validation, curated load, error history, import monitoring & scheduled processing
10. Configurable ETL transforms, rule-based validation, transactional load, duplicate strategies, bounded retry
