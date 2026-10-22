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
    private readonly IStatusProbe _probe;
    private readonly IExitHandler _exitHandler;
    private readonly ILogger<Worker> _logger;
    private readonly string _logPath;

    public Worker(IOptions<StatusMonitorOptions> options, IStatusProbe probe, IExitHandler exitHandler, ILogger<Worker> logger)
    {
        _options = options.Value;
        _probe = probe;
        _exitHandler = exitHandler;
        _logger = logger;

        // AppContext.BaseDirectory, not the working directory: a Windows service starts in System32.
        var directory = string.IsNullOrWhiteSpace(_options.LogDirectory) ? AppContext.BaseDirectory : _options.LogDirectory;
        _logPath = Path.Combine(directory, _options.LogFileName);
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(_options.IntervalSeconds));

        _logger.LogInformation("Monitoring {Url} every {Interval}s, log file: {LogPath}",
            _options.Url, _options.IntervalSeconds, _logPath);

        // Probe immediately, then once per interval.
        do
        {
            var result = await _probe.ProbeAsync(stoppingToken);
            await WriteLogAsync(result, stoppingToken);

            if (result.Code != (int)HttpStatusCode.OK)
            {
                _logger.LogError("Unexpected status {Code} ({Message}); stopping the service.", result.Code, result.Message);
                _exitHandler.Exit(1);
                return; // the real handler never returns; test doubles do
            }
        }
        while (await WaitForNextTickAsync(timer, stoppingToken));
    }

    private async Task WriteLogAsync(ProbeResult result, CancellationToken cancellationToken)
    {
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz} | {_options.Url} | {result.Code} | {result.Message}{Environment.NewLine}";
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
