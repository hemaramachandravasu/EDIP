namespace Edip.Core.DTOs;

public sealed class ProfilingRunDto
{
    public Guid ProfilingRunId { get; set; }
    public Guid DataSourceId { get; set; }
    public string TriggerType { get; set; } = string.Empty;
    public string Status { get; set; } = string.Empty;
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public int TablesProfiled { get; set; }
    public int ColumnsProfiled { get; set; }
    public string? ErrorMessage { get; set; }
    public IReadOnlyList<TableProfileDto> Tables { get; set; } = [];
}

public sealed class TableProfileDto
{
    public Guid TableProfileId { get; set; }
    public string SchemaName { get; set; } = string.Empty;
    public string ObjectName { get; set; } = string.Empty;
    public string ObjectType { get; set; } = string.Empty;
    public long RowCountValue { get; set; }
    public long DuplicateRowCount { get; set; }
    public bool IsEmpty { get; set; }
    public DateTime? LastDataChangeUtc { get; set; }
    public IReadOnlyList<ColumnProfileDto> Columns { get; set; } = [];
}

public sealed class ColumnProfileDto
{
    public string ColumnName { get; set; } = string.Empty;
    public string DataType { get; set; } = string.Empty;
    public long NullCount { get; set; }
    public decimal NullPct { get; set; }
    public long DistinctCount { get; set; }
    public string? MinValue { get; set; }
    public string? MaxValue { get; set; }
    public long SampleInvalidCount { get; set; }
}

public sealed class QualityAssessmentDto
{
    public Guid AssessmentId { get; set; }
    public Guid DataSourceId { get; set; }
    public Guid? ProfilingRunId { get; set; }
    public decimal OverallScore { get; set; }
    public string Grade { get; set; } = string.Empty;
    public decimal MissingScore { get; set; }
    public decimal DuplicateScore { get; set; }
    public decimal TypeScore { get; set; }
    public decimal ReferentialScore { get; set; }
    public decimal EmptyTableScore { get; set; }
    public decimal FreshnessScore { get; set; }
    public DateTime AssessedUtc { get; set; }
    public string? Summary { get; set; }
    public IReadOnlyList<QualityCheckResultDto> Checks { get; set; } = [];
}

public sealed class QualityCheckResultDto
{
    public string CheckCode { get; set; } = string.Empty;
    public string CheckName { get; set; } = string.Empty;
    public string Severity { get; set; } = string.Empty;
    public bool Passed { get; set; }
    public long AffectedCount { get; set; }
    public string? Details { get; set; }
}

public sealed class MetadataSyncResultDto
{
    public Guid SyncLogId { get; set; }
    public Guid DataSourceId { get; set; }
    public string Status { get; set; } = string.Empty;
    public int ObjectsAdded { get; set; }
    public int ObjectsRemoved { get; set; }
    public int ColumnsChanged { get; set; }
    public string? ErrorMessage { get; set; }
    public DateTime StartedUtc { get; set; }
    public DateTime? CompletedUtc { get; set; }
    public IReadOnlyList<SchemaChangeEventDto> Changes { get; set; } = [];
}

public sealed class SchemaChangeEventDto
{
    public Guid SchemaChangeId { get; set; }
    public string ChangeType { get; set; } = string.Empty;
    public string SchemaName { get; set; } = string.Empty;
    public string ObjectName { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? OldValue { get; set; }
    public string? NewValue { get; set; }
    public DateTime DetectedUtc { get; set; }
}

public sealed class DataQualitySummaryRow
{
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public Guid AssessmentId { get; set; }
    public decimal OverallScore { get; set; }
    public string Grade { get; set; } = string.Empty;
    public decimal MissingScore { get; set; }
    public decimal DuplicateScore { get; set; }
    public decimal TypeScore { get; set; }
    public decimal ReferentialScore { get; set; }
    public decimal EmptyTableScore { get; set; }
    public decimal FreshnessScore { get; set; }
    public DateTime AssessedUtc { get; set; }
}

public sealed class DatasetHealthRow
{
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public string ConnectionHealth { get; set; } = string.Empty;
    public decimal? LatestQualityScore { get; set; }
    public string? LatestGrade { get; set; }
    public DateTime? LastAssessedUtc { get; set; }
    public DateTime? LastProfiledUtc { get; set; }
    public string? LastProfileStatus { get; set; }
    public string DatasetHealth { get; set; } = string.Empty;
}

public sealed class SchemaChangeHistoryRow
{
    public Guid SchemaChangeId { get; set; }
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public string ChangeType { get; set; } = string.Empty;
    public string SchemaName { get; set; } = string.Empty;
    public string ObjectName { get; set; } = string.Empty;
    public string? ColumnName { get; set; }
    public string? OldValue { get; set; }
    public string? NewValue { get; set; }
    public DateTime DetectedUtc { get; set; }
}

public sealed class MetadataSyncStatusRow
{
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public Guid? SyncLogId { get; set; }
    public string? LastSyncStatus { get; set; }
    public DateTime? LastSyncUtc { get; set; }
    public int? ObjectsAdded { get; set; }
    public int? ObjectsRemoved { get; set; }
    public int? ColumnsChanged { get; set; }
    public int SyncCount30d { get; set; }
}

public sealed class QualityTrendRow
{
    public DateTime DayUtc { get; set; }
    public Guid DataSourceId { get; set; }
    public string DataSourceName { get; set; } = string.Empty;
    public decimal AvgOverallScore { get; set; }
    public decimal MinOverallScore { get; set; }
    public decimal MaxOverallScore { get; set; }
    public int AssessmentCount { get; set; }
}
