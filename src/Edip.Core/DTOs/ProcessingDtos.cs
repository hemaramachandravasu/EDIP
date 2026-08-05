namespace Edip.Core.DTOs;

public sealed class ProcessingJobDto
{
    public Guid JobId { get; set; }
    public string JobName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public Guid DataSourceId { get; set; }
    public string JobType { get; set; } = string.Empty;
    public bool IsEnabled { get; set; }
    public int MaxRetries { get; set; }
    public int RetryDelaySeconds { get; set; }
    public JobScheduleDto? Schedule { get; set; }
}

public sealed class JobScheduleDto
{
    public Guid ScheduleId { get; set; }
    public string FrequencyCode { get; set; } = "Hourly";
    public int IntervalMinutes { get; set; } = 60;
    public string? CronExpression { get; set; }
    public DateTime? NextRunUtc { get; set; }
    public DateTime? LastRunUtc { get; set; }
    public bool IsActive { get; set; }
}

public sealed class CreateProcessingJobRequest
{
    public string JobName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public Guid DataSourceId { get; set; }
    public string JobType { get; set; } = "MetadataRefresh";
    public bool IsEnabled { get; set; } = true;
    public int MaxRetries { get; set; } = 3;
    public int RetryDelaySeconds { get; set; } = 60;
    public CreateJobScheduleRequest? Schedule { get; set; }
}

public sealed class CreateJobScheduleRequest
{
    public string FrequencyCode { get; set; } = "Hourly";
    public int IntervalMinutes { get; set; } = 60;
    public string? CronExpression { get; set; }
    public bool IsActive { get; set; } = true;
}

public sealed class UpdateProcessingJobRequest
{
    public string JobName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsEnabled { get; set; } = true;
    public int MaxRetries { get; set; } = 3;
    public int RetryDelaySeconds { get; set; } = 60;
    public CreateJobScheduleRequest? Schedule { get; set; }
}

public sealed class JobExecutionDto
{
    public Guid ExecutionId { get; set; }
    public Guid JobId { get; set; }
    public string TriggerType { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public string? ErrorMessage { get; set; }
    public int AttemptNumber { get; set; }
}

public sealed class ExecuteJobResultDto
{
    public Guid ExecutionId { get; set; }
    public Guid JobId { get; set; }
    public string Status { get; set; } = string.Empty;
    public string Message { get; set; } = string.Empty;
}
