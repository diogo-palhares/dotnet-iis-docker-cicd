namespace CustomerSpike.StatusMonitor;

/// <summary>Abstracts the termination of the process so the failure path can be unit-tested.</summary>
public interface IExitHandler
{
    void Exit(int exitCode);
}

public sealed class ProcessExitHandler : IExitHandler
{
    // Terminating with a non-zero exit code makes the Service Control Manager treat the stop as a failure,
    // so the recovery action configured at install time (restart after 300s) applies.
    public void Exit(int exitCode) => Environment.Exit(exitCode);
}
