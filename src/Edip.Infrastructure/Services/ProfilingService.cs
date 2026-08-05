using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Services;

public sealed class ProfilingService(
    IDataSourceRepository dataSourceRepository,
    ISecretProtector secretProtector,
    IDataProfiler dataProfiler,
    IQualityRepository qualityRepository) : IProfilingService
{
    public async Task<ProfilingRunDto> ProfileAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default)
    {
        var source = await dataSourceRepository.GetByIdAsync(dataSourceId, ct)
            ?? throw new KeyNotFoundException($"Data source '{dataSourceId}' was not found.");

        string? password = null;
        if (source.SqlConnection?.EncryptedPassword is not null)
        {
            try { password = secretProtector.Unprotect(source.SqlConnection.EncryptedPassword); }
            catch { /* leave null for integrated auth */ }
        }

        var run = await dataProfiler.ProfileAsync(source, password, triggerType, ct);
        return Map(run);
    }

    public async Task<ProfilingRunDto?> GetRunAsync(Guid runId, CancellationToken ct = default)
    {
        var run = await qualityRepository.GetProfilingRunAsync(runId, ct);
        return run is null ? null : Map(run);
    }

    public async Task<IReadOnlyList<ProfilingRunDto>> GetRunsAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var runs = await qualityRepository.GetProfilingRunsAsync(dataSourceId, 20, ct);
        return runs.Select(Map).ToList();
    }

    private static ProfilingRunDto Map(ProfilingRun run) => new()
    {
        ProfilingRunId = run.ProfilingRunId,
        DataSourceId = run.DataSourceId,
        TriggerType = run.TriggerType,
        Status = run.Status,
        StartedUtc = run.StartedUtc,
        CompletedUtc = run.CompletedUtc,
        TablesProfiled = run.TablesProfiled,
        ColumnsProfiled = run.ColumnsProfiled,
        ErrorMessage = run.ErrorMessage,
        Tables = run.Tables.Select(t => new TableProfileDto
        {
            TableProfileId = t.TableProfileId,
            SchemaName = t.SchemaName,
            ObjectName = t.ObjectName,
            ObjectType = t.ObjectType,
            RowCountValue = t.RowCountValue,
            DuplicateRowCount = t.DuplicateRowCount,
            IsEmpty = t.IsEmpty,
            LastDataChangeUtc = t.LastDataChangeUtc,
            Columns = t.Columns.Select(c => new ColumnProfileDto
            {
                ColumnName = c.ColumnName,
                DataType = c.DataType,
                NullCount = c.NullCount,
                NullPct = c.NullPct,
                DistinctCount = c.DistinctCount,
                MinValue = c.MinValue,
                MaxValue = c.MaxValue,
                SampleInvalidCount = c.SampleInvalidCount
            }).ToList()
        }).ToList()
    };
}
