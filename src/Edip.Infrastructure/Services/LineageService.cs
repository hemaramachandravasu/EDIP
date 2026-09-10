using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class LineageService(ILineageRepository repository) : ILineageService
{
    public Task<IReadOnlyList<LineageNodeDto>> GetUpstreamAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        Guid? workspaceId, int maxDepth = 20, CancellationToken ct = default)
        => repository.GetUpstreamAsync(entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct);

    public Task<IReadOnlyList<LineageNodeDto>> GetDownstreamAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        Guid? workspaceId, int maxDepth = 20, CancellationToken ct = default)
        => repository.GetDownstreamAsync(entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct);

    public Task<IReadOnlyList<LineageNodeDto>> ImpactAnalysisAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        string changeType = "Dataset", Guid? workspaceId = null, int maxDepth = 20, CancellationToken ct = default)
        => repository.ImpactAnalysisAsync(entityId, datasetCode, datasetVersionId, versionNumber, changeType, workspaceId, maxDepth, ct);

    public Task<VersionLineageResultDto> GetVersionLineageAsync(
        string datasetCode, int? versionNumber = null, Guid? datasetVersionId = null, Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetVersionLineageAsync(datasetCode, versionNumber, datasetVersionId, workspaceId, ct);

    public Task<IReadOnlyList<CircularDependencyDto>> DetectCircularAsync(Guid? workspaceId = null, int maxDepth = 50, CancellationToken ct = default)
        => repository.DetectCircularAsync(workspaceId, maxDepth, ct);

    public Task<AddRelationshipResultDto> AddRelationshipAsync(AddRelationshipRequest request, CancellationToken ct = default)
        => repository.AddRelationshipAsync(request, ct);

    public Task<LineageSyncResultDto> SyncPlatformAsync(int maxBatches = 200, CancellationToken ct = default)
        => repository.SyncPlatformAsync(maxBatches, ct);

    public Task ArchiveHistoryAsync(int retainDays = 365, CancellationToken ct = default)
        => repository.ArchiveHistoryAsync(retainDays, ct);

    public Task<IReadOnlyList<LineageEntityDto>> GetEntitiesAsync(
        Guid? entityId = null, string? entityCode = null, string? entityTypeCode = null, Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetEntitiesAsync(entityId, entityCode, entityTypeCode, workspaceId, ct);

    public Task<IReadOnlyList<LineageConnectedRow>> GetMostConnectedAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default)
        => repository.GetMostConnectedAsync(workspaceId, take, ct);

    public Task<IReadOnlyList<LineageDegreeRow>> GetHighestDependenciesAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default)
        => repository.GetHighestDependenciesAsync(workspaceId, take, ct);

    public Task<IReadOnlyList<LineageDegreeRow>> GetHighestDependentsAsync(Guid? workspaceId = null, int take = 20, CancellationToken ct = default)
        => repository.GetHighestDependentsAsync(workspaceId, take, ct);

    public Task<IReadOnlyList<LineageRelationshipCountRow>> GetRelationshipCountsAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetRelationshipCountsAsync(workspaceId, ct);

    public Task<IReadOnlyList<LineageSourceToDatasetRow>> GetSourceToDatasetCountsAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetSourceToDatasetCountsAsync(workspaceId, ct);

    public Task<IReadOnlyList<LineageDatasetToReportRow>> GetDatasetToReportAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetDatasetToReportAsync(workspaceId, ct);

    public Task<IReadOnlyList<LineageDepthRow>> GetDependencyDepthAsync(Guid? workspaceId = null, int maxDepth = 20, CancellationToken ct = default)
        => repository.GetDependencyDepthAsync(workspaceId, maxDepth, ct);
}
