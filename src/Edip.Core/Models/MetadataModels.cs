using Edip.Core.Enums;

namespace Edip.Core.Models;

public sealed class SchemaObject
{
    public Guid SchemaObjectId { get; set; }
    public Guid DataSourceId { get; set; }
    public string SchemaName { get; set; } = "dbo";
    public string ObjectName { get; set; } = string.Empty;
    public SchemaObjectType ObjectType { get; set; }
    public DateTime CapturedUtc { get; set; }
}

public sealed class ColumnDefinition
{
    public Guid ColumnDefinitionId { get; set; }
    public Guid SchemaObjectId { get; set; }
    public string ColumnName { get; set; } = string.Empty;
    public string DataType { get; set; } = string.Empty;
    public int? MaxLength { get; set; }
    public byte? NumericPrecision { get; set; }
    public int? NumericScale { get; set; }
    public bool IsNullable { get; set; }
    public int OrdinalPosition { get; set; }
    public bool IsPrimaryKey { get; set; }
    public bool IsForeignKey { get; set; }
}

public sealed class ObjectRelationship
{
    public Guid RelationshipId { get; set; }
    public Guid DataSourceId { get; set; }
    public Guid ParentObjectId { get; set; }
    public Guid ChildObjectId { get; set; }
    public string ParentColumnName { get; set; } = string.Empty;
    public string ChildColumnName { get; set; } = string.Empty;
    public string? ConstraintName { get; set; }
}

public sealed class MetadataRefreshHistory
{
    public long RefreshHistoryId { get; set; }
    public Guid DataSourceId { get; set; }
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public string Status { get; set; } = "Running";
    public int ObjectsCaptured { get; set; }
    public int ColumnsCaptured { get; set; }
    public int RelationshipsCaptured { get; set; }
    public string? ErrorMessage { get; set; }
}

public sealed class CapturedMetadataSnapshot
{
    public List<SchemaObject> Objects { get; set; } = [];
    public List<ColumnDefinition> Columns { get; set; } = [];
    public List<ObjectRelationship> Relationships { get; set; } = [];
}
