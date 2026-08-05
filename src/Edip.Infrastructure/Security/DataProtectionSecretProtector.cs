using Microsoft.AspNetCore.DataProtection;
using Edip.Core.Interfaces;

namespace Edip.Infrastructure.Security;

public sealed class DataProtectionSecretProtector(IDataProtectionProvider provider) : ISecretProtector
{
    private readonly IDataProtector _protector = provider.CreateProtector("Edip.ConnectionSecrets.v1");

    public string Protect(string plaintext) => _protector.Protect(plaintext);

    public string Unprotect(string protectedPayload) => _protector.Unprotect(protectedPayload);
}
