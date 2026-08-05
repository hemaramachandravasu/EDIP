using Edip.Core.DTOs;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/jobs")]
public sealed class JobsController(IProcessingJobService service) : ControllerBase
{
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<ProcessingJobDto>>> GetAll(CancellationToken ct)
        => Ok(await service.GetAllAsync(ct));

    [HttpGet("{id:guid}")]
    public async Task<ActionResult<ProcessingJobDto>> GetById(Guid id, CancellationToken ct)
    {
        var job = await service.GetByIdAsync(id, ct);
        return job is null ? NotFound() : Ok(job);
    }

    [HttpPost]
    public async Task<ActionResult<ProcessingJobDto>> Create([FromBody] CreateProcessingJobRequest request, CancellationToken ct)
    {
        try
        {
            var created = await service.CreateAsync(request, ct);
            return CreatedAtAction(nameof(GetById), new { id = created.JobId }, created);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new { error = ex.Message });
        }
    }

    [HttpPut("{id:guid}")]
    public async Task<ActionResult<ProcessingJobDto>> Update(Guid id, [FromBody] UpdateProcessingJobRequest request, CancellationToken ct)
    {
        var updated = await service.UpdateAsync(id, request, ct);
        return updated is null ? NotFound() : Ok(updated);
    }

    [HttpPost("{id:guid}/execute")]
    public async Task<ActionResult<ExecuteJobResultDto>> Execute(Guid id, CancellationToken ct)
    {
        try
        {
            return Ok(await service.ExecuteAsync(id, JobTriggerType.Manual, ct));
        }
        catch (KeyNotFoundException)
        {
            return NotFound();
        }
    }

    [HttpGet("{id:guid}/executions")]
    public async Task<ActionResult<IReadOnlyList<JobExecutionDto>>> GetExecutions(Guid id, CancellationToken ct)
        => Ok(await service.GetExecutionsAsync(id, ct));
}
