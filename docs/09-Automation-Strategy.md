# Automation Strategy

## Job types added
| JobType | Action |
|---------|--------|
| `DataProfiling` | Profile registered SQL Server source |
| `QualityAssessment` | Score latest profiling run |
| `MetadataSync` | Sync metadata + schema change detection |
| `ArchiveProfilingHistory` | Purge DQ history older than retention (default 90 days) |

## Agent jobs
1. `EDIP_ProcessDueJobs` (existing) — polls due schedules every 5 minutes including new DQ jobs  
2. `EDIP_ScheduledProfiling` / `EDIP_ArchiveProfilingHistory` — optional dedicated Agent wrappers (`database/14_SqlAgentJobs_Quality.sql`)

## Recommended cadence
| Workload | Cadence |
|----------|---------|
| Metadata sync | Hourly |
| Profiling | Daily off-peak |
| Quality assessment | Daily after profiling |
| Archive | Weekly |

Seed script `13_Seed_Quality.sql` installs these schedules for the local demo catalog.

## Failure handling
Retries use the existing job retry policy (`MaxRetries`, exponential backoff) and write `jobs.JobExecutionLog` / `jobs.JobRetryAttempt`.
