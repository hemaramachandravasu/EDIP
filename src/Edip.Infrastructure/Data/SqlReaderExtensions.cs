using System.Data;
using Microsoft.Data.SqlClient;

namespace Edip.Infrastructure.Data;

internal static class SqlReaderExtensions
{
    public static Guid GetGuid(this SqlDataReader reader, string name) => reader.GetGuid(reader.GetOrdinal(name));

    public static string GetString(this SqlDataReader reader, string name) => reader.GetString(reader.GetOrdinal(name));

    public static string? GetNullableString(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
    }

    public static int GetInt32(this SqlDataReader reader, string name) => reader.GetInt32(reader.GetOrdinal(name));

    public static int? GetNullableInt32(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetInt32(ordinal);
    }

    // Widening conversion so SUM(int) / COUNT(...) columns map cleanly to Int64 DTOs.
    public static long GetInt64(this SqlDataReader reader, string name)
        => Convert.ToInt64(reader.GetValue(reader.GetOrdinal(name)));

    public static bool GetBoolean(this SqlDataReader reader, string name) => reader.GetBoolean(reader.GetOrdinal(name));

    public static DateTime GetDateTime(this SqlDataReader reader, string name) => reader.GetDateTime(reader.GetOrdinal(name));

    public static DateTime? GetNullableDateTime(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
    }

    public static byte? GetNullableByte(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetByte(ordinal);
    }

    public static double? GetNullableDouble(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : Convert.ToDouble(reader.GetValue(ordinal));
    }

    public static decimal GetDecimal(this SqlDataReader reader, string name) => reader.GetDecimal(reader.GetOrdinal(name));

    public static decimal? GetNullableDecimal(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : reader.GetDecimal(ordinal);
    }

    public static long? GetNullableInt64(this SqlDataReader reader, string name)
    {
        var ordinal = reader.GetOrdinal(name);
        return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal));
    }

    public static void AddNullable(this SqlParameterCollection parameters, string name, object? value)
    {
        parameters.AddWithValue(name, value ?? DBNull.Value);
    }
}
