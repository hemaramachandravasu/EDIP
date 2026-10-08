namespace Edip.Core.DTOs;

public static class CatalogSortFields
{
    public const string Relevance = "Relevance";
    public const string Name = "Name";
    public const string Code = "Code";
    public const string CreatedDate = "CreatedDate";
    public const string UpdatedDate = "UpdatedDate";
    public const string QualityScore = "QualityScore";
    public const string LastImportDate = "LastImportDate";
    public const string Classification = "Classification";
    public const string GovernanceStatus = "GovernanceStatus";
}

// ---------------- Search ----------------

public sealed class CatalogSearchQuery
{
    public string UserName { get; init; } = "";
    public string? SearchText { get; init; }
    public string? WorkspaceCode { get; init; }
    public string? Category { get; init; }
    public string? ClassificationCode { get; init; }
    public string? GovernanceStatusCode { get; init; }
    public string? DatasetStatus { get; init; }
    public string? CertificationStatusCode { get; init; }
    public string? OwnerUserName { get; init; }
    public string? StewardUserName { get; init; }
    public string? SourceTypeCode { get; init; }
    public decimal? MinQualityScore { get; init; }
    public decimal? MaxQualityScore { get; init; }
    public DateTime? CreatedFrom { get; init; }
    public DateTime? CreatedTo { get; init; }
    public DateTime? UpdatedFrom { get; init; }
    public DateTime? UpdatedTo { get; init; }
    /// <summary>Comma-separated tag names (max 10).</summary>
    public string? Tags { get; init; }
    /// <summary>Any | All.</summary>
    public string TagMatch { get; init; } = "Any";
    public bool IncludeInactive { get; init; }
    public string? SortBy { get; init; }
    public string? SortDirection { get; init; }
    public int PageNumber { get; init; } = 1;
    public int PageSize { get; init; } = 25;
    /// <summary>Keyset cursor (Name, Code, CreatedDate, UpdatedDate sorts): sort value of the last row.</summary>
    public string? AfterValue { get; init; }
    public Guid? AfterDatasetId { get; init; }
    public bool IncludeTotalCount { get; init; } = true;
}

public sealed class CatalogDatasetDto
{
    public Guid DatasetId { get; init; }
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public string? Description { get; init; }
    public Guid? WorkspaceId { get; init; }
    public string? WorkspaceCode { get; init; }
    public string? WorkspaceName { get; init; }
    public string? Category { get; init; }
    public string? OwnerUserName { get; init; }
    public string? OwnerDisplayName { get; init; }
    public string? StewardUserName { get; init; }
    public string? StewardDisplayName { get; init; }
    public string? SourceTypeCode { get; init; }
    public string? SourceTypeName { get; init; }
    public string ClassificationCode { get; init; } = "";
    public string GovernanceStatusCode { get; init; } = "";
    public string DatasetStatus { get; init; } = "";
    public string CertificationStatusCode { get; init; } = "";
    public int? CurrentVersion { get; init; }
    public DateTime CreatedUtc { get; init; }
    public DateTime UpdatedUtc { get; init; }
    public decimal? QualityScore { get; init; }
    public DateTime? LastImportUtc { get; init; }
    public IReadOnlyList<string> Tags { get; init; } = [];
    public int RelevanceScore { get; init; }
    public string AccessSource { get; init; } = "";
    public string? EffectiveAccessLevel { get; init; }
    public bool CanReadData { get; init; }
    public bool CanRequestAccess { get; init; }
}

public sealed class CatalogSearchResult
{
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public IReadOnlyList<CatalogDatasetDto> Items { get; init; } = [];
    /// <summary>Null for keyset requests.</summary>
    public int? PageNumber { get; init; }
    public int PageSize { get; init; }
    public int? TotalCount { get; init; }
    public bool HasMore { get; init; }
    public string? NextAfterValue { get; init; }
    public Guid? NextAfterDatasetId { get; init; }
    public string? SortBy { get; init; }
    public string? SortDirection { get; init; }
}

// ---------------- Detail ----------------

public sealed class CatalogDatasetSummaryDto
{
    public Guid DatasetId { get; init; }
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public string? Description { get; init; }
    public string? Category { get; init; }
    public string DatasetStatus { get; init; } = "";
    public bool IsCurrent { get; init; }
    public Guid? WorkspaceId { get; init; }
    public string? WorkspaceCode { get; init; }
    public string? WorkspaceName { get; init; }
    public DateTime CreatedUtc { get; init; }
    public DateTime UpdatedUtc { get; init; }

