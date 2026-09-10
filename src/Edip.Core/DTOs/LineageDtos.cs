namespace Edip.Core.DTOs;

public sealed class LineageNodeDto
{
    public Guid EntityId { get; set; }
    public string EntityTypeCode { get; set; } = "";
    public string EntityCode { get; set; } = "";
    public string EntityName { get; set; } = "";
    public string? RelationshipType { get; set; }
    public int Depth { get; set; }
    public int? VersionNumber { get; set; }
    public Guid? WorkspaceId { get; set; }
    public Guid? RelationshipId { get; set; }
    public Guid? ViaEntityId { get; set; }
}

public sealed class LineageEntityDto
{
    public Guid EntityId { get; set; }
    public string EntityTypeCode { get; set; } = "";
    public string EntityCode { get; set; } = "";
    public string EntityName { get; set; } = "";
    public Guid? ExternalKey { get; set; }
    public Guid? WorkspaceId { get; set; }
    public Guid? DatasetId { get; set; }
    public int? VersionNumber { get; set; }
    public bool IsActive { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime ModifiedUtc { get; set; }
}

public sealed class DatasetVersionDto
{
    public Guid DatasetVersionId { get; set; }
    public string DatasetCode { get; set; } = "";
    public string DatasetName { get; set; } = "";
    public int VersionNumber { get; set; }
    public Guid EntityId { get; set; }
    public Guid? WorkspaceId { get; set; }
    public Guid? ImportBatchId { get; set; }
    public Guid? ImportId { get; set; }
    public Guid? EtlRunId { get; set; }
    public Guid? ProfileRunId { get; set; }
    public Guid? DataSourceId { get; set; }
    public string? DataSourceCode { get; set; }
    public DateTime ProducedUtc { get; set; }
    public string ProducedBy { get; set; } = "";
    public string? Notes { get; set; }
}

public sealed class VersionLineageEdgeDto
{
    public Guid EntityId { get; set; }
    public string EntityTypeCode { get; set; } = "";
    public string EntityCode { get; set; } = "";
    public string EntityName { get; set; } = "";
    public string RelationshipType { get; set; } = "";
    public string Direction { get; set; } = "";
    public int? VersionNumber { get; set; }
    public Guid? WorkspaceId { get; set; }
    public string? ProcessType { get; set; }
    public string? ProcessReference { get; set; }
    public int SubjectVersionNumber { get; set; }
}

public sealed class VersionLineageResultDto
{
    public IReadOnlyList<DatasetVersionDto> Versions { get; set; } = [];
    public IReadOnlyList<VersionLineageEdgeDto> Edges { get; set; } = [];
}

public sealed class CircularDependencyDto
{
    public Guid CycleStartEntityId { get; set; }
    public string CycleStartType { get; set; } = "";
    public string CycleStartCode { get; set; } = "";
    public string CycleStartName { get; set; } = "";
    public int CycleLength { get; set; }
    public string CyclePath { get; set; } = "";
    public Guid? FirstRelationshipId { get; set; }
}

public sealed class AddRelationshipRequest
{
    public Guid SourceEntityId { get; set; }
    public Guid TargetEntityId { get; set; }
    public string RelationshipType { get; set; } = "DependsOn";
    public Guid? WorkspaceId { get; set; }
    public Guid? SourceVersionId { get; set; }
    public Guid? TargetVersionId { get; set; }
    public string? ProcessReference { get; set; }
    public string? ProcessType { get; set; }
    public string CreatedBy { get; set; } = "api";
    public bool PreventCycles { get; set; } = true;
}

public sealed class AddRelationshipResultDto
{
    public Guid? RelationshipId { get; set; }
    public string StatusCode { get; set; } = "";
    public string StatusMessage { get; set; } = "";
}

public sealed class LineageSyncResultDto
{
    public long CaptureLogId { get; set; }
    public int RelationshipsAdded { get; set; }
    public int EntitiesAdded { get; set; }
    public string Status { get; set; } = "";
}

public sealed class LineageConnectedRow
{
    public Guid EntityId { get; set; }
    public string EntityTypeCode { get; set; } = "";
    public string EntityCode { get; set; } = "";
    public string EntityName { get; set; } = "";
    public Guid? WorkspaceId { get; set; }
    public int? VersionNumber { get; set; }
    public int ConnectionCount { get; set; }
}

public sealed class LineageDegreeRow
{
    public Guid EntityId { get; set; }
    public string EntityTypeCode { get; set; } = "";
    public string EntityCode { get; set; } = "";
    public string EntityName { get; set; } = "";
    public Guid? WorkspaceId { get; set; }
    public int Count { get; set; }
}

public sealed class LineageRelationshipCountRow
{
    public string RelationshipType { get; set; } = "";
    public string? ProcessType { get; set; }
    public int RelationshipCount { get; set; }
}

public sealed class LineageSourceToDatasetRow
{
    public string SourceCode { get; set; } = "";
    public string SourceName { get; set; } = "";
    public string DatasetCode { get; set; } = "";
    public string DatasetName { get; set; } = "";
    public int PathCount { get; set; }
}

public sealed class LineageDatasetToReportRow
{
    public string DatasetCode { get; set; } = "";
    public string DatasetName { get; set; } = "";
    public string AssetType { get; set; } = "";
    public string AssetCode { get; set; } = "";
    public string AssetName { get; set; } = "";
    public string RelationshipType { get; set; } = "";
    public DateTime CreatedUtc { get; set; }
}

public sealed class LineageDepthRow
{
    public string DatasetCode { get; set; } = "";
    public string DatasetName { get; set; } = "";
    public Guid? WorkspaceId { get; set; }
    public int MaxDownstreamDepth { get; set; }
    public int DownstreamEntityCount { get; set; }
}
