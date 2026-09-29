using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/sharing")]
public sealed class SharingController(ISharingService service) : ControllerBase
{
    private static readonly HashSet<string> Forbidden = new(StringComparer.OrdinalIgnoreCase)
    {
        "Unauthorized", "AccessDenied", "CrossWorkspaceDenied"
    };

    private static readonly HashSet<string> Conflicts = new(StringComparer.OrdinalIgnoreCase)
    {
        "DuplicateActive", "DuplicateInFlight", "ConcurrencyConflict"
    };

    private IActionResult Fail(string statusCode, string message, object? id = null)
    {
        var body = new { statusCode, error = message, id };
        if (string.Equals(statusCode, "NotFound", StringComparison.OrdinalIgnoreCase)) return NotFound(body);
        if (Forbidden.Contains(statusCode)) return StatusCode(StatusCodes.Status403Forbidden, body);
        if (Conflicts.Contains(statusCode)) return Conflict(body);
        return BadRequest(body);
    }

    // ---------------- Shares ----------------

    [HttpPost("shares")]
    public async Task<IActionResult> CreateShare([FromBody] CreateShareRequest request, CancellationToken ct)
    {
        var result = await service.CreateShareAsync(request, ct);
        return result.StatusCode == "Created" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage, result.ShareId);
    }

    [HttpGet("shares")]
    public async Task<ActionResult<PagedList<DatasetShareDto>>> GetShares(
        [FromQuery] string? datasetCode, [FromQuery] string? recipientUserName, [FromQuery] Guid? workspaceId,
        [FromQuery] string? status, [FromQuery] int pageNumber = 1, [FromQuery] int pageSize = 50, CancellationToken ct = default)
        => Ok(await service.GetSharesAsync(datasetCode, recipientUserName, workspaceId, status, pageNumber, pageSize, ct));

    [HttpGet("shares/active")]
    public async Task<ActionResult<IReadOnlyList<DatasetShareDto>>> GetActiveShares(
        [FromQuery] string? datasetCode, [FromQuery] string? recipientUserName, [FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetActiveSharesAsync(datasetCode, recipientUserName, workspaceId, ct));

    [HttpGet("shares/expired")]
    public async Task<ActionResult<IReadOnlyList<DatasetShareDto>>> GetExpiredShares(
        [FromQuery] Guid? workspaceId, [FromQuery] bool onlyUnmarked = false, CancellationToken ct = default)
        => Ok(await service.GetExpiredSharesAsync(workspaceId, onlyUnmarked, ct));

    [HttpGet("shares/history")]
    public async Task<ActionResult<IReadOnlyList<ShareHistoryRow>>> GetShareHistory(
        [FromQuery] Guid? shareId, [FromQuery] string? datasetCode, [FromQuery] string? recipientUserName,
        [FromQuery] int take = 100, CancellationToken ct = default)
        => Ok(await service.GetShareHistoryAsync(shareId, datasetCode, recipientUserName, take, ct));

    [HttpGet("shares/{shareId:guid}")]
    public async Task<ActionResult<DatasetShareDto>> GetShare(Guid shareId, CancellationToken ct)
    {
        var share = await service.GetShareAsync(shareId, ct);
        return share is null ? NotFound() : Ok(share);
    }

    [HttpPut("shares/{shareId:guid}")]
    public async Task<IActionResult> UpdateShare(Guid shareId, [FromBody] UpdateShareRequest request, CancellationToken ct)
    {
        var result = await service.UpdateShareAsync(shareId, request, ct);
        return result.StatusCode is "Updated" or "NoChange" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage, shareId);
    }

    [HttpPost("shares/{shareId:guid}/revoke")]
    public async Task<IActionResult> RevokeShare(Guid shareId, [FromBody] RevokeShareRequest request, CancellationToken ct)
    {
        var result = await service.RevokeShareAsync(shareId, request, ct);
        return result.StatusCode == "Revoked" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage, shareId);
    }

    // ---------------- Authorization / columns ----------------

    [HttpGet("access/evaluate")]
    public async Task<ActionResult<ExportAccessEvaluationDto>> EvaluateAccess(
        [FromQuery] string datasetCode, [FromQuery] string userName, CancellationToken ct)
        => Ok(await service.EvaluateExportAccessAsync(datasetCode, userName, ct));

    [HttpGet("datasets/{datasetCode}/columns")]
    public async Task<ActionResult<IReadOnlyList<ExportableColumnDto>>> GetColumns(string datasetCode, CancellationToken ct)
        => Ok(await service.GetExportableColumnsAsync(datasetCode, ct));

    [HttpPost("datasets/columns/sync")]
    public async Task<IActionResult> SyncColumns([FromQuery] string? datasetCode, CancellationToken ct)
        => Ok(new { columnsSynced = await service.SyncExportableColumnsAsync(datasetCode, ct) });

    // ---------------- Exports ----------------

    [HttpPost("exports")]
    public async Task<IActionResult> SubmitExport([FromBody] SubmitExportRequest request, CancellationToken ct)
    {
        var result = await service.SubmitExportAsync(request, ct);
        return result.StatusCode == "Created" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage, result.ExportRequestId);
    }

    [HttpGet("exports")]
    public async Task<ActionResult<PagedList<ExportRequestDto>>> GetExportHistory([FromQuery] ExportHistoryQuery query, CancellationToken ct)
        => Ok(await service.GetExportHistoryAsync(query, ct));

    [HttpGet("exports/{exportRequestId:guid}")]
    public async Task<ActionResult<ExportRequestDetailDto>> GetExport(Guid exportRequestId, CancellationToken ct)
    {
        var detail = await service.GetExportRequestAsync(exportRequestId, ct);
        return detail is null ? NotFound() : Ok(detail);
    }

    [HttpPost("exports/{exportRequestId:guid}/transition")]
    public async Task<IActionResult> Transition(Guid exportRequestId, [FromBody] TransitionExportRequest request, CancellationToken ct)
    {
        var result = await service.TransitionExportAsync(exportRequestId, request, ct);
        return string.Equals(result.StatusCode, request.NewStatus, StringComparison.OrdinalIgnoreCase)
            ? Ok(result)
            : Fail(result.StatusCode, result.StatusMessage, exportRequestId);
    }

    [HttpPost("exports/claim")]
    public async Task<IActionResult> Claim(CancellationToken ct)
    {
        var result = await service.ClaimNextExportAsync(ct);
        return result.StatusCode is ExportStatuses.Processing or "QueueEmpty"
            ? Ok(result)
            : Fail(result.StatusCode, result.StatusMessage, result.ExportRequestId);
    }

    [HttpGet("exports/{exportRequestId:guid}/data")]
    public async Task<IActionResult> GetData(Guid exportRequestId,
        [FromQuery] string? userName, [FromQuery] int pageSize = 1000, [FromQuery] int pageNumber = 1,
        [FromQuery] string? afterKey = null, [FromQuery] bool includeTotalCount = false, CancellationToken ct = default)
    {
        var page = await service.GetExportDataAsync(exportRequestId, userName, pageSize, pageNumber, afterKey, includeTotalCount, ct);
        return page.StatusCode == "OK" ? Ok(page) : Fail(page.StatusCode, page.StatusMessage, exportRequestId);
    }

    [HttpPost("exports/{exportRequestId:guid}/download")]
    public async Task<IActionResult> Download(Guid exportRequestId, [FromBody] RecordDownloadRequest request, CancellationToken ct)
    {
        var result = await service.RecordDownloadAsync(exportRequestId, request, ct);
        return result.StatusCode == "Downloaded" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage, exportRequestId);
    }

    // ---------------- Reports ----------------

    [HttpGet("reports/summary")]
    public async Task<ActionResult<ExportSummaryDto>> Summary(
        [FromQuery] Guid? workspaceId, [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, CancellationToken ct)
        => Ok(await service.GetExportSummaryAsync(workspaceId, fromUtc, toUtc, ct));

    [HttpGet("reports/by-format")]
    public async Task<IActionResult> ByFormat(
        [FromQuery] Guid? workspaceId, [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, CancellationToken ct)
        => Ok(await service.GetExportsByFormatAsync(workspaceId, fromUtc, toUtc, ct));

    [HttpGet("reports/by-dataset")]
    public async Task<IActionResult> ByDataset(
        [FromQuery] Guid? workspaceId, [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, CancellationToken ct)
        => Ok(await service.GetExportsByDatasetAsync(workspaceId, fromUtc, toUtc, ct));

    [HttpGet("reports/by-user")]
    public async Task<IActionResult> ByUser(
        [FromQuery] Guid? workspaceId, [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, CancellationToken ct)
        => Ok(await service.GetExportsByUserAsync(workspaceId, fromUtc, toUtc, ct));

    [HttpGet("reports/activity")]
    public async Task<IActionResult> Activity([FromQuery] int days = 30, [FromQuery] Guid? workspaceId = null, CancellationToken ct = default)
        => Ok(await service.GetExportActivityAsync(days, workspaceId, ct));

    [HttpGet("reports/share-status")]
    public async Task<IActionResult> ShareStatus([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetShareStatusSummaryAsync(workspaceId, ct));

    // ---------------- Maintenance ----------------

    [HttpPost("maintenance/expire-shares")]
    public async Task<IActionResult> ExpireShares(CancellationToken ct)
        => Ok(new { expiredCount = await service.ExpireSharesAsync(ct) });

    [HttpPost("maintenance/cleanup-exports")]
    public async Task<IActionResult> CleanupExports(
        [FromQuery] int processingTimeoutMinutes = 120, [FromQuery] int pendingTimeoutHours = 72, CancellationToken ct = default)
        => Ok(await service.CleanupStaleExportsAsync(processingTimeoutMinutes, pendingTimeoutHours, ct));
}
