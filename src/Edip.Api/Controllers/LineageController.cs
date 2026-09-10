using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/lineage")]
public sealed class LineageController(ILineageService service) : ControllerBase
{
    private IActionResult Bad(string message) => BadRequest(new { error = message });

    [HttpGet("upstream")]
    public async Task<ActionResult<IReadOnlyList<LineageNodeDto>>> Upstream(
        [FromQuery] Guid? entityId,
        [FromQuery] string? datasetCode,
        [FromQuery] Guid? datasetVersionId,
        [FromQuery] int? versionNumber,
        [FromQuery] Guid? workspaceId,
        [FromQuery] int maxDepth = 20,
        CancellationToken ct = default)
        => Ok(await service.GetUpstreamAsync(entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct));

    [HttpGet("downstream")]
    public async Task<ActionResult<IReadOnlyList<LineageNodeDto>>> Downstream(
        [FromQuery] Guid? entityId,
        [FromQuery] string? datasetCode,
        [FromQuery] Guid? datasetVersionId,
        [FromQuery] int? versionNumber,
        [FromQuery] Guid? workspaceId,
        [FromQuery] int maxDepth = 20,
        CancellationToken ct = default)
        => Ok(await service.GetDownstreamAsync(entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct));

    [HttpGet("impact")]
    public async Task<ActionResult<IReadOnlyList<LineageNodeDto>>> Impact(
        [FromQuery] Guid? entityId,
        [FromQuery] string? datasetCode,
        [FromQuery] Guid? datasetVersionId,
        [FromQuery] int? versionNumber,
        [FromQuery] string changeType = "Dataset",
        [FromQuery] Guid? workspaceId = null,
        [FromQuery] int maxDepth = 20,
        CancellationToken ct = default)
        => Ok(await service.ImpactAnalysisAsync(entityId, datasetCode, datasetVersionId, versionNumber, changeType, workspaceId, maxDepth, ct));

    [HttpGet("versions/{datasetCode}")]
    public async Task<ActionResult<VersionLineageResultDto>> VersionLineage(
        string datasetCode,
        [FromQuery] int? versionNumber,
        [FromQuery] Guid? datasetVersionId,
        [FromQuery] Guid? workspaceId,
        CancellationToken ct = default)
        => Ok(await service.GetVersionLineageAsync(datasetCode, versionNumber, datasetVersionId, workspaceId, ct));

    [HttpGet("circular")]
    public async Task<ActionResult<IReadOnlyList<CircularDependencyDto>>> Circular(
        [FromQuery] Guid? workspaceId, [FromQuery] int maxDepth = 50, CancellationToken ct = default)
        => Ok(await service.DetectCircularAsync(workspaceId, maxDepth, ct));

    [HttpPost("relationships")]
    public async Task<IActionResult> AddRelationship(
        [FromBody] AddRelationshipRequest request, CancellationToken ct = default)
    {
        var result = await service.AddRelationshipAsync(request, ct);
        if (result.StatusCode is "CycleRejected" or "InvalidEntity")
            return Bad(result.StatusMessage);
        return Ok(result);
    }

    [HttpPost("sync")]
    public async Task<ActionResult<LineageSyncResultDto>> Sync(
        [FromQuery] int maxBatches = 200, CancellationToken ct = default)
        => Ok(await service.SyncPlatformAsync(maxBatches, ct));

    [HttpGet("entities")]
    public async Task<ActionResult<IReadOnlyList<LineageEntityDto>>> Entities(
        [FromQuery] Guid? entityId,
        [FromQuery] string? entityCode,
        [FromQuery] string? entityTypeCode,
        [FromQuery] Guid? workspaceId,
        CancellationToken ct = default)
        => Ok(await service.GetEntitiesAsync(entityId, entityCode, entityTypeCode, workspaceId, ct));

    [HttpGet("analytics/most-connected")]
    public async Task<IActionResult> MostConnected([FromQuery] Guid? workspaceId, [FromQuery] int take = 20, CancellationToken ct = default)
        => Ok(await service.GetMostConnectedAsync(workspaceId, take, ct));

    [HttpGet("analytics/highest-dependencies")]
    public async Task<IActionResult> HighestDependencies([FromQuery] Guid? workspaceId, [FromQuery] int take = 20, CancellationToken ct = default)
        => Ok(await service.GetHighestDependenciesAsync(workspaceId, take, ct));

    [HttpGet("analytics/highest-dependents")]
    public async Task<IActionResult> HighestDependents([FromQuery] Guid? workspaceId, [FromQuery] int take = 20, CancellationToken ct = default)
        => Ok(await service.GetHighestDependentsAsync(workspaceId, take, ct));

    [HttpGet("analytics/relationship-counts")]
    public async Task<IActionResult> RelationshipCounts([FromQuery] Guid? workspaceId, CancellationToken ct = default)
        => Ok(await service.GetRelationshipCountsAsync(workspaceId, ct));

    [HttpGet("analytics/source-to-dataset")]
    public async Task<IActionResult> SourceToDataset([FromQuery] Guid? workspaceId, CancellationToken ct = default)
        => Ok(await service.GetSourceToDatasetCountsAsync(workspaceId, ct));

    [HttpGet("analytics/dataset-to-report")]
    public async Task<IActionResult> DatasetToReport([FromQuery] Guid? workspaceId, CancellationToken ct = default)
        => Ok(await service.GetDatasetToReportAsync(workspaceId, ct));

    [HttpGet("analytics/dependency-depth")]
    public async Task<IActionResult> DependencyDepth(
        [FromQuery] Guid? workspaceId, [FromQuery] int maxDepth = 20, CancellationToken ct = default)
        => Ok(await service.GetDependencyDepthAsync(workspaceId, maxDepth, ct));
}
