# Job Scheduling Strategy

## Model
Schedules live in `proc.JobSchedule` (1:1 with `proc.ProcessingJob`):
- `FrequencyCode` — `Minutely`, `Hourly`, `Daily`, `Weekly`, or `Cron` (expression stored for future use)
- `IntervalMinutes` — concrete interval used by the v1 next-run calculator
- `NextRunUtc` / `LastRunUtc` — due-date driven scheduling
- `IsActive` — soft disable without deleting the job

## Dual trigger paths
1. **Manual** — `POST /api/jobs/{id}/execute` → `JobTriggerType.Manual`
2. **Agent** — SQL Agent job `EDIP_ProcessDueJobs` every 5 minutes runs `Edip.Worker --due` → `JobTriggerType.Agent`

The Agent cadence is intentionally finer than most job intervals so due jobs are picked up promptly without requiring Agent to know each job’s cron.

## Due selection
```sql
-- conceptually: proc.usp_GetDueJobs
IsEnabled = 1 AND Schedule.IsActive = 1 AND NextRunUtc <= SYSUTCDATETIME()
```

## Next-run calculation (v1)
After each attempt (success or final failure), `NextRunUtc` advances by interval:
| Frequency | Effective minutes |
|-----------|-------------------|
| Minutely | `max(1, IntervalMinutes)` |
| Hourly | `max(60, IntervalMinutes)` |
| Daily | `max(1440, IntervalMinutes)` |
| Weekly | `max(10080, IntervalMinutes)` |

`CronExpression` is persisted for forward compatibility; full cron parsing can replace the interval calculator later without schema changes.

## Retry mechanism
Configured per job:
- `MaxRetries`
- `RetryDelaySeconds` (base delay; doubles each attempt — exponential backoff)

On failure:
1. Execution status becomes `Retrying`
2. Row written to `proc.JobRetryAttempt`
3. Immediate in-process retries with backoff (suitable for Worker/API hosts)
4. If all attempts fail → `Failed` with error message retained

## Operational guidance
- Keep Agent step path aligned with the published Worker binary (`database/09_SqlAgentJobs.sql`).
- Prefer enabling/disabling via `IsEnabled` / `IsActive` rather than deleting jobs.
- Use report `job-stats` to tune intervals and retry policy.
