using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

[ApiController]
[Route("api/etl")]
public sealed class EtlController(IEtlService service, IIngestionService ingestion) : ControllerBase
{
    [HttpPost("batches")]
    public async Task<ActionResult<ImportBatchDto>> CreateAndLoad(
        [FromBody] CreateImportBatchRequest request,
        CancellationToken ct)
    {
        try
        {
            var batch = await ingestion.CreateBatchAsync(request, ct);
            return CreatedAtAction(nameof(GetBatch), new { batchId = batch.BatchId }, batch);
        }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (ArgumentException ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpPost("batches/{batchId:guid}/run")]
    public async Task<ActionResult<ImportBatchDto>> Run(
        Guid batchId,
        [FromQuery] bool forceFail = false,
        CancellationToken ct = default)
    {
        try { return Ok(await service.RunPipelineAsync(batchId, forceFail, ct)); }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpPost("batches/{batchId:guid}/retry")]
    public async Task<ActionResult<ImportBatchDto>> Retry(Guid batchId, CancellationToken ct)
    {
        try { return Ok(await service.RetryAsync(batchId, ct)); }
        catch (KeyNotFoundException) { return NotFound(); }
        catch (Exception ex) { return BadRequest(new { error = ex.Message }); }
    }

    [HttpGet("batches/{batchId:guid}")]
    public async Task<ActionResult<ImportBatchDto>> GetBatch(Guid batchId, CancellationToken ct)
    {
        var batch = await service.GetBatchAsync(batchId, ct);
        return batch is null ? NotFound() : Ok(batch);
    }

    [HttpGet("batches/{batchId:guid}/errors")]
    public async Task<ActionResult<IReadOnlyList<EtlErrorDto>>> GetBatchErrors(Guid batchId, CancellationToken ct)
        => Ok(await service.GetErrorsByBatchAsync(batchId, ct));

    [HttpGet("datasets/{datasetCode}/errors")]
    public async Task<ActionResult<IReadOnlyList<EtlErrorDto>>> GetDatasetErrors(
        string datasetCode,
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        CancellationToken ct)
        => Ok(await service.GetErrorsByDatasetAsync(datasetCode, fromUtc, toUtc, ct));

    [HttpPost("process-pending")]
    public async Task<ActionResult<object>> ProcessPending([FromQuery] int maxBatches = 10, CancellationToken ct = default)
        => Ok(new { batchesProcessed = await service.ProcessPendingAsync(maxBatches, ct) });

    [HttpPost("archive-errors")]
    public async Task<IActionResult> ArchiveErrors([FromQuery] int retainDays = 90, CancellationToken ct = default)
    {
        await service.ArchiveErrorsAsync(retainDays, ct);
        return Ok(new { status = "archived", retainDays });
    }

    [HttpPost("cleanup")]
    public async Task<IActionResult> Cleanup([FromQuery] int retainDays = 90, CancellationToken ct = default)
    {
        await service.CleanupBatchesAsync(retainDays, ct);
        return Ok(new { status = "cleaned", retainDays });
    }

    [HttpPost("quality-snapshot")]
    public async Task<IActionResult> QualitySnapshot(CancellationToken ct)
    {
        await service.GenerateQualitySnapshotAsync(ct);
        return Ok(new { status = "snapshot-written" });
    }

    [HttpPost("generate-test-batch")]
    public async Task<ActionResult<object>> GenerateTestBatch([FromQuery] int rowCount = 1000, CancellationToken ct = default)
    {
        var batchId = await service.GenerateTestBatchAsync(Math.Clamp(rowCount, 1, 20000), ct);
        return Ok(new { batchId, rowCount });
    }
}
