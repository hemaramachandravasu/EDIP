using Edip.Core.Enums;

namespace Edip.Core.DTOs;

public sealed class DataSourceDto
{
    public Guid DataSourceId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string DataSourceTypeCode { get; set; } = string.Empty;
    public string Status { get; set; } = "Active";
    public string HealthStatus { get; set; } = "Unknown";
    public DateTime? LastValidatedUtc { get; set; }
    public SqlConnectionDto? SqlConnection { get; set; }
    public FileDataSourceDto? FileDetail { get; set; }
}

public class SqlConnectionDto
{
    public string Host { get; set; } = string.Empty;
    public int Port { get; set; }
    public string DatabaseName { get; set; } = string.Empty;
    public string AuthMode { get; set; } = "SqlPassword";
    public string Username { get; set; } = string.Empty;
    public bool TrustServerCertificate { get; set; }
    public int ConnectionTimeoutSeconds { get; set; } = 30;
}

public sealed class FileDataSourceDto
{
    public string FilePath { get; set; } = string.Empty;
    public string Format { get; set; } = "CSV";
    public string Delimiter { get; set; } = ",";
    public bool HasHeaderRow { get; set; } = true;
    public string? SheetName { get; set; }
    public string EncodingName { get; set; } = "UTF-8";
}

public sealed class CreateDataSourceRequest
{
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string DataSourceTypeCode { get; set; } = string.Empty;
    public SqlConnectionCreateDto? SqlConnection { get; set; }
    public FileDataSourceDto? FileDetail { get; set; }
}

public sealed class SqlConnectionCreateDto : SqlConnectionDto
{
    public string? Password { get; set; }
}

public sealed class UpdateDataSourceRequest
{
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public string Status { get; set; } = "Active";
    public SqlConnectionCreateDto? SqlConnection { get; set; }
    public FileDataSourceDto? FileDetail { get; set; }
}

public sealed class ValidationResultDto
{
    public Guid DataSourceId { get; set; }
    public bool IsSuccess { get; set; }
    public string Message { get; set; } = string.Empty;
    public int? LatencyMs { get; set; }
    public string HealthStatus { get; set; } = "Unknown";
    public DateTime ValidatedUtc { get; set; }
}

public sealed class DataSourceHealthDto
{
    public Guid DataSourceId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string HealthStatus { get; set; } = "Unknown";
    public DateTime? LastValidatedUtc { get; set; }
    public IReadOnlyList<ConnectionValidationLogDto> RecentValidations { get; set; } = [];
}

public sealed class ConnectionValidationLogDto
{
    public bool IsSuccess { get; set; }
    public string? Message { get; set; }
    public int? LatencyMs { get; set; }
    public DateTime ValidatedUtc { get; set; }
}
