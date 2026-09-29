using System.Text.Json;

namespace Edip.Core.DTOs;

public static class ExportStatuses
{
    public const string Pending = "Pending";
    public const string Processing = "Processing";
    public const string Completed = "Completed";
    public const string Failed = "Failed";
    public const string Cancelled = "Cancelled";
}

public static class ShareStatuses
{
    public const string Active = "Active";
    public const string Expired = "Expired";
    public const string Revoked = "Revoked";
}

// ---------------- Shares ----------------

public sealed class DatasetShareDto
{
    public Guid ShareId { get; init; }
    public Guid DatasetId { get; init; }
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public Guid? WorkspaceId { get; init; }
    public string? WorkspaceCode { get; init; }
    public Guid RecipientUserId { get; init; }
    public string RecipientUserName { get; init; } = "";
    public string? RecipientDisplayName { get; init; }
    public string AccessLevelCode { get; init; } = "";
    public string SharedByUserName { get; init; } = "";
    public DateTime SharedUtc { get; init; }
    public DateTime? ExpiresUtc { get; init; }
    public string PersistedStatus { get; init; } = "";
    public string EffectiveStatus { get; init; } = "";
    public string? RevokedByUserName { get; init; }
    public DateTime? RevokedUtc { get; init; }
    public string? RevokeReason { get; init; }
    public string? Notes { get; init; }
    public DateTime ModifiedUtc { get; init; }
}

public sealed class CreateShareRequest
{
    public string DatasetCode { get; init; } = "";
    public string RecipientUserName { get; init; } = "";
    public string AccessLevelCode { get; init; } = "Read";
    public string SharedByUserName { get; init; } = "";
    public DateTime? ExpiresUtc { get; init; }
    public string? Notes { get; init; }
}

public sealed class UpdateShareRequest
{
    public string ActorUserName { get; init; } = "";
    public string? AccessLevelCode { get; init; }
    public DateTime? ExpiresUtc { get; init; }
    public bool ClearExpiry { get; init; }
    public string? Comments { get; init; }
}

public sealed class RevokeShareRequest
{
    public string ActorUserName { get; init; } = "";
    public string? RevokeReason { get; init; }
}

public sealed class ShareActionResult
{
    public Guid? ShareId { get; init; }
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public DatasetShareDto? Share { get; init; }
}

public sealed class ShareHistoryRow
{
    public long ShareHistoryId { get; init; }
    public Guid ShareId { get; init; }
    public string DatasetCode { get; init; } = "";
    public string RecipientUserName { get; init; } = "";
    public string Action { get; init; } = "";
    public string? PreviousStatus { get; init; }
    public string NewStatus { get; init; } = "";
    public string? PreviousAccessLevel { get; init; }
    public string NewAccessLevel { get; init; } = "";
    public DateTime? PreviousExpiresUtc { get; init; }
    public DateTime? NewExpiresUtc { get; init; }
    public string? ActorUserName { get; init; }
    public DateTime ActionUtc { get; init; }
    public string? Comments { get; init; }
}

public sealed class PagedList<T>
{
    public IReadOnlyList<T> Items { get; init; } = [];
    public int PageNumber { get; init; }
    public int PageSize { get; init; }
    public int TotalCount { get; init; }
}

// ---------------- Authorization ----------------

public sealed class ExportAccessEvaluationDto
{
    public bool IsAllowed { get; init; }
    public string DecisionCode { get; init; } = "";
    public string Reason { get; init; } = "";
    public string? DatasetCode { get; init; }
    public string? UserName { get; init; }
    public Guid? WorkspaceId { get; init; }
    public string? ClassificationCode { get; init; }
    public string? GovernanceStatusCode { get; init; }
    public string? CertificationStatusCode { get; init; }
    public string? RequiredAccessLevel { get; init; }
    public bool RequireCertified { get; init; }
    public string? EffectiveAccessLevel { get; init; }
    public string? AccessSource { get; init; }
    public string? WorkspaceRole { get; init; }
    public bool IsWorkspaceMember { get; init; }
    public bool IsPlatformAdmin { get; init; }
    public bool IsOwner { get; init; }
    public bool IsSteward { get; init; }
    public string? GrantLevel { get; init; }
    public string GrantStatus { get; init; } = "None";
    public Guid? ActiveShareId { get; init; }
    public string? ShareLevel { get; init; }
    public string ShareStatus { get; init; } = "None";
    public DateTime? ShareExpiresUtc { get; init; }
}

