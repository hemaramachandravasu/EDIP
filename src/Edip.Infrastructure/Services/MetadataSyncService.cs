using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Services;

public sealed class MetadataSyncService(
    IDataSourceRepository dataSourceRepository,
    IMetadataRepository metadataRepository,
    IConnectionProbeFactory probeFactory,
    ISecretProtector secretProtector,
    IQualityRepository qualityRepository) : IMetadataSyncService
{
    public async Task<MetadataSyncResultDto> SynchronizeAsync(Guid dataSourceId, string triggerType = "Manual", CancellationToken ct = default)
    {
        var source = await dataSourceRepository.GetByIdAsync(dataSourceId, ct)
            ?? throw new KeyNotFoundException($"Data source '{dataSourceId}' was not found.");

        var syncLogId = await qualityRepository.BeginSyncLogAsync(new MetadataSyncLog
        {
            DataSourceId = dataSourceId,
            TriggerType = triggerType
        }, ct);

        try
        {
            var beforeObjects = await metadataRepository.GetObjectsAsync(dataSourceId, ct);
            var beforeColumns = await metadataRepository.GetColumnsAsync(null, dataSourceId, ct);

            string? password = null;
            if (source.SqlConnection?.EncryptedPassword is not null)
            {
                try { password = secretProtector.Unprotect(source.SqlConnection.EncryptedPassword); }
                catch { /* ignore */ }
            }

            var probe = probeFactory.GetProbe(source.DataSourceTypeCode);
            var snapshot = await probe.CaptureMetadataAsync(source, password, ct);

            var changes = Diff(dataSourceId, beforeObjects, beforeColumns, snapshot);
            await metadataRepository.ReplaceSnapshotAsync(dataSourceId, snapshot, ct);
            await qualityRepository.AddSchemaChangesAsync(dataSourceId, syncLogId, changes, ct);

            var added = changes.Count(c => c.ChangeType is "ObjectAdded" or "ColumnAdded");
            var removed = changes.Count(c => c.ChangeType is "ObjectRemoved" or "ColumnRemoved");
            var typeChanged = changes.Count(c => c.ChangeType == "ColumnTypeChanged");

            await qualityRepository.CompleteSyncLogAsync(syncLogId, "Succeeded", added, removed, typeChanged, null, ct);

            // Also append classic refresh history for continuity
            var historyId = await metadataRepository.BeginRefreshAsync(dataSourceId, ct);
            await metadataRepository.CompleteRefreshAsync(historyId, "Succeeded",
                snapshot.Objects.Count, snapshot.Columns.Count, snapshot.Relationships.Count, null, ct);

            return new MetadataSyncResultDto
            {
                SyncLogId = syncLogId,
                DataSourceId = dataSourceId,
                Status = "Succeeded",
                ObjectsAdded = added,
                ObjectsRemoved = removed,
                ColumnsChanged = typeChanged,
                StartedUtc = DateTime.UtcNow,
                CompletedUtc = DateTime.UtcNow,
                Changes = changes.Select(MapChange).ToList()
            };
        }
        catch (Exception ex)
        {
            await qualityRepository.CompleteSyncLogAsync(syncLogId, "Failed", 0, 0, 0, ex.Message, ct);
            return new MetadataSyncResultDto
            {
                SyncLogId = syncLogId,
                DataSourceId = dataSourceId,
                Status = "Failed",
                ErrorMessage = ex.Message,
                StartedUtc = DateTime.UtcNow,
                CompletedUtc = DateTime.UtcNow
            };
        }
    }

    public async Task<IReadOnlyList<MetadataSyncResultDto>> GetSyncHistoryAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var logs = await qualityRepository.GetSyncLogsAsync(dataSourceId, 20, ct);
        return logs.Select(l => new MetadataSyncResultDto
        {
            SyncLogId = l.SyncLogId,
            DataSourceId = l.DataSourceId,
            Status = l.Status,
            ObjectsAdded = l.ObjectsAdded,
            ObjectsRemoved = l.ObjectsRemoved,
            ColumnsChanged = l.ColumnsChanged,
            ErrorMessage = l.ErrorMessage,
            StartedUtc = l.StartedUtc,
            CompletedUtc = l.CompletedUtc
        }).ToList();
    }

    public async Task<IReadOnlyList<SchemaChangeEventDto>> GetSchemaChangesAsync(Guid dataSourceId, CancellationToken ct = default)
    {
        var items = await qualityRepository.GetSchemaChangesAsync(dataSourceId, 50, ct);
        return items.Select(MapChange).ToList();
    }

    public Task ArchiveHistoryAsync(int retainDays = 90, CancellationToken ct = default)
        => qualityRepository.ArchiveHistoryAsync(retainDays, ct);

    private static List<SchemaChangeEvent> Diff(
        Guid dataSourceId,
        IReadOnlyList<SchemaObject> beforeObjects,
        IReadOnlyList<ColumnDefinition> beforeColumns,
        CapturedMetadataSnapshot after)
    {
        var changes = new List<SchemaChangeEvent>();
        var beforeObjKeys = beforeObjects.ToDictionary(
            o => Key(o.SchemaName, o.ObjectName, o.ObjectType.ToString()),
            o => o,
            StringComparer.OrdinalIgnoreCase);
        var afterObjKeys = after.Objects.ToDictionary(
            o => Key(o.SchemaName, o.ObjectName, o.ObjectType.ToString()),
            o => o,
            StringComparer.OrdinalIgnoreCase);

        foreach (var key in afterObjKeys.Keys.Except(beforeObjKeys.Keys, StringComparer.OrdinalIgnoreCase))
        {
            var o = afterObjKeys[key];
            changes.Add(Event(dataSourceId, "ObjectAdded", o.SchemaName, o.ObjectName, null, null, o.ObjectType.ToString()));
        }

        foreach (var key in beforeObjKeys.Keys.Except(afterObjKeys.Keys, StringComparer.OrdinalIgnoreCase))
        {
            var o = beforeObjKeys[key];
            changes.Add(Event(dataSourceId, "ObjectRemoved", o.SchemaName, o.ObjectName, null, o.ObjectType.ToString(), null));
        }

        // Column diffs keyed by schema.object.column using before object map + after object map names
        var beforeColLookup = new Dictionary<string, ColumnDefinition>(StringComparer.OrdinalIgnoreCase);
        foreach (var obj in beforeObjects)
        {
            foreach (var col in beforeColumns.Where(c => c.SchemaObjectId == obj.SchemaObjectId))
                beforeColLookup[Key(obj.SchemaName, obj.ObjectName, col.ColumnName)] = col;
        }

        var afterColLookup = new Dictionary<string, (SchemaObject Obj, ColumnDefinition Col)>(StringComparer.OrdinalIgnoreCase);
        foreach (var obj in after.Objects)
        {
            foreach (var col in after.Columns.Where(c => c.SchemaObjectId == obj.SchemaObjectId))
                afterColLookup[Key(obj.SchemaName, obj.ObjectName, col.ColumnName)] = (obj, col);
        }

        foreach (var key in afterColLookup.Keys.Except(beforeColLookup.Keys, StringComparer.OrdinalIgnoreCase))
        {
            var (obj, col) = afterColLookup[key];
            changes.Add(Event(dataSourceId, "ColumnAdded", obj.SchemaName, obj.ObjectName, col.ColumnName, null, col.DataType));
        }

        foreach (var key in beforeColLookup.Keys.Except(afterColLookup.Keys, StringComparer.OrdinalIgnoreCase))
        {
            // parse key parts carefully - Key uses '|'
            var parts = key.Split('|');
            changes.Add(Event(dataSourceId, "ColumnRemoved", parts[0], parts[1], parts.Length > 2 ? parts[2] : null,
                beforeColLookup[key].DataType, null));
        }

        foreach (var key in beforeColLookup.Keys.Intersect(afterColLookup.Keys, StringComparer.OrdinalIgnoreCase))
        {
            var before = beforeColLookup[key];
            var afterCol = afterColLookup[key];
            if (!string.Equals(before.DataType, afterCol.Col.DataType, StringComparison.OrdinalIgnoreCase))
            {
                changes.Add(Event(dataSourceId, "ColumnTypeChanged", afterCol.Obj.SchemaName, afterCol.Obj.ObjectName,
                    afterCol.Col.ColumnName, before.DataType, afterCol.Col.DataType));
            }
        }

        return changes;
    }

    private static string Key(params string[] parts) => string.Join('|', parts);

    private static SchemaChangeEvent Event(Guid ds, string type, string schema, string obj, string? col, string? oldV, string? newV)
        => new()
        {
            SchemaChangeId = Guid.NewGuid(),
            DataSourceId = ds,
            ChangeType = type,
            SchemaName = schema,
            ObjectName = obj,
            ColumnName = col,
            OldValue = oldV,
            NewValue = newV,
            DetectedUtc = DateTime.UtcNow
        };

    private static SchemaChangeEventDto MapChange(SchemaChangeEvent e) => new()
    {
        SchemaChangeId = e.SchemaChangeId,
        ChangeType = e.ChangeType,
        SchemaName = e.SchemaName,
        ObjectName = e.ObjectName,
        ColumnName = e.ColumnName,
        OldValue = e.OldValue,
        NewValue = e.NewValue,
        DetectedUtc = e.DetectedUtc
    };
}
