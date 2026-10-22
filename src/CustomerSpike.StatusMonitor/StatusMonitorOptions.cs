namespace CustomerSpike.StatusMonitor;

public sealed class StatusMonitorOptions
{
    public const string SectionName = "StatusMonitor";

    /// <summary>URL probed on every cycle (the web app health endpoint).</summary>
    public string Url { get; set; } = "http://localhost:8080/customers/health";

    public int IntervalSeconds { get; set; } = 60;

    public int TimeoutSeconds { get; set; } = 10;

    /// <summary>Log file name, created next to the executable.</summary>
    public string LogFileName { get; set; } = "status.log";

    /// <summary>Only for localhost HTTPS with a self-signed certificate.</summary>
    public bool AllowUntrustedCertificate { get; set; }
}
