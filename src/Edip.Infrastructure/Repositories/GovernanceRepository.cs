using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class GovernanceRepository(ISqlConnectionFactory connectionFactory) : IGovernanceRepository
{
    private const int Timeout = 120;

    public async Task<DatasetGovernanceDto> UpsertAsync(string datasetCode, UpsertDatasetGovernanceRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_UpsertDatasetGovernance");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@ClassificationCode", request.ClassificationCode);
        cmd.Parameters.AddNullable("@GovernanceStatusCode", request.GovernanceStatusCode);
        cmd.Parameters.AddNullable("@OwnerUserName", request.OwnerUserName);
        cmd.Parameters.AddNullable("@StewardUserName", request.StewardUserName);
        cmd.Parameters.AddNullable("@ReviewDueUtc", request.ReviewDueUtc);
        cmd.Parameters.AddNullable("@Notes", request.Notes);
        cmd.Parameters.AddNullable("@ActorUserName", request.ActorUserName);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            throw new InvalidOperationException("Upsert returned no governance row.");
        return MapGovernance(reader, includeNames: false);
    }

    public async Task<IReadOnlyList<DatasetGovernanceDto>> GetAsync(string? datasetCode, Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<DatasetGovernanceDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_GetDatasetGovernance");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapGovernance(reader, includeNames: true));
        return list;
    }

    public async Task<DatasetGovernanceDto> CertifyAsync(string datasetCode, CertifyDatasetRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_CertifyDataset");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@ActorUserName", request.ActorUserName);
        cmd.Parameters.AddNullable("@CertificationExpiryUtc", request.CertificationExpiryUtc);
        cmd.Parameters.AddNullable("@ReviewDueUtc", request.ReviewDueUtc);
        cmd.Parameters.AddNullable("@Comments", request.Comments);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            throw new InvalidOperationException("Certify returned no row.");
        return MapGovernance(reader, includeNames: true);
    }

    public async Task<DatasetGovernanceDto> SubmitForReviewAsync(string datasetCode, SubmitReviewRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_SubmitForReview");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@ActorUserName", request.ActorUserName);
        cmd.Parameters.AddNullable("@ReviewDueUtc", request.ReviewDueUtc);
        cmd.Parameters.AddNullable("@Comments", request.Comments);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            throw new InvalidOperationException("SubmitForReview returned no row.");
        return MapGovernance(reader, includeNames: true);
    }

    public async Task<IReadOnlyList<CertificationHistoryRow>> GetCertificationHistoryAsync(string datasetCode, CancellationToken ct = default)
    {
        var list = new List<CertificationHistoryRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_GetCertificationHistory");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new CertificationHistoryRow
            {
                HistoryId = reader.GetInt64("HistoryId"),
                DatasetCode = reader.GetString("DatasetCode"),
                PreviousGovStatus = reader.GetNullableString("PreviousGovStatus"),
                NewGovStatus = reader.GetString("NewGovStatus"),
                PreviousCertStatus = reader.GetNullableString("PreviousCertStatus"),
                NewCertStatus = reader.GetString("NewCertStatus"),
                ActionedByUserName = reader.GetNullableString("ActionedByUserName"),
                ActionedByDisplayName = reader.GetNullableString("ActionedByDisplayName"),
                ActionUtc = reader.GetDateTime("ActionUtc"),
                ReviewDueUtc = reader.GetNullableDateTime("ReviewDueUtc"),
                CertificationExpiryUtc = reader.GetNullableDateTime("CertificationExpiryUtc"),
                Comments = reader.GetNullableString("Comments")
            });
        }
        return list;
    }

    public async Task<AccessRequestActionResult> SubmitAccessRequestAsync(SubmitAccessRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_SubmitAccessRequest");
        cmd.Parameters.AddWithValue("@DatasetCode", request.DatasetCode);
        cmd.Parameters.AddWithValue("@RequestingUserName", request.RequestingUserName);
        cmd.Parameters.AddWithValue("@AccessLevelCode", request.AccessLevelCode);
        cmd.Parameters.AddWithValue("@BusinessJustification", request.BusinessJustification);
        var idParam = OutGuid("@AccessRequestId");
        var codeParam = OutNVarChar("@StatusCode", 32);
        var msgParam = OutNVarChar("@StatusMessage", 500);
        cmd.Parameters.Add(idParam);
        cmd.Parameters.Add(codeParam);
        cmd.Parameters.Add(msgParam);

        AccessRequestDto? dto = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
                dto = MapAccessRequest(reader, pendingShape: false);
        }

        return new AccessRequestActionResult
        {
            AccessRequestId = idParam.Value is Guid g ? g : dto?.AccessRequestId,
            StatusCode = codeParam.Value as string ?? "",
            StatusMessage = msgParam.Value as string ?? "",
            Request = dto
        };
    }

    public async Task<AccessRequestActionResult> ApproveAccessRequestAsync(Guid accessRequestId, ReviewAccessRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_ApproveAccessRequest");
        cmd.Parameters.AddWithValue("@AccessRequestId", accessRequestId);
        cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName);
        cmd.Parameters.AddNullable("@ReviewComments", request.ReviewComments);
        cmd.Parameters.AddNullable("@ExpiresUtc", request.ExpiresUtc);
        var codeParam = OutNVarChar("@StatusCode", 32);
        var msgParam = OutNVarChar("@StatusMessage", 500);
        cmd.Parameters.Add(codeParam);
        cmd.Parameters.Add(msgParam);
        await cmd.ExecuteNonQueryAsync(ct);
        return new AccessRequestActionResult
        {
            AccessRequestId = accessRequestId,
            StatusCode = codeParam.Value as string ?? "",
            StatusMessage = msgParam.Value as string ?? ""
        };
    }

    public async Task<AccessRequestActionResult> RejectAccessRequestAsync(Guid accessRequestId, ReviewAccessRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_RejectAccessRequest");
        cmd.Parameters.AddWithValue("@AccessRequestId", accessRequestId);
        cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName);
        cmd.Parameters.AddNullable("@ReviewComments", request.ReviewComments);
        var codeParam = OutNVarChar("@StatusCode", 32);
        var msgParam = OutNVarChar("@StatusMessage", 500);
        cmd.Parameters.Add(codeParam);
        cmd.Parameters.Add(msgParam);
        await cmd.ExecuteNonQueryAsync(ct);
        return new AccessRequestActionResult
        {
            AccessRequestId = accessRequestId,
            StatusCode = codeParam.Value as string ?? "",
            StatusMessage = msgParam.Value as string ?? ""
        };
    }

    public async Task<AccessRequestActionResult> RevokeAccessAsync(RevokeAccessRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_RevokeAccess");
        cmd.Parameters.AddNullable("@AccessRequestId", request.AccessRequestId);
        cmd.Parameters.AddNullable("@DatasetCode", request.DatasetCode);
        cmd.Parameters.AddNullable("@UserName", request.UserName);
        cmd.Parameters.AddNullable("@AccessLevelCode", request.AccessLevelCode);
        cmd.Parameters.AddWithValue("@ReviewerUserName", request.ReviewerUserName);
        cmd.Parameters.AddNullable("@RevokeReason", request.RevokeReason);
        var codeParam = OutNVarChar("@StatusCode", 32);
        var msgParam = OutNVarChar("@StatusMessage", 500);
        cmd.Parameters.Add(codeParam);
        cmd.Parameters.Add(msgParam);
        await cmd.ExecuteNonQueryAsync(ct);
        return new AccessRequestActionResult
        {
            AccessRequestId = request.AccessRequestId,
            StatusCode = codeParam.Value as string ?? "",
            StatusMessage = msgParam.Value as string ?? ""
        };
    }

    public async Task<IReadOnlyList<AccessRequestDto>> GetPendingAccessRequestsAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
    {
        var list = new List<AccessRequestDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_GetPendingAccessRequests");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapAccessRequest(reader, pendingShape: true));
        return list;
    }

    public async Task<IReadOnlyList<AccessRequestDto>> GetAccessRequestHistoryAsync(
        string? datasetCode, string? userName, Guid? workspaceId, int take, CancellationToken ct = default)
    {
        var list = new List<AccessRequestDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_GetAccessRequestHistory");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@UserName", userName);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapAccessRequest(reader, pendingShape: false));
        return list;
    }

    public async Task<PolicyEvaluationDto> EvaluateAccessAsync(
        string datasetCode, string userName, string requiredAccessLevel, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_EvaluateDatasetAccess");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddWithValue("@RequiredAccessLevel", requiredAccessLevel);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return new PolicyEvaluationDto { IsAllowed = false, Reason = "No result" };
        return new PolicyEvaluationDto
        {
            IsAllowed = reader.GetBoolean("IsAllowed"),
            EffectiveAccessLevel = reader.GetNullableString("EffectiveAccessLevel"),
            Reason = reader.GetString("Reason"),
            ClassificationCode = reader.GetNullableString("ClassificationCode"),
            IsOwner = reader.GetBoolean("IsOwner"),
            IsSteward = reader.GetBoolean("IsSteward"),
            IsWorkspaceMember = reader.GetBoolean("IsWorkspaceMember"),
            HasGrant = reader.GetBoolean("HasGrant"),
            IsPlatformAdmin = reader.GetBoolean("IsPlatformAdmin")
        };
    }

    public async Task<GovernanceSummaryDto> GetSummaryAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_GovernanceSummary");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return new GovernanceSummaryDto();
        return new GovernanceSummaryDto
        {
            TotalDatasets = reader.GetInt32("TotalDatasets"),
            CertifiedDatasets = reader.GetInt32("CertifiedDatasets"),
            PendingReview = reader.GetInt32("PendingReview"),
            ExpiredCertifications = reader.GetInt32("ExpiredCertifications"),
            PendingAccessRequests = reader.GetInt32("PendingAccessRequests"),
            ApprovedAccessRequests = reader.GetInt32("ApprovedAccessRequests"),
            RejectedAccessRequests = reader.GetInt32("RejectedAccessRequests")
        };
    }

    public async Task<IReadOnlyList<ClassificationCountRow>> GetByClassificationAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<ClassificationCountRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_DatasetsByClassification");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new ClassificationCountRow
            {
                ClassificationCode = reader.GetString("ClassificationCode"),
                ClassificationName = reader.GetNullableString("ClassificationName"),
                DatasetCount = reader.GetInt32("DatasetCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<GovernanceStatusCountRow>> GetStatusDistributionAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<GovernanceStatusCountRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_GovernanceStatusDistribution");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new GovernanceStatusCountRow
            {
                GovernanceStatusCode = reader.GetString("GovernanceStatusCode"),
                GovernanceStatusName = reader.GetNullableString("GovernanceStatusName"),
                DatasetCount = reader.GetInt32("DatasetCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<AccessRequestsByWorkspaceRow>> GetAccessRequestsByWorkspaceAsync(CancellationToken ct = default)
    {
        var list = new List<AccessRequestsByWorkspaceRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_AccessRequestsByWorkspace");
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new AccessRequestsByWorkspaceRow
            {
                WorkspaceCode = reader.GetString("WorkspaceCode"),
                WorkspaceName = reader.GetString("WorkspaceName"),
                PendingCount = reader.GetInt32("PendingCount"),
                ApprovedCount = reader.GetInt32("ApprovedCount"),
                RejectedCount = reader.GetInt32("RejectedCount"),
                RevokedCount = reader.GetInt32("RevokedCount"),
                TotalRequests = reader.GetInt32("TotalRequests")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<GovernanceAuditRow>> GetAuditEventsAsync(string? datasetCode, string? eventType, int take, CancellationToken ct = default)
    {
        var list = new List<GovernanceAuditRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_GetAuditEvents");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@EventType", eventType);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new GovernanceAuditRow
            {
                AuditEventId = reader.GetInt64("AuditEventId"),
                EventType = reader.GetString("EventType"),
                DatasetCode = reader.GetNullableString("DatasetCode"),
                SubjectUserName = reader.GetNullableString("SubjectUserName"),
                ActorUserName = reader.GetNullableString("ActorUserName"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                AccessRequestId = reader.GetNullableGuid("AccessRequestId"),
                DetailsJson = reader.GetNullableString("DetailsJson"),
                EventUtc = reader.GetDateTime("EventUtc")
            });
        }
        return list;
    }

    public async Task<int> ExpireCertificationsAsync(CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_ExpireDatasetCertifications");
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return 0;
        return reader.GetInt32("ExpiredCount");
    }

    public async Task ArchiveAuditAsync(int retainDays, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = Proc(conn, "gov.usp_ArchiveGovernanceAudit");
        cmd.Parameters.AddWithValue("@RetainDays", retainDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    private static SqlCommand Proc(SqlConnection conn, string name) =>
        new(name, conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = Timeout };

    private static SqlParameter OutGuid(string name) =>
        new(name, SqlDbType.UniqueIdentifier) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };

    private static SqlParameter OutNVarChar(string name, int size) =>
        new(name, SqlDbType.NVarChar, size) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };

    private static DatasetGovernanceDto MapGovernance(SqlDataReader reader, bool includeNames) => new()
    {
        DatasetId = reader.GetGuid("DatasetId"),
        DatasetCode = reader.GetString("DatasetCode"),
        DatasetName = reader.GetString("DatasetName"),
        WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = includeNames ? reader.GetNullableString("WorkspaceCode") : null,
        ClassificationCode = reader.GetString("ClassificationCode"),
        ClassificationName = includeNames ? reader.GetNullableString("ClassificationName") : null,
        GovernanceStatusCode = reader.GetString("GovernanceStatusCode"),
        CertificationStatusCode = reader.GetString("CertificationStatusCode"),
        OwnerUserName = reader.GetNullableString("OwnerUserName"),
        OwnerDisplayName = includeNames ? reader.GetNullableString("OwnerDisplayName") : null,
        StewardUserName = reader.GetNullableString("StewardUserName"),
        StewardDisplayName = includeNames ? reader.GetNullableString("StewardDisplayName") : null,
        ReviewDueUtc = reader.GetNullableDateTime("ReviewDueUtc"),
        CertifiedUtc = reader.GetNullableDateTime("CertifiedUtc"),
        CertificationExpiryUtc = reader.GetNullableDateTime("CertificationExpiryUtc"),
        Notes = reader.GetNullableString("Notes"),
        CreatedUtc = HasColumn(reader, "CreatedUtc") ? reader.GetNullableDateTime("CreatedUtc") : null,
        ModifiedUtc = HasColumn(reader, "ModifiedUtc") ? reader.GetNullableDateTime("ModifiedUtc") : null
    };

    private static AccessRequestDto MapAccessRequest(SqlDataReader reader, bool pendingShape) => new()
    {
        AccessRequestId = reader.GetGuid("AccessRequestId"),
        DatasetCode = reader.GetString("DatasetCode"),
        DatasetName = HasColumn(reader, "DatasetName") ? reader.GetNullableString("DatasetName") : null,
        RequestingUserName = reader.GetString("RequestingUserName"),
        RequestingDisplayName = HasColumn(reader, "RequestingDisplayName") ? reader.GetNullableString("RequestingDisplayName") : null,
        AccessLevelCode = reader.GetString("AccessLevelCode"),
        BusinessJustification = reader.GetString("BusinessJustification"),
        Status = reader.GetString("Status"),
        RequestedUtc = reader.GetDateTime("RequestedUtc"),
        ReviewerUserName = HasColumn(reader, "ReviewerUserName") ? reader.GetNullableString("ReviewerUserName") : null,
        ReviewComments = HasColumn(reader, "ReviewComments") ? reader.GetNullableString("ReviewComments") : null,
        DecisionUtc = HasColumn(reader, "DecisionUtc") ? reader.GetNullableDateTime("DecisionUtc") : null,
        WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = HasColumn(reader, "WorkspaceCode") ? reader.GetNullableString("WorkspaceCode") : null
    };

    private static bool HasColumn(SqlDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }
}
