namespace CodexTokenOverlay;

internal sealed record TokenCostEstimate(
    decimal InputCostUsd,
    decimal CachedInputCostUsd,
    decimal OutputCostUsd)
{
    public decimal TotalCostUsd => InputCostUsd + CachedInputCostUsd + OutputCostUsd;
}

internal static class TokenCostEstimator
{
    // Current standard-context API-equivalent rates per 1 million tokens.
    // Luna uses the reduced $0.20 / $0.02 / $1.20 rates published by OpenAI.
    // Codex JSONL does not expose cache-write tokens, so cache-write pricing is excluded.
    private static readonly ModelRates SolRates = new(5.00m, 0.50m, 30.00m);
    private static readonly ModelRates LunaRates = new(0.20m, 0.02m, 1.20m);
    private const decimal TokensPerMillion = 1_000_000m;

    public static TokenCostEstimate Estimate(TokenSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var usages = snapshot.PricingUsages.Count > 0
            ? snapshot.PricingUsages
            : new[]
            {
                new TokenPricingUsage(
                    "gpt-5.6-sol",
                    snapshot.TotalTokens,
                    snapshot.InputTokens,
                    snapshot.CachedInputTokens,
                    snapshot.OutputTokens,
                    IsMainAgent: true)
            };

        return Estimate(usages);
    }

    public static TokenCostEstimate Estimate(IEnumerable<TokenPricingUsage> usages)
    {
        ArgumentNullException.ThrowIfNull(usages);

        var input = 0m;
        var cached = 0m;
        var output = 0m;
        foreach (var usage in usages)
        {
            var rates = RatesFor(usage.Model);
            input += Cost(usage.UncachedInputTokens, rates.InputUsdPerMillion);
            cached += Cost(usage.CachedInputTokens, rates.CachedInputUsdPerMillion);
            output += Cost(usage.OutputTokens, rates.OutputUsdPerMillion);
        }

        return new TokenCostEstimate(input, cached, output);
    }

    private static ModelRates RatesFor(string? model) =>
        model?.Contains("luna", StringComparison.OrdinalIgnoreCase) == true
            ? LunaRates
            : SolRates;

    private static decimal Cost(long tokens, decimal usdPerMillion) =>
        Math.Max(0, tokens) * usdPerMillion / TokensPerMillion;

    private readonly record struct ModelRates(
        decimal InputUsdPerMillion,
        decimal CachedInputUsdPerMillion,
        decimal OutputUsdPerMillion);
}
