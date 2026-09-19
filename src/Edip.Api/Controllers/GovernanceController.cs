using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/governance")]
public sealed class GovernanceController(IGovernanceService service) : ControllerBase
{
    private static readonly HashSet<string> SoftFailures = new(StringComparer.OrdinalIgnoreCase)
    {
        "InvalidDataset", "InvalidUser", "InvalidAccessLevel", "InvalidJustification",
        "CrossWorkspaceDenied", "DuplicatePending", "AlreadyGranted", "NotFound",
        "InvalidTransition", "Unauthorized", "InvalidInput"
    };

    private IActionResult Bad(string message) => BadRequest(new { error = message });

    [HttpGet("datasets")]
    public async Task<ActionResult<IReadOnlyList<DatasetGovernanceDto>>> GetDatasets(
        [FromQuery] string? datasetCode, [FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetAsync(datasetCode, workspaceId, ct));

    [HttpGet("datasets/{datasetCode}")]
    public async Task<ActionResult<DatasetGovernanceDto>> GetDataset(string datasetCode, CancellationToken ct)
    {
        var rows = await service.GetAsync(datasetCode, null, ct);
        var row = rows.FirstOrDefault();
        return row is null ? NotFound() : Ok(row);
    }

    [HttpPut("datasets/{datasetCode}")]
    public async Task<IActionResult> Upsert(string datasetCode, [FromBody] UpsertDatasetGovernanceRequest request, CancellationToken ct)
    {
        try { return Ok(await service.UpsertAsync(datasetCode, request, ct)); }
        catch (Exception ex) { return Bad(ex.Message); }
    }

    [HttpPost("datasets/{datasetCode}/submit-review")]
    public async Task<IActionResult> SubmitReview(string datasetCode, [FromBody] SubmitReviewRequest request, CancellationToken ct)
    {
        try { return Ok(await service.SubmitForReviewAsync(datasetCode, request, ct)); }
        catch (Exception ex) { return Bad(ex.Message); }
    }

    [HttpPost("datasets/{datasetCode}/certify")]
    public async Task<IActionResult> Certify(string datasetCode, [FromBody] CertifyDatasetRequest request, CancellationToken ct)
    {
        try { return Ok(await service.CertifyAsync(datasetCode, request, ct)); }
        catch (Exception ex) { return Bad(ex.Message); }
    }

    [HttpGet("datasets/{datasetCode}/certification-history")]
    public async Task<ActionResult<IReadOnlyList<CertificationHistoryRow>>> CertificationHistory(string datasetCode, CancellationToken ct)
        => Ok(await service.GetCertificationHistoryAsync(datasetCode, ct));

    [HttpPost("access-requests")]
    public async Task<IActionResult> SubmitAccess([FromBody] SubmitAccessRequest request, CancellationToken ct)
    {
        var result = await service.SubmitAccessRequestAsync(request, ct);
        if (SoftFailures.Contains(result.StatusCode))
            return Bad(result.StatusMessage);
        return Ok(result);
    }

    [HttpPost("access-requests/{accessRequestId:guid}/approve")]
    public async Task<IActionResult> Approve(Guid accessRequestId, [FromBody] ReviewAccessRequest request, CancellationToken ct)
    {
        var result = await service.ApproveAccessRequestAsync(accessRequestId, request, ct);
        if (SoftFailures.Contains(result.StatusCode))
            return Bad(result.StatusMessage);
        return Ok(result);
    }

    [HttpPost("access-requests/{accessRequestId:guid}/reject")]
    public async Task<IActionResult> Reject(Guid accessRequestId, [FromBody] ReviewAccessRequest request, CancellationToken ct)
    {
        var result = await service.RejectAccessRequestAsync(accessRequestId, request, ct);
        if (SoftFailures.Contains(result.StatusCode))
            return Bad(result.StatusMessage);
        return Ok(result);
    }

    [HttpPost("access/revoke")]
    public async Task<IActionResult> Revoke([FromBody] RevokeAccessRequest request, CancellationToken ct)
    {
        var result = await service.RevokeAccessAsync(request, ct);
        if (SoftFailures.Contains(result.StatusCode))
            return Bad(result.StatusMessage);
        return Ok(result);
    }

    [HttpGet("access-requests/pending")]
    public async Task<ActionResult<IReadOnlyList<AccessRequestDto>>> Pending(
        [FromQuery] Guid? workspaceId, [FromQuery] string? datasetCode, CancellationToken ct)
        => Ok(await service.GetPendingAccessRequestsAsync(workspaceId, datasetCode, ct));

    [HttpGet("access-requests/history")]
    public async Task<ActionResult<IReadOnlyList<AccessRequestDto>>> History(
        [FromQuery] string? datasetCode, [FromQuery] string? userName, [FromQuery] Guid? workspaceId,
        [FromQuery] int take = 100, CancellationToken ct = default)
        => Ok(await service.GetAccessRequestHistoryAsync(datasetCode, userName, workspaceId, take, ct));

    [HttpGet("policy/evaluate")]
    public async Task<ActionResult<PolicyEvaluationDto>> Evaluate(
        [FromQuery] string datasetCode, [FromQuery] string userName,
        [FromQuery] string requiredAccessLevel = "Read", CancellationToken ct = default)
        => Ok(await service.EvaluateAccessAsync(datasetCode, userName, requiredAccessLevel, ct));

    [HttpGet("reports/summary")]
    public async Task<ActionResult<GovernanceSummaryDto>> Summary([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetSummaryAsync(workspaceId, ct));

    [HttpGet("reports/by-classification")]
    public async Task<IActionResult> ByClassification([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetByClassificationAsync(workspaceId, ct));

    [HttpGet("reports/status-distribution")]
    public async Task<IActionResult> StatusDistribution([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetStatusDistributionAsync(workspaceId, ct));

    [HttpGet("reports/access-by-workspace")]
    public async Task<IActionResult> AccessByWorkspace(CancellationToken ct)
        => Ok(await service.GetAccessRequestsByWorkspaceAsync(ct));

    [HttpGet("audit")]
    public async Task<IActionResult> Audit(
        [FromQuery] string? datasetCode, [FromQuery] string? eventType, [FromQuery] int take = 100, CancellationToken ct = default)
        => Ok(await service.GetAuditEventsAsync(datasetCode, eventType, take, ct));

    [HttpPost("maintenance/expire-certifications")]
    public async Task<IActionResult> Expire(CancellationToken ct)
        => Ok(new { expiredCount = await service.ExpireCertificationsAsync(ct) });
}
