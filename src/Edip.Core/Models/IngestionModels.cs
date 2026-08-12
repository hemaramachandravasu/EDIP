namespace Edip.Core.Models;

public sealed class ImportBatch
{
    public Guid BatchId { get; set; }
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DatasetName { get; set; } = string.Empty;
    public Guid? DataSourceId { get; set; }
    public string? SourceInfo { get; set; }
    public DateTime ImportUtc { get; set; }
    public string Status { get; set; } = "Pending";
    public int TotalRecords { get; set; }
    public int ValidRecords { get; set; }
    public int RejectedRecords { get; set; }
    public int ProcessedRecords { get; set; }
    public int InsertedRecords { get; set; }
    public int UpdatedRecords { get; set; }
    public int ErrorCount { get; set; }
    public int AttemptCount { get; set; }
    public DateTime? StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public double? DurationSeconds { get; set; }
    public string? LastErrorMessage { get; set; }
}

public sealed class ImportError
{
    public long ErrorId { get; set; }
    public Guid BatchId { get; set; }
    public Guid DatasetId { get; set; }
    public string? DatasetCode { get; set; }
    public long? StagingRowId { get; set; }
    public string? RowReference { get; set; }
    public string? ColumnName { get; set; }
    public string? InvalidValue { get; set; }
    public string ErrorCode { get; set; } = string.Empty;
    public string ErrorDescription { get; set; } = string.Empty;
    public string Severity { get; set; } = "Error";
    public DateTime ErrorUtc { get; set; }
}

public sealed class StagingCustomerRow
{
    public int RowNumber { get; set; }
    public string? CustomerCode { get; set; }
    public string? CustomerName { get; set; }
    public string? CountryCode { get; set; }
    public string? Email { get; set; }
    public string? CreditLimit { get; set; }
    public string? Status { get; set; }
    public string? CreatedDate { get; set; }
}

public sealed class IngestDataset
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string StagingTable { get; set; } = string.Empty;
    public string TargetTable { get; set; } = string.Empty;
    public bool IsActive { get; set; }
}
