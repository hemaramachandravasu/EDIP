using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class CatalogService(ICatalogRepository repository) : ICatalogService
{
    public Task<CatalogSearchResult> SearchAsync(CatalogSearchQuery query, CancellationToken ct = default)
        => repository.SearchAsync(query, ct);

    public Task<CatalogDetailResult> GetDatasetDetailAsync(string datasetCode, string userName, int recentImportCount = 5,
        int lineageNeighborLimit = 20, bool includeHistory = false, int historyCount = 10, CancellationToken ct = default)
        => repository.GetDatasetDetailAsync(datasetCode, userName, recentImportCount, lineageNeighborLimit, includeHistory, historyCount, ct);

    public Task<CatalogTagListResult> GetTagsAsync(string userName, string? search = null, bool includeUnused = false, CancellationToken ct = default)
        => repository.GetTagsAsync(userName, search, includeUnused, ct);

    public Task<DatasetTagActionResult> AddDatasetTagsAsync(string datasetCode, DatasetTagsRequest request, CancellationToken ct = default)
        => HasCommaTag(request.Tags)
            ? Task.FromResult(CommaRejected(datasetCode))
            : repository.AddDatasetTagsAsync(datasetCode, ToCsv(request.Tags), request.UserName, ct);

    public Task<DatasetTagActionResult> RemoveDatasetTagsAsync(string datasetCode, DatasetTagsRequest request, CancellationToken ct = default)
        => HasCommaTag(request.Tags)
            ? Task.FromResult(CommaRejected(datasetCode))
            : repository.RemoveDatasetTagsAsync(datasetCode, ToCsv(request.Tags), request.UserName, ct);

    public Task<CatalogSummaryDto> GetSummaryAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetSummaryAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogCountRow>> GetByClassificationAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetByClassificationAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogCountRow>> GetByGovernanceStatusAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetByGovernanceStatusAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogCountRow>> GetByCategoryAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetByCategoryAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogCertificationRow>> GetCertificationAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetCertificationAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogQualityBucketRow>> GetQualityDistributionAsync(string userName, string? workspaceCode = null, CancellationToken ct = default)
        => repository.GetQualityDistributionAsync(userName, workspaceCode, ct);

    public Task<IReadOnlyList<CatalogRecentDatasetRow>> GetRecentlyUpdatedAsync(string userName, string? workspaceCode = null, int days = 30, int top = 10, CancellationToken ct = default)
        => repository.GetRecentlyUpdatedAsync(userName, workspaceCode, days, top, ct);

    public Task<IReadOnlyList<CatalogRecentDatasetRow>> GetRecentlyImportedAsync(string userName, string? workspaceCode = null, int days = 30, int top = 10, CancellationToken ct = default)
        => repository.GetRecentlyImportedAsync(userName, workspaceCode, days, top, ct);

    // Commas are the list separator in SQL, so a comma inside one tag would silently become two tags.
    private static bool HasCommaTag(IReadOnlyList<string> tags) => tags.Any(t => t?.Contains(',') == true);

    private static DatasetTagActionResult CommaRejected(string datasetCode) => new()
    {
        DatasetCode = datasetCode,
        StatusCode = "InvalidTag",
        StatusMessage = "Tag names cannot contain commas."
    };

    private static string ToCsv(IReadOnlyList<string> tags) =>
        string.Join(',', tags.Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => t.Trim()));
}
