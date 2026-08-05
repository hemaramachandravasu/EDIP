using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/reports")]
public sealed class ReportsController(IReportService service) : ControllerBase
{
    [HttpGet("{name}")]
    public async Task<IActionResult> GetReport(
        string name,
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        CancellationToken ct)
    {
        try
        {
            var data = await service.GetReportAsync(name, fromUtc, toUtc, ct);
            return Ok(data);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpGet("{name}/export")]
    public async Task<IActionResult> Export(
        string name,
        [FromQuery] string format = "csv",
        [FromQuery] DateTime? fromUtc = null,
        [FromQuery] DateTime? toUtc = null,
        CancellationToken ct = default)
    {
        try
        {
            var (content, contentType, fileName) = await service.ExportReportAsync(name, format, fromUtc, toUtc, ct);
            return File(content, contentType, fileName);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }
}
