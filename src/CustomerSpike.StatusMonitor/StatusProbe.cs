using Microsoft.Extensions.Options;

namespace CustomerSpike.StatusMonitor;

/// <summary>Outcome of one probe. <see cref="Code"/> is the HTTP status, or 0 when no response was received.</summary>
public sealed record ProbeResult(int Code, string Message);

public interface IStatusProbe
{
    Task<ProbeResult> ProbeAsync(CancellationToken cancellationToken);
}

public sealed class HttpStatusProbe : IStatusProbe, IDisposable
{
    private readonly string _url;
    private readonly HttpClient _client;

    /// <param name="options">Monitor settings.</param>
    /// <param name="handler">Test seam: replaces the real network handler.</param>
    public HttpStatusProbe(IOptions<StatusMonitorOptions> options, HttpMessageHandler? handler = null)
    {
        var settings = options.Value;
        _url = settings.Url;

        if (handler is null)
        {
            var httpHandler = new HttpClientHandler();
            if (settings.AllowUntrustedCertificate)
            {
                httpHandler.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
            }

            handler = httpHandler;
        }

        _client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(settings.TimeoutSeconds) };
    }

    public async Task<ProbeResult> ProbeAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var response = await _client.GetAsync(_url, cancellationToken);
            return new ProbeResult((int)response.StatusCode, response.ReasonPhrase ?? response.StatusCode.ToString());
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Connection refused, DNS failure, timeout...: no HTTP status exists, report 0.
            return new ProbeResult(0, $"Request failed: {ex.GetType().Name} - {ex.Message}");
        }
    }

    public void Dispose() => _client.Dispose();
}
