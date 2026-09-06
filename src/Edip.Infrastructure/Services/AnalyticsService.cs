using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class AnalyticsService(
    IAnalyticsRepository repository,
    IExportService exportService) : IAnalyticsService
{
    private static (DateTime From, DateTime To) Range(DateTime? fromUtc, DateTime? toUtc, int defaultDays = 30)
    {
        var to = toUtc ?? DateTime.UtcNow;
        var from = fromUtc ?? to.AddDays(-defaultDays);
        return (from, to);
    }

    private static string NormalizeGranularity(string? g) => (g ?? "Day").Trim().ToLowerInvariant() switch
    {
        "day" or "daily" or "d" => "Day",
        "week" or "weekly" or "w" => "Week",
        "month" or "monthly" or "m" => "Month",
        "quarter" or "quarterly" or "q" => "Quarter",
        _ => "Day"
    };

    private static string NormalizePeriod(string? p)
        => string.IsNullOrWhiteSpace(p) ? "Month" : NormalizeGranularity(p);

    public Task<AnalyticsRefreshResultDto> RefreshAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct = default)
        => RefreshInternalAsync(fromDate, toDate, ct);

    private async Task<AnalyticsRefreshResultDto> RefreshInternalAsync(DateTime? fromDate, DateTime? toDate, CancellationToken ct)
    {
        var metrics = await repository.RefreshDailyMetricsAsync(fromDate, toDate, ct);
        metrics.SnapshotsMerged = await repository.SnapshotQualityTrendAsync(fromDate, toDate, ct);
        return metrics;
    }

    // ----- dataset analytics -----

    public Task<DatasetCountSummaryDto> GetDatasetCountSummaryAsync(Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDatasetCountSummaryAsync(workspaceId, ct);

    public Task<IReadOnlyList<DimensionCountRow>> GetDatasetCountByDimensionAsync(string dimension, Guid? workspaceId, CancellationToken ct = default)
    {
        var dim = (dimension ?? string.Empty).Trim();
        dim = dim.Length == 0 ? "Status"
            : char.ToUpperInvariant(dim[0]) + dim[1..].ToLowerInvariant();
        if (dim is not ("Status" or "Category" or "Workspace" or "Owner"))
            throw new ArgumentException("dimension must be one of: Status, Category, Workspace, Owner.");
        return repository.GetDatasetCountByDimensionAsync(dim, workspaceId, ct);
    }

    public Task<IReadOnlyList<RecentDatasetRow>> GetRecentDatasetsAsync(string mode, int days, int take, Guid? workspaceId, CancellationToken ct = default)
    {
        var m = (mode ?? "Created").Trim().ToLowerInvariant() == "modified" ? "Modified" : "Created";
        days = days is >= 1 and <= 365 ? days : 30;
        take = take is >= 1 and <= 500 ? take : 20;
        return repository.GetRecentDatasetsAsync(m, DateTime.UtcNow.AddDays(-days), take, workspaceId, ct);
    }

    public Task<IReadOnlyList<DatasetActivityRow>> GetDatasetActivityAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, int take, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc);
        take = take is >= 1 and <= 5000 ? take : 500;
        return repository.GetDatasetActivityAsync(from, to, workspaceId, datasetCode, take, ct);
    }

    // ----- import analytics -----

    public Task<ImportAnalyticsSummaryDto> GetImportAnalyticsSummaryAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc);
        return repository.GetImportAnalyticsSummaryAsync(from, to, workspaceId, datasetCode, ct);
    }

    public Task<IReadOnlyList<ImportVolumeRow>> GetImportVolumeByDateAsync(DateTime? fromUtc, DateTime? toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc, 90);
        return repository.GetImportVolumeByDateAsync(from, to, NormalizeGranularity(granularity), workspaceId, datasetCode, ct);
    }

    public Task<IReadOnlyList<ImportVolumeByDatasetRow>> GetImportVolumeByDatasetAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc);
        return repository.GetImportVolumeByDatasetAsync(from, to, workspaceId, ct);
    }

    // ----- quality analytics -----

    public Task<QualityAnalyticsSummaryDto> GetQualityAnalyticsSummaryAsync(Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
        => repository.GetQualityAnalyticsSummaryAsync(workspaceId, datasetCode, ct);

    public Task<IReadOnlyList<QualityByDatasetRow>> GetQualityByDatasetAsync(Guid? workspaceId, CancellationToken ct = default)
        => repository.GetQualityByDatasetAsync(workspaceId, ct);

    public Task<IReadOnlyList<QualityByDatasetRow>> GetLowestQualityScoresAsync(int take, Guid? workspaceId, CancellationToken ct = default)
        => repository.GetLowestQualityScoresAsync(take is >= 1 and <= 200 ? take : 10, workspaceId, ct);

    public Task<IReadOnlyList<QualityIssueBreakdownRow>> GetQualityIssueBreakdownAsync(DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc);
        return repository.GetQualityIssueBreakdownAsync(from, to, workspaceId, ct);
    }

    // ----- trend analysis -----

    public Task<IReadOnlyList<QualityTrendSeriesRow>> GetQualityTrendSeriesAsync(string datasetCode, string periodType, DateTime? fromDate, DateTime? toDate, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(datasetCode)) throw new ArgumentException("datasetCode is required.");
        return repository.GetQualityTrendSeriesAsync(datasetCode, NormalizePeriod(periodType), fromDate, toDate, ct);
    }

    public Task<QualityProfileComparisonDto?> GetQualityProfileComparisonAsync(string datasetCode, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(datasetCode)) throw new ArgumentException("datasetCode is required.");
        return repository.GetQualityProfileComparisonAsync(datasetCode, ct);
    }

    public Task<IReadOnlyList<QualityPeriodComparisonRow>> GetQualityPeriodComparisonAsync(string periodType, string? datasetCode, Guid? workspaceId, CancellationToken ct = default)
        => repository.GetQualityPeriodComparisonAsync(NormalizePeriod(periodType), datasetCode, workspaceId, ct);

    // ----- comparison / workspace / time -----

    public Task<IReadOnlyList<DatasetComparisonRow>> GetDatasetComparisonAsync(string? datasetCodes, Guid? workspaceId, int windowDays, int pageNumber, int pageSize, CancellationToken ct = default)
        => repository.GetDatasetComparisonAsync(
            string.IsNullOrWhiteSpace(datasetCodes) ? null : datasetCodes,
            workspaceId,
            windowDays is >= 1 and <= 365 ? windowDays : 30,
            pageNumber >= 1 ? pageNumber : 1,
            pageSize is >= 1 and <= 500 ? pageSize : 50,
            ct);

    public Task<IReadOnlyList<WorkspaceAnalyticsRow>> GetWorkspaceAnalyticsAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
        => repository.GetWorkspaceAnalyticsAsync(workspaceId, fromUtc, toUtc, ct);

    public Task<IReadOnlyList<TimeBasedActivityRow>> GetTimeBasedActivityAsync(DateTime? fromUtc, DateTime? toUtc, string granularity, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc, 90);
        return repository.GetTimeBasedActivityAsync(from, to, NormalizeGranularity(granularity), workspaceId, datasetCode, ct);
    }

    public Task<IReadOnlyList<QuarterlyTrendRow>> GetQuarterlyTrendsAsync(Guid? workspaceId, int quarters, CancellationToken ct = default)
        => repository.GetQuarterlyTrendsAsync(workspaceId, quarters is >= 1 and <= 40 ? quarters : 8, ct);

    // ----- dashboard feeds -----

    public Task<DashboardKpiCardsDto> GetDashboardKpiCardsAsync(Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDashboardKpiCardsAsync(workspaceId, ct);

    public Task<IReadOnlyList<DashboardTrendPointRow>> GetDashboardTrendChartAsync(string? datasetCode, int days, Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDashboardTrendChartAsync(datasetCode, days is >= 1 and <= 730 ? days : 90, workspaceId, ct);

    public Task<IReadOnlyList<QualityDistributionRow>> GetDashboardQualityDistributionAsync(Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDashboardQualityDistributionAsync(workspaceId, ct);

    public Task<IReadOnlyList<DatasetDistributionRow>> GetDashboardDatasetDistributionAsync(Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDashboardDatasetDistributionAsync(workspaceId, ct);

    public Task<IReadOnlyList<DashboardImportActivityRow>> GetDashboardImportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default)
        => repository.GetDashboardImportActivityAsync(days is >= 1 and <= 365 ? days : 30, workspaceId, ct);

    public Task<IReadOnlyList<DashboardTopIssueRow>> GetDashboardTopQualityIssuesAsync(int take, Guid? workspaceId, int days, CancellationToken ct = default)
        => repository.GetDashboardTopQualityIssuesAsync(
            take is >= 1 and <= 100 ? take : 10, workspaceId, days is >= 1 and <= 365 ? days : 30, ct);

    // ----- export -----

    public async Task<(byte[] Content, string ContentType, string FileName)> ExportAsync(
        string feed, string format, DateTime? fromUtc, DateTime? toUtc, Guid? workspaceId, string? datasetCode, CancellationToken ct = default)
    {
        var (from, to) = Range(fromUtc, toUtc);
        var safe = (feed ?? string.Empty).Replace(' ', '-').ToLowerInvariant();
        var stamp = DateTime.UtcNow.ToString("yyyyMMddHHmmss");

        var (rows, kind) = safe switch
        {
            "dataset-inventory" or "datasetinventory" =>
                ((object)await repository.GetDatasetInventoryExportAsync(workspaceId, ct), "dataset-inventory"),
            "import-detail" or "importdetail" =>
                (await repository.GetImportDetailExportAsync(from, to, workspaceId, datasetCode, ct), "import-detail"),
            "quality-detail" or "qualitydetail" =>
                (await repository.GetQualityDetailExportAsync(from, to, workspaceId, datasetCode, ct), "quality-detail"),
            _ => throw new ArgumentException("Unknown export feed. Valid: dataset-inventory, import-detail, quality-detail.")
        };

        byte[] content;
        string contentType;
        string ext;
        if (format.Equals("xlsx", StringComparison.OrdinalIgnoreCase) || format.Equals("excel", StringComparison.OrdinalIgnoreCase))
        {
            content = ExcelFor(rows, kind);
            contentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
            ext = "xlsx";
        }
        else if (format.Equals("csv", StringComparison.OrdinalIgnoreCase))
        {
            content = CsvFor(rows);
            contentType = "text/csv";
            ext = "csv";
        }
        else
        {
            throw new ArgumentException("Unsupported export format. Use csv or xlsx.");
        }

        return (content, contentType, $"analytics-{kind}-{stamp}.{ext}");
    }

    private byte[] CsvFor(object rows) => rows switch
    {
        IEnumerable<DatasetInventoryExportRow> r => exportService.ExportToCsv(r),
        IEnumerable<ImportDetailExportRow> r => exportService.ExportToCsv(r),
        IEnumerable<QualityDetailExportRow> r => exportService.ExportToCsv(r),
        _ => exportService.ExportToCsv(Array.Empty<object>())
    };

    private byte[] ExcelFor(object rows, string sheet) => rows switch
    {
        IEnumerable<DatasetInventoryExportRow> r => exportService.ExportToExcel(r, sheet),
        IEnumerable<ImportDetailExportRow> r => exportService.ExportToExcel(r, sheet),
        IEnumerable<QualityDetailExportRow> r => exportService.ExportToExcel(r, sheet),
        _ => exportService.ExportToExcel(Array.Empty<object>(), sheet)
    };
}
