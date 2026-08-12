using Edip.Core.DTOs;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;
using Microsoft.Extensions.Logging;

namespace Edip.Infrastructure.Services;

public sealed class ProcessingJobService(
    IProcessingJobRepository jobRepository,
    IDataSourceService dataSourceService,
    IMetadataService metadataService,
    IProfilingService profilingService,
    IQualityAssessmentService qualityAssessmentService,
    IMetadataSyncService metadataSyncService,
    IIngestionService ingestionService,
    ILogger<ProcessingJobService> logger) : IProcessingJobService
{
    public async Task<IReadOnlyList<ProcessingJobDto>> GetAllAsync(CancellationToken ct = default)
    {
        var jobs = await jobRepository.GetAllAsync(ct);
        return jobs.Select(MapDto).ToList();
    }

    public async Task<ProcessingJobDto?> GetByIdAsync(Guid jobId, CancellationToken ct = default)
    {
        var job = await jobRepository.GetByIdAsync(jobId, ct);
        return job is null ? null : MapDto(job);
    }

    public async Task<ProcessingJobDto> CreateAsync(CreateProcessingJobRequest request, CancellationToken ct = default)
    {
        if (!Enum.TryParse<ProcessingJobType>(request.JobType, true, out var jobType))
            throw new ArgumentException($"Invalid job type '{request.JobType}'.");

        var job = new ProcessingJob
        {
            JobName = request.JobName,
            Description = request.Description,
            DataSourceId = request.DataSourceId,
            JobType = jobType,
            IsEnabled = request.IsEnabled,
            MaxRetries = request.MaxRetries,
            RetryDelaySeconds = request.RetryDelaySeconds,
            Schedule = request.Schedule is null ? null : new JobSchedule
            {
                FrequencyCode = request.Schedule.FrequencyCode,
                IntervalMinutes = Math.Max(1, request.Schedule.IntervalMinutes),
                CronExpression = request.Schedule.CronExpression,
                IsActive = request.Schedule.IsActive,
                NextRunUtc = DateTime.UtcNow.AddMinutes(Math.Max(1, request.Schedule.IntervalMinutes))
            }
        };

        var id = await jobRepository.CreateAsync(job, ct);
        return (await GetByIdAsync(id, ct))!;
    }

    public async Task<ProcessingJobDto?> UpdateAsync(Guid jobId, UpdateProcessingJobRequest request, CancellationToken ct = default)
    {
        var existing = await jobRepository.GetByIdAsync(jobId, ct);
        if (existing is null)
            return null;

        existing.JobName = request.JobName;
        existing.Description = request.Description;
        existing.IsEnabled = request.IsEnabled;
        existing.MaxRetries = request.MaxRetries;
        existing.RetryDelaySeconds = request.RetryDelaySeconds;
        if (request.Schedule is not null)
        {
            existing.Schedule = new JobSchedule
            {
                JobId = jobId,
                FrequencyCode = request.Schedule.FrequencyCode,
                IntervalMinutes = Math.Max(1, request.Schedule.IntervalMinutes),
                CronExpression = request.Schedule.CronExpression,
                IsActive = request.Schedule.IsActive,
                NextRunUtc = existing.Schedule?.NextRunUtc ?? DateTime.UtcNow
            };
        }

        await jobRepository.UpdateAsync(existing, ct);
        return await GetByIdAsync(jobId, ct);
    }

    public async Task<ExecuteJobResultDto> ExecuteAsync(Guid jobId, JobTriggerType trigger, CancellationToken ct = default)
    {
        var job = await jobRepository.GetByIdAsync(jobId, ct)
            ?? throw new KeyNotFoundException($"Job '{jobId}' was not found.");

        var execution = new JobExecution
        {
            JobId = jobId,
            TriggerType = trigger,
            Status = JobExecutionStatus.Running,
            StartedUtc = DateTime.UtcNow,
            AttemptNumber = 1
        };
        execution.ExecutionId = await jobRepository.CreateExecutionAsync(execution, ct);
        await jobRepository.AddExecutionLogAsync(execution.ExecutionId, "Info", $"Execution started ({trigger}).", ct);

        try
        {
            await RunJobLogicAsync(job, execution.ExecutionId, ct);

            execution.Status = JobExecutionStatus.Succeeded;
            execution.CompletedUtc = DateTime.UtcNow;
            await jobRepository.UpdateExecutionAsync(execution, ct);
            await jobRepository.AddExecutionLogAsync(execution.ExecutionId, "Info", "Execution succeeded.", ct);

            if (job.Schedule is not null)
            {
                var next = ComputeNextRun(job.Schedule, DateTime.UtcNow);
                await jobRepository.UpdateScheduleAfterRunAsync(jobId, DateTime.UtcNow, next, ct);
            }

            return new ExecuteJobResultDto
            {
                ExecutionId = execution.ExecutionId,
                JobId = jobId,
                Status = JobExecutionStatus.Succeeded.ToString(),
                Message = "Job completed successfully."
            };
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Job {JobId} failed", jobId);
            await jobRepository.AddExecutionLogAsync(execution.ExecutionId, "Error", ex.Message, ct);

            if (job.MaxRetries > 0)
            {
                execution.Status = JobExecutionStatus.Retrying;
                execution.ErrorMessage = ex.Message;
                execution.CompletedUtc = DateTime.UtcNow;
                await jobRepository.UpdateExecutionAsync(execution, ct);

                var delay = TimeSpan.FromSeconds(Math.Max(1, job.RetryDelaySeconds));
                await jobRepository.AddRetryAttemptAsync(new JobRetryAttempt
                {
                    ExecutionId = execution.ExecutionId,
                    JobId = jobId,
                    AttemptNumber = 2,
                    ScheduledUtc = DateTime.UtcNow.Add(delay),
                    Outcome = "Pending",
                    ErrorMessage = ex.Message
                }, ct);

                // Immediate retry with exponential backoff within the same call for API/worker simplicity
                for (var attempt = 2; attempt <= job.MaxRetries + 1; attempt++)
                {
                    await Task.Delay(delay, ct);
                    delay = TimeSpan.FromSeconds(delay.TotalSeconds * 2);
                    try
                    {
                        await jobRepository.AddExecutionLogAsync(execution.ExecutionId, "Info", $"Retry attempt {attempt}.", ct);
                        await RunJobLogicAsync(job, execution.ExecutionId, ct);
                        execution.Status = JobExecutionStatus.Succeeded;
                        execution.AttemptNumber = attempt;
                        execution.CompletedUtc = DateTime.UtcNow;
                        execution.ErrorMessage = null;
                        await jobRepository.UpdateExecutionAsync(execution, ct);
                        await jobRepository.AddRetryAttemptAsync(new JobRetryAttempt
                        {
                            ExecutionId = execution.ExecutionId,
                            JobId = jobId,
                            AttemptNumber = attempt,
                            ScheduledUtc = DateTime.UtcNow,
                            ExecutedUtc = DateTime.UtcNow,
                            Outcome = "Succeeded"
                        }, ct);

                        if (job.Schedule is not null)
                        {
                            var next = ComputeNextRun(job.Schedule, DateTime.UtcNow);
                            await jobRepository.UpdateScheduleAfterRunAsync(jobId, DateTime.UtcNow, next, ct);
                        }

                        return new ExecuteJobResultDto
                        {
                            ExecutionId = execution.ExecutionId,
                            JobId = jobId,
                            Status = JobExecutionStatus.Succeeded.ToString(),
                            Message = $"Job succeeded on retry attempt {attempt}."
                        };
                    }
                    catch (Exception retryEx)
                    {
                        await jobRepository.AddRetryAttemptAsync(new JobRetryAttempt
                        {
                            ExecutionId = execution.ExecutionId,
                            JobId = jobId,
                            AttemptNumber = attempt,
                            ScheduledUtc = DateTime.UtcNow,
                            ExecutedUtc = DateTime.UtcNow,
                            Outcome = "Failed",
                            ErrorMessage = retryEx.Message
                        }, ct);
                        execution.ErrorMessage = retryEx.Message;
                        execution.AttemptNumber = attempt;
                    }
                }
            }

            execution.Status = JobExecutionStatus.Failed;
            execution.CompletedUtc = DateTime.UtcNow;
            await jobRepository.UpdateExecutionAsync(execution, ct);

            if (job.Schedule is not null)
            {
                var next = ComputeNextRun(job.Schedule, DateTime.UtcNow);
                await jobRepository.UpdateScheduleAfterRunAsync(jobId, DateTime.UtcNow, next, ct);
            }

            return new ExecuteJobResultDto
            {
                ExecutionId = execution.ExecutionId,
                JobId = jobId,
                Status = JobExecutionStatus.Failed.ToString(),
                Message = execution.ErrorMessage ?? ex.Message
            };
        }
    }

    public async Task<IReadOnlyList<JobExecutionDto>> GetExecutionsAsync(Guid jobId, CancellationToken ct = default)
    {
        var items = await jobRepository.GetExecutionsAsync(jobId, 50, ct);
        return items.Select(e => new JobExecutionDto
        {
            ExecutionId = e.ExecutionId,
            JobId = e.JobId,
            TriggerType = e.TriggerType.ToString(),
            Status = e.Status.ToString(),
            StartedUtc = e.StartedUtc,
            CompletedUtc = e.CompletedUtc,
            ErrorMessage = e.ErrorMessage,
            AttemptNumber = e.AttemptNumber
        }).ToList();
    }

    public async Task ProcessDueJobsAsync(CancellationToken ct = default)
    {
        var due = await jobRepository.GetDueJobsAsync(DateTime.UtcNow, ct);
        foreach (var job in due)
        {
            logger.LogInformation("Processing due job {JobName} ({JobId})", job.JobName, job.JobId);
            await ExecuteAsync(job.JobId, JobTriggerType.Agent, ct);
        }
    }

    private async Task RunJobLogicAsync(ProcessingJob job, Guid executionId, CancellationToken ct)
    {
        switch (job.JobType)
        {
            case ProcessingJobType.HealthCheck:
                var validation = await dataSourceService.ValidateAsync(job.DataSourceId, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Health check: success={validation.IsSuccess}; {validation.Message}", ct);
                if (!validation.IsSuccess)
                    throw new InvalidOperationException(validation.Message);
                break;

            case ProcessingJobType.MetadataRefresh:
                var refresh = await metadataService.RefreshAsync(job.DataSourceId, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Metadata refresh status={refresh.Status}; objects={refresh.ObjectsCaptured}", ct);
                if (!string.Equals(refresh.Status, "Succeeded", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(refresh.ErrorMessage ?? "Metadata refresh failed.");
                break;

            case ProcessingJobType.SampleExtract:
                var objects = await metadataService.GetObjectsAsync(job.DataSourceId, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Sample extract counted {objects.Count} schema objects.", ct);
                break;

            case ProcessingJobType.DataProfiling:
                var profile = await profilingService.ProfileAsync(job.DataSourceId, "Agent", ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Profiling status={profile.Status}; tables={profile.TablesProfiled}; columns={profile.ColumnsProfiled}", ct);
                if (!string.Equals(profile.Status, "Succeeded", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(profile.ErrorMessage ?? "Profiling failed.");
                break;

            case ProcessingJobType.QualityAssessment:
                var assessment = await qualityAssessmentService.AssessAsync(job.DataSourceId, null, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Quality score={assessment.OverallScore} grade={assessment.Grade}", ct);
                break;

            case ProcessingJobType.MetadataSync:
                var sync = await metadataSyncService.SynchronizeAsync(job.DataSourceId, "Agent", ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Sync status={sync.Status}; added={sync.ObjectsAdded}; removed={sync.ObjectsRemoved}; changed={sync.ColumnsChanged}", ct);
                if (!string.Equals(sync.Status, "Succeeded", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(sync.ErrorMessage ?? "Metadata sync failed.");
                break;

            case ProcessingJobType.ArchiveProfilingHistory:
                await metadataSyncService.ArchiveHistoryAsync(90, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info", "Archived DQ history older than 90 days.", ct);
                break;

            case ProcessingJobType.ProcessPendingImports:
                var batches = await ingestionService.ProcessPendingBatchesAsync(25, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info",
                    $"Processed {batches} pending import batch(es).", ct);
                break;

            case ProcessingJobType.ArchiveImportHistory:
                await ingestionService.ArchiveImportHistoryAsync(90, ct);
                await jobRepository.AddExecutionLogAsync(executionId, "Info", "Archived import history older than 90 days.", ct);
                break;

            default:
                throw new NotSupportedException($"Unsupported job type '{job.JobType}'.");
        }
    }

    private static DateTime ComputeNextRun(JobSchedule schedule, DateTime fromUtc)
    {
        var minutes = schedule.FrequencyCode switch
        {
            "Minutely" => Math.Max(1, schedule.IntervalMinutes),
            "Hourly" => Math.Max(60, schedule.IntervalMinutes),
            "Daily" => Math.Max(1440, schedule.IntervalMinutes),
            "Weekly" => Math.Max(10080, schedule.IntervalMinutes),
            _ => Math.Max(1, schedule.IntervalMinutes)
        };
        return fromUtc.AddMinutes(minutes);
    }

    private static ProcessingJobDto MapDto(ProcessingJob job) => new()
    {
        JobId = job.JobId,
        JobName = job.JobName,
        Description = job.Description,
        DataSourceId = job.DataSourceId,
        JobType = job.JobType.ToString(),
        IsEnabled = job.IsEnabled,
        MaxRetries = job.MaxRetries,
        RetryDelaySeconds = job.RetryDelaySeconds,
        Schedule = job.Schedule is null ? null : new JobScheduleDto
        {
            ScheduleId = job.Schedule.ScheduleId,
            FrequencyCode = job.Schedule.FrequencyCode,
            IntervalMinutes = job.Schedule.IntervalMinutes,
            CronExpression = job.Schedule.CronExpression,
            NextRunUtc = job.Schedule.NextRunUtc,
            LastRunUtc = job.Schedule.LastRunUtc,
            IsActive = job.Schedule.IsActive
        }
    };
}
