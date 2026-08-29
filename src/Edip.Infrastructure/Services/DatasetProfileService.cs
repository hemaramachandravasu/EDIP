using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class DatasetProfileService(IDatasetProfileRepository repository) : IDatasetProfileService
{
    public Task<ProfileRunDto> ProfileAsync(
        string datasetCode, string profileScope = "Processed", Guid? importId = null, Guid? batchId = null, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(datasetCode))
            throw new ArgumentException("DatasetCode is required.");
        return repository.ProfileAsync(datasetCode, profileScope, "Api", importId, batchId, ct);
    }

    public Task<ProfileRunDto?> GetRunAsync(Guid profileRunId, CancellationToken ct = default)
        => repository.GetRunAsync(profileRunId, ct);

    public Task<ProfileRunDto?> GetLatestScoreAsync(string datasetCode, CancellationToken ct = default)
        => repository.GetLatestScoreAsync(datasetCode, ct);

    public Task<IReadOnlyList<DatasetColumnProfileDto>> GetColumnProfilesAsync(Guid profileRunId, CancellationToken ct = default)
        => repository.GetColumnProfilesAsync(profileRunId, ct);

    public Task<IReadOnlyList<DatasetQualityIssueDto>> GetIssuesAsync(Guid profileRunId, CancellationToken ct = default)
        => repository.GetIssuesAsync(profileRunId, ct);

    public Task<IReadOnlyList<DatasetThresholdResultDto>> GetThresholdResultsAsync(Guid profileRunId, CancellationToken ct = default)
        => repository.GetThresholdResultsAsync(profileRunId, ct);

    public Task<IReadOnlyList<DatasetQualityTrendRow>> GetTrendAsync(
        string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        var to = toUtc ?? DateTime.UtcNow;
        var from = fromUtc ?? to.AddDays(-90);
        return repository.GetTrendAsync(datasetCode, from, to, ct);
    }

    public Task<int> ProfileDueDatasetsAsync(int maxDatasets = 10, CancellationToken ct = default)
        => repository.ProfileDueDatasetsAsync(maxDatasets, ct);

    public Task ArchiveHistoryAsync(int retainDays = 180, CancellationToken ct = default)
        => repository.ArchiveHistoryAsync(retainDays, ct);
}
