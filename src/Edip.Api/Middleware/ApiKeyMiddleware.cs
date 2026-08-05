using Edip.Infrastructure.Configuration;
using Microsoft.Extensions.Options;

namespace Edip.Api.Middleware;

public sealed class ApiKeyMiddleware(RequestDelegate next, IOptions<EdipOptions> options)
{
    private const string HeaderName = "X-Api-Key";

    public async Task InvokeAsync(HttpContext context)
    {
        var path = context.Request.Path.Value ?? string.Empty;
        if (path.StartsWith("/swagger", StringComparison.OrdinalIgnoreCase)
            || path.StartsWith("/openapi", StringComparison.OrdinalIgnoreCase)
            || path.Equals("/health", StringComparison.OrdinalIgnoreCase))
        {
            await next(context);
            return;
        }

        if (!context.Request.Headers.TryGetValue(HeaderName, out var provided)
            || !string.Equals(provided.ToString(), options.Value.ApiKey, StringComparison.Ordinal))
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            await context.Response.WriteAsJsonAsync(new { error = "Missing or invalid X-Api-Key header." });
            return;
        }

        await next(context);
    }
}