public sealed class ExportableColumnDto
{
    public string ColumnName { get; init; } = "";
    public string DataTypeName { get; init; } = "";
    public string SqlTypeDeclaration { get; init; } = "";
    public int OrdinalPosition { get; init; }
    public bool IsKey { get; init; }
    public bool IsFilterable { get; init; }
    public bool IsSortable { get; init; }
    public bool IsExportable { get; init; }
}

// ---------------- Export requests ----------------

public sealed class ExportFilter
{
    public string Column { get; init; } = "";
    /// <summary>eq, ne, gt, ge, lt, le, like, in, between, isnull, notnull</summary>
    public string Op { get; init; } = "eq";
    /// <summary>Scalar for comparisons/like, array for in/between, omitted for isnull/notnull.</summary>
    public JsonElement? Value { get; init; }
}

public sealed class ExportSort
{
    public string Column { get; init; } = "";
    public string Dir { get; init; } = "asc";
}

public sealed class SubmitExportRequest
{
    public string DatasetCode { get; init; } = "";
    public string UserName { get; init; } = "";
    public string FormatCode { get; init; } = "Csv";
    public Guid? DatasetVersionId { get; init; }
    public IReadOnlyList<string>? SelectedColumns { get; init; }
    public IReadOnlyList<ExportFilter>? Filters { get; init; }
    public IReadOnlyList<ExportSort>? Sort { get; init; }
}

public sealed class ExportRequestDto
{
    public Guid ExportRequestId { get; init; }
    public Guid DatasetId { get; init; }
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public Guid? DatasetVersionId { get; init; }
    public int? DatasetVersionNumber { get; init; }
    public string RequestedByUserName { get; init; } = "";
    public Guid? WorkspaceId { get; init; }
    public string? WorkspaceCode { get; init; }
    public string FormatCode { get; init; } = "";
    public string Status { get; init; } = "";
    public string? AccessSource { get; init; }
    public int SelectedColumnCount { get; init; }
    public int FilterCount { get; init; }
    public DateTime RequestedUtc { get; init; }
    public DateTime? StartedUtc { get; init; }
    public DateTime? CompletedUtc { get; init; }
    public int? DurationSeconds { get; init; }
    public long? RecordCount { get; init; }
    public long? FileSizeBytes { get; init; }
    public string? FileReference { get; init; }
    public string? FailureReason { get; init; }
    public int AttemptCount { get; init; }
    public int? DownloadCount { get; init; }
    public string? SelectedColumnsJson { get; init; }
    public string? FiltersJson { get; init; }
    public string? SortJson { get; init; }
}

public sealed class ExportStatusHistoryRow
{
    public long StatusHistoryId { get; init; }
    public string? PreviousStatus { get; init; }
    public string NewStatus { get; init; } = "";
    public string? ActorUserName { get; init; }
    public DateTime ChangedUtc { get; init; }
    public string? Message { get; init; }
}

public sealed class ExportDownloadRow
{
    public long DownloadId { get; init; }
    public string DownloadedByUserName { get; init; } = "";
    public DateTime DownloadedUtc { get; init; }
    public string? ClientInfo { get; init; }
}

public sealed class ExportRequestDetailDto
{
    public ExportRequestDto Request { get; init; } = new();
    public IReadOnlyList<ExportStatusHistoryRow> StatusHistory { get; init; } = [];
    public IReadOnlyList<ExportDownloadRow> Downloads { get; init; } = [];
}

