using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class CatalogRepository(ISqlConnectionFactory connectionFactory) : ICatalogRepository
{
    private const int Timeout = 60;

    // ---------------- Search ----------------

    public async Task<CatalogSearchResult> SearchAsync(CatalogSearchQuery query, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "cat.usp_SearchCatalog");
        var p = cmd.Parameters;
        p.AddWithValue("@UserName", query.UserName);
        p.AddNullable("@SearchText", query.SearchText);
        p.AddNullable("@WorkspaceCode", query.WorkspaceCode);
        p.AddNullable("@Category", query.Category);
        p.AddNullable("@ClassificationCode", query.ClassificationCode);
        p.AddNullable("@GovernanceStatusCode", query.GovernanceStatusCode);
        p.AddNullable("@DatasetStatus", query.DatasetStatus);
        p.AddNullable("@CertificationStatusCode", query.CertificationStatusCode);
        p.AddNullable("@OwnerUserName", query.OwnerUserName);
        p.AddNullable("@StewardUserName", query.StewardUserName);
        p.AddNullable("@SourceTypeCode", query.SourceTypeCode);
        p.Add(Score("@MinQualityScore", query.MinQualityScore));
        p.Add(Score("@MaxQualityScore", query.MaxQualityScore));
        p.Add(Date("@CreatedFrom", query.CreatedFrom));
        p.Add(Date("@CreatedTo", query.CreatedTo));
        p.Add(Date("@UpdatedFrom", query.UpdatedFrom));
        p.Add(Date("@UpdatedTo", query.UpdatedTo));
        p.AddNullable("@Tags", query.Tags);
        p.AddWithValue("@TagMatch", query.TagMatch);
        p.AddWithValue("@IncludeInactive", query.IncludeInactive);
        p.AddNullable("@SortBy", query.SortBy);
        p.AddNullable("@SortDirection", query.SortDirection);
        p.AddWithValue("@PageNumber", query.PageNumber);
        p.AddWithValue("@PageSize", query.PageSize);
        p.AddNullable("@AfterValue", query.AfterValue);
        p.AddNullable("@AfterDatasetId", query.AfterDatasetId);
        p.AddWithValue("@IncludeTotalCount", query.IncludeTotalCount);

        var total = p.Add(Out("@TotalCount", SqlDbType.Int));
        var hasMore = p.Add(Out("@HasMore", SqlDbType.Bit));
        var nextValue = p.Add(Out("@NextAfterValue", SqlDbType.NVarChar, 200));
        var nextId = p.Add(Out("@NextAfterDatasetId", SqlDbType.UniqueIdentifier));
        var sortBy = p.Add(Out("@AppliedSortBy", SqlDbType.NVarChar, 32));
        var sortDir = p.Add(Out("@AppliedSortDirection", SqlDbType.NVarChar, 4));
        var (code, msg) = AddStatus(cmd);

        // One result set, only produced when StatusCode = 'OK'.
        var items = new List<CatalogDatasetDto>();
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
                items.Add(MapDataset(reader));
        }

        // Output parameters are only populated once the reader is closed.
        return new CatalogSearchResult
        {
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Items = items,
            PageNumber = query.AfterDatasetId is null ? query.PageNumber : null,
            PageSize = query.PageSize,
            TotalCount = total.Value is int t ? t : null,
            HasMore = hasMore.Value is bool b && b,
            NextAfterValue = nextValue.Value as string,
            NextAfterDatasetId = nextId.Value is Guid g ? g : null,
            SortBy = sortBy.Value as string,
            SortDirection = sortDir.Value as string
        };
    }

    // ---------------- Detail ----------------

    public async Task<CatalogDetailResult> GetDatasetDetailAsync(string datasetCode, string userName, int recentImportCount,
        int lineageNeighborLimit, bool includeHistory, int historyCount, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "cat.usp_GetDatasetDetail");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddWithValue("@RecentImportCount", recentImportCount);
        cmd.Parameters.AddWithValue("@LineageNeighborLimit", lineageNeighborLimit);
        cmd.Parameters.AddWithValue("@IncludeHistory", includeHistory);
        cmd.Parameters.AddWithValue("@HistoryCount", historyCount);
        var (code, msg) = AddStatus(cmd);

        CatalogDatasetDetailDto? detail = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            // Seven fixed result sets on success; none otherwise.
            if (reader.FieldCount > 0 && await reader.ReadAsync(ct))
            {
                var summary = MapSummary(reader);
                var tags = await NextListAsync(reader, r => new CatalogDatasetTagDto
                {
                    TagName = r.GetString("TagName"),
                    Description = r.GetNullableString("Description"),
                    TaggedUtc = r.GetDateTime("TaggedUtc"),
                    TaggedByUserName = r.GetNullableString("TaggedByUserName")
                }, ct);
                var imports = await NextListAsync(reader, r => new CatalogImportDto
                {
                    BatchId = r.GetGuid("BatchId"),
                    ImportUtc = r.GetDateTime("ImportUtc"),
                    Status = r.GetString("Status"),
                    TotalRecords = IntN(r, "TotalRecords"),
                    ValidRecords = IntN(r, "ValidRecords"),
                    RejectedRecords = IntN(r, "RejectedRecords"),
                    ErrorCount = IntN(r, "ErrorCount"),
                    CompletedUtc = r.GetNullableDateTime("CompletedUtc"),
                    DataSourceName = r.GetNullableString("DataSourceName"),
                    SourceTypeCode = r.GetNullableString("SourceTypeCode")
                }, ct);
                var lineage = (await NextListAsync(reader, r => new CatalogLineageSummaryDto
                {
                    PipelineEntityCount = Int(r, "PipelineEntityCount"),
                    UpstreamEntityCount = Int(r, "UpstreamEntityCount"),
                    DownstreamEntityCount = Int(r, "DownstreamEntityCount"),
                    UpstreamSourceCount = Int(r, "UpstreamSourceCount"),
                    UpstreamDatasetCount = Int(r, "UpstreamDatasetCount"),
                    DownstreamDatasetCount = Int(r, "DownstreamDatasetCount"),
                    ConsumerAssetCount = Int(r, "ConsumerAssetCount"),
                    LastLineageUtc = r.GetNullableDateTime("LastLineageUtc")
                }, ct)).FirstOrDefault() ?? new CatalogLineageSummaryDto();
                var neighbors = await NextListAsync(reader, r => new CatalogLineageNeighborDto
                {
                    Direction = r.GetString("Direction"),
                    RelationshipType = r.GetString("RelationshipType"),
                    EntityTypeCode = r.GetString("EntityTypeCode"),
                    EntityCode = r.GetString("EntityCode"),
                    DisplayName = r.GetNullableString("DisplayName"),
                    NeighborDatasetCode = r.GetNullableString("NeighborDatasetCode"),
                    EdgeCount = Int(r, "EdgeCount"),
                    LastSeenUtc = r.GetNullableDateTime("LastSeenUtc")
                }, ct);
                var versions = await NextListAsync(reader, r => new CatalogVersionDto
                {
                    DatasetVersionId = r.GetGuid("DatasetVersionId"),
                    VersionNumber = Int(r, "VersionNumber"),
                    ProducedUtc = r.GetDateTime("ProducedUtc"),
                    ProducedBy = r.GetNullableString("ProducedBy"),
                    ImportBatchId = r.GetNullableGuid("ImportBatchId"),
                    EtlRunId = r.GetNullableGuid("EtlRunId"),
                    ProfileRunId = r.GetNullableGuid("ProfileRunId"),
                    Notes = r.GetNullableString("Notes")
                }, ct);
                var certification = await NextListAsync(reader, r => new CatalogCertificationEventDto
                {
                    HistoryId = r.GetInt64("HistoryId"),
                    ActionUtc = r.GetDateTime("ActionUtc"),
                    PreviousGovStatus = r.GetNullableString("PreviousGovStatus"),
                    NewGovStatus = r.GetNullableString("NewGovStatus"),
                    PreviousCertStatus = r.GetNullableString("PreviousCertStatus"),
                    NewCertStatus = r.GetNullableString("NewCertStatus"),
                    ActionedByUserName = r.GetNullableString("ActionedByUserName"),
                    Comments = r.GetNullableString("Comments")
                }, ct);

                detail = new CatalogDatasetDetailDto
                {
                    Summary = summary,
                    Tags = tags,
                    RecentImports = imports,
                    Lineage = lineage,
                    LineageNeighbors = neighbors,
                    VersionHistory = versions,
                    CertificationHistory = certification
                };
            }
        }

        return new CatalogDetailResult
        {
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Detail = detail
        };
    }

    // ---------------- Tags ----------------

    public async Task<CatalogTagListResult> GetTagsAsync(string userName, string? search, bool includeUnused, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "cat.usp_GetTags");
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddNullable("@Search", search);
        cmd.Parameters.AddWithValue("@IncludeUnused", includeUnused);
        var (code, msg) = AddStatus(cmd);

        var tags = new List<CatalogTagDto>();
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                tags.Add(new CatalogTagDto
                {
                    TagId = reader.GetInt32("TagId"),
                    TagName = reader.GetString("TagName"),
                    Description = reader.GetNullableString("Description"),
                    DatasetCount = Int(reader, "DatasetCount")
                });
            }
        }
        return new CatalogTagListResult { StatusCode = code.Value as string ?? "", StatusMessage = msg.Value as string ?? "", Tags = tags };
    }

    public Task<DatasetTagActionResult> AddDatasetTagsAsync(string datasetCode, string tagsCsv, string userName, CancellationToken ct = default)
        => ExecuteTagActionAsync("cat.usp_AddDatasetTags", datasetCode, tagsCsv, userName, ct);

    public Task<DatasetTagActionResult> RemoveDatasetTagsAsync(string datasetCode, string tagsCsv, string userName, CancellationToken ct = default)
        => ExecuteTagActionAsync("cat.usp_RemoveDatasetTags", datasetCode, tagsCsv, userName, ct);

    // ---------------- Reports ----------------

    public async Task<CatalogSummaryDto> GetSummaryAsync(string userName, string? workspaceCode, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_CatalogSummary", userName, workspaceCode);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return new CatalogSummaryDto();
        return new CatalogSummaryDto
        {
            TotalDiscoverable = Int(reader, "TotalDiscoverable"),
            ReadableCount = Int(reader, "ReadableCount"),
            MetadataOnlyCount = Int(reader, "MetadataOnlyCount"),
            CertifiedCount = Int(reader, "CertifiedCount"),
            UncertifiedCount = Int(reader, "UncertifiedCount"),
            ProfiledCount = Int(reader, "ProfiledCount"),
            AvgQualityScore = reader.GetNullableDecimal("AvgQualityScore"),
            TaggedCount = Int(reader, "TaggedCount"),
            WorkspaceCount = Int(reader, "WorkspaceCount"),
            UpdatedLast7Days = Int(reader, "UpdatedLast7Days"),
            ImportedLast7Days = Int(reader, "ImportedLast7Days"),
            DeprecatedCount = Int(reader, "DeprecatedCount")
        };
    }

    public Task<IReadOnlyList<CatalogCountRow>> GetByClassificationAsync(string userName, string? workspaceCode, CancellationToken ct = default)
        => ReadReportAsync("rpt.usp_CatalogByClassification", userName, workspaceCode, MapCount, ct);

    public Task<IReadOnlyList<CatalogCountRow>> GetByGovernanceStatusAsync(string userName, string? workspaceCode, CancellationToken ct = default)
        => ReadReportAsync("rpt.usp_CatalogByGovernanceStatus", userName, workspaceCode, MapCount, ct);

    public Task<IReadOnlyList<CatalogCountRow>> GetByCategoryAsync(string userName, string? workspaceCode, CancellationToken ct = default)
        => ReadReportAsync("rpt.usp_CatalogByCategory", userName, workspaceCode, r => new CatalogCountRow
        {
            Key = r.GetNullableString("Key") ?? "",
            Name = r.GetNullableString("Name"),
            SortOrder = r.GetInt64("SortOrder"),
            DatasetCount = Int(r, "DatasetCount"),
            CertifiedCount = Int(r, "CertifiedCount"),
            AvgQualityScore = r.GetNullableDecimal("AvgQualityScore")
        }, ct);

    public Task<IReadOnlyList<CatalogCertificationRow>> GetCertificationAsync(string userName, string? workspaceCode, CancellationToken ct = default)
        => ReadReportAsync("rpt.usp_CatalogCertification", userName, workspaceCode, r => new CatalogCertificationRow
        {
            CertificationGroup = r.GetString("CertificationGroup"),
            Key = r.GetString("Key"),
            Name = r.GetNullableString("Name"),
            DatasetCount = Int(r, "DatasetCount"),
            Pct = r.GetNullableDecimal("Pct")
        }, ct);

    public Task<IReadOnlyList<CatalogQualityBucketRow>> GetQualityDistributionAsync(string userName, string? workspaceCode, CancellationToken ct = default)
        => ReadReportAsync("rpt.usp_CatalogQualityDistribution", userName, workspaceCode, r => new CatalogQualityBucketRow
        {
            Bucket = r.GetString("Bucket"),
            MinScore = r.GetNullableDecimal("MinScore"),
            MaxScore = r.GetNullableDecimal("MaxScore"),
            SortOrder = Int(r, "SortOrder"),
            DatasetCount = Int(r, "DatasetCount")
        }, ct);

    public async Task<IReadOnlyList<CatalogRecentDatasetRow>> GetRecentlyUpdatedAsync(string userName, string? workspaceCode, int days, int top, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_CatalogRecentlyUpdated", userName, workspaceCode);
        cmd.Parameters.AddWithValue("@Days", days);
        cmd.Parameters.AddWithValue("@Top", top);
        return await ReadListAsync(cmd, r => new CatalogRecentDatasetRow
        {
            DatasetCode = r.GetString("DatasetCode"),
            DatasetName = r.GetString("DatasetName"),
            WorkspaceCode = r.GetNullableString("WorkspaceCode"),
            Category = r.GetNullableString("Category"),
            ClassificationCode = r.GetNullableString("ClassificationCode"),
            GovernanceStatusCode = r.GetNullableString("GovernanceStatusCode"),
            CertificationStatusCode = r.GetNullableString("CertificationStatusCode"),
            UpdatedUtc = r.GetNullableDateTime("UpdatedUtc"),
            AccessSource = r.GetString("AccessSource"),
            CanReadData = r.GetBoolean("CanReadData")
        }, ct);
    }

    public async Task<IReadOnlyList<CatalogRecentDatasetRow>> GetRecentlyImportedAsync(string userName, string? workspaceCode, int days, int top, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_CatalogRecentlyImported", userName, workspaceCode);
        cmd.Parameters.AddWithValue("@Days", days);
        cmd.Parameters.AddWithValue("@Top", top);
        return await ReadListAsync(cmd, r => new CatalogRecentDatasetRow
        {
            DatasetCode = r.GetString("DatasetCode"),
            DatasetName = r.GetString("DatasetName"),
            WorkspaceCode = r.GetNullableString("WorkspaceCode"),
            Category = r.GetNullableString("Category"),
            LastImportUtc = r.GetNullableDateTime("LastImportUtc"),
            LastImportStatus = r.GetNullableString("LastImportStatus"),
            LastImportRecords = IntN(r, "LastImportRecords"),
            SourceTypeCode = r.GetNullableString("SourceTypeCode"),
            AccessSource = r.GetString("AccessSource"),
            CanReadData = r.GetBoolean("CanReadData")
        }, ct);
    }

    // ---------------- Helpers ----------------

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        return conn;
    }

    private static SqlCommand Proc(SqlConnection conn, string name) =>
        new(name, conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = Timeout };

    private static SqlCommand ReportProc(SqlConnection conn, string name, string userName, string? workspaceCode)
    {
        var cmd = Proc(conn, name);
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddNullable("@WorkspaceCode", workspaceCode);
        return cmd;
    }

    private async Task<IReadOnlyList<T>> ReadReportAsync<T>(string proc, string userName, string? workspaceCode,
        Func<SqlDataReader, T> map, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, proc, userName, workspaceCode);
        return await ReadListAsync(cmd, map, ct);
    }

    private async Task<DatasetTagActionResult> ExecuteTagActionAsync(string proc, string datasetCode, string tagsCsv, string userName, CancellationToken ct)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, proc);
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.Add(new SqlParameter("@Tags", SqlDbType.NVarChar, 1000) { Value = tagsCsv });
        cmd.Parameters.AddWithValue("@UserName", userName);
        var (code, msg) = AddStatus(cmd);

        var tags = new List<string>();
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            while (await reader.ReadAsync(ct))
                tags.Add(reader.GetString(0));
        }
        return new DatasetTagActionResult
        {
            DatasetCode = datasetCode,
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Tags = tags
        };
    }

    private static SqlParameter Out(string name, SqlDbType type, int size = 0) =>
        new(name, type, size) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };

    private static SqlParameter Score(string name, decimal? value) =>
        new(name, SqlDbType.Decimal) { Precision = 5, Scale = 2, Value = (object?)value ?? DBNull.Value };

    private static SqlParameter Date(string name, DateTime? value) =>
        new(name, SqlDbType.DateTime2) { Scale = 3, Value = (object?)value ?? DBNull.Value };

    private static (SqlParameter Code, SqlParameter Message) AddStatus(SqlCommand cmd)
    {
        var code = cmd.Parameters.Add(Out("@StatusCode", SqlDbType.NVarChar, 32));
        var msg = cmd.Parameters.Add(Out("@StatusMessage", SqlDbType.NVarChar, 500));
        return (code, msg);
    }

    private static async Task<IReadOnlyList<T>> ReadListAsync<T>(SqlCommand cmd, Func<SqlDataReader, T> map, CancellationToken ct)
    {
        var list = new List<T>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(map(reader));
        return list;
    }

    private static async Task<IReadOnlyList<T>> NextListAsync<T>(SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken ct)
    {
        var list = new List<T>();
        if (!await reader.NextResultAsync(ct)) return list;
        while (await reader.ReadAsync(ct))
            list.Add(map(reader));
        return list;
    }

    // Counts / SUMs may be NULL (empty set) or a narrower integer type (tinyint, bigint).
    private static int Int(SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? 0 : Convert.ToInt32(reader.GetValue(ordinal));
    }

    private static int? IntN(SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
    }

    private static IReadOnlyList<string> SplitTags(string? csv) =>
        string.IsNullOrEmpty(csv) ? [] : csv.Split(',', StringSplitOptions.RemoveEmptyEntries);

    private static CatalogDatasetDto MapDataset(SqlDataReader r) => new()
    {
        DatasetId = r.GetGuid("DatasetId"),
        DatasetCode = r.GetString("DatasetCode"),
        DatasetName = r.GetString("DatasetName"),
        Description = r.GetNullableString("Description"),
        WorkspaceId = r.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = r.GetNullableString("WorkspaceCode"),
        WorkspaceName = r.GetNullableString("WorkspaceName"),
        Category = r.GetNullableString("Category"),
        OwnerUserName = r.GetNullableString("OwnerUserName"),
        OwnerDisplayName = r.GetNullableString("OwnerDisplayName"),
        StewardUserName = r.GetNullableString("StewardUserName"),
        StewardDisplayName = r.GetNullableString("StewardDisplayName"),
        SourceTypeCode = r.GetNullableString("SourceTypeCode"),
        SourceTypeName = r.GetNullableString("SourceTypeName"),
        ClassificationCode = r.GetString("ClassificationCode"),
        GovernanceStatusCode = r.GetString("GovernanceStatusCode"),
        DatasetStatus = r.GetString("DatasetStatus"),
        CertificationStatusCode = r.GetString("CertificationStatusCode"),
        CurrentVersion = IntN(r, "CurrentVersion"),
        CreatedUtc = r.GetDateTime("CreatedUtc"),
        UpdatedUtc = r.GetDateTime("UpdatedUtc"),
        QualityScore = r.GetNullableDecimal("QualityScore"),
        LastImportUtc = r.GetNullableDateTime("LastImportUtc"),
        Tags = SplitTags(r.GetNullableString("Tags")),
        RelevanceScore = Int(r, "RelevanceScore"),
        AccessSource = r.GetString("AccessSource"),
        EffectiveAccessLevel = r.GetNullableString("EffectiveAccessLevel"),
        CanReadData = r.GetBoolean("CanReadData"),
        CanRequestAccess = r.GetBoolean("CanRequestAccess")
    };

    private static CatalogDatasetSummaryDto MapSummary(SqlDataReader r) => new()
    {
        DatasetId = r.GetGuid("DatasetId"),
        DatasetCode = r.GetString("DatasetCode"),
        DatasetName = r.GetString("DatasetName"),
        Description = r.GetNullableString("Description"),
        Category = r.GetNullableString("Category"),
        DatasetStatus = r.GetString("DatasetStatus"),
        IsCurrent = r.GetBoolean("IsCurrent"),
        WorkspaceId = r.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = r.GetNullableString("WorkspaceCode"),
        WorkspaceName = r.GetNullableString("WorkspaceName"),
        CreatedUtc = r.GetDateTime("CreatedUtc"),
        UpdatedUtc = r.GetDateTime("UpdatedUtc"),
        ClassificationCode = r.GetString("ClassificationCode"),
        ClassificationName = r.GetNullableString("ClassificationName"),
        SensitivityRank = IntN(r, "SensitivityRank"),
        GovernanceStatusCode = r.GetString("GovernanceStatusCode"),
        CertificationStatusCode = r.GetString("CertificationStatusCode"),
        CertifiedUtc = r.GetNullableDateTime("CertifiedUtc"),
        CertificationExpiryUtc = r.GetNullableDateTime("CertificationExpiryUtc"),
        ReviewDueUtc = r.GetNullableDateTime("ReviewDueUtc"),
        OwnerUserName = r.GetNullableString("OwnerUserName"),
        OwnerDisplayName = r.GetNullableString("OwnerDisplayName"),
        OwnerEmail = r.GetNullableString("OwnerEmail"),
        StewardUserName = r.GetNullableString("StewardUserName"),
        StewardDisplayName = r.GetNullableString("StewardDisplayName"),
        StewardEmail = r.GetNullableString("StewardEmail"),
        CurrentVersion = IntN(r, "CurrentVersion"),
        CurrentVersionProducedUtc = r.GetNullableDateTime("CurrentVersionProducedUtc"),
        VersionCount = Int(r, "VersionCount"),
        SourceTypeCode = r.GetNullableString("SourceTypeCode"),
        SourceTypeName = r.GetNullableString("SourceTypeName"),
        DataSourceName = r.GetNullableString("DataSourceName"),
        QualityScore = r.GetNullableDecimal("QualityScore"),
        QualityGrade = r.GetNullableString("QualityGrade"),
        QualityThresholdResult = r.GetNullableString("QualityThresholdResult"),
        LastProfiledUtc = r.GetNullableDateTime("LastProfiledUtc"),
        CompletenessPct = r.GetNullableDecimal("CompletenessPct"),
        ValidityPct = r.GetNullableDecimal("ValidityPct"),
        UniquenessPct = r.GetNullableDecimal("UniquenessPct"),
        ConsistencyPct = r.GetNullableDecimal("ConsistencyPct"),
        QualityIssueCount = IntN(r, "QualityIssueCount"),
        LastImportUtc = r.GetNullableDateTime("LastImportUtc"),
        LastImportStatus = r.GetNullableString("LastImportStatus"),
        LastImportRecords = IntN(r, "LastImportRecords"),
        ImportCount = Int(r, "ImportCount"),
        FailedImportCount30d = Int(r, "FailedImportCount30d"),
        AccessSource = r.GetString("AccessSource"),
        EffectiveAccessLevel = r.GetNullableString("EffectiveAccessLevel"),
        CanReadData = r.GetBoolean("CanReadData"),
        CanRequestAccess = r.GetBoolean("CanRequestAccess"),
        WorkspaceRole = r.GetNullableString("WorkspaceRole"),
        HasPendingAccessRequest = r.GetBoolean("HasPendingAccessRequest"),
        ActiveGrantCount = IntN(r, "ActiveGrantCount"),
        ActiveShareCount = IntN(r, "ActiveShareCount"),
        PendingAccessRequestCount = IntN(r, "PendingAccessRequestCount")
    };

    private static CatalogCountRow MapCount(SqlDataReader r) => new()
    {
        Key = r.GetString("Key"),
        Name = r.GetNullableString("Name"),
        SortOrder = r.GetInt64("SortOrder"),
        DatasetCount = Int(r, "DatasetCount")
    };
}
