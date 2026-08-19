using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Services;

public sealed class IngestionService(IIngestionRepository repository) : IIngestionService
{
    public async Task<IReadOnlyList<IngestDatasetDto>> GetDatasetsAsync(CancellationToken ct = default)
    {
        var items = await repository.GetDatasetsAsync(ct);
        return items.Select(d => new IngestDatasetDto
        {
            DatasetId = d.DatasetId,
            DatasetCode = d.DatasetCode,
            DisplayName = d.DisplayName,
            Description = d.Description,
            IsActive = d.IsActive
        }).ToList();
    }

    public async Task<ImportBatchDto> CreateBatchAsync(CreateImportBatchRequest request, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(request.DatasetCode))
            throw new ArgumentException("DatasetCode is required.");

        if (!string.Equals(request.DatasetCode, "CUSTOMER", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Only the CUSTOMER dataset is supported for staging load via API.");

        var datasetId = await repository.GetDatasetIdByCodeAsync(request.DatasetCode, ct)
            ?? throw new KeyNotFoundException($"Dataset '{request.DatasetCode}' was not found.");

        var batchId = await repository.CreateBatchAsync(
            request.DatasetCode,
            request.DataSourceId,
            request.SourceInfo,
            ct,
            request.SourceFile,
            request.LoadMode,
            request.DuplicateStrategy);

        if (request.Records.Count > 0)
        {
            var rows = request.Records.Select((r, i) => new StagingCustomerRow
            {
                RowNumber = i + 1,
                CustomerCode = r.CustomerCode,
                CustomerName = r.CustomerName,
                CountryCode = r.CountryCode,
                Email = r.Email,
                CreditLimit = r.CreditLimit,
                Status = r.Status,
                CreatedDate = r.CreatedDate
            }).ToList();

            await repository.LoadStagingCustomersAsync(batchId, datasetId, rows, request.SourceInfo, ct);
            await repository.CompleteStagingLoadAsync(batchId, ct);
        }

        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        var batch = await repository.GetBatchAsync(batchId, ct);
        return batch is null ? null : Map(batch);
    }

    public async Task<ImportBatchDto> ValidateBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        _ = await repository.GetBatchAsync(batchId, ct)
            ?? throw new KeyNotFoundException($"Batch '{batchId}' was not found.");
        await repository.ValidateBatchAsync(batchId, ct);
        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<ImportBatchDto> ProcessBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        _ = await repository.GetBatchAsync(batchId, ct)
            ?? throw new KeyNotFoundException($"Batch '{batchId}' was not found.");
        await repository.ProcessBatchAsync(batchId, "Api", ct);
        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<ImportBatchDto> RetryBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        _ = await repository.GetBatchAsync(batchId, ct)
            ?? throw new KeyNotFoundException($"Batch '{batchId}' was not found.");
        await repository.RetryBatchAsync(batchId, ct);
        return (await GetBatchAsync(batchId, ct))!;
    }

    public async Task<IReadOnlyList<ImportErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default)
    {
        var errors = await repository.GetErrorsByBatchAsync(batchId, ct);
        return errors.Select(MapError).ToList();
    }

    public async Task<IReadOnlyList<ImportErrorDto>> GetErrorsByDatasetAsync(
        string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        var to = toUtc ?? DateTime.UtcNow;
        var from = fromUtc ?? to.AddDays(-30);
        var errors = await repository.GetErrorsByDatasetAsync(datasetCode, from, to, ct);
        return errors.Select(MapError).ToList();
    }

    public Task<int> ProcessPendingBatchesAsync(int maxBatches = 10, CancellationToken ct = default)
        => repository.ProcessPendingBatchesAsync(maxBatches, ct);

    public Task ArchiveImportHistoryAsync(int retainDays = 90, CancellationToken ct = default)
        => repository.ArchiveImportHistoryAsync(retainDays, ct);

    private static ImportBatchDto Map(ImportBatch b) => new()
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

    private static ImportErrorDto MapError(ImportError e) => new()
    {
        ErrorId = e.ErrorId,
        BatchId = e.BatchId,
        DatasetCode = e.DatasetCode,
        RowReference = e.RowReference,
        ColumnName = e.ColumnName,
        InvalidValue = e.InvalidValue,
        ErrorCode = e.ErrorCode,
        ErrorDescription = e.ErrorDescription,
        Severity = e.Severity,
        ErrorUtc = e.ErrorUtc
    };
}
