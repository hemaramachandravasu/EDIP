# Database Design

## Database
- Name: `EDIP`
- Engine: Microsoft SQL Server
- Deployment scripts: `database/01_*.sql` … `database/56_*.sql` (orchestrated by `00_DeployAll.sql`)

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

### ETL (`etl`)
| Table | Description |
|-------|-------------|
| DatasetConfig | Load mode, duplicate strategy, max retries |
| TransformRule | Reusable per-column transform steps |
| StandardizationMap | Source → canonical value |
| ValidationRule | Configurable validation |
| AllowedValue / ReferentialRule | Domain and RI helpers |
| EtlRun | Pipeline attempt metrics and duration |
| EtlError / EtlErrorArchive | Dedicated error structure + archive |
| QualitySnapshot | Scheduled dataset-level ETL quality |

### Dataset quality profiling (`profile`)
| Table | Description |
|-------|-------------|
| DatasetProfile | Dataset catalog + latest run pointer |
| ProfileRun | Unique profile execution + dataset metrics/score |
| ColumnProfile | Column completeness, uniqueness, stats |
| QualityMetric | Named metric values |
| QualityIssue | Missing/duplicate/invalid/threshold issues |
| QualityThreshold | Configurable pass/fail rules |
| ScoreWeight | Score dimension weights |
| ThresholdResult | Per-run threshold evaluation |

### Reporting (`rpt`)
Views and procedures:
- `vw_ProcessingSuccessFailureSummary` / `usp_ProcessingSuccessFailureSummary`
- `vw_DataSourceHealthStatus` / `usp_DataSourceHealthStatus`
- `vw_JobExecutionStatistics` / `usp_JobExecutionStatistics`
- `vw_MetadataRefreshStatus` / `usp_MetadataRefreshStatus`
- Import monitoring: `usp_ImportSummary`, `usp_BatchProcessingHistory`, `usp_ValidationErrors`, `usp_DatasetProcessingStatistics`, `usp_ImportErrorTrends`, `usp_FailedImports`
- ETL monitoring: `usp_EtlBatchSummary`, `usp_EtlSuccessRate`, `usp_EtlFailedBatches`, `usp_EtlValidationErrorSummary`, `usp_EtlDatasetHistory`
- Dataset profile monitoring: `usp_DatasetQualitySummary`, `usp_LowestQualityDatasets`, `usp_TopDataQualityIssues`, `usp_QualityTrendReport`, `usp_FailedQualityThresholds`, `usp_DatasetQualityComparison`, `usp_ImportQualitySummary`
- Lineage analytics: `usp_LineageMostConnected`, `usp_LineageHighestDependencies`, `usp_LineageHighestDependents`, `usp_LineageRelationshipCounts`, `usp_LineageSourceToDatasetCounts`, `usp_LineageDatasetToReport`, `usp_LineageDependencyDepth`

### Lineage (`lineage`)
| Table | Description |
|-------|-------------|
| EntityType | Node type catalog |
| LineageEntity | Polymorphic graph nodes |
| DatasetVersion | Append-only dataset versions |
| LineageRelationship | Directed edges with process/version context |
| LineageCaptureLog | Sync/capture audit |

### Governance (`gov`)
| Table | Description |
|-------|-------------|
| Classification / GovernanceStatus / CertificationStatus / AccessLevel | Reference catalogs |
| AppUser / Role / UserRole / WorkspaceMember | Minimal identity & workspace membership |
| DatasetGovernance | Classification, owner/steward, cert status on datasets |
| CertificationHistory | Append-only certification/review history |
| AccessRequest / DatasetAccessGrant | Access workflow + effective grants |
| GovernanceAuditEvent | Governance operation audit (also records share/export events) |

### Sharing & export (`share`)
| Table | Description |
|-------|-------------|
| ExportFormat / ExportStatus / ExportStatusTransition | Reference catalogs + allowed status transitions |
| ExportPolicy | Per-classification minimum access level / certification requirement for export |
| DatasetShare / DatasetShareHistory | Current share state (one active per dataset+recipient) + append-only history |
| ExportableColumn | Whitelist of exportable/filterable/sortable columns per dataset |
| ExportRequest / ExportRequestSpec | Narrow request header + 1:1 JSON spec (columns, filters, sort) |
| ExportStatusHistory / ExportDownload | Append-only status transitions and download log |

### Data catalog (`cat`)
The catalog is a query layer over existing tables (no catalog dataset table); see `docs/18-SQL-Data-Catalog-Discovery.md`.

| Table | Description |
|-------|-------------|
| Tag / DatasetTag | The platform's single dataset tag structure (lower-case unique tag names, dataset ↔ tag link) |
| DiscoveryPolicy | Per-classification minimum workspace role needed to discover a dataset |

## Indexing highlights
- Filtered unique index on `reg.DataSource(Name)` where not deleted
- `jobs.JobSchedule(NextRunUtc)` filtered to active schedules for due scans
- Covering indexes on execution and validation timestamps for reporting
- `ingest.ImportBatch(Status)` filtered covering index for pending-batch scans
- `ingest.StagingCustomer(BatchId, RowStatus)` for validation/process set operations
- Unique `ingest.Customer(CustomerCode)` for MERGE upserts
- `etl.EtlRun(DatasetId, StartedUtc)` and `etl.EtlError(BatchId, ErrorCode)` for monitoring
- `ingest.ImportBatch(DatasetId, ImportUtc DESC) INCLUDE (DataSourceId)` filtered to batches with a registered source (catalog source type, ~15% fewer reads measured)

## Security considerations
- Encrypted passwords stored only in `reg.SqlConnectionDetail.EncryptedPassword`
- Application login should have DML on `reg`/`meta`/`jobs`/`ingest` and execute on `rpt`/`ingest` procedures — not `db_owner` in production
- SQL Agent service account needs rights to execute the Worker process and/or T-SQL Agent steps against `EDIP`

## Seed data
`08_SeedData.sql` inserts connector types, a local SQL catalog source, a sample CSV source, and two demo jobs (health check + metadata refresh).  
`18_Seed_Ingestion.sql` seeds countries, the CUSTOMER dataset, import Agent jobs, and a mixed valid/invalid demo batch.  
`23_Seed_Etl.sql` seeds transform/validation rules, ETL jobs, and a transformation demo batch.  
`28_Seed_Profile.sql` seeds score weights, thresholds, profile jobs, and a demo profile run.  
`38_Seed_Lineage.sql` syncs platform lineage, seeds a multi-hop demo graph, and lineage jobs.