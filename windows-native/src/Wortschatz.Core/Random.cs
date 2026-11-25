using System.Security.Cryptography;

namespace Wortschatz.Core;

/// <summary>
/// Port of Random.swift: a source of random numbers in [0, 1) like JS <c>Math.random</c>.
/// Engines take an <see cref="RNG"/> so tests replay exact sequences with <see cref="Rand.Mulberry32(uint)"/>.
/// </summary>
public delegate double RNG();

public static class Rand
{
    /// <summary>The seeded PRNG of the web tests, bit-for-bit identical (wrapping uint arithmetic).</summary>
    public static RNG Mulberry32(uint seed)
    {
        uint a = seed;
        return () =>
        {
            unchecked
            {
                a += 0x6D2B79F5;
                uint t = a;
                t = (t ^ (t >> 15)) * (t | 1);
                t ^= t + ((t ^ (t >> 7)) * (t | 61));
                return (t ^ (t >> 14)) / 4294967296.0;
            }
        };
    }

    /// <summary>JS <c>seed &gt;&gt;&gt; 0</c> for any integer seed.</summary>
    public static RNG Mulberry32(long seed) => Mulberry32(unchecked((uint)seed));

    /// <summary>The system random source (<c>Math.random</c>), unless <see cref="Fixed"/> stands in for it.</summary>
    public static RNG SystemRNG() => Fixed ?? (() => Random.Shared.NextDouble());

    /// <summary>
    /// A seeded source every engine takes instead of the system's (null: random). The snapshot tool sets it: every run
    /// asks the same questions in the same order, so two runs draw the same pictures and a change can be compared.
    /// </summary>
    public static RNG? Fixed { get; set; }
}

/// <summary>Port of IDGen.swift (src/lib/id.js): random, URL-safe identifiers.</summary>
public static class IDGen
{
    public const string ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
    public const int DEFAULT_SIZE = 16;

    /// <summary>A url-safe id of <paramref name="size"/> characters (minimum 12; 0 = 16).</summary>
    public static string Uid(int size = DEFAULT_SIZE)
    {
        int n = size == 0 ? DEFAULT_SIZE : Math.Max(12, size);
        Span<byte> bytes = stackalloc byte[n];
        RandomNumberGenerator.Fill(bytes);
        var chars = new char[n];
        for (int i = 0; i < n; i++) chars[i] = ALPHABET[bytes[i] & 63];
        return new string(chars);
    }
}
