namespace Edip.Core.DTOs;

public sealed class ImportBatchDto
{
    public Guid BatchId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DatasetName { get; set; } = string.Empty;
    public Guid? DataSourceId { get; set; }
    public string? SourceInfo { get; set; }
    public Guid? ImportId { get; set; }
    public string? SourceFile { get; set; }
    public string? LoadMode { get; set; }
    public string? DuplicateStrategy { get; set; }
    public DateTime ImportUtc { get; set; }
    public string Status { get; set; } = string.Empty;
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int TransformedRecords { get; set; }
    public int DuplicateRecords { get; set; }
    public int ErrorCount { get; set; }
    public int AttemptCount { get; set; }
    public int MaxRetries { get; set; }
    public DateTime? StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public double? DurationSeconds { get; set; }
    public string? LastErrorMessage { get; set; }
}

public sealed class ImportErrorDto
{
    public long ErrorId { get; set; }
    public Guid BatchId { get; set; }
    public string? DatasetCode { get; set; }
    public string? RowReference { get; set; }
    public string? ColumnName { get; set; }
    public string? InvalidValue { get; set; }
    public string ErrorCode { get; set; } = string.Empty;
    public string ErrorDescription { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
    public DateTime ErrorUtc { get; set; }
}

public sealed class CreateImportBatchRequest
{
    public string DatasetCode { get; set; } = "CUSTOMER";
    public Guid? DataSourceId { get; set; }
    public string? SourceInfo { get; set; }
    public string? SourceFile { get; set; }
    public string? LoadMode { get; set; }
    public string? DuplicateStrategy { get; set; }
    public List<StagingCustomerRowDto> Records { get; set; } = [];
}

public sealed class StagingCustomerRowDto
{
    public string? CustomerCode { get; set; }
    public string? CustomerName { get; set; }
    public string? CountryCode { get; set; }
    public string? Email { get; set; }
    public string? CreditLimit { get; set; }
    public string? Status { get; set; }
    public string? CreatedDate { get; set; }
}

public sealed class IngestDatasetDto
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public bool IsActive { get; set; }
}

public sealed class ImportSummaryRow
{
    public DateTime DayUtc { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public int TotalBatches { get; set; }
    public int SuccessfulBatches { get; set; }
    public int FailedBatches { get; set; }
    public decimal SuccessRatePct { get; set; }
    public int TotalRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int RejectedRecords { get; set; }
}

public sealed class BatchProcessingHistoryRow
{
    public Guid BatchId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DatasetName { get; set; } = string.Empty;
    public string? SourceInfo { get; set; }
    public string Status { get; set; } = string.Empty;
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int ErrorCount { get; set; }
    public int AttemptCount { get; set; }
    public DateTime ImportUtc { get; set; }
    public DateTime? StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public double? DurationSeconds { get; set; }
    public string? LastErrorMessage { get; set; }
}

public sealed class ValidationErrorReportRow
{
    public long ErrorId { get; set; }
    public Guid BatchId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string? RowReference { get; set; }
    public string? ColumnName { get; set; }
    public string? InvalidValue { get; set; }
    public string ErrorCode { get; set; } = string.Empty;
    public string ErrorDescription { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
    public DateTime ErrorUtc { get; set; }
}

public sealed class DatasetProcessingStatisticsRow
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public int BatchCount { get; set; }
    public int TotalRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int ErrorCount { get; set; }
    public double? AvgDurationSeconds { get; set; }
    public DateTime? LastImportUtc { get; set; }
    public DateTime? LastSuccessUtc { get; set; }
}

public sealed class ImportErrorTrendRow
{
    public DateTime DayUtc { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string ErrorCode { get; set; } = string.Empty;
    public int ErrorCount { get; set; }
}
