# Database Design

## Database
- Name: `EDIP`
- Engine: Microsoft SQL Server
- Deployment scripts: `database/01_*.sql` … `database/19_*.sql` (orchestrated by `00_DeployAll.sql`)

## Schema map

### Registry (`reg`)
| Table | Description |
|-------|-------------|
| DataSourceType | Enumeration of connector kinds |
| DataSource | Logical source registry (status, health, soft delete) |
| SqlConnectionDetail | Host/port/database/auth + encrypted password |
| FileDataSourceDetail | Path, format, delimiter, sheet |
| ConnectionValidationLog | Validation attempt history |

### Metadata (`meta`)
| Table | Description |
|-------|-------------|
| SchemaObject | Tables/views |
| ColumnDefinition | Columns |
| ObjectRelationship | FK-style relationships |
| MetadataRefreshHistory | Refresh audit |

### Processing (`jobs`)
| Table | Description |
|-------|-------------|
| ProcessingJob | Job definition + retry policy |
| JobSchedule | Due-date schedule |
| JobExecution | Run header |
| JobExecutionLog | Step/failure detail |
| JobRetryAttempt | Retry audit |

### Ingestion (`ingest`)
| Table | Description |
|-------|-------------|
| Dataset | Ingestible dataset catalog |
| ImportBatch | Batch identity, counts, status, timing |
| BatchProcessAttempt | Retry / attempt audit |
| ImportError | Row/column validation errors |
| StagingCustomer | Staging layer for customer imports |
| Customer | Curated target dataset |
| Country | Reference data for RI validation |

### Reporting (`rpt`)
Views and procedures:
- `vw_ProcessingSuccessFailureSummary` / `usp_ProcessingSuccessFailureSummary`
- `vw_DataSourceHealthStatus` / `usp_DataSourceHealthStatus`
- `vw_JobExecutionStatistics` / `usp_JobExecutionStatistics`
- `vw_MetadataRefreshStatus` / `usp_MetadataRefreshStatus`
- Import monitoring: `usp_ImportSummary`, `usp_BatchProcessingHistory`, `usp_ValidationErrors`, `usp_DatasetProcessingStatistics`, `usp_ImportErrorTrends`, `usp_FailedImports`

## Indexing highlights
- Filtered unique index on `reg.DataSource(Name)` where not deleted
- `jobs.JobSchedule(NextRunUtc)` filtered to active schedules for due scans
- Covering indexes on execution and validation timestamps for reporting
- `ingest.ImportBatch(Status)` filtered covering index for pending-batch scans
- `ingest.StagingCustomer(BatchId, RowStatus)` for validation/process set operations
- Unique `ingest.Customer(CustomerCode)` for MERGE upserts

## Security considerations
- Encrypted passwords stored only in `reg.SqlConnectionDetail.EncryptedPassword`
- Application login should have DML on `reg`/`meta`/`jobs`/`ingest` and execute on `rpt`/`ingest` procedures — not `db_owner` in production
- SQL Agent service account needs rights to execute the Worker process and/or T-SQL Agent steps against `EDIP`

## Seed data
`08_SeedData.sql` inserts connector types, a local SQL catalog source, a sample CSV source, and two demo jobs (health check + metadata refresh).  
`18_Seed_Ingestion.sql` seeds countries, the CUSTOMER dataset, import Agent jobs, and a mixed valid/invalid demo batch.