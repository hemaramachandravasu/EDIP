using Edip.Core.Models;

namespace Edip.Core.Interfaces;

public sealed class ProbeResult
{
    public bool IsSuccess { get; init; }
    public string Message { get; init; } = string.Empty;
    public int LatencyMs { get; init; }
}

public interface IConnectionProbe
{
    string SupportedTypeCode { get; }
    Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
    Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default);
}

public interface IConnectionProbeFactory
{
    IConnectionProbe GetProbe(string dataSourceTypeCode);
}

public interface IExportService
{
    byte[] ExportToCsv<T>(IEnumerable<T> rows);
    byte[] ExportToExcel<T>(IEnumerable<T> rows, string sheetName);
}

public interface IDataSourceService
{
    Task<IReadOnlyList<DTOs.DataSourceDto>> GetAllAsync(CancellationToken ct = default);
    Task<DTOs.DataSourceDto?> GetByIdAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.DataSourceDto> CreateAsync(DTOs.CreateDataSourceRequest request, CancellationToken ct = default);
    Task<DTOs.DataSourceDto?> UpdateAsync(Guid id, DTOs.UpdateDataSourceRequest request, CancellationToken ct = default);
    Task<bool> DeleteAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.ValidationResultDto> ValidateAsync(Guid id, CancellationToken ct = default);
    Task<DTOs.DataSourceHealthDto?> GetHealthAsync(Guid id, CancellationToken ct = default);
}

public interface IMetadataService
{
    Task<DTOs.MetadataRefreshResultDto> RefreshAsync(Guid dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.SchemaObjectDto>> GetObjectsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ColumnDefinitionDto>> GetColumnsAsync(Guid? schemaObjectId, Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ObjectRelationshipDto>> GetRelationshipsAsync(Guid? dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataRefreshResultDto>> GetRefreshHistoryAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IProcessingJobService
{
    Task<IReadOnlyList<DTOs.ProcessingJobDto>> GetAllAsync(CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto?> GetByIdAsync(Guid jobId, CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto> CreateAsync(DTOs.CreateProcessingJobRequest request, CancellationToken ct = default);
    Task<DTOs.ProcessingJobDto?> UpdateAsync(Guid jobId, DTOs.UpdateProcessingJobRequest request, CancellationToken ct = default);
    Task<DTOs.ExecuteJobResultDto> ExecuteAsync(Guid jobId, Enums.JobTriggerType trigger, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.JobExecutionDto>> GetExecutionsAsync(Guid jobId, CancellationToken ct = default);
    Task ProcessDueJobsAsync(CancellationToken ct = default);
}

public interface IReportService
{
    Task<object> GetReportAsync(string reportName, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<(byte[] Content, string ContentType, string FileName)> ExportReportAsync(string reportName, string format, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
}

public interface IDataProfiler
{
    Task<ProfilingRun> ProfileAsync(DataSource source, string? plaintextPassword, string triggerType, CancellationToken ct = default);
}

public interface IProfilingService
{
    Task<DTOs.ProfilingRunDto> ProfileAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default);
    Task<DTOs.ProfilingRunDto?> GetRunAsync(Guid runId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ProfilingRunDto>> GetRunsAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IQualityAssessmentService
{
    Task<DTOs.QualityAssessmentDto> AssessAsync(Guid dataSourceId, Guid? profilingRunId = null, CancellationToken ct = default);
    Task<DTOs.QualityAssessmentDto?> GetAssessmentAsync(Guid assessmentId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.QualityAssessmentDto>> GetAssessmentsAsync(Guid dataSourceId, CancellationToken ct = default);
}

public interface IMetadataSyncService
{
    Task<DTOs.MetadataSyncResultDto> SynchronizeAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.MetadataSyncResultDto>> GetSyncHistoryAsync(Guid dataSourceId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.SchemaChangeEventDto>> GetSchemaChangesAsync(Guid dataSourceId, CancellationToken ct = default);
    Task ArchiveHistoryAsync(int retainDays = 90, CancellationToken ct = default);
}

public interface IIngestionService
{
    Task<IReadOnlyList<DTOs.IngestDatasetDto>> GetDatasetsAsync(CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> CreateBatchAsync(DTOs.CreateImportBatchRequest request, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> ValidateBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> ProcessBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> RetryBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.ImportErrorDto>> GetErrorsByDatasetAsync(string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingBatchesAsync(int maxBatches = 10, CancellationToken ct = default);
    Task ArchiveImportHistoryAsync(int retainDays = 90, CancellationToken ct = default);
}

public interface IEtlService
{
    Task<DTOs.ImportBatchDto> RunPipelineAsync(Guid batchId, bool forceFail = false, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto> RetryAsync(Guid batchId, CancellationToken ct = default);
    Task<DTOs.ImportBatchDto?> GetBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByBatchAsync(Guid batchId, CancellationToken ct = default);
    Task<IReadOnlyList<DTOs.EtlErrorDto>> GetErrorsByDatasetAsync(string datasetCode, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default);
    Task<int> ProcessPendingAsync(int maxBatches = 10, CancellationToken ct = default);
    Task ArchiveErrorsAsync(int retainDays = 90, CancellationToken ct = default);
    Task CleanupBatchesAsync(int retainDays = 90, CancellationToken ct = default);
    Task GenerateQualitySnapshotAsync(CancellationToken ct = default);
    Task<Guid> GenerateTestBatchAsync(int rowCount = 1000, CancellationToken ct = default);
}
