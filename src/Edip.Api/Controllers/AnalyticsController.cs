using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Edip.Api.Controllers;

/// <summary>
/// Task 19 - SQL Analytics &amp; Reporting Engine.
/// Thin HTTP surface over <see cref="IAnalyticsService"/>; every feed is
/// driven by a parameterised stored procedure (scripts 30-32).
/// </summary>
[ApiController]
[Route("api/analytics")]
public sealed class AnalyticsController(IAnalyticsService service) : ControllerBase
{
    private IActionResult Bad(string message) => BadRequest(new { error = message });

    // ---------------- maintenance ----------------

    [HttpPost("refresh")]
    public async Task<ActionResult<AnalyticsRefreshResultDto>> Refresh(
        [FromQuery] DateTime? fromDate, [FromQuery] DateTime? toDate, CancellationToken ct)
        => Ok(await service.RefreshAsync(fromDate, toDate, ct));

    // ---------------- dataset analytics ----------------

    [HttpGet("datasets/count-summary")]
    public async Task<ActionResult<DatasetCountSummaryDto>> DatasetCountSummary(
        [FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetDatasetCountSummaryAsync(workspaceId, ct));

    [HttpGet("datasets/count-by/{dimension}")]
    public async Task<IActionResult> DatasetCountByDimension(
        string dimension, [FromQuery] Guid? workspaceId, CancellationToken ct)
    {
        try { return Ok(await service.GetDatasetCountByDimensionAsync(dimension, workspaceId, ct)); }
        catch (ArgumentException ex) { return Bad(ex.Message); }
    }

    [HttpGet("datasets/recent")]
    public async Task<IActionResult> RecentDatasets(
        [FromQuery] string mode = "Created",
        [FromQuery] int days = 30,
        [FromQuery] int take = 20,
        [FromQuery] Guid? workspaceId = null,
        CancellationToken ct = default)
        => Ok(await service.GetRecentDatasetsAsync(mode, days, take, workspaceId, ct));

    [HttpGet("datasets/activity")]
    public async Task<IActionResult> DatasetActivity(
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        [FromQuery] Guid? workspaceId,
        [FromQuery] string? datasetCode,
        [FromQuery] int take = 500,
        CancellationToken ct = default)
        => Ok(await service.GetDatasetActivityAsync(fromUtc, toUtc, workspaceId, datasetCode, take, ct));

    // ---------------- import analytics ----------------

    [HttpGet("imports/summary")]
    public async Task<ActionResult<ImportAnalyticsSummaryDto>> ImportSummary(
        [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc,
        [FromQuery] Guid? workspaceId, [FromQuery] string? datasetCode, CancellationToken ct)
        => Ok(await service.GetImportAnalyticsSummaryAsync(fromUtc, toUtc, workspaceId, datasetCode, ct));

    [HttpGet("imports/volume-by-date")]
    public async Task<IActionResult> ImportVolumeByDate(
        [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc,
        [FromQuery] string granularity = "Day",
        [FromQuery] Guid? workspaceId = null, [FromQuery] string? datasetCode = null,
        CancellationToken ct = default)
        => Ok(await service.GetImportVolumeByDateAsync(fromUtc, toUtc, granularity, workspaceId, datasetCode, ct));

    [HttpGet("imports/volume-by-dataset")]
    public async Task<IActionResult> ImportVolumeByDataset(
        [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, [FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetImportVolumeByDatasetAsync(fromUtc, toUtc, workspaceId, ct));

    // ---------------- data quality analytics ----------------

    [HttpGet("quality/summary")]
    public async Task<ActionResult<QualityAnalyticsSummaryDto>> QualitySummary(
        [FromQuery] Guid? workspaceId, [FromQuery] string? datasetCode, CancellationToken ct)
        => Ok(await service.GetQualityAnalyticsSummaryAsync(workspaceId, datasetCode, ct));

    [HttpGet("quality/by-dataset")]
    public async Task<IActionResult> QualityByDataset([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetQualityByDatasetAsync(workspaceId, ct));

    [HttpGet("quality/lowest-scores")]
    public async Task<IActionResult> LowestQualityScores(
        [FromQuery] int take = 10, [FromQuery] Guid? workspaceId = null, CancellationToken ct = default)
        => Ok(await service.GetLowestQualityScoresAsync(take, workspaceId, ct));

    [HttpGet("quality/issue-breakdown")]
    public async Task<IActionResult> QualityIssueBreakdown(
        [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, [FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetQualityIssueBreakdownAsync(fromUtc, toUtc, workspaceId, ct));

    // ---------------- quality trend analysis ----------------

    [HttpGet("quality/trend/{datasetCode}")]
    public async Task<IActionResult> QualityTrend(
        string datasetCode,
        [FromQuery] string period = "Month",
        [FromQuery] DateTime? fromDate = null,
        [FromQuery] DateTime? toDate = null,
        CancellationToken ct = default)
    {
        try { return Ok(await service.GetQualityTrendSeriesAsync(datasetCode, period, fromDate, toDate, ct)); }
        catch (ArgumentException ex) { return Bad(ex.Message); }
    }

    [HttpGet("quality/profile-comparison/{datasetCode}")]
    public async Task<IActionResult> QualityProfileComparison(string datasetCode, CancellationToken ct)
    {
        try
        {
            var result = await service.GetQualityProfileComparisonAsync(datasetCode, ct);
            return result is null ? NotFound() : Ok(result);
        }
        catch (ArgumentException ex) { return Bad(ex.Message); }
    }

    [HttpGet("quality/period-comparison")]
    public async Task<IActionResult> QualityPeriodComparison(
        [FromQuery] string period = "Month",
        [FromQuery] string? datasetCode = null,
        [FromQuery] Guid? workspaceId = null,
        CancellationToken ct = default)
        => Ok(await service.GetQualityPeriodComparisonAsync(period, datasetCode, workspaceId, ct));

    // ---------------- dataset comparison ----------------

    [HttpGet("datasets/comparison")]
    public async Task<IActionResult> DatasetComparison(
        [FromQuery] string? datasetCodes = null,
        [FromQuery] Guid? workspaceId = null,
        [FromQuery] int windowDays = 30,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 50,
        CancellationToken ct = default)
        => Ok(await service.GetDatasetComparisonAsync(datasetCodes, workspaceId, windowDays, pageNumber, pageSize, ct));

    // ---------------- workspace analytics ----------------

    [HttpGet("workspaces")]
    public async Task<IActionResult> WorkspaceAnalytics(
        [FromQuery] Guid? workspaceId, [FromQuery] DateTime? fromUtc, [FromQuery] DateTime? toUtc, CancellationToken ct)
        => Ok(await service.GetWorkspaceAnalyticsAsync(workspaceId, fromUtc, toUtc, ct));

    // ---------------- time-based reporting ----------------

    [HttpGet("time-based")]
    public async Task<IActionResult> TimeBased(
        [FromQuery] DateTime? fromUtc,
        [FromQuery] DateTime? toUtc,
        [FromQuery] string granularity = "Day",
        [FromQuery] Guid? workspaceId = null,
        [FromQuery] string? datasetCode = null,
        CancellationToken ct = default)
        => Ok(await service.GetTimeBasedActivityAsync(fromUtc, toUtc, granularity, workspaceId, datasetCode, ct));

    [HttpGet("quarterly-trends")]
    public async Task<IActionResult> QuarterlyTrends(
        [FromQuery] Guid? workspaceId, [FromQuery] int quarters = 8, CancellationToken ct = default)
        => Ok(await service.GetQuarterlyTrendsAsync(workspaceId, quarters, ct));

    // ---------------- dashboard feeds ----------------

    [HttpGet("dashboard/kpi-cards")]
    public async Task<ActionResult<DashboardKpiCardsDto>> KpiCards([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetDashboardKpiCardsAsync(workspaceId, ct));

    [HttpGet("dashboard/trend-chart")]
    public async Task<IActionResult> TrendChart(
        [FromQuery] string? datasetCode, [FromQuery] int days = 90, [FromQuery] Guid? workspaceId = null, CancellationToken ct = default)
        => Ok(await service.GetDashboardTrendChartAsync(datasetCode, days, workspaceId, ct));

    [HttpGet("dashboard/quality-distribution")]
    public async Task<IActionResult> QualityDistribution([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetDashboardQualityDistributionAsync(workspaceId, ct));

    [HttpGet("dashboard/dataset-distribution")]
    public async Task<IActionResult> DatasetDistribution([FromQuery] Guid? workspaceId, CancellationToken ct)
        => Ok(await service.GetDashboardDatasetDistributionAsync(workspaceId, ct));

    [HttpGet("dashboard/import-activity")]
    public async Task<IActionResult> ImportActivity(
        [FromQuery] int days = 30, [FromQuery] Guid? workspaceId = null, CancellationToken ct = default)
        => Ok(await service.GetDashboardImportActivityAsync(days, workspaceId, ct));

    [HttpGet("dashboard/top-quality-issues")]
    public async Task<IActionResult> TopQualityIssues(
        [FromQuery] int take = 10, [FromQuery] Guid? workspaceId = null, [FromQuery] int days = 30, CancellationToken ct = default)
        => Ok(await service.GetDashboardTopQualityIssuesAsync(take, workspaceId, days, ct));

    [HttpGet("dashboard/workspace-summary")]
    public async Task<IActionResult> WorkspaceSummary(CancellationToken ct)
        => Ok(await service.GetWorkspaceAnalyticsAsync(null, null, null, ct));

    // ---------------- export ----------------

    [HttpGet("export/{feed}")]
    public async Task<IActionResult> Export(
        string feed,
        [FromQuery] string format = "csv",
        [FromQuery] DateTime? fromUtc = null,
        [FromQuery] DateTime? toUtc = null,
        [FromQuery] Guid? workspaceId = null,
        [FromQuery] string? datasetCode = null,
        CancellationToken ct = default)
    {
        try
        {
            var (content, contentType, fileName) = await service.ExportAsync(feed, format, fromUtc, toUtc, workspaceId, datasetCode, ct);
            return File(content, contentType, fileName);
        }
        catch (ArgumentException ex) { return Bad(ex.Message); }
    }
}
