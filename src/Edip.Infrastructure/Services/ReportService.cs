using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class ReportService(
    IReportRepository reportRepository,
    IExportService exportService) : IReportService
{
    public async Task<object> GetReportAsync(string reportName, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        var (from, to) = NormalizeRange(fromUtc, toUtc);
        return reportName.ToLowerInvariant() switch
        {
            "processing-summary" or "processingsuccessfailuresummary" =>
                await reportRepository.GetProcessingSummaryAsync(from, to, ct),
            "datasource-health" or "datasourcehealthstatus" =>
                await reportRepository.GetDataSourceHealthAsync(ct),
            "job-stats" or "jobexecutionstatistics" =>
                await reportRepository.GetJobExecutionStatsAsync(from, to, ct),
            "metadata-refresh" or "metadatarefreshstatus" =>
                await reportRepository.GetMetadataRefreshStatusAsync(ct),
            "data-quality" or "dataqualitysummary" =>
                await reportRepository.GetDataQualitySummaryAsync(from, to, ct),
            "dataset-health" or "datasethealthstatus" =>
                await reportRepository.GetDatasetHealthAsync(ct),
            "schema-changes" or "schemachangehistory" =>
                await reportRepository.GetSchemaChangeHistoryAsync(from, to, ct),
            "metadata-sync" or "metadatasyncstatus" =>
                await reportRepository.GetMetadataSyncStatusAsync(ct),
            "quality-trend" or "qualitytrendanalysis" =>
                await reportRepository.GetQualityTrendAsync(from, to, ct),
            _ => throw new ArgumentException(
                $"Unknown report '{reportName}'. Valid: processing-summary, datasource-health, job-stats, metadata-refresh, data-quality, dataset-health, schema-changes, metadata-sync, quality-trend.")
        };
    }

    public async Task<(byte[] Content, string ContentType, string FileName)> ExportReportAsync(
        string reportName, string format, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        var data = await GetReportAsync(reportName, fromUtc, toUtc, ct);
        var safeName = reportName.Replace(' ', '-').ToLowerInvariant();
        var stamp = DateTime.UtcNow.ToString("yyyyMMddHHmmss");

        if (format.Equals("csv", StringComparison.OrdinalIgnoreCase))
            return (ExportDynamicCsv(data), "text/csv", $"{safeName}-{stamp}.csv");

        if (format.Equals("xlsx", StringComparison.OrdinalIgnoreCase) || format.Equals("excel", StringComparison.OrdinalIgnoreCase))
            return (ExportDynamicExcel(data, safeName),
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", $"{safeName}-{stamp}.xlsx");

        throw new ArgumentException("Unsupported export format. Use csv or xlsx.");
    }

    private byte[] ExportDynamicCsv(object data) => data switch
    {
        IEnumerable<Core.DTOs.ProcessingSummaryRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.DataSourceHealthRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.JobExecutionStatsRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.MetadataRefreshStatusRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.DataQualitySummaryRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.DatasetHealthRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.SchemaChangeHistoryRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.MetadataSyncStatusRow> rows => exportService.ExportToCsv(rows),
        IEnumerable<Core.DTOs.QualityTrendRow> rows => exportService.ExportToCsv(rows),
        _ => exportService.ExportToCsv(Array.Empty<object>())
    };

    private byte[] ExportDynamicExcel(object data, string sheet) => data switch
    {
        IEnumerable<Core.DTOs.ProcessingSummaryRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.DataSourceHealthRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.JobExecutionStatsRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.MetadataRefreshStatusRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.DataQualitySummaryRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.DatasetHealthRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.SchemaChangeHistoryRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.MetadataSyncStatusRow> rows => exportService.ExportToExcel(rows, sheet),
        IEnumerable<Core.DTOs.QualityTrendRow> rows => exportService.ExportToExcel(rows, sheet),
        _ => exportService.ExportToExcel(Array.Empty<object>(), sheet)
    };

    private static (DateTime From, DateTime To) NormalizeRange(DateTime? fromUtc, DateTime? toUtc)
    {
        var to = toUtc ?? DateTime.UtcNow;
        var from = fromUtc ?? to.AddDays(-30);
        return (from, to);
    }
}
