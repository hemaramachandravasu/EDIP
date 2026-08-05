using Edip.Api.Middleware;
using Edip.Infrastructure;
using Microsoft.OpenApi;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(c =>
{
    c.SwaggerDoc("v1", new()
    {
        Title = "Enterprise Data Intelligence Platform API",
        Version = "v1",
        Description = "Click Authorize and enter: edip-dev-api-key"
    });

    c.AddSecurityDefinition("ApiKey", new OpenApiSecurityScheme
    {
        Type = SecuritySchemeType.ApiKey,
        Name = "X-Api-Key",
        In = ParameterLocation.Header,
        Description = "API key. Value: edip-dev-api-key"
    });

    c.AddSecurityRequirement(document => new OpenApiSecurityRequirement
    {
        [new OpenApiSecuritySchemeReference("ApiKey", document)] = []
    });
});

builder.Services.AddEdipInfrastructure(builder.Configuration);

var app = builder.Build();

app.UseSwagger();
app.UseSwaggerUI();

app.UseHttpsRedirection();
app.UseMiddleware<ApiKeyMiddleware>();
app.MapControllers();
app.MapGet("/health", () => Results.Ok(new { status = "Healthy", service = "Edip.Api" }));

app.Run();
