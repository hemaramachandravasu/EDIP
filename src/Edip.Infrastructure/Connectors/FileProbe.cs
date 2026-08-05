using System.Diagnostics;
using System.Globalization;
using System.Text;
using ClosedXML.Excel;
using CsvHelper;
using CsvHelper.Configuration;
using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Core.Models;

namespace Edip.Infrastructure.Connectors;

public sealed class FileProbe : IConnectionProbe
{
    public string SupportedTypeCode => "File";

    public Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            var detail = source.FileDetail ?? throw new InvalidOperationException("File details are missing.");
            if (!File.Exists(detail.FilePath))
                return Task.FromResult(new ProbeResult { IsSuccess = false, Message = $"File not found: {detail.FilePath}", LatencyMs = (int)sw.ElapsedMilliseconds });

            using var stream = File.OpenRead(detail.FilePath);
            if (stream.Length == 0)
                return Task.FromResult(new ProbeResult { IsSuccess = false, Message = "File is empty.", LatencyMs = (int)sw.ElapsedMilliseconds });

            sw.Stop();
            return Task.FromResult(new ProbeResult
            {
                IsSuccess = true,
                Message = $"File accessible ({stream.Length} bytes).",
                LatencyMs = (int)sw.ElapsedMilliseconds
            });
        }
        catch (Exception ex)
        {
            sw.Stop();
            return Task.FromResult(new ProbeResult { IsSuccess = false, Message = ex.Message, LatencyMs = (int)sw.ElapsedMilliseconds });
        }
    }

    public Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
    {
        var detail = source.FileDetail ?? throw new InvalidOperationException("File details are missing.");
        var snapshot = new CapturedMetadataSnapshot();
        var objectId = Guid.NewGuid();
        var objectName = Path.GetFileNameWithoutExtension(detail.FilePath);

        snapshot.Objects.Add(new SchemaObject
        {
            SchemaObjectId = objectId,
            DataSourceId = source.DataSourceId,
            SchemaName = "file",
            ObjectName = objectName,
            ObjectType = SchemaObjectType.Table
        });

        IReadOnlyList<string> headers = detail.Format.Equals("Excel", StringComparison.OrdinalIgnoreCase)
            ? ReadExcelHeaders(detail)
            : ReadCsvHeaders(detail);

        for (var i = 0; i < headers.Count; i++)
        {
            snapshot.Columns.Add(new ColumnDefinition
            {
                ColumnDefinitionId = Guid.NewGuid(),
                SchemaObjectId = objectId,
                ColumnName = headers[i],
                DataType = "string",
                IsNullable = true,
                OrdinalPosition = i + 1
            });
        }

        return Task.FromResult(snapshot);
    }

    private static IReadOnlyList<string> ReadCsvHeaders(FileDataSourceDetail detail)
    {
        using var reader = new StreamReader(detail.FilePath, Encoding.GetEncoding(detail.EncodingName));
        var config = new CsvConfiguration(CultureInfo.InvariantCulture)
        {
            HasHeaderRecord = detail.HasHeaderRow,
            Delimiter = detail.Delimiter
        };
        using var csv = new CsvReader(reader, config);
        csv.Read();
        csv.ReadHeader();
        return csv.HeaderRecord?.ToList() ?? [];
    }

    private static IReadOnlyList<string> ReadExcelHeaders(FileDataSourceDetail detail)
    {
        using var workbook = new XLWorkbook(detail.FilePath);
        var sheet = string.IsNullOrWhiteSpace(detail.SheetName)
            ? workbook.Worksheets.First()
            : workbook.Worksheet(detail.SheetName);
        var firstRow = sheet.FirstRowUsed() ?? throw new InvalidOperationException("Excel sheet has no rows.");
        return firstRow.CellsUsed().Select(c => c.GetString()).Where(s => !string.IsNullOrWhiteSpace(s)).ToList();
    }
}

public sealed class CsvProbe(FileProbe inner) : IConnectionProbe
{
    public string SupportedTypeCode => "Csv";
    public Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
        => inner.ValidateAsync(source, plaintextPassword, ct);
    public Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
        => inner.CaptureMetadataAsync(source, plaintextPassword, ct);
}

public sealed class ExcelProbe(FileProbe inner) : IConnectionProbe
{
    public string SupportedTypeCode => "Excel";
    public Task<ProbeResult> ValidateAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
        => inner.ValidateAsync(source, plaintextPassword, ct);
    public Task<CapturedMetadataSnapshot> CaptureMetadataAsync(DataSource source, string? plaintextPassword, CancellationToken ct = default)
        => inner.CaptureMetadataAsync(source, plaintextPassword, ct);
}
