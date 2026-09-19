namespace Edip.Core.DTOs;

public sealed class DatasetGovernanceDto
{
    public Guid DatasetId { get; set; }
    public string DatasetCode { get; set; } = "";
    public string DatasetName { get; set; } = "";
    public Guid? WorkspaceId { get; set; }
    public string? WorkspaceCode { get; set; }
    public string ClassificationCode { get; set; } = "";
    public string? ClassificationName { get; set; }
    public string GovernanceStatusCode { get; set; } = "";
    public string CertificationStatusCode { get; set; } = "";
    public string? OwnerUserName { get; set; }
    public string? OwnerDisplayName { get; set; }
    public string? StewardUserName { get; set; }
    public string? StewardDisplayName { get; set; }
    public DateTime? ReviewDueUtc { get; set; }
    public DateTime? CertifiedUtc { get; set; }
    public DateTime? CertificationExpiryUtc { get; set; }
    public string? Notes { get; set; }
    public DateTime? CreatedUtc { get; set; }
    public DateTime? ModifiedUtc { get; set; }
}

public sealed class UpsertDatasetGovernanceRequest
{
    public string? ClassificationCode { get; set; }
    public string? GovernanceStatusCode { get; set; }
    public string? OwnerUserName { get; set; }
    public string? StewardUserName { get; set; }
    public DateTime? ReviewDueUtc { get; set; }
    public string? Notes { get; set; }
    public string? ActorUserName { get; set; }
}

public sealed class CertifyDatasetRequest
{
    public string ActorUserName { get; set; } = "";
    public DateTime? CertificationExpiryUtc { get; set; }
    public DateTime? ReviewDueUtc { get; set; }
    public string? Comments { get; set; }
}

public sealed class SubmitReviewRequest
{
    public string ActorUserName { get; set; } = "";
    public DateTime? ReviewDueUtc { get; set; }
    public string? Comments { get; set; }
}

public sealed class CertificationHistoryRow
{
    public long HistoryId { get; set; }
    public string DatasetCode { get; set; } = "";
    public string? PreviousGovStatus { get; set; }
    public string NewGovStatus { get; set; } = "";
    public string? PreviousCertStatus { get; set; }
    public string NewCertStatus { get; set; } = "";
    public string? ActionedByUserName { get; set; }
    public string? ActionedByDisplayName { get; set; }
    public DateTime ActionUtc { get; set; }
    public DateTime? ReviewDueUtc { get; set; }
    public DateTime? CertificationExpiryUtc { get; set; }
    public string? Comments { get; set; }
}

public sealed class AccessRequestDto
{
    public Guid AccessRequestId { get; set; }
    public string DatasetCode { get; set; } = "";
    public string? DatasetName { get; set; }
    public string RequestingUserName { get; set; } = "";
    public string? RequestingDisplayName { get; set; }
    public string AccessLevelCode { get; set; } = "";
    public string BusinessJustification { get; set; } = "";
    public string Status { get; set; } = "";
    public DateTime RequestedUtc { get; set; }
    public string? ReviewerUserName { get; set; }
    public string? ReviewComments { get; set; }
    public DateTime? DecisionUtc { get; set; }
    public Guid? WorkspaceId { get; set; }
    public string? WorkspaceCode { get; set; }
}

public sealed class SubmitAccessRequest
{
    public string DatasetCode { get; set; } = "";
    public string RequestingUserName { get; set; } = "";
    public string AccessLevelCode { get; set; } = "Read";
    public string BusinessJustification { get; set; } = "";
}

public sealed class AccessRequestActionResult
{
    public Guid? AccessRequestId { get; set; }
    public string StatusCode { get; set; } = "";
    public string StatusMessage { get; set; } = "";
    public AccessRequestDto? Request { get; set; }
}

public sealed class ReviewAccessRequest
{
    public string ReviewerUserName { get; set; } = "";
    public string? ReviewComments { get; set; }
    public DateTime? ExpiresUtc { get; set; }
}

public sealed class RevokeAccessRequest
{
    public Guid? AccessRequestId { get; set; }
    public string? DatasetCode { get; set; }
    public string? UserName { get; set; }
    public string? AccessLevelCode { get; set; }
    public string ReviewerUserName { get; set; } = "";
    public string? RevokeReason { get; set; }
}

public sealed class PolicyEvaluationDto
{
    public bool IsAllowed { get; set; }
    public string? EffectiveAccessLevel { get; set; }
    public string Reason { get; set; } = "";
    public string? ClassificationCode { get; set; }
    public bool IsOwner { get; set; }
    public bool IsSteward { get; set; }
    public bool IsWorkspaceMember { get; set; }
    public bool HasGrant { get; set; }
    public bool IsPlatformAdmin { get; set; }
}

public sealed class GovernanceSummaryDto
{
    public int TotalDatasets { get; set; }
    public int CertifiedDatasets { get; set; }
    public int PendingReview { get; set; }
    public int ExpiredCertifications { get; set; }
    public int PendingAccessRequests { get; set; }
    public int ApprovedAccessRequests { get; set; }
    public int RejectedAccessRequests { get; set; }
}

public sealed class ClassificationCountRow
{
    public string ClassificationCode { get; set; } = "";
    public string? ClassificationName { get; set; }
    public int DatasetCount { get; set; }
}

public sealed class GovernanceStatusCountRow
{
    public string GovernanceStatusCode { get; set; } = "";
    public string? GovernanceStatusName { get; set; }
    public int DatasetCount { get; set; }
}

public sealed class AccessRequestsByWorkspaceRow
{
    public string WorkspaceCode { get; set; } = "";
    public string WorkspaceName { get; set; } = "";
    public int PendingCount { get; set; }
    public int ApprovedCount { get; set; }
    public int RejectedCount { get; set; }
    public int RevokedCount { get; set; }
    public int TotalRequests { get; set; }
}

public sealed class GovernanceAuditRow
{
    public long AuditEventId { get; set; }
    public string EventType { get; set; } = "";
    public string? DatasetCode { get; set; }
    public string? SubjectUserName { get; set; }
    public string? ActorUserName { get; set; }
    public Guid? WorkspaceId { get; set; }
    public Guid? AccessRequestId { get; set; }
    public string? DetailsJson { get; set; }
    public DateTime EventUtc { get; set; }
}
