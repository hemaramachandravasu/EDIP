using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Connectors;

public sealed class ConnectionProbeFactory(IEnumerable<IConnectionProbe> probes) : IConnectionProbeFactory
{
    private readonly Dictionary<string, IConnectionProbe> _probes =
        probes.Where(p => p.SupportedTypeCode != "File")
              .ToDictionary(p => p.SupportedTypeCode, StringComparer.OrdinalIgnoreCase);

    public IConnectionProbe GetProbe(string dataSourceTypeCode)
    {
        if (_probes.TryGetValue(dataSourceTypeCode, out var probe))
            return probe;
        throw new NotSupportedException($"No connection probe registered for type '{dataSourceTypeCode}'.");
    }
}
