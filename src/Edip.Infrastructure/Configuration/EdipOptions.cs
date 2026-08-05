namespace Edip.Infrastructure.Configuration;

public sealed class EdipOptions
{
    public const string SectionName = "Edip";

    public string ConnectionString { get; set; } = string.Empty;
    public string ApiKey { get; set; } = "edip-dev-api-key";
    public string DataProtectionKeysPath { get; set; } = "dp-keys";
}
