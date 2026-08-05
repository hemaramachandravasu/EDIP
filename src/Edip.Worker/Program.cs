using Edip.Core.Enums;
using Edip.Core.Interfaces;
using Edip.Infrastructure;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

var builder = Host.CreateApplicationBuilder(args);

builder.Configuration
    .AddJsonFile("appsettings.json", optional: true)
    .AddJsonFile("appsettings.Development.json", optional: true)
    .AddEnvironmentVariables();

builder.Services.AddEdipInfrastructure(builder.Configuration);
builder.Services.AddLogging(logging =>
{
    logging.ClearProviders();
    logging.AddConsole();
});

using var host = builder.Build();
var logger = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("Edip.Worker");

if (args.Length == 0 || args.Contains("--help") || args.Contains("-h"))
{
    Console.WriteLine("""
        Edip.Worker — Enterprise Data Intelligence Platform job runner

        Usage:
          Edip.Worker --due
          Edip.Worker --jobId <guid>
          Edip.Worker --executionId <guid>
        """);
    return 0;
}

try
{
    using var scope = host.Services.CreateScope();
    var jobs = scope.ServiceProvider.GetRequiredService<IProcessingJobService>();

    if (args.Contains("--due"))
    {
        logger.LogInformation("Processing due jobs...");
        await jobs.ProcessDueJobsAsync();
        logger.LogInformation("Due job processing complete.");
        return 0;
    }

    var jobIdIndex = Array.FindIndex(args, a => a.Equals("--jobId", StringComparison.OrdinalIgnoreCase));
    if (jobIdIndex >= 0 && jobIdIndex + 1 < args.Length && Guid.TryParse(args[jobIdIndex + 1], out var jobId))
    {
        logger.LogInformation("Executing job {JobId}", jobId);
        var result = await jobs.ExecuteAsync(jobId, JobTriggerType.Agent);
        logger.LogInformation("Result: {Status} — {Message}", result.Status, result.Message);
        return string.Equals(result.Status, "Succeeded", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
    }

    var execIndex = Array.FindIndex(args, a => a.Equals("--executionId", StringComparison.OrdinalIgnoreCase));
    if (execIndex >= 0 && execIndex + 1 < args.Length && Guid.TryParse(args[execIndex + 1], out var executionId))
    {
        var repo = scope.ServiceProvider.GetRequiredService<IProcessingJobRepository>();
        var execution = await repo.GetExecutionByIdAsync(executionId);
        if (execution is null)
        {
            logger.LogError("Execution {ExecutionId} not found.", executionId);
            return 1;
        }

        logger.LogInformation("Re-running job {JobId} for execution {ExecutionId}", execution.JobId, executionId);
        var result = await jobs.ExecuteAsync(execution.JobId, JobTriggerType.Retry);
        logger.LogInformation("Result: {Status} — {Message}", result.Status, result.Message);
        return string.Equals(result.Status, "Succeeded", StringComparison.OrdinalIgnoreCase) ? 0 : 1;
    }

    logger.LogError("Unrecognized arguments: {Args}", string.Join(' ', args));
    return 1;
}
catch (Exception ex)
{
    logger.LogError(ex, "Worker failed.");
    return 1;
}
