using Edip.Core.Enums;

namespace Edip.Core.Models;

public sealed class DataSource
{
    public Guid DataSourceId { get; set; }
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int DataSourceTypeId { get; set; }
    public string DataSourceTypeCode { get; set; } = string.Empty;
    public string Status { get; set; } = "Active";
    public HealthStatus HealthStatus { get; set; } = HealthStatus.Unknown;
    public DateTime? LastValidatedUtc { get; set; }
    public DateTime CreatedUtc { get; set; }
    public DateTime ModifiedUtc { get; set; }
    public bool IsDeleted { get; set; }
    public SqlConnectionDetail? SqlConnection { get; set; }
    public FileDataSourceDetail? FileDetail { get; set; }
}

public sealed class SqlConnectionDetail
{
    public Guid DataSourceId { get; set; }
    public string Host { get; set; } = string.Empty;
    public int Port { get; set; }
    public string DatabaseName { get; set; } = string.Empty;
    public string AuthMode { get; set; } = "SqlPassword";
    public string Username { get; set; } = string.Empty;
    public string? EncryptedPassword { get; set; }
    public bool TrustServerCertificate { get; set; }
    public int ConnectionTimeoutSeconds { get; set; } = 30;
}

public sealed class FileDataSourceDetail
{
    public Guid DataSourceId { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public string Format { get; set; } = "CSV";
    public string Delimiter { get; set; } = ",";
    public bool HasHeaderRow { get; set; } = true;
    public string? SheetName { get; set; }
    public string EncodingName { get; set; } = "UTF-8";
}

public sealed class ConnectionValidationLog
{
    public long ValidationLogId { get; set; }
    public Guid DataSourceId { get; set; }
    public bool IsSuccess { get; set; }
    public string? Message { get; set; }
    public int? LatencyMs { get; set; }
    public DateTime ValidatedUtc { get; set; }
}
