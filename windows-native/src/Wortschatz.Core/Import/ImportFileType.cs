namespace Wortschatz.Core;

/// <summary>
/// Port of ImportFileType.swift (file type detection of src/import/files.js): extension and MIME type
/// (<c>detectFileKind</c>) plus content sniffing (<c>sniff</c>), so mislabeled files (a PDF without extension)
/// still work.
/// </summary>
public static class ImportFileType
{
    /// <summary>The extensions the file picker offers (JS <c>ACCEPT</c>, without the MIME wildcards).</summary>
    public static readonly IReadOnlyList<string> AcceptedExtensions = ["txt", "text", "csv", "tsv", "tab", "md", "pdf", "heic", "heif"];

    /// <summary>
    /// Every extension the importer reads by name: text, PDF and images (for a Windows file dialog filter;
    /// replaces the UTType list <c>supportedContentTypes</c> of the Mac app).
    /// </summary>
    public static IReadOnlyList<string> SupportedExtensions =>
        TextExtensions.Concat(["pdf"]).Concat(ImageExtensions).Distinct().ToList();

    internal static readonly HashSet<string> TextExtensions = ["txt", "text", "csv", "tsv", "tab", "md", "markdown"];
    internal static readonly HashSet<string> ImageExtensions =
        ["png", "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp", "heic", "heif", "webp", "gif", "bmp", "avif", "tif", "tiff"];
    internal static readonly HashSet<string> DocumentExtensions =
        ["doc", "docx", "odt", "pages", "rtf", "xls", "xlsx", "numbers", "key", "ppt", "pptx"];
    static readonly HashSet<string> TextTypes = ["application/csv", "application/x-csv", "application/tab-separated-values"];
    static readonly HashSet<string> NonTextTextTypes = ["text/html", "text/rtf", "text/xml", "text/javascript", "text/css"];

    /// <summary>What the content sniffing found (JS <c>sniff</c>): Heic is reported separately from other images.</summary>
    public enum Sniffed { Pdf, Image, Heic }

    /// <summary>Text, Pdf, Image or null (unsupported), from the MIME type and the file name (JS <c>detectFileKind</c>).</summary>
    public static ImportFileKind? DetectKind(string name, string mimeType)
    {
        var ext = ExtensionOf(name);
        var type = NormalizedMIME(mimeType);
        if (type == "application/pdf" || ext == "pdf") return ImportFileKind.Pdf;
        if (DocumentExtensions.Contains(ext)) return null;
        if (TextExtensions.Contains(ext)) return ImportFileKind.Text;
        if (type == "image/svg+xml" || ext == "svg") return null;
        if (ImageExtensions.Contains(ext) || type.StartsWith("image/", StringComparison.Ordinal)) return ImportFileKind.Image;
        if (NonTextTextTypes.Contains(type)) return null;
        if (type.StartsWith("text/", StringComparison.Ordinal) || TextTypes.Contains(type)) return ImportFileKind.Text;
        if (ext.Length == 0 && type.Length == 0) return ImportFileKind.Text;
        return null;
    }

    /// <summary>The kind decided from the first bytes (JS <c>sniff</c>), null when the bytes are not recognised.</summary>
    public static Sniffed? Sniff(ReadOnlySpan<byte> bytes)
    {
        var b = bytes[..Math.Min(16, bytes.Length)].ToArray();
        bool Ascii(int from, string s)
        {
            for (int i = 0; i < s.Length; i++) if (b[from + i] != s[i]) return false;
            return true;
        }
        if (b.Length >= 5 && Ascii(0, "%PDF-")) return Sniffed.Pdf;
        if (b.Length >= 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return Sniffed.Image;
        if (b.Length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return Sniffed.Image;
        if (b.Length >= 4 && Ascii(0, "GIF8")) return Sniffed.Image;
        if (b.Length >= 12 && Ascii(0, "RIFF") && Ascii(8, "WEBP")) return Sniffed.Image;
        if (b.Length >= 12 && Ascii(4, "ftyp"))
        {
            foreach (var brand in new[] { "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" })
                if (Ascii(8, brand)) return Sniffed.Heic;
            if (Ascii(8, "avif") || Ascii(8, "avis")) return Sniffed.Image;
        }
        return null;
    }

    /// <summary>The kind used for the import (JS <c>readImportFile</c>): sniffed content wins over the name.</summary>
    public static ImportFileKind? ResolveKind(string name, string mimeType, Sniffed? sniffed) => sniffed switch
    {
        Sniffed.Pdf => ImportFileKind.Pdf,
        Sniffed.Image or Sniffed.Heic => ImportFileKind.Image,
        _ => DetectKind(name, mimeType),
    };

    /// <summary>The message for an unsupported file: office documents get a hint to paste the text or save as PDF.</summary>
    public static string UnsupportedMessage(string name) =>
        DocumentExtensions.Contains(ExtensionOf(name)) ? ImportMessages.Document : ImportMessages.Unsupported;

    /// <summary>
    /// Lower-cased extension after the last dot; "" for none, a leading dot (".bashrc") or a trailing dot
    /// (JS <c>extensionOf</c>).
    /// </summary>
    public static string ExtensionOf(string name)
    {
        var n = JSCompat.Lower(name);
        int dot = n.LastIndexOf('.');
        return dot > 0 && dot < n.Length - 1 ? n[(dot + 1)..] : "";
    }

    /// <summary><c>type.toLowerCase().split(';')[0].trim()</c></summary>
    internal static string NormalizedMIME(string type) => JSCompat.Lower(type).Split(';', 2)[0].Trim();

    /// <summary>
    /// The MIME type of a file extension ("" when unknown); stands in for <c>UTType.preferredMIMEType</c> in
    /// <see cref="ImportSource.FromFile"/>.
    /// </summary>
    public static string MimeTypeFor(string extension) => JSCompat.Lower(extension) switch
    {
        "txt" or "text" => "text/plain",
        "csv" => "text/csv",
        "tsv" or "tab" => "text/tab-separated-values",
        "md" or "markdown" => "text/markdown",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" or "jpeg" or "jpe" or "jfif" or "pjpeg" or "pjp" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "tif" or "tiff" => "image/tiff",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "avif" => "image/avif",
        "svg" => "image/svg+xml",
        "html" or "htm" => "text/html",
        "rtf" => "text/rtf",
        "xml" => "text/xml",
        "css" => "text/css",
        "js" => "text/javascript",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt" => "application/vnd.oasis.opendocument.text",
        "zip" => "application/zip",
        _ => "",
    };
}
