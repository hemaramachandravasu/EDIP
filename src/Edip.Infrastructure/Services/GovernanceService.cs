using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class GovernanceService(IGovernanceRepository repository) : IGovernanceService
{
    public Task<DatasetGovernanceDto> UpsertAsync(string datasetCode, UpsertDatasetGovernanceRequest request, CancellationToken ct = default)
        => repository.UpsertAsync(datasetCode, request, ct);

    public Task<IReadOnlyList<DatasetGovernanceDto>> GetAsync(string? datasetCode = null, Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetAsync(datasetCode, workspaceId, ct);

    public Task<DatasetGovernanceDto> CertifyAsync(string datasetCode, CertifyDatasetRequest request, CancellationToken ct = default)
        => repository.CertifyAsync(datasetCode, request, ct);

    public Task<DatasetGovernanceDto> SubmitForReviewAsync(string datasetCode, SubmitReviewRequest request, CancellationToken ct = default)
        => repository.SubmitForReviewAsync(datasetCode, request, ct);

    public Task<IReadOnlyList<CertificationHistoryRow>> GetCertificationHistoryAsync(string datasetCode, CancellationToken ct = default)
        => repository.GetCertificationHistoryAsync(datasetCode, ct);

    public Task<AccessRequestActionResult> SubmitAccessRequestAsync(SubmitAccessRequest request, CancellationToken ct = default)
        => repository.SubmitAccessRequestAsync(request, ct);

    public Task<AccessRequestActionResult> ApproveAccessRequestAsync(Guid accessRequestId, ReviewAccessRequest request, CancellationToken ct = default)
        => repository.ApproveAccessRequestAsync(accessRequestId, request, ct);

    public Task<AccessRequestActionResult> RejectAccessRequestAsync(Guid accessRequestId, ReviewAccessRequest request, CancellationToken ct = default)
        => repository.RejectAccessRequestAsync(accessRequestId, request, ct);

    public Task<AccessRequestActionResult> RevokeAccessAsync(RevokeAccessRequest request, CancellationToken ct = default)
        => repository.RevokeAccessAsync(request, ct);

    public Task<IReadOnlyList<AccessRequestDto>> GetPendingAccessRequestsAsync(Guid? workspaceId = null, string? datasetCode = null, CancellationToken ct = default)
        => repository.GetPendingAccessRequestsAsync(workspaceId, datasetCode, ct);

    public Task<IReadOnlyList<AccessRequestDto>> GetAccessRequestHistoryAsync(
        string? datasetCode = null, string? userName = null, Guid? workspaceId = null, int take = 100, CancellationToken ct = default)
        => repository.GetAccessRequestHistoryAsync(datasetCode, userName, workspaceId, take, ct);

    public Task<PolicyEvaluationDto> EvaluateAccessAsync(
        string datasetCode, string userName, string requiredAccessLevel = "Read", CancellationToken ct = default)
        => repository.EvaluateAccessAsync(datasetCode, userName, requiredAccessLevel, ct);

    public Task<GovernanceSummaryDto> GetSummaryAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetSummaryAsync(workspaceId, ct);

    public Task<IReadOnlyList<ClassificationCountRow>> GetByClassificationAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetByClassificationAsync(workspaceId, ct);

    public Task<IReadOnlyList<GovernanceStatusCountRow>> GetStatusDistributionAsync(Guid? workspaceId = null, CancellationToken ct = default)
        => repository.GetStatusDistributionAsync(workspaceId, ct);

    public Task<IReadOnlyList<AccessRequestsByWorkspaceRow>> GetAccessRequestsByWorkspaceAsync(CancellationToken ct = default)
        => repository.GetAccessRequestsByWorkspaceAsync(ct);

    public Task<IReadOnlyList<GovernanceAuditRow>> GetAuditEventsAsync(
        string? datasetCode = null, string? eventType = null, int take = 100, CancellationToken ct = default)
        => repository.GetAuditEventsAsync(datasetCode, eventType, take, ct);

    public Task<int> ExpireCertificationsAsync(CancellationToken ct = default)
        => repository.ExpireCertificationsAsync(ct);

    public Task ArchiveAuditAsync(int retainDays = 730, CancellationToken ct = default)
        => repository.ArchiveAuditAsync(retainDays, ct);
}
