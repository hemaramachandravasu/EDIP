using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/dataset-profile")]
public sealed class DatasetProfileController(IDatasetProfileService service) : ControllerBase
{
    [HttpPost("{datasetCode}")]
    public async Task<ActionResult<ProfileRunDto>> Profile(
        string datasetCode,
        [FromQuery] string scope = "Processed",
        [FromQuery] Guid? importId = null,
        [FromQuery] Guid? batchId = null,
        CancellationToken ct = default)
    {
        try
        {
            return Ok(await service.ProfileAsync(datasetCode, scope, importId, batchId, ct));
        }
        catch (ArgumentException ex) { return BadRequest(new { error = ex.Message }); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("runs/{profileRunId:guid}")]
    public async Task<ActionResult<ProfileRunDto>> GetRun(Guid profileRunId, CancellationToken ct)
    {
        var run = await service.GetRunAsync(profileRunId, ct);
        return run is null ? NotFound() : Ok(run);
    }

    [HttpGet("{datasetCode}/score")]
    public async Task<ActionResult<ProfileRunDto>> GetLatestScore(string datasetCode, CancellationToken ct)
    {
        var run = await service.GetLatestScoreAsync(datasetCode, ct);
        return run is null ? NotFound() : Ok(run);
    }

    [HttpGet("runs/{profileRunId:guid}/columns")]
    public async Task<ActionResult<IReadOnlyList<DatasetColumnProfileDto>>> GetColumns(Guid profileRunId, CancellationToken ct)
        => Ok(await service.GetColumnProfilesAsync(profileRunId, ct));

    [HttpGet("runs/{profileRunId:guid}/issues")]
    public async Task<ActionResult<IReadOnlyList<DatasetQualityIssueDto>>> GetIssues(Guid profileRunId, CancellationToken ct)
        => Ok(await service.GetIssuesAsync(profileRunId, ct));

    [HttpGet("runs/{profileRunId:guid}/thresholds")]
    public async Task<ActionResult<IReadOnlyList<DatasetThresholdResultDto>>> GetThresholds(Guid profileRunId, CancellationToken ct)
        => Ok(await service.GetThresholdResultsAsync(profileRunId, ct));

    [HttpGet("{datasetCode}/trend")]
    public async Task<ActionResult<IReadOnlyList<DatasetQualityTrendRow>>> GetTrend(
        string datasetCode,
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        CancellationToken ct)
        => Ok(await service.GetTrendAsync(datasetCode, fromUtc, toUtc, ct));

    [HttpPost("process-due")]
    public async Task<ActionResult<object>> ProcessDue([FromQuery] int maxDatasets = 10, CancellationToken ct = default)
        => Ok(new { datasetsProfiled = await service.ProfileDueDatasetsAsync(maxDatasets, ct) });
}
