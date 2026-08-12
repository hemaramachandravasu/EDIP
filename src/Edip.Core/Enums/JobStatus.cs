namespace Edip.Core.Enums;

public enum JobExecutionStatus
{
    Pending = 0,
    Running = 1,
    Succeeded = 2,
    Failed = 3,
    Retrying = 4,
    Cancelled = 5
}

public enum JobTriggerType
{
    Manual = 1,
    Agent = 2,
    Retry = 3
}

public enum ProcessingJobType
{
    MetadataRefresh = 1,
    HealthCheck = 2,
    SampleExtract = 3,
    DataProfiling = 4,
    QualityAssessment = 5,
    MetadataSync = 6,
    ArchiveProfilingHistory = 7,
    ProcessPendingImports = 8,
    ArchiveImportHistory = 9
}
