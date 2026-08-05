using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/quality")]
public sealed class QualityController(IQualityAssessmentService service) : ControllerBase
{
    [HttpPost("{dataSourceId:guid}/assess")]
    public async Task<ActionResult<QualityAssessmentDto>> Assess(
        Guid dataSourceId,
        [FromQuery] Guid? profilingRunId,
        CancellationToken ct)
    {
        try
        {
            return Ok(await service.AssessAsync(dataSourceId, profilingRunId, ct));
        }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (InvalidOperationException ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("assessments/{assessmentId:guid}")]
    public async Task<ActionResult<QualityAssessmentDto>> GetAssessment(Guid assessmentId, CancellationToken ct)
    {
        var item = await service.GetAssessmentAsync(assessmentId, ct);
        return item is null ? NotFound() : Ok(item);
    }

    [HttpGet("source/{dataSourceId:guid}")]
    public async Task<ActionResult<IReadOnlyList<QualityAssessmentDto>>> GetAssessments(Guid dataSourceId, CancellationToken ct)
        => Ok(await service.GetAssessmentsAsync(dataSourceId, ct));
}
