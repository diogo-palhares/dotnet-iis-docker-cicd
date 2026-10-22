using System.Net;
using System.Net.Http.Json;
using CustomerSpike.Web;
using Microsoft.AspNetCore.Mvc.Testing;

namespace CustomerSpike.Web.Tests;

public class CustomerApiTests : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly HttpClient _client;

    public CustomerApiTests(WebApplicationFactory<Program> factory) => _client = factory.CreateClient();

    [Fact]
    public async Task Health_returns_200()
    {
        var response = await _client.GetAsync("/health");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }

    [Fact]
    public async Task Post_with_valid_data_creates_customer_and_lists_it()
    {
        var request = new CreateCustomerRequest("Ada Lovelace", "ada@example.com", null, "UK");

        var created = await _client.PostAsJsonAsync("/api/customers", request);
        var customers = await _client.GetFromJsonAsync<List<Customer>>("/api/customers");

        Assert.Equal(HttpStatusCode.Created, created.StatusCode);
        Assert.Contains(customers!, c => c.Email == "ada@example.com" && c.FullName == "Ada Lovelace");
    }

    [Theory]
    [InlineData(null, "ok@example.com")]
    [InlineData("  ", "ok@example.com")]
    [InlineData("Valid Name", "not-an-email")]
    [InlineData("Valid Name", null)]
    public async Task Post_with_invalid_data_returns_400(string? fullName, string? email)
    {
        var response = await _client.PostAsJsonAsync("/api/customers", new CreateCustomerRequest(fullName, email, null, null));

        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
    }

    [Fact]
    public async Task Root_serves_the_customer_page()
    {
        var html = await _client.GetStringAsync("/");

        Assert.Contains("Customer Spike", html);
    }
}
