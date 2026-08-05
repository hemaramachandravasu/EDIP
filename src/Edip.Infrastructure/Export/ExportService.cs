using System.Globalization;
using System.Text;
using ClosedXML.Excel;
using CsvHelper;
using CsvHelper.Configuration;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Export;

public sealed class ExportService : IExportService
{
    public byte[] ExportToCsv<T>(IEnumerable<T> rows)
    {
        using var ms = new MemoryStream();
        using (var writer = new StreamWriter(ms, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true), leaveOpen: true))
        using (var csv = new CsvWriter(writer, new CsvConfiguration(CultureInfo.InvariantCulture)))
        {
            csv.WriteRecords(rows);
        }
        return ms.ToArray();
    }

    public byte[] ExportToExcel<T>(IEnumerable<T> rows, string sheetName)
    {
        using var workbook = new XLWorkbook();
        var list = rows.ToList();
        var sheet = workbook.Worksheets.Add(string.IsNullOrWhiteSpace(sheetName) ? "Report" : sheetName);

        if (list.Count == 0)
        {
            sheet.Cell(1, 1).Value = "No data";
        }
        else
        {
            sheet.Cell(1, 1).InsertTable(list, createTable: true);
            sheet.Columns().AdjustToContents();
        }

        using var ms = new MemoryStream();
        workbook.SaveAs(ms);
        return ms.ToArray();
    }
}
