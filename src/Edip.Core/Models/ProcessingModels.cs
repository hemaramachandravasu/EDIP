using Edip.Core.Enums;

namespace Edip.Core.Models;

public sealed class ProcessingJob
{
    public Guid JobId { get; set; }
    public string JobName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public Guid DataSourceId { get; set; }
    public ProcessingJobType JobType { get; set; }
    public bool IsEnabled { get; set; } = true;
    public int MaxRetries { get; set; } = 3;
    public int RetryDelaySeconds { get; set; } = 60;
    public DateTime CreatedUtc { get; set; }
    public DateTime ModifiedUtc { get; set; }
    public JobSchedule? Schedule { get; set; }
}

public sealed class JobSchedule
{
    public Guid ScheduleId { get; set; }
    public Guid JobId { get; set; }
    public string FrequencyCode { get; set; } = "Hourly";
    public int IntervalMinutes { get; set; } = 60;
    public string? CronExpression { get; set; }
    public DateTime? NextRunUtc { get; set; }
    public DateTime? LastRunUtc { get; set; }
    public bool IsActive { get; set; } = true;
}

public sealed class JobExecution
{
    public Guid ExecutionId { get; set; }
    public Guid JobId { get; set; }
    public JobTriggerType TriggerType { get; set; }
    public JobExecutionStatus Status { get; set; }
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public string? ErrorMessage { get; set; }
    public int AttemptNumber { get; set; } = 1;
}

public sealed class JobExecutionLog
{
    public long LogId { get; set; }
    public Guid ExecutionId { get; set; }
    public DateTime LoggedUtc { get; set; }
    public string Level { get; set; } = "Info";
    public string Message { get; set; } = string.Empty;
}

public sealed class JobRetryAttempt
{
    public long RetryAttemptId { get; set; }
    public Guid ExecutionId { get; set; }
    public Guid JobId { get; set; }
    public int AttemptNumber { get; set; }
    public DateTime ScheduledUtc { get; set; }
    public DateTime? ExecutedUtc { get; set; }
    public string Outcome { get; set; } = "Pending";
    public string? ErrorMessage { get; set; }
}
