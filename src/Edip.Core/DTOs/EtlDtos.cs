namespace Edip.Core.DTOs;

public sealed class EtlErrorDto
{
    public long ErrorId { get; set; }
    public Guid? RunId { get; set; }
    public Guid BatchId { get; set; }
    public Guid? ImportId { get; set; }
    public int? RowNumber { get; set; }
    public string? ColumnName { get; set; }
    public string? InvalidValue { get; set; }
    public string ErrorCode { get; set; } = string.Empty;
    public string ErrorDescription { get; set; } = string.Empty;
    public string Phase { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
    public DateTime ErrorUtc { get; set; }
}

public sealed class EtlBatchSummaryRow
{
    public Guid RunId { get; set; }
    public Guid BatchId { get; set; }
    public Guid ImportId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string TriggerType { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public int AttemptNumber { get; set; }
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int? DurationMs { get; set; }
    public int TotalRecords { get; set; }
    public int TransformedRecords { get; set; }
    public int ValidRecords { get; set; }
    public int InvalidRecords { get; set; }
    public int DuplicateRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int SkippedRecords { get; set; }
    public int ProcessingErrors { get; set; }
    public decimal? ValidRatePct { get; set; }
}

public sealed class EtlSuccessRateRow
{
    public DateTime DayUtc { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public int RunCount { get; set; }
    public int SuccessfulRuns { get; set; }
    public int FailedRuns { get; set; }
    public decimal SuccessRatePct { get; set; }
    public int? AvgDurationMs { get; set; }
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int InvalidRecords { get; set; }
}

public sealed class EtlFailedBatchRow
{
    public Guid BatchId { get; set; }
    public Guid ImportId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string? SourceFile { get; set; }
    public string LoadMode { get; set; } = string.Empty;
    public string DuplicateStrategy { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public int AttemptCount { get; set; }
    public int MaxRetries { get; set; }
    public int TotalRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int ErrorCount { get; set; }
    public DateTime ImportUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int? DurationMs { get; set; }
    public string? LastErrorMessage { get; set; }
}

public sealed class EtlValidationErrorSummaryRow
{
    public DateTime DayUtc { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string Phase { get; set; } = string.Empty;
    public string ErrorCode { get; set; } = string.Empty;
    public int ErrorCount { get; set; }
}

public sealed class EtlDatasetHistoryRow
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public int RunCount { get; set; }
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int InvalidRecords { get; set; }
    public int TransformedRecords { get; set; }
    public int DuplicateRecords { get; set; }
    public int? AvgDurationMs { get; set; }
    public DateTime? LastRunUtc { get; set; }
}
