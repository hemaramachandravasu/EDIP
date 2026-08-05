using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;
using Edip.Infrastructure.Configuration;

namespace Edip.Infrastructure.Data;

public sealed class SqlConnectionFactory(IOptions<EdipOptions> options) : ISqlConnectionFactory
{
    private readonly string _connectionString = options.Value.ConnectionString
        ?? throw new InvalidOperationException("Edip:ConnectionString is not configured.");

    public SqlConnection CreateConnection() => new(_connectionString);
}
