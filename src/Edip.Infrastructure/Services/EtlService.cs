using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class EtlService(
    IEtlRepository etlRepository,
    IIngestionRepository ingestionRepository) : IEtlService
{
    public async Task<ImportBatchDto> RunPipelineAsync(Guid batchId, bool forceFail = false, CancellationToken ct = default)
    {
        _ = await ingestionRepository.GetBatchAsync(batchId, ct)
            ?? throw new KeyNotFoundException($"Batch '{batchId}' was not found.");
        await etlRepository.RunPipelineAsync(batchId, "Api", forceFail, ct);
        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<ImportBatchDto> RetryAsync(Guid batchId, CancellationToken ct = default)
    {
        _ = await ingestionRepository.GetBatchAsync(batchId, ct)
            ?? throw new KeyNotFoundException($"Batch '{batchId}' was not found.");
        await etlRepository.RetryBatchAsync(batchId, ct);
        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        var batch = await ingestionRepository.GetBatchAsync(batchId, ct);
        return batch is null ? null : Map(batch);
    }

    public Task<IReadOnlyList<EtlErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default)
        => etlRepository.GetErrorsByBatchAsync(batchId, ct);

    public Task<IReadOnlyList<EtlErrorDto>> GetErrorsByDatasetAsync(
        string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        var to = toUtc ?? DateTime.UtcNow;
        var from = fromUtc ?? to.AddDays(-30);
        return etlRepository.GetErrorsByDatasetAsync(datasetCode, from, to, ct);
    }

    public Task<int> ProcessPendingAsync(int maxBatches = 10, CancellationToken ct = default)
        => etlRepository.ProcessPendingAsync(maxBatches, ct);

    public Task ArchiveErrorsAsync(int retainDays = 90, CancellationToken ct = default)
        => etlRepository.ArchiveErrorsAsync(retainDays, ct);

    public Task CleanupBatchesAsync(int retainDays = 90, CancellationToken ct = default)
        => etlRepository.CleanupBatchesAsync(retainDays, ct);

    public Task GenerateQualitySnapshotAsync(CancellationToken ct = default)
        => etlRepository.GenerateQualitySnapshotAsync(ct);

    public Task<Guid> GenerateTestBatchAsync(int rowCount = 1000, CancellationToken ct = default)
        => etlRepository.GenerateTestBatchAsync(rowCount, ct);

    private static ImportBatchDto Map(Core.Models.ImportBatch b) => new()
    {
        BatchId = b.BatchId,
        DatasetCode = b.DatasetCode,
        DatasetName = b.DatasetName,
        DataSourceId = b.DataSourceId,
        SourceInfo = b.SourceInfo,
        ImportId = b.ImportId,
        SourceFile = b.SourceFile,
        LoadMode = b.LoadMode,
        DuplicateStrategy = b.DuplicateStrategy,
        ImportUtc = b.ImportUtc,
        Status = b.Status,
        TotalRecords = b.TotalRecords,
        ValidRecords = b.ValidRecords,
        RejectedRecords = b.RejectedRecords,
        ProcessedRecords = b.ProcessedRecords,
        InsertedRecords = b.InsertedRecords,
        UpdatedRecords = b.UpdatedRecords,
        TransformedRecords = b.TransformedRecords,
        DuplicateRecords = b.DuplicateRecords,
        ErrorCount = b.ErrorCount,
        AttemptCount = b.AttemptCount,
        MaxRetries = b.MaxRetries,
        StartedUtc = b.StartedUtc,
        CompletedUtc = b.CompletedUtc,
        DurationSeconds = b.DurationSeconds,
        LastErrorMessage = b.LastErrorMessage
    };
}
