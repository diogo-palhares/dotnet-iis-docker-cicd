using CustomerSpike.StatusMonitor;

// Content root = executable folder, so appsettings.json is found when running as a Windows service
// (the service working directory would otherwise be C:\Windows\System32).
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory
});

builder.Services.AddWindowsService(options => options.ServiceName = "CustomerSpikeStatusMonitor");
builder.Services.Configure<StatusMonitorOptions>(builder.Configuration.GetSection(StatusMonitorOptions.SectionName));
builder.Services.AddSingleton<IStatusProbe, HttpStatusProbe>();
builder.Services.AddSingleton<IExitHandler, ProcessExitHandler>();
builder.Services.AddHostedService<Worker>();

builder.Build().Run();
