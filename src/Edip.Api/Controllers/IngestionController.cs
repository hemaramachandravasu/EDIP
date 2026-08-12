using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/ingestion")]
public sealed class IngestionController(IIngestionService service) : ControllerBase
{
    [HttpGet("datasets")]
    public async Task<ActionResult<IReadOnlyList<IngestDatasetDto>>> GetDatasets(CancellationToken ct)
        => Ok(await service.GetDatasetsAsync(ct));

    [HttpPost("batches")]
    public async Task<ActionResult<ImportBatchDto>> CreateBatch(
        [FromBody] CreateImportBatchRequest request,
        CancellationToken ct)
    {
        try
        {
            var batch = await service.CreateBatchAsync(request, ct);
            return CreatedAtAction(nameof(GetBatch), new { batchId = batch.BatchId }, batch);
        }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (ArgumentException ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("batches/{batchId:guid}")]
    public async Task<ActionResult<ImportBatchDto>> GetBatch(Guid batchId, CancellationToken ct)
    {
        var batch = await service.GetBatchAsync(batchId, ct);
        return batch is null ? NotFound() : Ok(batch);
    }

    [HttpPost("batches/{batchId:guid}/validate")]
    public async Task<ActionResult<ImportBatchDto>> Validate(Guid batchId, CancellationToken ct)
    {
        try { return Ok(await service.ValidateBatchAsync(batchId, ct)); }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpPost("batches/{batchId:guid}/process")]
    public async Task<ActionResult<ImportBatchDto>> Process(Guid batchId, CancellationToken ct)
    {
        try { return Ok(await service.ProcessBatchAsync(batchId, ct)); }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpPost("batches/{batchId:guid}/retry")]
    public async Task<ActionResult<ImportBatchDto>> Retry(Guid batchId, CancellationToken ct)
    {
        try { return Ok(await service.RetryBatchAsync(batchId, ct)); }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("batches/{batchId:guid}/errors")]
    public async Task<ActionResult<IReadOnlyList<ImportErrorDto>>> GetBatchErrors(Guid batchId, CancellationToken ct)
        => Ok(await service.GetErrorsByBatchAsync(batchId, ct));

    [HttpGet("datasets/{datasetCode}/errors")]
    public async Task<ActionResult<IReadOnlyList<ImportErrorDto>>> GetDatasetErrors(
        string datasetCode,
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        CancellationToken ct)
        => Ok(await service.GetErrorsByDatasetAsync(datasetCode, fromUtc, toUtc, ct));

    [HttpPost("process-pending")]
    public async Task<ActionResult<object>> ProcessPending([FromQuery] int maxBatches = 10, CancellationToken ct = default)
    {
        var count = await service.ProcessPendingBatchesAsync(maxBatches, ct);
        return Ok(new { batchesProcessed = count });
    }
}
