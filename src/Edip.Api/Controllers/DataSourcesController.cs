using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/datasources")]
public sealed class DataSourcesController(IDataSourceService service) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<DataSourceDto>>> GetAll(CancellationToken ct)
        => Ok(await service.GetAllAsync(ct));

    [HttpGet("{id:guid}")]
    public async Task<ActionResult<DataSourceDto>> GetById(Guid id, CancellationToken ct)
    {
        var item = await service.GetByIdAsync(id, ct);
        return item is null ? NotFound() : Ok(item);
    }

    [HttpPost]
    public async Task<ActionResult<DataSourceDto>> Create([FromBody] CreateDataSourceRequest request, CancellationToken ct)
    {
        var created = await service.CreateAsync(request, ct);
        return CreatedAtAction(nameof(GetById), new { id = created.DataSourceId }, created);
    }

    [HttpPut("{id:guid}")]
    public async Task<ActionResult<DataSourceDto>> Update(Guid id, [FromBody] UpdateDataSourceRequest request, CancellationToken ct)
    {
        var updated = await service.UpdateAsync(id, request, ct);
        return updated is null ? NotFound() : Ok(updated);
    }

    [HttpDelete("{id:guid}")]
    public async Task<IActionResult> Delete(Guid id, CancellationToken ct)
        => await service.DeleteAsync(id, ct) ? NoContent() : NotFound();

    [HttpPost("{id:guid}/validate")]
    public async Task<ActionResult<ValidationResultDto>> Validate(Guid id, CancellationToken ct)
    {
        try
        {
            return Ok(await service.ValidateAsync(id, ct));
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
    }

    [HttpGet("{id:guid}/health")]
    public async Task<ActionResult<DataSourceHealthDto>> Health(Guid id, CancellationToken ct)
    {
        var health = await service.GetHealthAsync(id, ct);
        return health is null ? NotFound() : Ok(health);
    }
}
