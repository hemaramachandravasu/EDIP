namespace Edip.Core.Models;

public sealed class ProfilingRun
{
    public Guid ProfilingRunId { get; set; }
    public Guid DataSourceId { get; set; }
    public string TriggerType { get; set; } = "Manual";
    public string Status { get; set; } = "Running";
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int TablesProfiled { get; set; }
    public int ColumnsProfiled { get; set; }
    public string? ErrorMessage { get; set; }
    public List<TableProfile> Tables { get; set; } = [];
}

public sealed class TableProfile
{
    public Guid TableProfileId { get; set; }
    public Guid ProfilingRunId { get; set; }
    public string SchemaName { get; set; } = string.Empty;
    public string ObjectName { get; set; } = string.Empty;
    public string ObjectType { get; set; } = "Table";
    public long RowCountValue { get; set; }
    public long DuplicateRowCount { get; set; }
    public bool IsEmpty { get; set; }
    public DateTime? LastDataChangeUtc { get; set; }
    public List<ColumnProfile> Columns { get; set; } = [];
}

public sealed class ColumnProfile
{
    public Guid ColumnProfileId { get; set; }
    public Guid TableProfileId { get; set; }
    public string ColumnName { get; set; } = string.Empty;
    public string DataType { get; set; } = string.Empty;
    public long NullCount { get; set; }
    public decimal NullPct { get; set; }
    public long DistinctCount { get; set; }
    public string? MinValue { get; set; }
    public string? MaxValue { get; set; }
    public long SampleInvalidCount { get; set; }
}

public sealed class QualityAssessment
{
    public Guid AssessmentId { get; set; }
    public Guid DataSourceId { get; set; }
    public Guid? ProfilingRunId { get; set; }
    public decimal OverallScore { get; set; }
    public string Grade { get; set; } = "F";
    public decimal MissingScore { get; set; }
    public decimal DuplicateScore { get; set; }
    public decimal TypeScore { get; set; }
    public decimal ReferentialScore { get; set; }
    public decimal EmptyTableScore { get; set; }
    public decimal FreshnessScore { get; set; }
    public DateTime AssessedUtc { get; set; }
    public string? Summary { get; set; }
    public List<QualityCheckResult> Checks { get; set; } = [];
}

public sealed class QualityCheckResult
{
    public Guid CheckResultId { get; set; }
    public Guid AssessmentId { get; set; }
    public string CheckCode { get; set; } = string.Empty;
    public string CheckName { get; set; } = string.Empty;
    public string Severity { get; set; } = "Info";
    public bool Passed { get; set; }
    public long AffectedCount { get; set; }
    public string? Details { get; set; }
}

public sealed class SchemaChangeEvent
{
    public Guid SchemaChangeId { get; set; }
    public Guid DataSourceId { get; set; }
    public Guid? SyncLogId { get; set; }
    public string ChangeType { get; set; } = string.Empty;
    public string SchemaName { get; set; } = string.Empty;
    public string ObjectName { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? OldValue { get; set; }
    public string? NewValue { get; set; }
    public DateTime DetectedUtc { get; set; }
}

public sealed class MetadataSyncLog
{
    public Guid SyncLogId { get; set; }
    public Guid DataSourceId { get; set; }
    public string TriggerType { get; set; } = "Manual";
    public string Status { get; set; } = "Running";
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int ObjectsAdded { get; set; }
    public int ObjectsRemoved { get; set; }
    public int ColumnsChanged { get; set; }
    public string? ErrorMessage { get; set; }
}
