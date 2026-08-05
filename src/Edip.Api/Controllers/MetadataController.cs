using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/metadata")]
public sealed class MetadataController(IMetadataService service) : ControllerBase
{
    [HttpPost("refresh/{sourceId:guid}")]
    public async Task<ActionResult<MetadataRefreshResultDto>> Refresh(Guid sourceId, CancellationToken ct)
    {
        try
        {
            return Ok(await service.RefreshAsync(sourceId, ct));
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
    }

    [HttpGet("objects")]
    public async Task<ActionResult<IReadOnlyList<SchemaObjectDto>>> GetObjects([FromQuery] Guid? dataSourceId, CancellationToken ct)
        => Ok(await service.GetObjectsAsync(dataSourceId, ct));

    [HttpGet("columns")]
    public async Task<ActionResult<IReadOnlyList<ColumnDefinitionDto>>> GetColumns(
        [FromQuery] Guid? schemaObjectId,
        [FromQuery] Guid? dataSourceId,
        CancellationToken ct)
        => Ok(await service.GetColumnsAsync(schemaObjectId, dataSourceId, ct));

    [HttpGet("relationships")]
    public async Task<ActionResult<IReadOnlyList<ObjectRelationshipDto>>> GetRelationships([FromQuery] Guid? dataSourceId, CancellationToken ct)
        => Ok(await service.GetRelationshipsAsync(dataSourceId, ct));

    [HttpGet("refresh-history/{sourceId:guid}")]
    public async Task<ActionResult<IReadOnlyList<MetadataRefreshResultDto>>> GetRefreshHistory(Guid sourceId, CancellationToken ct)
        => Ok(await service.GetRefreshHistoryAsync(sourceId, ct));
}
