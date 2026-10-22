using System.Collections.Concurrent;

namespace CustomerSpike.Web;

public sealed record Customer(
    Guid Id,
    string FullName,
    string Email,
    string? Phone,
    string? Country,
    DateTimeOffset CreatedAt);

public sealed record CreateCustomerRequest(
    string? FullName,
    string? Email,
    string? Phone,
    string? Country);

public interface ICustomerStore
{
    IReadOnlyList<Customer> GetAll();

    Customer Add(CreateCustomerRequest request);
}

/// <summary>Spike-grade storage: data lives in memory and is lost on restart.</summary>
public sealed class InMemoryCustomerStore : ICustomerStore
{
    private readonly ConcurrentDictionary<Guid, Customer> _customers = new();

    public IReadOnlyList<Customer> GetAll() =>
        _customers.Values.OrderBy(c => c.CreatedAt).ToList();

    public Customer Add(CreateCustomerRequest request)
    {
        var customer = new Customer(
            Guid.NewGuid(),
            request.FullName!.Trim(),
            request.Email!.Trim(),
            string.IsNullOrWhiteSpace(request.Phone) ? null : request.Phone.Trim(),
            string.IsNullOrWhiteSpace(request.Country) ? null : request.Country.Trim(),
            DateTimeOffset.UtcNow);

        _customers[customer.Id] = customer;
        return customer;
    }
}