    public string ClassificationCode { get; init; } = "";
    public string? ClassificationName { get; init; }
    public int? SensitivityRank { get; init; }
    public string GovernanceStatusCode { get; init; } = "";
    public string CertificationStatusCode { get; init; } = "";
    public DateTime? CertifiedUtc { get; init; }
    public DateTime? CertificationExpiryUtc { get; init; }
    public DateTime? ReviewDueUtc { get; init; }
    public string? OwnerUserName { get; init; }
    public string? OwnerDisplayName { get; init; }
    public string? OwnerEmail { get; init; }
    public string? StewardUserName { get; init; }
    public string? StewardDisplayName { get; init; }
    public string? StewardEmail { get; init; }

    public int? CurrentVersion { get; init; }
    public DateTime? CurrentVersionProducedUtc { get; init; }
    public int VersionCount { get; init; }

    public string? SourceTypeCode { get; init; }
    public string? SourceTypeName { get; init; }
    public string? DataSourceName { get; init; }

    public decimal? QualityScore { get; init; }
    public string? QualityGrade { get; init; }
    public string? QualityThresholdResult { get; init; }
    public DateTime? LastProfiledUtc { get; init; }
    public decimal? CompletenessPct { get; init; }
    public decimal? ValidityPct { get; init; }
    public decimal? UniquenessPct { get; init; }
    public decimal? ConsistencyPct { get; init; }
    public int? QualityIssueCount { get; init; }

    public DateTime? LastImportUtc { get; init; }
    public string? LastImportStatus { get; init; }
    public int? LastImportRecords { get; init; }
    public int ImportCount { get; init; }
    public int FailedImportCount30d { get; init; }

    public string AccessSource { get; init; } = "";
    public string? EffectiveAccessLevel { get; init; }
    public bool CanReadData { get; init; }
    public bool CanRequestAccess { get; init; }
    public string? WorkspaceRole { get; init; }
    public bool HasPendingAccessRequest { get; init; }
    /// <summary>Only populated for platform admins and dataset owners/stewards.</summary>
    public int? ActiveGrantCount { get; init; }
    public int? ActiveShareCount { get; init; }
    public int? PendingAccessRequestCount { get; init; }
}

public sealed class CatalogDatasetTagDto
{
    public string TagName { get; init; } = "";
    public string? Description { get; init; }
    public DateTime TaggedUtc { get; init; }
    public string? TaggedByUserName { get; init; }
}

public sealed class CatalogImportDto
{
    public Guid BatchId { get; init; }
    public DateTime ImportUtc { get; init; }
    public string Status { get; init; } = "";
    public int? TotalRecords { get; init; }
    public int? ValidRecords { get; init; }
    public int? RejectedRecords { get; init; }
    public int? ErrorCount { get; init; }
    public DateTime? CompletedUtc { get; init; }
    public string? DataSourceName { get; init; }
    public string? SourceTypeCode { get; init; }
}

public sealed class CatalogLineageSummaryDto
{
    public int PipelineEntityCount { get; init; }
    public int UpstreamEntityCount { get; init; }
    public int DownstreamEntityCount { get; init; }
    public int UpstreamSourceCount { get; init; }
    public int UpstreamDatasetCount { get; init; }
    public int DownstreamDatasetCount { get; init; }
    public int ConsumerAssetCount { get; init; }
    public DateTime? LastLineageUtc { get; init; }
}

public sealed class CatalogLineageNeighborDto
{
    public string Direction { get; init; } = "";
    public string RelationshipType { get; init; } = "";
    public string EntityTypeCode { get; init; } = "";
    public string EntityCode { get; init; } = "";
    public string? DisplayName { get; init; }
    public string? NeighborDatasetCode { get; init; }
    public int EdgeCount { get; init; }
    public DateTime? LastSeenUtc { get; init; }
}

public sealed class CatalogVersionDto
{
    public Guid DatasetVersionId { get; init; }
    public int VersionNumber { get; init; }
    public DateTime ProducedUtc { get; init; }
    public string? ProducedBy { get; init; }
    public Guid? ImportBatchId { get; init; }
    public Guid? EtlRunId { get; init; }
    public Guid? ProfileRunId { get; init; }
    public string? Notes { get; init; }
}

