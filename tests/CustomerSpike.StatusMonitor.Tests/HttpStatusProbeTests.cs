using System.Net;
using CustomerSpike.StatusMonitor;
using Microsoft.Extensions.Options;

namespace CustomerSpike.StatusMonitor.Tests;

public class HttpStatusProbeTests
{
    [Theory]
    [InlineData(HttpStatusCode.OK, 200, "OK")]
    [InlineData(HttpStatusCode.NotFound, 404, "Not Found")]
    [InlineData(HttpStatusCode.ServiceUnavailable, 503, "Service Unavailable")]
    public async Task Reports_the_http_status_code_and_reason(HttpStatusCode status, int expectedCode, string expectedMessage)
    {
        using var probe = CreateProbe(new StubHandler(_ => new HttpResponseMessage(status)));

        var result = await probe.ProbeAsync(CancellationToken.None);

        Assert.Equal(expectedCode, result.Code);
        Assert.Equal(expectedMessage, result.Message);
    }

    [Fact]
    public async Task Network_errors_are_reported_as_code_0()
    {
        using var probe = CreateProbe(new StubHandler(_ => throw new HttpRequestException("connection refused")));

        var result = await probe.ProbeAsync(CancellationToken.None);

        Assert.Equal(0, result.Code);
        Assert.Contains("connection refused", result.Message);
    }

    [Fact]
    public async Task Cancellation_is_not_swallowed()
    {
        using var probe = CreateProbe(new StubHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)));
        using var cts = new CancellationTokenSource();
        await cts.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => probe.ProbeAsync(cts.Token));
    }

    private static HttpStatusProbe CreateProbe(HttpMessageHandler handler) =>
        new(Options.Create(new StatusMonitorOptions { Url = "http://test.invalid/health" }), handler);

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }
}
