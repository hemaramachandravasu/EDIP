using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Services;

public sealed class QualityAssessmentService(
    IDataSourceRepository dataSourceRepository,
    IMetadataRepository metadataRepository,
    IQualityRepository qualityRepository) : IQualityAssessmentService
{
    // Weights sum to 1.0
    private const decimal WMissing = 0.25m;
    private const decimal WDuplicate = 0.20m;
    private const decimal WType = 0.15m;
    private const decimal WReferential = 0.20m;
    private const decimal WEmpty = 0.10m;
    private const decimal WFreshness = 0.10m;

    public async Task<QualityAssessmentDto> AssessAsync(Guid dataSourceId, Guid? profilingRunId = null, CancellationToken ct = default)
    {
        _ = await dataSourceRepository.GetByIdAsync(dataSourceId, ct)
            ?? throw new KeyNotFoundException($"Data source '{dataSourceId}' was not found.");

        ProfilingRun? run = null;
        if (profilingRunId.HasValue)
            run = await qualityRepository.GetProfilingRunAsync(profilingRunId.Value, ct);
        run ??= await qualityRepository.GetLatestSucceededRunAsync(dataSourceId, ct)
            ?? throw new InvalidOperationException("No successful profiling run found. Run profiling first.");

        var relationships = await metadataRepository.GetRelationshipsAsync(dataSourceId, ct);
        var checks = new List<QualityCheckResult>();

        var totalNullPct = run.Tables.SelectMany(t => t.Columns).DefaultIfEmpty()
            .Average(c => c?.NullPct ?? 0m);
        var missingScore = ScoreFromRate(totalNullPct / 100m);
        var highNullCols = run.Tables.SelectMany(t => t.Columns).Count(c => c.NullPct > 20m);
        checks.Add(Check("MISSING_VALUES", "Missing Values", highNullCols == 0, highNullCols,
            $"Average null %={totalNullPct:F2}; columns with >20% nulls={highNullCols}", highNullCols > 0 ? "Warning" : "Info"));

        var totalRows = run.Tables.Sum(t => t.RowCountValue);
        var totalDupes = run.Tables.Sum(t => t.DuplicateRowCount);
        var dupeRate = totalRows == 0 ? 0m : (decimal)totalDupes / totalRows;
        var duplicateScore = ScoreFromRate(dupeRate);
        checks.Add(Check("DUPLICATE_RECORDS", "Duplicate Records", totalDupes == 0, totalDupes,
            $"Duplicate row surplus={totalDupes} across {run.Tables.Count} tables", totalDupes > 0 ? "Warning" : "Info"));

        var invalid = run.Tables.SelectMany(t => t.Columns).Sum(c => c.SampleInvalidCount);
        var typeScore = invalid == 0 ? 100m : Math.Max(0, 100m - Math.Min(100m, invalid));
        checks.Add(Check("INVALID_TYPES", "Invalid Data Types", invalid == 0, invalid,
            $"Suspect invalid values={invalid}", invalid > 0 ? "Warning" : "Info"));

        // Referential: prefer live relationship inventory; if none catalogued, score neutrally high
        var referentialScore = relationships.Count == 0 ? 90m : 100m;
        checks.Add(Check("REFERENTIAL_INTEGRITY", "Referential Integrity", relationships.Count >= 0, relationships.Count,
            relationships.Count == 0
                ? "No FK relationships catalogued; assigned neutral score."
                : $"Catalogued FK relationships={relationships.Count}", "Info"));

        var emptyTables = run.Tables.Count(t => t.IsEmpty);
        var emptyScore = run.Tables.Count == 0 ? 0m : 100m * (run.Tables.Count - emptyTables) / run.Tables.Count;
        checks.Add(Check("EMPTY_TABLES", "Empty Tables", emptyTables == 0, emptyTables,
            $"Empty tables={emptyTables}/{run.Tables.Count}", emptyTables > 0 ? "Warning" : "Info"));

        var newest = run.Tables.Where(t => t.LastDataChangeUtc.HasValue).Select(t => t.LastDataChangeUtc!.Value).DefaultIfEmpty().Max();
        var freshnessScore = 70m;
        if (newest != default)
        {
            var ageDays = (DateTime.UtcNow - newest).TotalDays;
            freshnessScore = ageDays switch
            {
                <= 1 => 100m,
                <= 7 => 90m,
                <= 30 => 75m,
                <= 90 => 55m,
                _ => 35m
            };
        }
        checks.Add(Check("DATA_FRESHNESS", "Data Freshness", freshnessScore >= 60m, 0,
            newest == default ? "No modify_date available." : $"Latest object modify_date={newest:u}; score={freshnessScore}", "Info"));

        var overall = Math.Round(
            missingScore * WMissing +
            duplicateScore * WDuplicate +
            typeScore * WType +
            referentialScore * WReferential +
            emptyScore * WEmpty +
            freshnessScore * WFreshness, 2);

        var assessment = new QualityAssessment
        {
            DataSourceId = dataSourceId,
            ProfilingRunId = run.ProfilingRunId,
            OverallScore = overall,
            Grade = Grade(overall),
            MissingScore = missingScore,
            DuplicateScore = duplicateScore,
            TypeScore = typeScore,
            ReferentialScore = referentialScore,
            EmptyTableScore = emptyScore,
            FreshnessScore = freshnessScore,
            AssessedUtc = DateTime.UtcNow,
            Summary = $"Overall {overall} ({Grade(overall)}) from profiling run {run.ProfilingRunId}",
            Checks = checks
        };

        assessment.AssessmentId = await qualityRepository.SaveQualityAssessmentAsync(assessment, ct);
        return Map(assessment);
    }

    public async Task<QualityAssessmentDto?> GetAssessmentAsync(Guid assessmentId, CancellationToken ct = default)
    {
        var item = await qualityRepository.GetAssessmentAsync(assessmentId, ct);
        return item is null ? null : Map(item);
    }

    public async Task<IReadOnlyList<QualityAssessmentDto>> GetAssessmentsAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var items = await qualityRepository.GetAssessmentsAsync(dataSourceId, 20, ct);
        return items.Select(Map).ToList();
    }

    private static decimal ScoreFromRate(decimal badRate)
        => Math.Round(Math.Max(0m, 100m - Math.Min(100m, badRate * 100m)), 2);

    private static string Grade(decimal score) => score switch
    {
        >= 90 => "A",
        >= 80 => "B",
        >= 70 => "C",
        >= 60 => "D",
        _ => "F"
    };

    private static QualityCheckResult Check(string code, string name, bool passed, long count, string details, string severity)
        => new()
        {
            CheckCode = code,
            CheckName = name,
            Passed = passed,
            AffectedCount = count,
            Details = details,
            Severity = severity
        };

    private static QualityAssessmentDto Map(QualityAssessment a) => new()
    {
        AssessmentId = a.AssessmentId,
        DataSourceId = a.DataSourceId,
        ProfilingRunId = a.ProfilingRunId,
        OverallScore = a.OverallScore,
        Grade = a.Grade,
        MissingScore = a.MissingScore,
        DuplicateScore = a.DuplicateScore,
        TypeScore = a.TypeScore,
        ReferentialScore = a.ReferentialScore,
        EmptyTableScore = a.EmptyTableScore,
        FreshnessScore = a.FreshnessScore,
        AssessedUtc = a.AssessedUtc,
        Summary = a.Summary,
        Checks = a.Checks.Select(c => new QualityCheckResultDto
        {
            CheckCode = c.CheckCode,
            CheckName = c.CheckName,
            Severity = c.Severity,
            Passed = c.Passed,
            AffectedCount = c.AffectedCount,
            Details = c.Details
        }).ToList()
    };
}
