# Profiling Methodology

## Scope
The profiling engine analyzes registered SQL Server data sources (v1). It produces table- and column-level statistics used by quality scoring.

## Metrics collected
| Level | Metric | Method |
|-------|--------|--------|
| Table | Row count | `COUNT_BIG(*)` |
| Table | Duplicate surplus | `GROUP BY` all profiled columns with `HAVING COUNT > 1` (skipped for very large tables) |
| Table | Empty flag | `RowCount = 0` |
| Table | Freshness proxy | `sys.tables.modify_date` |
| Column | Null count / % | Conditional aggregation |
| Column | Distinct count | `COUNT(DISTINCT col)` |
| Column | Min / Max | Where type is comparable |
| Column | Invalid samples | Heuristic on char columns with `id` in the name |

## Run model
1. Create `dq.ProfilingRun` (`Running`)
2. Prefer tables from `meta.SchemaObject`; otherwise discover live `sys.tables`
3. Persist `dq.TableProfile` + `dq.ColumnProfile`
4. Complete run as `Succeeded` / `Failed`

## Limits (v1 safeguards)
- Max 40 tables per run
- Max 30 columns per table
- Duplicate scan skipped when row count > 500,000

## API
- `POST /api/profiling/{dataSourceId}`
- `GET /api/profiling/runs/{runId}`
- `GET /api/profiling/source/{dataSourceId}`

## Automation
Job type `DataProfiling` is executed by `Edip.Worker` / SQL Agent due-job polling.
