namespace Edip.Core.DTOs;

public sealed class ProcessingSummaryRow
{
    public DateTime DayUtc { get; set; }
    public int TotalExecutions { get; set; }
    public int Succeeded { get; set; }
    public int Failed { get; set; }
    public int Retrying { get; set; }
    public decimal SuccessRatePct { get; set; }
}

public sealed class DataSourceHealthRow
{
    public Guid DataSourceId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string DataSourceTypeCode { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public string HealthStatus { get; set; } = string.Empty;
    public DateTime? LastValidatedUtc { get; set; }
    public int ValidationFailures24h { get; set; }
}

public sealed class JobExecutionStatsRow
{
    public Guid JobId { get; set; }
    public string JobName { get; set; } = string.Empty;
    public string JobType { get; set; } = string.Empty;
    public int TotalRuns { get; set; }
    public int Succeeded { get; set; }
    public int Failed { get; set; }
    public double? AvgDurationSeconds { get; set; }
    public DateTime? LastRunUtc { get; set; }
}

public sealed class MetadataRefreshStatusRow
{
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public DateTime? LastRefreshUtc { get; set; }
    public string? LastStatus { get; set; }
    public int? ObjectsCaptured { get; set; }
    public int? ColumnsCaptured { get; set; }
    public int RefreshCount30d { get; set; }
}
