using CustomerSpike.StatusMonitor;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace CustomerSpike.StatusMonitor.Tests;

public sealed class WorkerTests : IDisposable
{
    private readonly string _directory = Directory.CreateTempSubdirectory("status-monitor-tests-").FullName;

    private string LogPath => Path.Combine(_directory, "status.log");

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    [Fact]
    public async Task Healthy_site_is_logged_every_interval_and_the_process_keeps_running()
    {
        var probe = new FakeProbe(new ProbeResult(200, "OK"));
        var exit = new FakeExit();
        using var worker = CreateWorker(probe, exit, intervalSeconds: 1);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => ReadLog().Length >= 2);
        await worker.StopAsync(CancellationToken.None);

        Assert.All(ReadLog(), line => Assert.Contains("| 200 | OK", line));
        Assert.Null(exit.ExitCode);
    }

    [Fact]
    public async Task Non_200_status_is_logged_and_the_process_exits_with_code_1()
    {
        var probe = new FakeProbe(new ProbeResult(503, "Service Unavailable"));
        var exit = new FakeExit();
        using var worker = CreateWorker(probe, exit, intervalSeconds: 60);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => exit.ExitCode is not null);
        await worker.StopAsync(CancellationToken.None);

        Assert.Equal(1, exit.ExitCode);
        Assert.Equal(1, probe.Calls);
        var line = Assert.Single(ReadLog());
        Assert.Contains("| 503 | Service Unavailable", line);
    }

    [Fact]
    public async Task Failing_after_healthy_checks_stops_at_the_first_bad_status()
    {
        var probe = new FakeProbe(new ProbeResult(200, "OK"), new ProbeResult(500, "Internal Server Error"), new ProbeResult(200, "OK"));
        var exit = new FakeExit();
        using var worker = CreateWorker(probe, exit, intervalSeconds: 1);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => exit.ExitCode is not null);
        await worker.StopAsync(CancellationToken.None);

        Assert.Equal(1, exit.ExitCode);
        Assert.Equal(2, probe.Calls);
        var lines = ReadLog();
        Assert.Equal(2, lines.Length);
        Assert.Contains("| 200 | OK", lines[0]);
        Assert.Contains("| 500 | Internal Server Error", lines[1]);
    }

    [Fact]
    public async Task Unreachable_site_is_treated_as_a_failure()
    {
        var probe = new FakeProbe(new ProbeResult(0, "Request failed: HttpRequestException - connection refused"));
        var exit = new FakeExit();
        using var worker = CreateWorker(probe, exit, intervalSeconds: 60);

        await worker.StartAsync(CancellationToken.None);
        await WaitUntilAsync(() => exit.ExitCode is not null);
        await worker.StopAsync(CancellationToken.None);

        Assert.Equal(1, exit.ExitCode);
        Assert.Contains("| 0 | Request failed", Assert.Single(ReadLog()));
    }

    private Worker CreateWorker(FakeProbe probe, FakeExit exit, int intervalSeconds)
    {
        var options = Options.Create(new StatusMonitorOptions
        {
            Url = "http://test.invalid/health",
            IntervalSeconds = intervalSeconds,
            LogDirectory = _directory,
            LogFileName = "status.log"
        });

        return new Worker(options, probe, exit, NullLogger<Worker>.Instance);
    }

    private string[] ReadLog()
    {
        if (!File.Exists(LogPath))
        {
            return [];
        }

        // The worker may be appending at the same moment, so open with shared access.
        using var stream = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "Timed out waiting for the expected condition.");
            await Task.Delay(50);
        }
    }

    private sealed class FakeProbe(params ProbeResult[] results) : IStatusProbe
    {
        private int _calls;

        public int Calls => _calls;

        public Task<ProbeResult> ProbeAsync(CancellationToken cancellationToken)
        {
            var index = Interlocked.Increment(ref _calls) - 1;
            return Task.FromResult(results[Math.Min(index, results.Length - 1)]);
        }
    }

    private sealed class FakeExit : IExitHandler
    {
        public int? ExitCode { get; private set; }

        public void Exit(int exitCode) => ExitCode = exitCode;
    }
}
