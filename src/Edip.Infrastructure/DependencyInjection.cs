using Edip.Core.Interfaces;
using Edip.Infrastructure.Configuration;
using Edip.Infrastructure.Connectors;
using Edip.Infrastructure.Data;
using Edip.Infrastructure.Export;
using Edip.Infrastructure.Repositories;
using Edip.Infrastructure.Security;
using Edip.Infrastructure.Services;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace Edip.Infrastructure;

public static class DependencyInjection
{
    public static IServiceCollection AddEdipInfrastructure(this IServiceCollection services, IConfiguration configuration)
    {
        services.Configure<EdipOptions>(configuration.GetSection(EdipOptions.SectionName));

        var keysPath = configuration.GetSection(EdipOptions.SectionName).GetValue<string>(nameof(EdipOptions.DataProtectionKeysPath))
                       ?? "dp-keys";
        Directory.CreateDirectory(keysPath);

        services.AddDataProtection()
            .PersistKeysToFileSystem(new DirectoryInfo(keysPath))
            .SetApplicationName("EnterpriseDataIntelligencePlatform");

        services.AddSingleton<ISqlConnectionFactory, SqlConnectionFactory>();
        services.AddSingleton<ISecretProtector, DataProtectionSecretProtector>();
        services.AddSingleton<IExportService, ExportService>();

        services.AddScoped<IDataSourceRepository, DataSourceRepository>();
        services.AddScoped<IMetadataRepository, MetadataRepository>();
        services.AddScoped<IProcessingJobRepository, ProcessingJobRepository>();
        services.AddScoped<IReportRepository, ReportRepository>();
        services.AddScoped<IQualityRepository, QualityRepository>();
        services.AddScoped<IIngestionRepository, IngestionRepository>();
        services.AddScoped<IEtlRepository, EtlRepository>();

        services.AddSingleton<FileProbe>();
        services.AddSingleton<IConnectionProbe, SqlServerProbe>();
        services.AddSingleton<IConnectionProbe, MySqlProbe>();
        services.AddSingleton<IConnectionProbe, PostgreSqlProbe>();
        services.AddSingleton<IConnectionProbe, CsvProbe>();
        services.AddSingleton<IConnectionProbe, ExcelProbe>();
        services.AddSingleton<IConnectionProbeFactory, ConnectionProbeFactory>();
        services.AddScoped<IDataProfiler, Profiling.SqlServerDataProfiler>();

        services.AddScoped<IDataSourceService, DataSourceService>();
        services.AddScoped<IMetadataService, MetadataService>();
        services.AddScoped<IProcessingJobService, ProcessingJobService>();
        services.AddScoped<IReportService, ReportService>();
        services.AddScoped<IProfilingService, ProfilingService>();
        services.AddScoped<IQualityAssessmentService, QualityAssessmentService>();
        services.AddScoped<IMetadataSyncService, MetadataSyncService>();
        services.AddScoped<IIngestionService, IngestionService>();
        services.AddScoped<IEtlService, EtlService>();

        return services;
    }
}
