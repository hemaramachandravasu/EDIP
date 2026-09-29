using System.Data;
using Edip.Core.DTOs;
using Edip.Core.Interfaces;
using Edip.Infrastructure.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Repositories;

public sealed class SharingRepository(ISqlConnectionFactory connectionFactory) : ISharingRepository
{
    private const int Timeout = 120;

    // ---------------- Shares ----------------

    public async Task<ShareActionResult> CreateShareAsync(CreateShareRequest request, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_CreateDatasetShare");
        cmd.Parameters.AddWithValue("@DatasetCode", request.DatasetCode);
        cmd.Parameters.AddWithValue("@RecipientUserName", request.RecipientUserName);
        cmd.Parameters.AddWithValue("@AccessLevelCode", request.AccessLevelCode);
        cmd.Parameters.AddWithValue("@SharedByUserName", request.SharedByUserName);
        cmd.Parameters.AddNullable("@ExpiresUtc", request.ExpiresUtc);
        cmd.Parameters.AddNullable("@Notes", request.Notes);
        var id = cmd.Parameters.Add(OutGuid("@ShareId"));
        var (code, msg) = AddStatus(cmd);

        DatasetShareDto? share = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct)) share = MapShare(reader);
        }

        return new ShareActionResult
        {
            ShareId = id.Value is Guid g ? g : share?.ShareId,
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Share = share
        };
    }

    public async Task<ShareActionResult> UpdateShareAsync(Guid shareId, UpdateShareRequest request, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_UpdateDatasetShare");
        cmd.Parameters.AddWithValue("@ShareId", shareId);
        cmd.Parameters.AddWithValue("@ActorUserName", request.ActorUserName);
        cmd.Parameters.AddNullable("@AccessLevelCode", request.AccessLevelCode);
        cmd.Parameters.AddNullable("@ExpiresUtc", request.ExpiresUtc);
        cmd.Parameters.AddWithValue("@ClearExpiry", request.ClearExpiry);
        cmd.Parameters.AddNullable("@Comments", request.Comments);
        return await ExecuteShareActionAsync(cmd, shareId, ct);
    }

    public async Task<ShareActionResult> RevokeShareAsync(Guid shareId, RevokeShareRequest request, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_RevokeDatasetShare");
        cmd.Parameters.AddWithValue("@ShareId", shareId);
        cmd.Parameters.AddWithValue("@ActorUserName", request.ActorUserName);
        cmd.Parameters.AddNullable("@RevokeReason", request.RevokeReason);
        return await ExecuteShareActionAsync(cmd, shareId, ct);
    }

    public async Task<DatasetShareDto?> GetShareAsync(Guid shareId, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetShare");
        cmd.Parameters.AddWithValue("@ShareId", shareId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? MapShare(reader) : null;
    }

    public async Task<IReadOnlyList<DatasetShareDto>> GetActiveSharesAsync(
        string? datasetCode, string? recipientUserName, Guid? workspaceId, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetActiveShares");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@RecipientUserName", recipientUserName);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        return await ReadListAsync(cmd, MapShare, ct);
    }

    public async Task<PagedList<DatasetShareDto>> GetSharesAsync(
        string? datasetCode, string? recipientUserName, Guid? workspaceId, string? effectiveStatus,
        int pageNumber, int pageSize, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetShares");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@RecipientUserName", recipientUserName);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddNullable("@EffectiveStatus", effectiveStatus);
        cmd.Parameters.AddWithValue("@PageNumber", pageNumber);
        cmd.Parameters.AddWithValue("@PageSize", pageSize);

        var items = new List<DatasetShareDto>();
        var total = 0;
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            items.Add(MapShare(reader));
            total = Int(reader, "TotalCount");
        }
        return new PagedList<DatasetShareDto> { Items = items, PageNumber = pageNumber, PageSize = pageSize, TotalCount = total };
    }

    public async Task<IReadOnlyList<DatasetShareDto>> GetExpiredSharesAsync(Guid? workspaceId, bool onlyUnmarked, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetExpiredShares");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddWithValue("@OnlyUnmarked", onlyUnmarked);
        return await ReadListAsync(cmd, MapShare, ct);
    }

    public async Task<IReadOnlyList<ShareHistoryRow>> GetShareHistoryAsync(
        Guid? shareId, string? datasetCode, string? recipientUserName, int take, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetShareHistory");
        cmd.Parameters.AddNullable("@ShareId", shareId);
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddNullable("@RecipientUserName", recipientUserName);
        cmd.Parameters.AddWithValue("@Take", take);
        return await ReadListAsync(cmd, r => new ShareHistoryRow
        {
            ShareHistoryId = r.GetInt64("ShareHistoryId"),
            ShareId = r.GetGuid("ShareId"),
            DatasetCode = r.GetString("DatasetCode"),
            RecipientUserName = r.GetString("RecipientUserName"),
            Action = r.GetString("Action"),
            PreviousStatus = r.GetNullableString("PreviousStatus"),
            NewStatus = r.GetString("NewStatus"),
            PreviousAccessLevel = r.GetNullableString("PreviousAccessLevel"),
            NewAccessLevel = r.GetString("NewAccessLevel"),
            PreviousExpiresUtc = r.GetNullableDateTime("PreviousExpiresUtc"),
            NewExpiresUtc = r.GetNullableDateTime("NewExpiresUtc"),
            ActorUserName = r.GetNullableString("ActorUserName"),
            ActionUtc = r.GetDateTime("ActionUtc"),
            Comments = r.GetNullableString("Comments")
        }, ct);
    }

    public async Task<int> ExpireSharesAsync(CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_ExpireDatasetShares");
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Int(reader, "ExpiredCount") : 0;
    }

    // ---------------- Authorization / columns ----------------

    public async Task<ExportAccessEvaluationDto> EvaluateExportAccessAsync(string datasetCode, string userName, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_EvaluateExportAccess");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@UserName", userName);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct))
            return new ExportAccessEvaluationDto { DecisionCode = "NoResult", Reason = "No evaluation result." };

        return new ExportAccessEvaluationDto
        {
            IsAllowed = reader.GetBoolean("IsAllowed"),
            DecisionCode = reader.GetString("DecisionCode"),
            Reason = reader.GetString("Reason"),
            DatasetCode = reader.GetNullableString("DatasetCode"),
            UserName = reader.GetNullableString("UserName"),
            WorkspaceId = reader.GetNullableGuid("WorkspaceId"),
            ClassificationCode = reader.GetNullableString("ClassificationCode"),
            GovernanceStatusCode = reader.GetNullableString("GovernanceStatusCode"),
            CertificationStatusCode = reader.GetNullableString("CertificationStatusCode"),
            RequiredAccessLevel = reader.GetNullableString("RequiredAccessLevel"),
            RequireCertified = reader.GetBoolean("RequireCertified"),
            EffectiveAccessLevel = reader.GetNullableString("EffectiveAccessLevel"),
            AccessSource = reader.GetNullableString("AccessSource"),
            WorkspaceRole = reader.GetNullableString("WorkspaceRole"),
            IsWorkspaceMember = reader.GetBoolean("IsWorkspaceMember"),
            IsPlatformAdmin = reader.GetBoolean("IsPlatformAdmin"),
            IsOwner = reader.GetBoolean("IsOwner"),
            IsSteward = reader.GetBoolean("IsSteward"),
            GrantLevel = reader.GetNullableString("GrantLevel"),
            GrantStatus = reader.GetString("GrantStatus"),
            ActiveShareId = reader.GetNullableGuid("ActiveShareId"),
            ShareLevel = reader.GetNullableString("ShareLevel"),
            ShareStatus = reader.GetString("ShareStatus"),
            ShareExpiresUtc = reader.GetNullableDateTime("ShareExpiresUtc")
        };
    }

    public async Task<IReadOnlyList<ExportableColumnDto>> GetExportableColumnsAsync(string datasetCode, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetExportableColumns");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        return await ReadListAsync(cmd, r => new ExportableColumnDto
        {
            ColumnName = r.GetString("ColumnName"),
            DataTypeName = r.GetString("DataTypeName"),
            SqlTypeDeclaration = r.GetString("SqlTypeDeclaration"),
            OrdinalPosition = r.GetInt32("OrdinalPosition"),
            IsKey = r.GetBoolean("IsKey"),
            IsFilterable = r.GetBoolean("IsFilterable"),
            IsSortable = r.GetBoolean("IsSortable"),
            IsExportable = r.GetBoolean("IsExportable")
        }, ct);
    }

    public async Task<int> SyncExportableColumnsAsync(string? datasetCode, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_SyncExportableColumns");
        cmd.Parameters.AddNullable("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@ReturnSummary", true);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? Int(reader, "ColumnsSynced") : 0;
    }

    // ---------------- Export requests ----------------

    public async Task<ExportActionResult> SubmitExportAsync(string datasetCode, string userName, string formatCode, Guid? datasetVersionId,
        string? selectedColumnsJson, string? filtersJson, string? sortJson, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_SubmitExportRequest");
        cmd.Parameters.AddWithValue("@DatasetCode", datasetCode);
        cmd.Parameters.AddWithValue("@UserName", userName);
        cmd.Parameters.AddWithValue("@FormatCode", formatCode);
        cmd.Parameters.AddNullable("@DatasetVersionId", datasetVersionId);
        cmd.Parameters.Add(new SqlParameter("@SelectedColumnsJson", SqlDbType.NVarChar, 4000) { Value = (object?)selectedColumnsJson ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@FiltersJson", SqlDbType.NVarChar, -1) { Value = (object?)filtersJson ?? DBNull.Value });
        cmd.Parameters.Add(new SqlParameter("@SortJson", SqlDbType.NVarChar, 1000) { Value = (object?)sortJson ?? DBNull.Value });
        var id = cmd.Parameters.Add(OutGuid("@ExportRequestId"));
        var (code, msg) = AddStatus(cmd);

        ExportRequestDto? dto = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct)) dto = MapExport(reader);
        }

        return new ExportActionResult
        {
            ExportRequestId = id.Value is Guid g ? g : dto?.ExportRequestId,
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Request = dto
        };
    }

    public async Task<ExportActionResult> TransitionExportAsync(Guid exportRequestId, TransitionExportRequest request, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_TransitionExportStatus");
        cmd.Parameters.AddWithValue("@ExportRequestId", exportRequestId);
        cmd.Parameters.AddWithValue("@NewStatus", request.NewStatus);
        cmd.Parameters.AddNullable("@ActorUserName", request.ActorUserName);
        cmd.Parameters.AddNullable("@RecordCount", request.RecordCount);
        cmd.Parameters.AddNullable("@FileSizeBytes", request.FileSizeBytes);
        cmd.Parameters.AddNullable("@FileReference", request.FileReference);
        cmd.Parameters.AddNullable("@FailureReason", request.FailureReason);
        return await ExecuteExportActionAsync(cmd, exportRequestId, ct);
    }

    public async Task<ExportActionResult> ClaimNextExportAsync(CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_ClaimNextExportRequest");
        return await ExecuteExportActionAsync(cmd, null, ct);
    }

    public async Task<ExportRequestDetailDto?> GetExportRequestAsync(Guid exportRequestId, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetExportRequest");
        cmd.Parameters.AddWithValue("@ExportRequestId", exportRequestId);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        var request = MapExport(reader);

        var history = new List<ExportStatusHistoryRow>();
        if (await reader.NextResultAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                history.Add(new ExportStatusHistoryRow
                {
                    StatusHistoryId = reader.GetInt64("StatusHistoryId"),
                    PreviousStatus = reader.GetNullableString("PreviousStatus"),
                    NewStatus = reader.GetString("NewStatus"),
                    ActorUserName = reader.GetNullableString("ActorUserName"),
                    ChangedUtc = reader.GetDateTime("ChangedUtc"),
                    Message = reader.GetNullableString("Message")
                });
            }
        }

        var downloads = new List<ExportDownloadRow>();
        if (await reader.NextResultAsync(ct))
        {
            while (await reader.ReadAsync(ct))
            {
                downloads.Add(new ExportDownloadRow
                {
                    DownloadId = reader.GetInt64("DownloadId"),
                    DownloadedByUserName = reader.GetString("DownloadedByUserName"),
                    DownloadedUtc = reader.GetDateTime("DownloadedUtc"),
                    ClientInfo = reader.GetNullableString("ClientInfo")
                });
            }
        }

        return new ExportRequestDetailDto { Request = request, StatusHistory = history, Downloads = downloads };
    }

    public async Task<ExportDataPageDto> GetExportDataAsync(Guid exportRequestId, string? userName, int pageSize, int pageNumber,
        string? afterKey, bool includeTotalCount, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetExportData");
        cmd.Parameters.AddWithValue("@ExportRequestId", exportRequestId);
        cmd.Parameters.AddNullable("@UserName", userName);
        cmd.Parameters.AddWithValue("@PageSize", pageSize);
        cmd.Parameters.AddWithValue("@PageNumber", pageNumber);
        cmd.Parameters.AddNullable("@AfterKey", afterKey);
        cmd.Parameters.AddWithValue("@IncludeTotalCount", includeTotalCount);
        var (code, msg) = AddStatus(cmd);

        var columns = new List<string>();
        var rows = new List<Dictionary<string, object?>>();
        string? mode = null, keyColumn = null, after = null, next = null;
        int? pageNo = null;
        int rowsReturned = 0, size = pageSize;
        bool hasMore = false;
        long? total = null;

        // Result sets are only produced on success; output parameters are readable after the reader closes.
        await using (var reader = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess, ct))
        {
            if (reader.FieldCount > 0)
            {
                for (var i = 0; i < reader.FieldCount; i++) columns.Add(reader.GetName(i));
                while (await reader.ReadAsync(ct))
                {
                    var row = new Dictionary<string, object?>(reader.FieldCount, StringComparer.OrdinalIgnoreCase);
                    for (var i = 0; i < reader.FieldCount; i++)
                        row[columns[i]] = await reader.IsDBNullAsync(i, ct) ? null : reader.GetValue(i);
                    rows.Add(row);
                }

                if (await reader.NextResultAsync(ct) && await reader.ReadAsync(ct))
                {
                    mode = reader.IsDBNull(0) ? null : reader.GetString(0);
                    keyColumn = reader.IsDBNull(1) ? null : reader.GetString(1);
                    size = reader.GetInt32(2);
                    pageNo = reader.IsDBNull(3) ? null : reader.GetInt32(3);
                    after = reader.IsDBNull(4) ? null : reader.GetString(4);
                    rowsReturned = reader.GetInt32(5);
                    next = reader.IsDBNull(6) ? null : reader.GetString(6);
                    hasMore = reader.GetBoolean(7);
                    total = reader.IsDBNull(8) ? null : reader.GetInt64(8);
                }
            }
        }

        return new ExportDataPageDto
        {
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Columns = columns,
            Rows = rows,
            PagingMode = mode,
            KeyColumn = keyColumn,
            PageSize = size,
            PageNumber = pageNo,
            AfterKey = after,
            RowsReturned = rowsReturned,
            NextAfterKey = next,
            HasMore = hasMore,
            TotalCount = total
        };
    }

    public async Task<ExportDownloadResult> RecordDownloadAsync(Guid exportRequestId, RecordDownloadRequest request, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_RecordExportDownload");
        cmd.Parameters.AddWithValue("@ExportRequestId", exportRequestId);
        cmd.Parameters.AddWithValue("@UserName", request.UserName);
        cmd.Parameters.AddNullable("@ClientInfo", request.ClientInfo);
        var (code, msg) = AddStatus(cmd);

        string? format = null, mime = null, ext = null, fileRef = null;
        long? size = null, records = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct))
            {
                format = reader.GetString("FormatCode");
                mime = reader.GetString("MimeType");
                ext = reader.GetString("FileExtension");
                fileRef = reader.GetNullableString("FileReference");
                size = reader.GetNullableInt64("FileSizeBytes");
                records = reader.GetNullableInt64("RecordCount");
            }
        }

        return new ExportDownloadResult
        {
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            ExportRequestId = exportRequestId,
            FormatCode = format,
            MimeType = mime,
            FileExtension = ext,
            FileReference = fileRef,
            FileSizeBytes = size,
            RecordCount = records
        };
    }

    public async Task<PagedList<ExportRequestDto>> GetExportHistoryAsync(ExportHistoryQuery query, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_GetExportHistory");
        cmd.Parameters.AddNullable("@UserName", query.UserName);
        cmd.Parameters.AddNullable("@DatasetCode", query.DatasetCode);
        cmd.Parameters.AddNullable("@WorkspaceId", query.WorkspaceId);
        cmd.Parameters.AddNullable("@Status", query.Status);
        cmd.Parameters.AddNullable("@FormatCode", query.FormatCode);
        cmd.Parameters.AddNullable("@FromUtc", query.FromUtc);
        cmd.Parameters.AddNullable("@ToUtc", query.ToUtc);
        cmd.Parameters.AddWithValue("@PageNumber", query.PageNumber);
        cmd.Parameters.AddWithValue("@PageSize", query.PageSize);

        var items = new List<ExportRequestDto>();
        var total = 0;
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
        {
            items.Add(MapExport(reader));
            total = Int(reader, "TotalCount");
        }
        return new PagedList<ExportRequestDto> { Items = items, PageNumber = query.PageNumber, PageSize = query.PageSize, TotalCount = total };
    }

    public async Task<ExportCleanupResult> CleanupStaleExportsAsync(int processingTimeoutMinutes, int pendingTimeoutHours, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "share.usp_CleanupStaleExports");
        cmd.Parameters.AddWithValue("@ProcessingTimeoutMinutes", processingTimeoutMinutes);
        cmd.Parameters.AddWithValue("@PendingTimeoutHours", pendingTimeoutHours);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return new ExportCleanupResult();
        return new ExportCleanupResult
        {
            TimedOutCount = Int(reader, "TimedOutCount"),
            AbandonedCount = Int(reader, "AbandonedCount")
        };
    }

    // ---------------- Reports ----------------

    public async Task<ExportSummaryDto> GetExportSummaryAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_ExportSummary", workspaceId, fromUtc, toUtc);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return new ExportSummaryDto();
        return new ExportSummaryDto
        {
            TotalExports = Int(reader, "TotalExports"),
            CompletedExports = Int(reader, "CompletedExports"),
            FailedExports = Int(reader, "FailedExports"),
            PendingExports = Int(reader, "PendingExports"),
            ProcessingExports = Int(reader, "ProcessingExports"),
            CancelledExports = Int(reader, "CancelledExports"),
            TotalRecordsExported = reader.GetNullableInt64("TotalRecordsExported") ?? 0,
            AvgDurationSeconds = reader.GetNullableDecimal("AvgDurationSeconds"),
            DistinctRequesters = Int(reader, "DistinctRequesters"),
            DistinctDatasets = Int(reader, "DistinctDatasets"),
            TotalDownloads = Int(reader, "TotalDownloads"),
            ActiveShares = Int(reader, "ActiveShares"),
            ExpiredShares = Int(reader, "ExpiredShares"),
            RevokedShares = Int(reader, "RevokedShares")
        };
    }

    public async Task<IReadOnlyList<ExportCountRow>> GetExportsByFormatAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_ExportsByFormat", workspaceId, fromUtc, toUtc);
        return await ReadListAsync(cmd, r => MapCount(r, "FormatCode", "DisplayName"), ct);
    }

    public async Task<IReadOnlyList<ExportCountRow>> GetExportsByDatasetAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_ExportsByDataset", workspaceId, fromUtc, toUtc);
        return await ReadListAsync(cmd, r => MapCount(r, "DatasetCode", "DatasetName"), ct);
    }

    public async Task<IReadOnlyList<ExportCountRow>> GetExportsByUserAsync(Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = ReportProc(conn, "rpt.usp_ExportsByUser", workspaceId, fromUtc, toUtc);
        return await ReadListAsync(cmd, r => MapCount(r, "UserName", "DisplayName"), ct);
    }

    public async Task<IReadOnlyList<ExportActivityRow>> GetExportActivityAsync(int days, Guid? workspaceId, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_ExportActivityByDate");
        cmd.Parameters.AddWithValue("@Days", days);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        return await ReadListAsync(cmd, r => new ExportActivityRow
        {
            ActivityDate = r.GetDateTime("ActivityDate"),
            Requested = Int(r, "Requested"),
            Completed = Int(r, "Completed"),
            Failed = Int(r, "Failed"),
            Cancelled = Int(r, "Cancelled"),
            InFlight = Int(r, "InFlight"),
            RecordsExported = r.GetNullableInt64("RecordsExported") ?? 0,
            Downloads = Int(r, "Downloads")
        }, ct);
    }

    public async Task<IReadOnlyList<ShareStatusSummaryRow>> GetShareStatusSummaryAsync(Guid? workspaceId, CancellationToken ct = default)
    {
        await using var conn = await OpenAsync(ct);
        await using var cmd = Proc(conn, "rpt.usp_ShareStatusSummary");
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        return await ReadListAsync(cmd, r => new ShareStatusSummaryRow
        {
            DatasetCode = r.GetString("DatasetCode"),
            DatasetName = r.GetString("DatasetName"),
            WorkspaceId = r.GetNullableGuid("WorkspaceId"),
            ActiveShares = Int(r, "ActiveShares"),
            ExpiredShares = Int(r, "ExpiredShares"),
            RevokedShares = Int(r, "RevokedShares"),
            ExpiringWithin7Days = Int(r, "ExpiringWithin7Days"),
            ExpiredNotYetMarked = Int(r, "ExpiredNotYetMarked")
        }, ct);
    }

    // ---------------- Helpers ----------------

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var conn = connectionFactory.CreateConnection();
        await conn.OpenAsync(ct);
        return conn;
    }

    private static SqlCommand Proc(SqlConnection conn, string name) =>
        new(name, conn) { CommandType = CommandType.StoredProcedure, CommandTimeout = Timeout };

    private static SqlCommand ReportProc(SqlConnection conn, string name, Guid? workspaceId, DateTime? fromUtc, DateTime? toUtc)
    {
        var cmd = Proc(conn, name);
        cmd.Parameters.AddNullable("@WorkspaceId", workspaceId);
        cmd.Parameters.AddNullable("@FromUtc", fromUtc);
        cmd.Parameters.AddNullable("@ToUtc", toUtc);
        return cmd;
    }

    private static SqlParameter OutGuid(string name) =>
        new(name, SqlDbType.UniqueIdentifier) { Direction = ParameterDirection.InputOutput, Value = DBNull.Value };

    private static (SqlParameter Code, SqlParameter Message) AddStatus(SqlCommand cmd)
    {
        var code = cmd.Parameters.Add(new SqlParameter("@StatusCode", SqlDbType.NVarChar, 32)
            { Direction = ParameterDirection.InputOutput, Value = DBNull.Value });
        var msg = cmd.Parameters.Add(new SqlParameter("@StatusMessage", SqlDbType.NVarChar, 500)
            { Direction = ParameterDirection.InputOutput, Value = DBNull.Value });
        return (code, msg);
    }

    private static async Task<ShareActionResult> ExecuteShareActionAsync(SqlCommand cmd, Guid shareId, CancellationToken ct)
    {
        var (code, msg) = AddStatus(cmd);
        DatasetShareDto? share = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct)) share = MapShare(reader);
        }
        return new ShareActionResult
        {
            ShareId = shareId,
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Share = share
        };
    }

    private static async Task<ExportActionResult> ExecuteExportActionAsync(SqlCommand cmd, Guid? exportRequestId, CancellationToken ct)
    {
        var (code, msg) = AddStatus(cmd);
        ExportRequestDto? dto = null;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (await reader.ReadAsync(ct)) dto = MapExport(reader);
        }
        return new ExportActionResult
        {
            ExportRequestId = dto?.ExportRequestId ?? exportRequestId,
            StatusCode = code.Value as string ?? "",
            StatusMessage = msg.Value as string ?? "",
            Request = dto
        };
    }

    private static async Task<IReadOnlyList<T>> ReadListAsync<T>(SqlCommand cmd, Func<SqlDataReader, T> map, CancellationToken ct)
    {
        var list = new List<T>();
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        while (await reader.ReadAsync(ct))
            list.Add(map(reader));
        return list;
    }

    // SUM over an empty set returns NULL; counts are reported as 0.
    private static int Int(SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? 0 : Convert.ToInt32(reader.GetValue(ordinal));
    }

    private static bool HasColumn(SqlDataReader reader, string name)
    {
        for (var i = 0; i < reader.FieldCount; i++)
            if (string.Equals(reader.GetName(i), name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    private static DatasetShareDto MapShare(SqlDataReader r) => new()
    {
        ShareId = r.GetGuid("ShareId"),
        DatasetId = r.GetGuid("DatasetId"),
        DatasetCode = r.GetString("DatasetCode"),
        DatasetName = r.GetString("DatasetName"),
        WorkspaceId = r.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = r.GetNullableString("WorkspaceCode"),
        RecipientUserId = r.GetGuid("RecipientUserId"),
        RecipientUserName = r.GetString("RecipientUserName"),
        RecipientDisplayName = r.GetNullableString("RecipientDisplayName"),
        AccessLevelCode = r.GetString("AccessLevelCode"),
        SharedByUserName = r.GetString("SharedByUserName"),
        SharedUtc = r.GetDateTime("SharedUtc"),
        ExpiresUtc = r.GetNullableDateTime("ExpiresUtc"),
        PersistedStatus = r.GetString("PersistedStatus"),
        EffectiveStatus = r.GetString("EffectiveStatus"),
        RevokedByUserName = r.GetNullableString("RevokedByUserName"),
        RevokedUtc = r.GetNullableDateTime("RevokedUtc"),
        RevokeReason = r.GetNullableString("RevokeReason"),
        Notes = r.GetNullableString("Notes"),
        ModifiedUtc = r.GetDateTime("ModifiedUtc")
    };

    private static ExportRequestDto MapExport(SqlDataReader r) => new()
    {
        ExportRequestId = r.GetGuid("ExportRequestId"),
        DatasetId = r.GetGuid("DatasetId"),
        DatasetCode = r.GetString("DatasetCode"),
        DatasetName = r.GetString("DatasetName"),
        DatasetVersionId = r.GetNullableGuid("DatasetVersionId"),
        DatasetVersionNumber = r.GetNullableInt32("DatasetVersionNumber"),
        RequestedByUserName = r.GetString("RequestedByUserName"),
        WorkspaceId = r.GetNullableGuid("WorkspaceId"),
        WorkspaceCode = r.GetNullableString("WorkspaceCode"),
        FormatCode = r.GetString("FormatCode"),
        Status = r.GetString("Status"),
        AccessSource = r.GetNullableString("AccessSource"),
        SelectedColumnCount = r.GetInt32("SelectedColumnCount"),
        FilterCount = r.GetInt32("FilterCount"),
        RequestedUtc = r.GetDateTime("RequestedUtc"),
        StartedUtc = r.GetNullableDateTime("StartedUtc"),
        CompletedUtc = r.GetNullableDateTime("CompletedUtc"),
        DurationSeconds = r.GetNullableInt32("DurationSeconds"),
        RecordCount = r.GetNullableInt64("RecordCount"),
        FileSizeBytes = r.GetNullableInt64("FileSizeBytes"),
        FileReference = r.GetNullableString("FileReference"),
        FailureReason = r.GetNullableString("FailureReason"),
        AttemptCount = r.GetInt32("AttemptCount"),
        DownloadCount = HasColumn(r, "DownloadCount") ? r.GetNullableInt32("DownloadCount") : null,
        SelectedColumnsJson = HasColumn(r, "SelectedColumnsJson") ? r.GetNullableString("SelectedColumnsJson") : null,
        FiltersJson = HasColumn(r, "FiltersJson") ? r.GetNullableString("FiltersJson") : null,
        SortJson = HasColumn(r, "SortJson") ? r.GetNullableString("SortJson") : null
    };

    private static ExportCountRow MapCount(SqlDataReader r, string keyColumn, string nameColumn) => new()
    {
        Key = r.GetString(keyColumn),
        Name = r.GetNullableString(nameColumn),
        TotalExports = Int(r, "TotalExports"),
        CompletedExports = Int(r, "CompletedExports"),
        FailedExports = Int(r, "FailedExports"),
        RecordsExported = r.GetNullableInt64("RecordsExported") ?? 0,
        LastRequestedUtc = HasColumn(r, "LastRequestedUtc") ? r.GetNullableDateTime("LastRequestedUtc") : null
    };
}
