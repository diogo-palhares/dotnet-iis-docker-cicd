using System.Net.Mail;
using CustomerSpike.Web;

// Container HEALTHCHECK entry point: the aspnet base image has no curl/wget, so the app probes itself.
if (args.Contains("--healthcheck"))
{
    var port = Environment.GetEnvironmentVariable("ASPNETCORE_HTTP_PORTS")?.Split(';')[0] ?? "8080";
    using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
    try
    {
        using var response = await client.GetAsync($"http://localhost:{port}/health");
        return response.IsSuccessStatusCode ? 0 : 1;
    }
    catch (HttpRequestException)
    {
        return 1;
    }
    catch (TaskCanceledException)
    {
        return 1;
    }
}

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<ICustomerStore, InMemoryCustomerStore>();

var app = builder.Build();

app.UseDefaultFiles();
app.UseStaticFiles();

// Liveness endpoint polled by the StatusMonitor Windows service and by container health checks.
app.MapGet("/health", () => Results.Ok(new { status = "Healthy", timestampUtc = DateTimeOffset.UtcNow }));

var customers = app.MapGroup("/api/customers");

customers.MapGet("", (ICustomerStore store) => Results.Ok(store.GetAll()));

customers.MapPost("", (CreateCustomerRequest request, ICustomerStore store, HttpContext http) =>
{
    var errors = Validate(request);
    if (errors.Count > 0)
    {
        return Results.ValidationProblem(errors);
    }

    var customer = store.Add(request);
    // PathBase keeps the Location header correct when the app is hosted as an IIS sub-application.
    return Results.Created($"{http.Request.PathBase}/api/customers/{customer.Id}", customer);
});

app.Run();
return 0;

static Dictionary<string, string[]> Validate(CreateCustomerRequest request)
{
    var errors = new Dictionary<string, string[]>();

    if (string.IsNullOrWhiteSpace(request.FullName))
    {
        errors[nameof(request.FullName)] = ["Full name is required."];
    }

    if (string.IsNullOrWhiteSpace(request.Email) || !MailAddress.TryCreate(request.Email, out _))
    {
        errors[nameof(request.Email)] = ["A valid e-mail address is required."];
    }

    return errors;
}

// Exposed so integration tests can use WebApplicationFactory<Program>.
public partial class Program;