public sealed class TransitionExportRequest
{
    public string NewStatus { get; init; } = "";
    public string? ActorUserName { get; init; }
    public long? RecordCount { get; init; }
    public long? FileSizeBytes { get; init; }
    public string? FileReference { get; init; }
    public string? FailureReason { get; init; }
}

public sealed class ExportActionResult
{
    public Guid? ExportRequestId { get; init; }
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public ExportRequestDto? Request { get; init; }
}

public sealed class ExportDataPageDto
{
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public IReadOnlyList<string> Columns { get; init; } = [];
    public IReadOnlyList<Dictionary<string, object?>> Rows { get; init; } = [];
    public string? PagingMode { get; init; }
    public string? KeyColumn { get; init; }
    public int PageSize { get; init; }
    public int? PageNumber { get; init; }
    public string? AfterKey { get; init; }
    public int RowsReturned { get; init; }
    public string? NextAfterKey { get; init; }
    public bool HasMore { get; init; }
    public long? TotalCount { get; init; }
}

public sealed class RecordDownloadRequest
{
    public string UserName { get; init; } = "";
    public string? ClientInfo { get; init; }
}

public sealed class ExportDownloadResult
{
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public Guid ExportRequestId { get; init; }
    public string? FormatCode { get; init; }
    public string? MimeType { get; init; }
    public string? FileExtension { get; init; }
    public string? FileReference { get; init; }
    public long? FileSizeBytes { get; init; }
    public long? RecordCount { get; init; }
}

public sealed class ExportHistoryQuery
{
    public string? UserName { get; init; }
    public string? DatasetCode { get; init; }
    public Guid? WorkspaceId { get; init; }
    public string? Status { get; init; }
    public string? FormatCode { get; init; }
    public DateTime? FromUtc { get; init; }
    public DateTime? ToUtc { get; init; }
    public int PageNumber { get; init; } = 1;
    public int PageSize { get; init; } = 50;
}

public sealed class ExportCleanupResult
{
    public int TimedOutCount { get; init; }
    public int AbandonedCount { get; init; }
}

// ---------------- Reports ----------------

public sealed class ExportSummaryDto
{
    public int TotalExports { get; init; }
    public int CompletedExports { get; init; }
    public int FailedExports { get; init; }
    public int PendingExports { get; init; }
    public int ProcessingExports { get; init; }
    public int CancelledExports { get; init; }
    public long TotalRecordsExported { get; init; }
    public decimal? AvgDurationSeconds { get; init; }
    public int DistinctRequesters { get; init; }
    public int DistinctDatasets { get; init; }
    public int TotalDownloads { get; init; }
    public int ActiveShares { get; init; }
    public int ExpiredShares { get; init; }
    public int RevokedShares { get; init; }
}

public sealed class ExportCountRow
{
    public string Key { get; init; } = "";
    public string? Name { get; init; }
    public int TotalExports { get; init; }
    public int CompletedExports { get; init; }
    public int FailedExports { get; init; }
    public long RecordsExported { get; init; }
    public DateTime? LastRequestedUtc { get; init; }
}

public sealed class ExportActivityRow
{
    public DateTime ActivityDate { get; init; }
    public int Requested { get; init; }
    public int Completed { get; init; }
    public int Failed { get; init; }
    public int Cancelled { get; init; }
    public int InFlight { get; init; }
    public long RecordsExported { get; init; }
    public int Downloads { get; init; }
}

public sealed class ShareStatusSummaryRow
{
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public Guid? WorkspaceId { get; init; }
    public int ActiveShares { get; init; }
    public int ExpiredShares { get; init; }
    public int RevokedShares { get; init; }
    public int ExpiringWithin7Days { get; init; }
    public int ExpiredNotYetMarked { get; init; }
}
