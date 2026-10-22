using System.Net;
using Microsoft.Extensions.Options;

namespace CustomerSpike.StatusMonitor;

/// <summary>
/// Probes the IIS web site every <see cref="StatusMonitorOptions.IntervalSeconds"/> seconds, appends the
/// HTTP status to a log file next to the executable and stops the service when the status is not 200 OK.
/// </summary>
public sealed class Worker : BackgroundService
{
    private readonly StatusMonitorOptions _options;
    private readonly ILogger<Worker> _logger;
    private readonly string _logPath;

    public Worker(IOptions<StatusMonitorOptions> options, ILogger<Worker> logger)
    {
        _options = options.Value;
        _logger = logger;
        // AppContext.BaseDirectory, not the working directory: a Windows service starts in System32.
        _logPath = Path.Combine(AppContext.BaseDirectory, _options.LogFileName);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var client = CreateClient();
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(_options.IntervalSeconds));

        _logger.LogInformation("Monitoring {Url} every {Interval}s, log file: {LogPath}",
            _options.Url, _options.IntervalSeconds, _logPath);

        // Probe immediately, then once per interval.
        do
        {
            var (code, message) = await ProbeAsync(client, stoppingToken);
            await WriteLogAsync(code, message, stoppingToken);

            if (code != (int)HttpStatusCode.OK)
            {
                _logger.LogError("Unexpected status {Code} ({Message}); stopping the service.", code, message);

                // Terminating with a non-zero exit code makes the Service Control Manager treat this as a
                // failure, so the recovery action configured at install time (restart after 300s) applies.
                Environment.Exit(1);
            }
        }
        while (await WaitForNextTickAsync(timer, stoppingToken));
    }

    private HttpClient CreateClient()
    {
        var handler = new HttpClientHandler();
        if (_options.AllowUntrustedCertificate)
        {
            handler.ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator;
        }

        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(_options.TimeoutSeconds) };
    }

    private async Task<(int Code, string Message)> ProbeAsync(HttpClient client, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await client.GetAsync(_options.Url, cancellationToken);
            return ((int)response.StatusCode, response.ReasonPhrase ?? response.StatusCode.ToString());
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            // Connection refused, DNS failure, timeout...: no HTTP status exists, report 0.
            return (0, $"Request failed: {ex.GetType().Name} - {ex.Message}");
        }
    }

    private async Task WriteLogAsync(int code, string message, CancellationToken cancellationToken)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} | {_options.Url} | {code} | {message}{Environment.NewLine}";
        await File.AppendAllTextAsync(_logPath, line, cancellationToken);
    }

    private static async Task<bool> WaitForNextTickAsync(PeriodicTimer timer, CancellationToken cancellationToken)
    {
        try
        {
            return await timer.WaitForNextTickAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
}
