# syntax=docker/dockerfile:1

# ---- build -----------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Restore first so this layer is cached until a project file changes.
COPY global.json Directory.Build.props ./
COPY src/CustomerSpike.Web/CustomerSpike.Web.csproj src/CustomerSpike.Web/
RUN dotnet restore src/CustomerSpike.Web/CustomerSpike.Web.csproj

COPY src/CustomerSpike.Web/ src/CustomerSpike.Web/
ARG VERSION=1.0.0
RUN dotnet publish src/CustomerSpike.Web/CustomerSpike.Web.csproj \
    -c Release --no-restore -p:Version=${VERSION} -o /app/publish

# ---- runtime ---------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
COPY --from=build /app/publish .

# The .NET 8 images listen on port 8080 and ship a non-root "app" user.
EXPOSE 8080
USER $APP_UID

# No curl in the aspnet image: the app has a --healthcheck mode that probes its own /health endpoint.
HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
    CMD ["dotnet", "CustomerSpike.Web.dll", "--healthcheck"]
ENTRYPOINT ["dotnet", "CustomerSpike.Web.dll"]
