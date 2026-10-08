using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/catalog")]
public sealed class CatalogController(ICatalogService service) : ControllerBase
{
    private IActionResult Fail(string statusCode, string message)
    {
        var body = new { statusCode, error = message };
        return statusCode switch
        {
            "NotFound" or "InvalidDataset" => NotFound(body),
            "Unauthorized" => StatusCode(StatusCodes.Status403Forbidden, body),
            _ => BadRequest(body)
        };
    }

    // ---------------- Search / detail ----------------

    [HttpGet("datasets")]
    public async Task<IActionResult> Search([FromQuery] CatalogSearchQuery query, CancellationToken ct)
    {
        var result = await service.SearchAsync(query, ct);
        return result.StatusCode == "OK" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage);
    }

    [HttpGet("datasets/{datasetCode}")]
    public async Task<IActionResult> GetDetail(string datasetCode, [FromQuery] string userName,
        [FromQuery] int recentImportCount = 5, [FromQuery] int lineageNeighborLimit = 20,
        [FromQuery] bool includeHistory = false, [FromQuery] int historyCount = 10, CancellationToken ct = default)
    {
        var result = await service.GetDatasetDetailAsync(datasetCode, userName, recentImportCount, lineageNeighborLimit,
            includeHistory, historyCount, ct);
        return result.StatusCode == "OK" && result.Detail is not null
            ? Ok(result.Detail)
            : Fail(result.StatusCode, result.StatusMessage);
    }

    // ---------------- Tags ----------------

    [HttpGet("tags")]
    public async Task<IActionResult> GetTags([FromQuery] string userName, [FromQuery] string? search,
        [FromQuery] bool includeUnused = false, CancellationToken ct = default)
    {
        var result = await service.GetTagsAsync(userName, search, includeUnused, ct);
        return result.StatusCode == "OK" ? Ok(result.Tags) : Fail(result.StatusCode, result.StatusMessage);
    }

    [HttpPost("datasets/{datasetCode}/tags")]
    public async Task<IActionResult> AddTags(string datasetCode, [FromBody] DatasetTagsRequest request, CancellationToken ct)
    {
        var result = await service.AddDatasetTagsAsync(datasetCode, request, ct);
        return result.StatusCode is "Tagged" or "NoChange" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage);
    }

    [HttpPost("datasets/{datasetCode}/tags/remove")]
    public async Task<IActionResult> RemoveTags(string datasetCode, [FromBody] DatasetTagsRequest request, CancellationToken ct)
    {
        var result = await service.RemoveDatasetTagsAsync(datasetCode, request, ct);
        return result.StatusCode is "Untagged" or "NoChange" ? Ok(result) : Fail(result.StatusCode, result.StatusMessage);
    }

    // ---------------- Reports (access-aware; unknown users get zero counts) ----------------

    [HttpGet("reports/summary")]
    public async Task<ActionResult<CatalogSummaryDto>> Summary([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetSummaryAsync(userName, workspaceCode, ct));

    [HttpGet("reports/by-classification")]
    public async Task<IActionResult> ByClassification([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetByClassificationAsync(userName, workspaceCode, ct));

    [HttpGet("reports/by-governance-status")]
    public async Task<IActionResult> ByGovernanceStatus([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetByGovernanceStatusAsync(userName, workspaceCode, ct));

    [HttpGet("reports/by-category")]
    public async Task<IActionResult> ByCategory([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetByCategoryAsync(userName, workspaceCode, ct));

    [HttpGet("reports/certification")]
    public async Task<IActionResult> Certification([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetCertificationAsync(userName, workspaceCode, ct));

    [HttpGet("reports/quality-distribution")]
    public async Task<IActionResult> QualityDistribution([FromQuery] string userName, [FromQuery] string? workspaceCode, CancellationToken ct)
        => Ok(await service.GetQualityDistributionAsync(userName, workspaceCode, ct));

    [HttpGet("reports/recently-updated")]
    public async Task<IActionResult> RecentlyUpdated([FromQuery] string userName, [FromQuery] string? workspaceCode,
        [FromQuery] int days = 30, [FromQuery] int top = 10, CancellationToken ct = default)
        => Ok(await service.GetRecentlyUpdatedAsync(userName, workspaceCode, days, top, ct));

    [HttpGet("reports/recently-imported")]
    public async Task<IActionResult> RecentlyImported([FromQuery] string userName, [FromQuery] string? workspaceCode,
        [FromQuery] int days = 30, [FromQuery] int top = 10, CancellationToken ct = default)
        => Ok(await service.GetRecentlyImportedAsync(userName, workspaceCode, days, top, ct));
}
