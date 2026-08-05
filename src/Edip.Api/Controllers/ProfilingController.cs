using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/profiling")]
public sealed class ProfilingController(IProfilingService service) : ControllerBase
{
    [HttpPost("{dataSourceId:guid}")]
    public async Task<ActionResult<ProfilingRunDto>> Profile(Guid dataSourceId, CancellationToken ct)
    {
        try
        {
            return Ok(await service.ProfileAsync(dataSourceId, "Manual", ct));
        }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (NotSupportedException ex) { return BadRequest(new { error = ex.Message }); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("runs/{runId:guid}")]
    public async Task<ActionResult<ProfilingRunDto>> GetRun(Guid runId, CancellationToken ct)
    {
        var run = await service.GetRunAsync(runId, ct);
        return run is null ? NotFound() : Ok(run);
    }

    [HttpGet("source/{dataSourceId:guid}")]
    public async Task<ActionResult<IReadOnlyList<ProfilingRunDto>>> GetRuns(Guid dataSourceId, CancellationToken ct)
        => Ok(await service.GetRunsAsync(dataSourceId, ct));
}
