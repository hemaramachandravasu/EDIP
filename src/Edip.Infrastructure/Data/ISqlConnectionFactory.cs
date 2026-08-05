using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Data;

public interface ISqlConnectionFactory
{
    SqlConnection CreateConnection();
}