public sealed class CatalogCertificationEventDto
{
    public long HistoryId { get; init; }
    public DateTime ActionUtc { get; init; }
    public string? PreviousGovStatus { get; init; }
    public string? NewGovStatus { get; init; }
    public string? PreviousCertStatus { get; init; }
    public string? NewCertStatus { get; init; }
    public string? ActionedByUserName { get; init; }
    public string? Comments { get; init; }
}

public sealed class CatalogDatasetDetailDto
{
    public CatalogDatasetSummaryDto Summary { get; init; } = new();
    public IReadOnlyList<CatalogDatasetTagDto> Tags { get; init; } = [];
    public IReadOnlyList<CatalogImportDto> RecentImports { get; init; } = [];
    public CatalogLineageSummaryDto Lineage { get; init; } = new();
    public IReadOnlyList<CatalogLineageNeighborDto> LineageNeighbors { get; init; } = [];
    public IReadOnlyList<CatalogVersionDto> VersionHistory { get; init; } = [];
    public IReadOnlyList<CatalogCertificationEventDto> CertificationHistory { get; init; } = [];
}

public sealed class CatalogDetailResult
{
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public CatalogDatasetDetailDto? Detail { get; init; }
}

// ---------------- Tags ----------------

public sealed class CatalogTagDto
{
    public int TagId { get; init; }
    public string TagName { get; init; } = "";
    public string? Description { get; init; }
    /// <summary>Datasets carrying the tag that the requesting user can discover.</summary>
    public int DatasetCount { get; init; }
}

public sealed class CatalogTagListResult
{
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    public IReadOnlyList<CatalogTagDto> Tags { get; init; } = [];
}

public sealed class DatasetTagsRequest
{
    public IReadOnlyList<string> Tags { get; init; } = [];
    public string UserName { get; init; } = "";
}

public sealed class DatasetTagActionResult
{
    public string DatasetCode { get; init; } = "";
    public string StatusCode { get; init; } = "";
    public string StatusMessage { get; init; } = "";
    /// <summary>The dataset's tags after the change (empty when the call failed).</summary>
    public IReadOnlyList<string> Tags { get; init; } = [];
}

// ---------------- Reports ----------------

public sealed class CatalogSummaryDto
{
    public int TotalDiscoverable { get; init; }
    public int ReadableCount { get; init; }
    public int MetadataOnlyCount { get; init; }
    public int CertifiedCount { get; init; }
    public int UncertifiedCount { get; init; }
    public int ProfiledCount { get; init; }
    public decimal? AvgQualityScore { get; init; }
    public int TaggedCount { get; init; }
    public int WorkspaceCount { get; init; }
    public int UpdatedLast7Days { get; init; }
    public int ImportedLast7Days { get; init; }
    public int DeprecatedCount { get; init; }
}

public sealed class CatalogCountRow
{
    public string Key { get; init; } = "";
    public string? Name { get; init; }
    public long SortOrder { get; init; }
    public int DatasetCount { get; init; }
    /// <summary>By-category report only.</summary>
    public int? CertifiedCount { get; init; }
    /// <summary>By-category report only.</summary>
    public decimal? AvgQualityScore { get; init; }
}

public sealed class CatalogCertificationRow
{
    public string CertificationGroup { get; init; } = "";
    public string Key { get; init; } = "";
    public string? Name { get; init; }
    public int DatasetCount { get; init; }
    public decimal? Pct { get; init; }
}

public sealed class CatalogQualityBucketRow
{
    public string Bucket { get; init; } = "";
    public decimal? MinScore { get; init; }
    public decimal? MaxScore { get; init; }
    public int SortOrder { get; init; }
    public int DatasetCount { get; init; }
}

public sealed class CatalogRecentDatasetRow
{
    public string DatasetCode { get; init; } = "";
    public string DatasetName { get; init; } = "";
    public string? WorkspaceCode { get; init; }
    public string? Category { get; init; }
    public string? ClassificationCode { get; init; }
    public string? GovernanceStatusCode { get; init; }
    public string? CertificationStatusCode { get; init; }
    public DateTime? UpdatedUtc { get; init; }
    public DateTime? LastImportUtc { get; init; }
    public string? LastImportStatus { get; init; }
    public int? LastImportRecords { get; init; }
    public string? SourceTypeCode { get; init; }
    public string AccessSource { get; init; } = "";
    public bool CanReadData { get; init; }
}
