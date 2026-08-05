# Future Scalability Recommendations

## Near-term (next iteration)
- Add OAuth2 / Entra ID instead of static API keys; introduce role-based authorization (Admin, Operator, Reader).
- Persist full cron evaluation (NCrontab / Cronos) using `JobSchedule.CronExpression`.
- Move long-running extracts to a durable queue (Azure Service Bus / RabbitMQ) with competing Worker consumers.
- Add OpenTelemetry traces/metrics around probes, refreshes, and job executions.

## Data platform growth
- Partition `proc.JobExecution` and `proc.JobExecutionLog` by month once volume exceeds tens of millions of rows.
- Introduce `SnapshotId` versioning for metadata if multiple analytics consumers need historical schemas.
- Multi-tenant isolation via `TenantId` on registry/metadata tables with row-level security.

## Connector ecosystem
- Add Oracle, Snowflake, BigQuery, REST/SaaS connectors behind the same `IConnectionProbe` contract.
- Support cloud object storage (S3/ADLS) for file sources with SAS/managed identity auth.
- Capture data profiling and classification tags for AI governance.

## Analytics & AI readiness
- Expose a read-optimized catalog API / GraphQL layer for BI tools.
- Publish metadata change events to enable lineage and impact analysis.
- Use the metadata graph as grounding context for NL-to-SQL and semantic modeling modules.

## High availability
- Run API on multiple instances behind a load balancer; share Data Protection keys via blob/Redis.
- Run Workers as a scaled deployment; use leasing (`sp_getapplock` or queue visibility timeout) so each due job is claimed once.
- Host EDIP database on Always On / Business Critical tier with automated backups.
