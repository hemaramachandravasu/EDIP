using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/metadata-sync")]
public sealed class MetadataSyncController(IMetadataSyncService service) : ControllerBase
{
    [HttpPost("{dataSourceId:guid}")]
    public async Task<ActionResult<MetadataSyncResultDto>> Synchronize(Guid dataSourceId, CancellationToken ct)
    {
        try
        {
            return Ok(await service.SynchronizeAsync(dataSourceId, "Manual", ct));
        }
        catch (KeyNotFoundException) { return NotFound(); }
    }

    [HttpGet("{dataSourceId:guid}/history")]
    public async Task<ActionResult<IReadOnlyList<MetadataSyncResultDto>>> History(Guid dataSourceId, CancellationToken ct)
        => Ok(await service.GetSyncHistoryAsync(dataSourceId, ct));

    [HttpGet("{dataSourceId:guid}/schema-changes")]
    public async Task<ActionResult<IReadOnlyList<SchemaChangeEventDto>>> SchemaChanges(Guid dataSourceId, CancellationToken ct)
        => Ok(await service.GetSchemaChangesAsync(dataSourceId, ct));

    [HttpPost("archive")]
    public async Task<IActionResult> Archive([FromQuery] int retainDays = 90, CancellationToken ct = default)
    {
        await service.ArchiveHistoryAsync(retainDays, ct);
        return Ok(new { message = $"Archived history older than {retainDays} days." });
    }
}
