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
    // GPT-5.6 Sol API-equivalent rates supplied by the user, per 1 million tokens.
    // Codex JSONL does not expose cache-write tokens, so cache-write pricing is excluded.
    private const decimal InputUsdPerMillion = 5.00m;
    private const decimal CachedInputUsdPerMillion = 0.50m;
    private const decimal OutputUsdPerMillion = 30.00m;
    private const decimal TokensPerMillion = 1_000_000m;

    public static TokenCostEstimate Estimate(TokenSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        return new TokenCostEstimate(
            Cost(snapshot.UncachedInputTokens, InputUsdPerMillion),
            Cost(snapshot.CachedInputTokens, CachedInputUsdPerMillion),
            Cost(snapshot.OutputTokens, OutputUsdPerMillion));
    }

    private static decimal Cost(long tokens, decimal usdPerMillion) =>
        Math.Max(0, tokens) * usdPerMillion / TokensPerMillion;
}
