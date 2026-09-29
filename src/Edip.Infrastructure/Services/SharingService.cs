using System.Text.Json;
using System.Text.Json.Serialization;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class SharingService(ISharingRepository repository) : ISharingService
{
    private static readonly JsonSerializerOptions SpecJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public Task<ShareActionResult> CreateShareAsync(CreateShareRequest request, CancellationToken ct = default)
        => repository.CreateShareAsync(request, ct);

    public Task<ShareActionResult> UpdateShareAsync(Guid shareId, UpdateShareRequest request, CancellationToken ct = default)
        => repository.UpdateShareAsync(shareId, request, ct);

    public Task<ShareActionResult> RevokeShareAsync(Guid shareId, RevokeShareRequest request, CancellationToken ct = default)
        => repository.RevokeShareAsync(shareId, request, ct);

    public Task<DatasetShareDto?> GetShareAsync(Guid shareId, CancellationToken ct = default)
        => repository.GetShareAsync(shareId, ct);

    public Task<IReadOnlyList<DatasetShareDto>> GetActiveSharesAsync(
        string? datasetCode = null, string? recipientUserName = null, Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetActiveSharesAsync(datasetCode, recipientUserName, workspaceId, ct);

    public Task<PagedList<DatasetShareDto>> GetSharesAsync(
        string? datasetCode = null, string? recipientUserName = null, Guid? workspaceId = null, string? effectiveStatus = null,
        int pageNumber = 1, int pageSize = 50, CancellationToken ct = default)
        => repository.GetSharesAsync(datasetCode, recipientUserName, workspaceId, effectiveStatus, pageNumber, pageSize, ct);

    public Task<IReadOnlyList<DatasetShareDto>> GetExpiredSharesAsync(Guid? workspaceId = null, bool onlyUnmarked = false, CancellationToken ct = default)
        => repository.GetExpiredSharesAsync(workspaceId, onlyUnmarked, ct);

    public Task<IReadOnlyList<ShareHistoryRow>> GetShareHistoryAsync(
        Guid? shareId = null, string? datasetCode = null, string? recipientUserName = null, int take = 100, CancellationToken ct = default)
        => repository.GetShareHistoryAsync(shareId, datasetCode, recipientUserName, take, ct);

    public Task<int> ExpireSharesAsync(CancellationToken ct = default)
        => repository.ExpireSharesAsync(ct);

    public Task<ExportAccessEvaluationDto> EvaluateExportAccessAsync(string datasetCode, string userName, CancellationToken ct = default)
        => repository.EvaluateExportAccessAsync(datasetCode, userName, ct);

    public Task<IReadOnlyList<ExportableColumnDto>> GetExportableColumnsAsync(string datasetCode, CancellationToken ct = default)
        => repository.GetExportableColumnsAsync(datasetCode, ct);

    public Task<int> SyncExportableColumnsAsync(string? datasetCode = null, CancellationToken ct = default)
        => repository.SyncExportableColumnsAsync(datasetCode, ct);

    public Task<ExportActionResult> SubmitExportAsync(SubmitExportRequest request, CancellationToken ct = default)
    {
        var columnsJson = request.SelectedColumns is { Count: > 0 } ? JsonSerializer.Serialize(request.SelectedColumns, SpecJson) : null;
        var filtersJson = request.Filters is { Count: > 0 } ? JsonSerializer.Serialize(request.Filters, SpecJson) : null;
        var sortJson = request.Sort is { Count: > 0 } ? JsonSerializer.Serialize(request.Sort, SpecJson) : null;
        return repository.SubmitExportAsync(request.DatasetCode, request.UserName, request.FormatCode, request.DatasetVersionId,
            columnsJson, filtersJson, sortJson, ct);
    }

    public Task<ExportActionResult> TransitionExportAsync(Guid exportRequestId, TransitionExportRequest request, CancellationToken ct = default)
        => repository.TransitionExportAsync(exportRequestId, request, ct);

    public Task<ExportActionResult> ClaimNextExportAsync(CancellationToken ct = default)
        => repository.ClaimNextExportAsync(ct);

    public Task<ExportRequestDetailDto?> GetExportRequestAsync(Guid exportRequestId, CancellationToken ct = default)
        => repository.GetExportRequestAsync(exportRequestId, ct);

    public Task<ExportDataPageDto> GetExportDataAsync(Guid exportRequestId, string? userName = null, int pageSize = 5000,
        int pageNumber = 1, string? afterKey = null, bool includeTotalCount = false, CancellationToken ct = default)
        => repository.GetExportDataAsync(exportRequestId, userName, pageSize, pageNumber, afterKey, includeTotalCount, ct);

    public Task<ExportDownloadResult> RecordDownloadAsync(Guid exportRequestId, RecordDownloadRequest request, CancellationToken ct = default)
        => repository.RecordDownloadAsync(exportRequestId, request, ct);

    public Task<PagedList<ExportRequestDto>> GetExportHistoryAsync(ExportHistoryQuery query, CancellationToken ct = default)
        => repository.GetExportHistoryAsync(query, ct);

    public Task<ExportCleanupResult> CleanupStaleExportsAsync(int processingTimeoutMinutes = 120, int pendingTimeoutHours = 72, CancellationToken ct = default)
        => repository.CleanupStaleExportsAsync(processingTimeoutMinutes, pendingTimeoutHours, ct);

    public Task<ExportSummaryDto> GetExportSummaryAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default)
        => repository.GetExportSummaryAsync(workspaceId, fromUtc, toUtc, ct);

    public Task<IReadOnlyList<ExportCountRow>> GetExportsByFormatAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default)
        => repository.GetExportsByFormatAsync(workspaceId, fromUtc, toUtc, ct);

    public Task<IReadOnlyList<ExportCountRow>> GetExportsByDatasetAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default)
        => repository.GetExportsByDatasetAsync(workspaceId, fromUtc, toUtc, ct);

    public Task<IReadOnlyList<ExportCountRow>> GetExportsByUserAsync(Guid? workspaceId = null, DateTime? fromUtc = null, DateTime? toUtc = null, CancellationToken ct = default)
        => repository.GetExportsByUserAsync(workspaceId, fromUtc, toUtc, ct);

    public Task<IReadOnlyList<ExportActivityRow>> GetExportActivityAsync(int days = 30, Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetExportActivityAsync(days, workspaceId, ct);

    public Task<IReadOnlyList<ShareStatusSummaryRow>> GetShareStatusSummaryAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetShareStatusSummaryAsync(workspaceId, ct);
}
