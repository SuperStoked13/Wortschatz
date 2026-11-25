#if WINDOWS
using System.Net;
using System.Net.Http.Headers;
using Wortschatz.Core;

namespace Wortschatz.App.Services;

/// <summary>
/// How <see cref="AppUpdater"/> reaches GitHub: HTTPS through the system's proxy, no cookies, no cache on disk, a user
/// agent with the app's version only (GitHub refuses requests without one). An update test may read file:// addresses.
/// </summary>
sealed class HttpUpdateTransport(bool allowFiles) : IUpdateTransport
{
    static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(20),
        PooledConnectionLifetime = TimeSpan.FromMinutes(5),
    })
    {
        Timeout = Timeout.InfiniteTimeSpan,
        DefaultRequestHeaders =
        {
            UserAgent = { new ProductInfoHeaderValue("Wortschatz", UpdateFeed.Display(AppUpdater.Current)), new ProductInfoHeaderValue("(Windows)") },
        },
    };

    /// <summary>A small file must come within this time; the exe has the caller's limit (20 minutes for a whole look).</summary>
    static readonly TimeSpan SmallFileTimeout = TimeSpan.FromSeconds(30);

    public async Task<byte[]> GetAsync(string url, int maxBytes, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(SmallFileTimeout);
        await DownloadAsync(url, buffer, maxBytes, timeout.Token);
        return buffer.ToArray();
    }

    public async Task DownloadAsync(string url, Stream target, long maxBytes, CancellationToken ct)
    {
        var uri = new Uri(url);
        if (uri.IsFile)
        {
            if (!allowFiles) throw new InvalidOperationException("file addresses only in an update test");
            await using var file = File.OpenRead(uri.LocalPath);
            await CopyLimited(file, target, maxBytes, ct);
            return;
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        if (uri.Host == "api.github.com")
        {
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.Add("X-GitHub-Api-Version", "2022-11-28");
        }
        using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (response.StatusCode != HttpStatusCode.OK) throw new HttpRequestException($"HTTP {(int)response.StatusCode} for {uri.Host}");
        // Every hop of GitHub's redirects (to its file storage) must stay on HTTPS.
        if (response.RequestMessage?.RequestUri is { } final && final.Scheme != Uri.UriSchemeHttps && !allowFiles)
            throw new HttpRequestException($"redirected to {final.Scheme}");
        if (response.Content.Headers.ContentLength is { } length && length > maxBytes) throw new HttpRequestException($"{length} bytes, at most {maxBytes}");
        await using var body = await response.Content.ReadAsStreamAsync(ct);
        await CopyLimited(body, target, maxBytes, ct);
    }

    static async Task CopyLimited(Stream source, Stream target, long maxBytes, CancellationToken ct)
    {
        var buffer = new byte[81920];
        long total = 0;
        int read;
        while ((read = await source.ReadAsync(buffer, ct)) > 0)
        {
            total += read;
            if (total > maxBytes) throw new HttpRequestException($"more than {maxBytes} bytes");
            await target.WriteAsync(buffer.AsMemory(0, read), ct);
        }
    }
}
#endif
