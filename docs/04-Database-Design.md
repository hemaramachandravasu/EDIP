# Database Design

## Database
- Name: `EDIP`
- Engine: Microsoft SQL Server
- Deployment scripts: `database/01_*.sql` … `database/09_*.sql` (orchestrated by `00_DeployAll.sql`)

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

### Processing (`proc`)
| Table | Description |
|-------|-------------|
| ProcessingJob | Job definition + retry policy |
| JobSchedule | Due-date schedule |
| JobExecution | Run header |
| JobExecutionLog | Step/failure detail |
| JobRetryAttempt | Retry audit |

### Reporting (`rpt`)
Views and procedures:
- `vw_ProcessingSuccessFailureSummary` / `usp_ProcessingSuccessFailureSummary`
- `vw_DataSourceHealthStatus` / `usp_DataSourceHealthStatus`
- `vw_JobExecutionStatistics` / `usp_JobExecutionStatistics`
- `vw_MetadataRefreshStatus` / `usp_MetadataRefreshStatus`

## Indexing highlights
- Filtered unique index on `reg.DataSource(Name)` where not deleted
- `proc.JobSchedule(NextRunUtc)` filtered to active schedules for due scans
- Covering indexes on execution and validation timestamps for reporting

## Security considerations
- Encrypted passwords stored only in `reg.SqlConnectionDetail.EncryptedPassword`
- Application login should have DML on `reg`/`meta`/`proc` and execute on `rpt`/`proc` procedures — not `db_owner` in production
- SQL Agent service account needs rights to execute the Worker process and read its configuration

## Seed data
`08_SeedData.sql` inserts connector types, a local SQL catalog source, a sample CSV source, and two demo jobs (health check + metadata refresh).
