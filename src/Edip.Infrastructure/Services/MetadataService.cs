using Edip.Core.DTOs;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Services;

public sealed class MetadataService(
    IDataSourceRepository dataSourceRepository,
    IMetadataRepository metadataRepository,
    IConnectionProbeFactory probeFactory,
    ISecretProtector secretProtector) : IMetadataService
{
    public async Task<MetadataRefreshResultDto> RefreshAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var source = await dataSourceRepository.GetByIdAsync(dataSourceId, ct)
            ?? throw new KeyNotFoundException($"Data source '{dataSourceId}' was not found.");

        var historyId = await metadataRepository.BeginRefreshAsync(dataSourceId, ct);
        var started = DateTime.UtcNow;

        try
        {
            string? password = null;
            if (source.SqlConnection?.EncryptedPassword is not null)
            {
                try { password = secretProtector.Unprotect(source.SqlConnection.EncryptedPassword); }
                catch { /* leave null */ }
            }

            var probe = probeFactory.GetProbe(source.DataSourceTypeCode);
            var snapshot = await probe.CaptureMetadataAsync(source, password, ct);
            await metadataRepository.ReplaceSnapshotAsync(dataSourceId, snapshot, ct);
            await metadataRepository.CompleteRefreshAsync(
                historyId, "Succeeded",
                snapshot.Objects.Count, snapshot.Columns.Count, snapshot.Relationships.Count,
                null, ct);

            return new MetadataRefreshResultDto
            {
                RefreshHistoryId = historyId,
                DataSourceId = dataSourceId,
                Status = "Succeeded",
                ObjectsCaptured = snapshot.Objects.Count,
                ColumnsCaptured = snapshot.Columns.Count,
                RelationshipsCaptured = snapshot.Relationships.Count,
                StartedUtc = started,
                CompletedUtc = DateTime.UtcNow
            };
        }
        catch (Exception ex)
        {
            await metadataRepository.CompleteRefreshAsync(historyId, "Failed", 0, 0, 0, ex.Message, ct);
            return new MetadataRefreshResultDto
            {
                RefreshHistoryId = historyId,
                DataSourceId = dataSourceId,
                Status = "Failed",
                ErrorMessage = ex.Message,
                StartedUtc = started,
                CompletedUtc = DateTime.UtcNow
            };
        }
    }

    public async Task<IReadOnlyList<SchemaObjectDto>> GetObjectsAsync(Guid? dataSourceId, CancellationToken ct = default)
    {
        var items = await metadataRepository.GetObjectsAsync(dataSourceId, ct);
        return items.Select(o => new SchemaObjectDto
        {
            SchemaObjectId = o.SchemaObjectId,
            DataSourceId = o.DataSourceId,
            SchemaName = o.SchemaName,
            ObjectName = o.ObjectName,
            ObjectType = o.ObjectType.ToString(),
            CapturedUtc = o.CapturedUtc
        }).ToList();
    }

    public async Task<IReadOnlyList<ColumnDefinitionDto>> GetColumnsAsync(Guid? schemaObjectId, Guid? dataSourceId, CancellationToken ct = default)
    {
        var items = await metadataRepository.GetColumnsAsync(schemaObjectId, dataSourceId, ct);
        return items.Select(c => new ColumnDefinitionDto
        {
            ColumnDefinitionId = c.ColumnDefinitionId,
            SchemaObjectId = c.SchemaObjectId,
            ColumnName = c.ColumnName,
            DataType = c.DataType,
            MaxLength = c.MaxLength,
            NumericPrecision = c.NumericPrecision,
            NumericScale = c.NumericScale,
            IsNullable = c.IsNullable,
            OrdinalPosition = c.OrdinalPosition,
            IsPrimaryKey = c.IsPrimaryKey,
            IsForeignKey = c.IsForeignKey
        }).ToList();
    }

    public async Task<IReadOnlyList<ObjectRelationshipDto>> GetRelationshipsAsync(Guid? dataSourceId, CancellationToken ct = default)
    {
        var items = await metadataRepository.GetRelationshipsAsync(dataSourceId, ct);
        return items.Select(r => new ObjectRelationshipDto
        {
            RelationshipId = r.RelationshipId,
            DataSourceId = r.DataSourceId,
            ParentObjectId = r.ParentObjectId,
            ChildObjectId = r.ChildObjectId,
            ParentColumnName = r.ParentColumnName,
            ChildColumnName = r.ChildColumnName,
            ConstraintName = r.ConstraintName
        }).ToList();
    }

    public async Task<IReadOnlyList<MetadataRefreshResultDto>> GetRefreshHistoryAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var items = await metadataRepository.GetRefreshHistoryAsync(dataSourceId, 20, ct);
        return items.Select(h => new MetadataRefreshResultDto
        {
            RefreshHistoryId = h.RefreshHistoryId,
            DataSourceId = h.DataSourceId,
            Status = h.Status,
            ObjectsCaptured = h.ObjectsCaptured,
            ColumnsCaptured = h.ColumnsCaptured,
            RelationshipsCaptured = h.RelationshipsCaptured,
            ErrorMessage = h.ErrorMessage,
            StartedUtc = h.StartedUtc,
            CompletedUtc = h.CompletedUtc
        }).ToList();
    }
}
