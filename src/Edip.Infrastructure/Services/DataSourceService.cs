using Edip.Core.DTOs;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Services;

public sealed class DataSourceService(
    IDataSourceRepository repository,
    IConnectionProbeFactory probeFactory,
    ISecretProtector secretProtector) : IDataSourceService
{
    public async Task<IReadOnlyList<DataSourceDto>> GetAllAsync(CancellationToken ct = default)
    {
        var items = await repository.GetAllAsync(ct);
        return items.Select(MapDto).ToList();
    }

    public async Task<DataSourceDto?> GetByIdAsync(Guid id, CancellationToken ct = default)
    {
        var item = await repository.GetByIdAsync(id, ct);
        return item is null ? null : MapDto(item);
    }

    public async Task<DataSourceDto> CreateAsync(CreateDataSourceRequest request, CancellationToken ct = default)
    {
        var source = new DataSource
        {
            Name = request.Name,
            Description = request.Description,
            DataSourceTypeCode = request.DataSourceTypeCode,
            Status = "Active",
            HealthStatus = HealthStatus.Unknown,
            SqlConnection = request.SqlConnection is null ? null : new SqlConnectionDetail
            {
                Host = request.SqlConnection.Host,
                Port = request.SqlConnection.Port,
                DatabaseName = request.SqlConnection.DatabaseName,
                AuthMode = request.SqlConnection.AuthMode,
                Username = request.SqlConnection.Username,
                TrustServerCertificate = request.SqlConnection.TrustServerCertificate,
                ConnectionTimeoutSeconds = request.SqlConnection.ConnectionTimeoutSeconds
            },
            FileDetail = request.FileDetail is null ? null : new FileDataSourceDetail
            {
                FilePath = request.FileDetail.FilePath,
                Format = request.FileDetail.Format,
                Delimiter = request.FileDetail.Delimiter,
                HasHeaderRow = request.FileDetail.HasHeaderRow,
                SheetName = request.FileDetail.SheetName,
                EncodingName = request.FileDetail.EncodingName
            }
        };

        var id = await repository.CreateAsync(source, request.SqlConnection?.Password, ct);
        return (await GetByIdAsync(id, ct))!;
    }

    public async Task<DataSourceDto?> UpdateAsync(Guid id, UpdateDataSourceRequest request, CancellationToken ct = default)
    {
        var existing = await repository.GetByIdAsync(id, ct);
        if (existing is null)
            return null;

        existing.Name = request.Name;
        existing.Description = request.Description;
        existing.Status = request.Status;

        if (request.SqlConnection is not null)
        {
            existing.SqlConnection = new SqlConnectionDetail
            {
                DataSourceId = id,
                Host = request.SqlConnection.Host,
                Port = request.SqlConnection.Port,
                DatabaseName = request.SqlConnection.DatabaseName,
                AuthMode = request.SqlConnection.AuthMode,
                Username = request.SqlConnection.Username,
                EncryptedPassword = existing.SqlConnection?.EncryptedPassword,
                TrustServerCertificate = request.SqlConnection.TrustServerCertificate,
                ConnectionTimeoutSeconds = request.SqlConnection.ConnectionTimeoutSeconds
            };
        }

        if (request.FileDetail is not null)
        {
            existing.FileDetail = new FileDataSourceDetail
            {
                DataSourceId = id,
                FilePath = request.FileDetail.FilePath,
                Format = request.FileDetail.Format,
                Delimiter = request.FileDetail.Delimiter,
                HasHeaderRow = request.FileDetail.HasHeaderRow,
                SheetName = request.FileDetail.SheetName,
                EncodingName = request.FileDetail.EncodingName
            };
        }

        await repository.UpdateAsync(existing, request.SqlConnection?.Password, ct);
        return await GetByIdAsync(id, ct);
    }

    public async Task<bool> DeleteAsync(Guid id, CancellationToken ct = default)
    {
        var existing = await repository.GetByIdAsync(id, ct);
        if (existing is null)
            return false;
        await repository.SoftDeleteAsync(id, ct);
        return true;
    }

    public async Task<ValidationResultDto> ValidateAsync(Guid id, CancellationToken ct = default)
    {
        var source = await repository.GetByIdAsync(id, ct)
            ?? throw new KeyNotFoundException($"Data source '{id}' was not found.");

        var password = ResolvePassword(source);
        var probe = probeFactory.GetProbe(source.DataSourceTypeCode);
        var result = await probe.ValidateAsync(source, password, ct);
        var validatedUtc = DateTime.UtcNow;
        var health = result.IsSuccess ? HealthStatus.Healthy : HealthStatus.Unhealthy;

        await repository.UpdateHealthAsync(id, health, validatedUtc, ct);
        await repository.AddValidationLogAsync(new ConnectionValidationLog
        {
            DataSourceId = id,
            IsSuccess = result.IsSuccess,
            Message = result.Message,
            LatencyMs = result.LatencyMs,
            ValidatedUtc = validatedUtc
        }, ct);

        return new ValidationResultDto
        {
            DataSourceId = id,
            IsSuccess = result.IsSuccess,
            Message = result.Message,
            LatencyMs = result.LatencyMs,
            HealthStatus = health.ToString(),
            ValidatedUtc = validatedUtc
        };
    }

    public async Task<DataSourceHealthDto?> GetHealthAsync(Guid id, CancellationToken ct = default)
    {
        var source = await repository.GetByIdAsync(id, ct);
        if (source is null)
            return null;

        var logs = await repository.GetRecentValidationsAsync(id, 10, ct);
        return new DataSourceHealthDto
        {
            DataSourceId = source.DataSourceId,
            Name = source.Name,
            HealthStatus = source.HealthStatus.ToString(),
            LastValidatedUtc = source.LastValidatedUtc,
            RecentValidations = logs.Select(l => new ConnectionValidationLogDto
            {
                IsSuccess = l.IsSuccess,
                Message = l.Message,
                LatencyMs = l.LatencyMs,
                ValidatedUtc = l.ValidatedUtc
            }).ToList()
        };
    }

    internal string? ResolvePassword(DataSource source)
    {
        if (source.SqlConnection?.EncryptedPassword is null)
            return null;
        try
        {
            return secretProtector.Unprotect(source.SqlConnection.EncryptedPassword);
        }
        catch
        {
            return null;
        }
    }

    private static DataSourceDto MapDto(DataSource source) => new()
    {
        DataSourceId = source.DataSourceId,
        Name = source.Name,
        Description = source.Description,
        DataSourceTypeCode = source.DataSourceTypeCode,
        Status = source.Status,
        HealthStatus = source.HealthStatus.ToString(),
        LastValidatedUtc = source.LastValidatedUtc,
        SqlConnection = source.SqlConnection is null ? null : new SqlConnectionDto
        {
            Host = source.SqlConnection.Host,
            Port = source.SqlConnection.Port,
            DatabaseName = source.SqlConnection.DatabaseName,
            AuthMode = source.SqlConnection.AuthMode,
            Username = source.SqlConnection.Username,
            TrustServerCertificate = source.SqlConnection.TrustServerCertificate,
            ConnectionTimeoutSeconds = source.SqlConnection.ConnectionTimeoutSeconds
        },
        FileDetail = source.FileDetail is null ? null : new FileDataSourceDto
        {
            FilePath = source.FileDetail.FilePath,
            Format = source.FileDetail.Format,
            Delimiter = source.FileDetail.Delimiter,
            HasHeaderRow = source.FileDetail.HasHeaderRow,
            SheetName = source.FileDetail.SheetName,
            EncodingName = source.FileDetail.EncodingName
        }
    };
}
