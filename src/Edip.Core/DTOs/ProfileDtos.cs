namespace Edip.Core.DTOs;

public sealed class ProfileRunDto
{
    public Guid ProfileRunId { get; set; }
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DatasetName { get; set; } = string.Empty;
    public Guid? ImportId { get; set; }
    public Guid? BatchId { get; set; }
    public string ProfileScope { get; set; } = string.Empty;
    public string TriggerType { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int? DurationMs { get; set; }
    public long TotalRecords { get; set; }
    public long ValidRecords { get; set; }
    public long InvalidRecords { get; set; }
    public long DuplicateRecords { get; set; }
    public long NullCellCount { get; set; }
    public decimal CompletenessPct { get; set; }
    public decimal UniquenessPct { get; set; }
    public decimal ValidityPct { get; set; }
    public decimal ConsistencyPct { get; set; }
    public decimal DuplicatePct { get; set; }
    public decimal ErrorPct { get; set; }
    public decimal OverallScore { get; set; }
    public string Grade { get; set; } = string.Empty;
    public string ThresholdResult { get; set; } = string.Empty;
    public int ColumnsProfiled { get; set; }
    public int IssueCount { get; set; }
    public string? ErrorMessage { get; set; }
}

public sealed class DatasetColumnProfileDto
{
    public Guid ColumnProfileId { get; set; }
    public Guid ProfileRunId { get; set; }
    public string ColumnName { get; set; } = string.Empty;
    public string DataCategory { get; set; } = string.Empty;
    public long TotalRecords { get; set; }
    public long NonNullRecords { get; set; }
    public long NullRecords { get; set; }
    public decimal NullPct { get; set; }
    public decimal CompletenessPct { get; set; }
    public long DistinctCount { get; set; }
    public long DuplicateValueCount { get; set; }
    public decimal UniquePct { get; set; }
    public decimal DuplicatePct { get; set; }
    public string? MinValue { get; set; }
    public string? MaxValue { get; set; }
    public decimal? AvgValue { get; set; }
    public decimal? MedianValue { get; set; }
    public decimal? StdDevValue { get; set; }
    public int? MinLength { get; set; }
    public int? MaxLength { get; set; }
    public decimal? AvgLength { get; set; }
    public DateTime? MinDate { get; set; }
    public DateTime? MaxDate { get; set; }
    public long? DistinctDateCount { get; set; }
    public long InvalidCount { get; set; }
}

public sealed class DatasetQualityIssueDto
{
    public long QualityIssueId { get; set; }
    public Guid ProfileRunId { get; set; }
    public Guid DatasetId { get; set; }
    public Guid? ImportId { get; set; }
    public string IssueType { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? ErrorCode { get; set; }
    public long AffectedCount { get; set; }
    public string? SampleValue { get; set; }
    public string Description { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
}

public sealed class DatasetThresholdResultDto
{
    public long ThresholdResultId { get; set; }
    public Guid ProfileRunId { get; set; }
    public int ThresholdId { get; set; }
    public string MetricCode { get; set; } = string.Empty;
    public decimal ActualValue { get; set; }
    public decimal ThresholdValue { get; set; }
    public string OperatorCode { get; set; } = string.Empty;
    public bool Passed { get; set; }
}

public sealed class DatasetQualityTrendRow
{
    public Guid ProfileRunId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public DateTime StartedUtc { get; set; }
    public decimal OverallScore { get; set; }
    public decimal CompletenessPct { get; set; }
    public decimal ValidityPct { get; set; }
    public decimal UniquenessPct { get; set; }
    public decimal ConsistencyPct { get; set; }
    public decimal DuplicatePct { get; set; }
    public string ThresholdResult { get; set; } = string.Empty;
    public string Grade { get; set; } = string.Empty;
    public decimal? PrevOverallScore { get; set; }
    public decimal? PrevCompletenessPct { get; set; }
    public decimal? PrevValidityPct { get; set; }
    public decimal? PrevDuplicatePct { get; set; }
    public decimal? DeltaOverallScore { get; set; }
    public decimal? DeltaCompletenessPct { get; set; }
    public decimal? DeltaValidityPct { get; set; }
    public decimal? DeltaDuplicatePct { get; set; }
}

public sealed class DatasetQualitySummaryRow
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public Guid? LatestProfileRunId { get; set; }
    public decimal? LatestOverallScore { get; set; }
    public string? LatestThresholdResult { get; set; }
    public string? Grade { get; set; }
    public decimal? CompletenessPct { get; set; }
    public decimal? ValidityPct { get; set; }
    public decimal? UniquenessPct { get; set; }
    public decimal? ConsistencyPct { get; set; }
    public decimal? DuplicatePct { get; set; }
    public long? TotalRecords { get; set; }
    public int? IssueCount { get; set; }
    public DateTime? LastProfiledUtc { get; set; }
    public int? DurationMs { get; set; }
}

public sealed class TopQualityIssueRow
{
    public string DatasetCode { get; set; } = string.Empty;
    public string IssueType { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? ErrorCode { get; set; }
    public long AffectedCount { get; set; }
    public string Severity { get; set; } = string.Empty;
    public int OccurrenceCount { get; set; }
}

public sealed class FailedThresholdReportRow
{
    public Guid ProfileRunId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string MetricCode { get; set; } = string.Empty;
    public decimal ActualValue { get; set; }
    public string OperatorCode { get; set; } = string.Empty;
    public decimal ThresholdValue { get; set; }
    public DateTime StartedUtc { get; set; }
    public decimal OverallScore { get; set; }
}

public sealed class ImportQualitySummaryRow
{
    public Guid BatchId { get; set; }
    public Guid ImportId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string ImportStatus { get; set; } = string.Empty;
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int ErrorCount { get; set; }
    public Guid? ProfileRunId { get; set; }
    public decimal? OverallScore { get; set; }
    public decimal? CompletenessPct { get; set; }
    public decimal? ValidityPct { get; set; }
    public string? ThresholdResult { get; set; }
    public DateTime ImportUtc { get; set; }
}
