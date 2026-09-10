using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class LineageRepository(ISqlConnectionFactory connectionFactory) : ILineageRepository
{
    private const int CommandTimeoutSeconds = 120;

    public Task<IReadOnlyList<LineageNodeDto>> GetUpstreamAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        Guid? workspaceId, int maxDepth, CancellationToken ct = default)
        => QueryLineageNodesAsync("lineage.usp_GetUpstreamLineage", entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct);

    public Task<IReadOnlyList<LineageNodeDto>> GetDownstreamAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        Guid? workspaceId, int maxDepth, CancellationToken ct = default)
        => QueryLineageNodesAsync("lineage.usp_GetDownstreamLineage", entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth, ct);

    public async Task<IReadOnlyList<LineageNodeDto>> ImpactAnalysisAsync(
        Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        string changeType, Guid? workspaceId, int maxDepth, CancellationToken ct = default)
    {
        var list = new List<LineageNodeDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_ImpactAnalysis");
        AddTraversalParams(cmd, entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth);
        cmd.Parameters.AddWithValue("@ChangeType", changeType);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapNode(reader));
        return list;
    }

    public async Task<VersionLineageResultDto> GetVersionLineageAsync(
        string datasetCode, int? versionNumber, Guid? datasetVersionId, Guid? workspaceId, CancellationToken ct = default)
    {
        var result = new VersionLineageResultDto();
        var versions = new List<DatasetVersionDto>();
        var edges = new List<VersionLineageEdgeDto>();

        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_GetVersionLineage");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@VersionNumber", versionNumber);
        cmd.Parameters.AddNullable("@DatasetVersionId", datasetVersionId);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);

        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            versions.Add(new DatasetVersionDto
            {
                DatasetVersionId = reader.GetGuid("DatasetVersionId"),
                DatasetCode = reader.GetString("DatasetCode"),
                DatasetName = reader.GetString("DatasetName"),
                VersionNumber = reader.GetInt32("VersionNumber"),
                EntityId = reader.GetGuid("EntityId"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                ImportBatchId = reader.GetNullableGuid("ImportBatchId"),
                ImportId = reader.GetNullableGuid("ImportId"),
                EtlRunId = reader.GetNullableGuid("EtlRunId"),
                ProfileRunId = reader.GetNullableGuid("ProfileRunId"),
                DataSourceId = reader.GetNullableGuid("DataSourceId"),
                DataSourceCode = reader.GetNullableString("DataSourceCode"),
                ProducedUtc = reader.GetDateTime("ProducedUtc"),
                ProducedBy = reader.GetString("ProducedBy"),
                Notes = reader.GetNullableString("Notes")
            });
        }

        if (await reader.NextResultAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                edges.Add(new VersionLineageEdgeDto
                {
                    EntityId = reader.GetGuid("EntityId"),
                    EntityTypeCode = reader.GetString("EntityTypeCode"),
                    EntityCode = reader.GetString("EntityCode"),
                    EntityName = reader.GetString("EntityName"),
                    RelationshipType = reader.GetString("RelationshipType"),
                    Direction = reader.GetString("Direction"),
                    VersionNumber = reader.GetNullableInt32("VersionNumber"),
                    WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                    ProcessType = reader.GetNullableString("ProcessType"),
                    ProcessReference = reader.GetNullableString("ProcessReference"),
                    SubjectVersionNumber = reader.GetInt32("SubjectVersionNumber")
                });
            }
        }

        result.Versions = versions;
        result.Edges = edges;
        return result;
    }

    public async Task<IReadOnlyList<CircularDependencyDto>> DetectCircularAsync(Guid? workspaceId, int maxDepth, CancellationToken ct = default)
    {
        var list = new List<CircularDependencyDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_DetectCircularDependencies");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@MaxDepth", maxDepth);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new CircularDependencyDto
            {
                CycleStartEntityId = reader.GetGuid("CycleStartEntityId"),
                CycleStartType = reader.GetString("CycleStartType"),
                CycleStartCode = reader.GetString("CycleStartCode"),
                CycleStartName = reader.GetString("CycleStartName"),
                CycleLength = reader.GetInt32("CycleLength"),
                CyclePath = reader.GetString("CyclePath"),
                FirstRelationshipId = reader.GetNullableGuid("FirstRelationshipId")
            });
        }
        return list;
    }

    public async Task<AddRelationshipResultDto> AddRelationshipAsync(AddRelationshipRequest request, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_AddRelationship");
        cmd.Parameters.AddWithValue("@SourceEntityId", request.SourceEntityId);
        cmd.Parameters.AddWithValue("@TargetEntityId", request.TargetEntityId);
        cmd.Parameters.AddWithValue("@RelationshipType", request.RelationshipType);
        cmd.Parameters.AddNullable("@WorkspaceId", request.WorkspaceId);
        cmd.Parameters.AddNullable("@SourceVersionId", request.SourceVersionId);
        cmd.Parameters.AddNullable("@TargetVersionId", request.TargetVersionId);
        cmd.Parameters.AddNullable("@ProcessReference", request.ProcessReference);
        cmd.Parameters.AddNullable("@ProcessType", request.ProcessType);
        cmd.Parameters.AddWithValue("@CreatedBy", request.CreatedBy);
        cmd.Parameters.AddWithValue("@PreventCycles", request.PreventCycles);
        var relParam = new SqlParameter("@RelationshipId", SqlDbType.UniqueIdentifier) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };
        var codeParam = new SqlParameter("@StatusCode", SqlDbType.NVarChar, 32) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };
        var msgParam = new SqlParameter("@StatusMessage", SqlDbType.NVarChar, 500) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };
        cmd.Parameters.Add(relParam);
        cmd.Parameters.Add(codeParam);
        cmd.Parameters.Add(msgParam);
        await cmd.ExecuteNonQueryAsync(ct);

        return new AddRelationshipResultDto
        {
            RelationshipId = relParam.Value is Guid g ? g : null,
            StatusCode = codeParam.Value as string ?? "",
            StatusMessage = msgParam.Value as string ?? ""
        };
    }

    public async Task<LineageSyncResultDto> SyncPlatformAsync(int maxBatches, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_SyncPlatformLineage");
        cmd.Parameters.AddWithValue("@CreatedBy", "api");
        cmd.Parameters.AddWithValue("@MaxBatches", maxBatches);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return new LineageSyncResultDto { Status = "Unknown" };
        return new LineageSyncResultDto
        {
            CaptureLogId = reader.GetInt64("CaptureLogId"),
            RelationshipsAdded = reader.GetInt32("RelationshipsAdded"),
            EntitiesAdded = reader.GetInt32("EntitiesAdded"),
            Status = reader.GetString("Status")
        };
    }

    public async Task ArchiveHistoryAsync(int retainDays, CancellationToken ct = default)
    {
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_ArchiveLineageHistory");
        cmd.Parameters.AddWithValue("@RetainDays", retainDays);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public async Task<IReadOnlyList<LineageEntityDto>> GetEntitiesAsync(
        Guid? entityId, string? entityCode, string? entityTypeCode, Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<LineageEntityDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "lineage.usp_GetEntity");
        cmd.Parameters.AddNullable("@EntityId", entityId);
        cmd.Parameters.AddNullable("@EntityCode", entityCode);
        cmd.Parameters.AddNullable("@EntityTypeCode", entityTypeCode);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageEntityDto
            {
                EntityId = reader.GetGuid("EntityId"),
                EntityTypeCode = reader.GetString("EntityTypeCode"),
                EntityCode = reader.GetString("EntityCode"),
                EntityName = reader.GetString("EntityName"),
                ExternalKey = reader.GetNullableGuid("ExternalKey"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                DatasetId = reader.GetNullableGuid("DatasetId"),
                VersionNumber = reader.GetNullableInt32("VersionNumber"),
                IsActive = reader.GetBoolean("IsActive"),
                CreatedUtc = reader.GetDateTime("CreatedUtc"),
                ModifiedUtc = reader.GetDateTime("ModifiedUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<LineageConnectedRow>> GetMostConnectedAsync(Guid? workspaceId, int take, CancellationToken ct = default)
    {
        var list = new List<LineageConnectedRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "rpt.usp_LineageMostConnected");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageConnectedRow
            {
                EntityId = reader.GetGuid("EntityId"),
                EntityTypeCode = reader.GetString("EntityTypeCode"),
                EntityCode = reader.GetString("EntityCode"),
                EntityName = reader.GetString("EntityName"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                VersionNumber = reader.GetNullableInt32("VersionNumber"),
                ConnectionCount = reader.GetInt32("ConnectionCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<LineageDegreeRow>> GetHighestDependenciesAsync(Guid? workspaceId, int take, CancellationToken ct = default)
        => await QueryDegreeAsync("rpt.usp_LineageHighestDependencies", "DependencyCount", workspaceId, take, ct);

    public async Task<IReadOnlyList<LineageDegreeRow>> GetHighestDependentsAsync(Guid? workspaceId, int take, CancellationToken ct = default)
        => await QueryDegreeAsync("rpt.usp_LineageHighestDependents", "DependentCount", workspaceId, take, ct);

    public async Task<IReadOnlyList<LineageRelationshipCountRow>> GetRelationshipCountsAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<LineageRelationshipCountRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "rpt.usp_LineageRelationshipCounts");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageRelationshipCountRow
            {
                RelationshipType = reader.GetString("RelationshipType"),
                ProcessType = reader.GetNullableString("ProcessType"),
                RelationshipCount = reader.GetInt32("RelationshipCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<LineageSourceToDatasetRow>> GetSourceToDatasetCountsAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<LineageSourceToDatasetRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "rpt.usp_LineageSourceToDatasetCounts");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageSourceToDatasetRow
            {
                SourceCode = reader.GetString("SourceCode"),
                SourceName = reader.GetString("SourceName"),
                DatasetCode = reader.GetString("DatasetCode"),
                DatasetName = reader.GetString("DatasetName"),
                PathCount = reader.GetInt32("PathCount")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<LineageDatasetToReportRow>> GetDatasetToReportAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        var list = new List<LineageDatasetToReportRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "rpt.usp_LineageDatasetToReport");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageDatasetToReportRow
            {
                DatasetCode = reader.GetString("DatasetCode"),
                DatasetName = reader.GetString("DatasetName"),
                AssetType = reader.GetString("AssetType"),
                AssetCode = reader.GetString("AssetCode"),
                AssetName = reader.GetString("AssetName"),
                RelationshipType = reader.GetString("RelationshipType"),
                CreatedUtc = reader.GetDateTime("CreatedUtc")
            });
        }
        return list;
    }

    public async Task<IReadOnlyList<LineageDepthRow>> GetDependencyDepthAsync(Guid? workspaceId, int maxDepth, CancellationToken ct = default)
    {
        var list = new List<LineageDepthRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, "rpt.usp_LineageDependencyDepth");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@MaxDepth", maxDepth);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageDepthRow
            {
                DatasetCode = reader.GetString("DatasetCode"),
                DatasetName = reader.GetString("DatasetName"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                MaxDownstreamDepth = reader.GetInt32("MaxDownstreamDepth"),
                DownstreamEntityCount = reader.GetInt32("DownstreamEntityCount")
            });
        }
        return list;
    }

    private async Task<IReadOnlyList<LineageNodeDto>> QueryLineageNodesAsync(
        string proc, Guid? entityId, string? datasetCode, Guid? datasetVersionId, int? versionNumber,
        Guid? workspaceId, int maxDepth, CancellationToken ct)
    {
        var list = new List<LineageNodeDto>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, proc);
        AddTraversalParams(cmd, entityId, datasetCode, datasetVersionId, versionNumber, workspaceId, maxDepth);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(MapNode(reader));
        return list;
    }

    private async Task<IReadOnlyList<LineageDegreeRow>> QueryDegreeAsync(
        string proc, string countColumn, Guid? workspaceId, int take, CancellationToken ct)
    {
        var list = new List<LineageDegreeRow>();
        await using var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        await using var cmd = CreateProc(conn, proc);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@Take", take);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            list.Add(new LineageDegreeRow
            {
                EntityId = reader.GetGuid("EntityId"),
                EntityTypeCode = reader.GetString("EntityTypeCode"),
                EntityCode = reader.GetString("EntityCode"),
                EntityName = reader.GetString("EntityName"),
                WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
                Count = reader.GetInt32(countColumn)
            });
        }
        return list;
    }

    private static SqlCommand CreateProc(SqlConnection conn, string name) =>
        new(name, conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = CommandTimeoutSeconds };

    private static void AddTraversalParams(
        SqlCommand cmd, Guid? entityId, string? datasetCode, Guid? datasetVersionId,
        int? versionNumber, Guid? workspaceId, int maxDepth)
    {
        cmd.Parameters.AddNullable("@EntityId", entityId);
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@DatasetVersionId", datasetVersionId);
        cmd.Parameters.AddNullable("@VersionNumber", versionNumber);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@MaxDepth", maxDepth);
    }

    private static LineageNodeDto MapNode(SqlDataReader reader) => new()
    {
        EntityId = reader.GetGuid("EntityId"),
        EntityTypeCode = reader.GetString("EntityTypeCode"),
        EntityCode = reader.GetString("EntityCode"),
        EntityName = reader.GetString("EntityName"),
        RelationshipType = reader.GetNullableString("RelationshipType"),
        Depth = reader.GetInt32("Depth"),
        VersionNumber = reader.GetNullableInt32("VersionNumber"),
        WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
        RelationshipId = reader.GetNullableGuid("RelationshipId"),
        ViaEntityId = reader.GetNullableGuid("ViaEntityId")
    };
}
