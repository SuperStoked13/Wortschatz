namespace Wortschatz.Core;

// Port of ImportTypes.swift: shared types of the importers (the contracts of src/import/files.js,
// pdf.js and ocr.js). All user-facing text is German with Swiss spelling.

/// <summary>What an imported file contained (JS <c>kind</c>).</summary>
public enum ImportFileKind { Text, Pdf, Image }

/// <summary>
/// A file to import: either bytes or a path (read lazily), with name and MIME type ("" when unknown).
/// The name is shown in messages and used as a set title ("" for pasted content). Like a browser's
/// <c>File.type</c>, the MIME type is only a hint: the content is sniffed as well.
/// </summary>
public sealed record ImportSource(string Name, string MimeType = "", byte[]? Data = null, string? FilePath = null)
{
    /// <summary>A file on disk; the name is its file name, the MIME type comes from its extension (Swift <c>init(url:)</c>).</summary>
    public static ImportSource FromFile(string path) =>
        new(Path.GetFileName(path), ImportFileType.MimeTypeFor(ImportFileType.ExtensionOf(Path.GetFileName(path))), FilePath: path);

    /// <summary>Bytes in memory. Pasted content has no name.</summary>
    public static ImportSource FromData(byte[] data, string name = "", string mimeType = "") => new(name, mimeType, data);
}

/// <summary>
/// The text read from one file (JS <c>{ text, kind, name, warnings }</c>). Warnings: German messages about
/// content that could not be read although the import worked (e.g. scanned pages of a text PDF).
/// </summary>
public sealed record ImportedFile(string Text, ImportFileKind Kind, string Name, IReadOnlyList<string> Warnings)
{
    public ImportedFile(string text, ImportFileKind kind, string name) : this(text, kind, name, []) { }
}

/// <summary>Progress of a running import: a fraction 0…1 and a German status line.</summary>
public readonly record struct ImportProgress(double Fraction, string Message);

/// <summary>The kind of an import failure (Swift <c>ImportError.Code</c>; raw values like the JS <c>err.code</c>).</summary>
public enum ImportErrorCode
{
    /// <summary>Not a text file, PDF or image (also binary data in a "text" file).</summary>
    Unsupported,
    /// <summary>The file has no bytes.</summary>
    Empty,
    /// <summary>A text file above 5 MB.</summary>
    TooLarge,
    /// <summary>The file could not be read (missing, a folder, no permission).</summary>
    Read,
    /// <summary>The import was cancelled.</summary>
    Aborted,
    /// <summary>The PDF or image contained no readable text.</summary>
    NoText,
    /// <summary>The image could not be decoded.</summary>
    Decode,
    /// <summary>Text recognition failed.</summary>
    OcrFailed,
    /// <summary>The PDF is password protected.</summary>
    PdfPassword,
    /// <summary>The PDF is damaged or not a PDF.</summary>
    PdfInvalid,
    /// <summary>Any other PDF failure.</summary>
    PdfFailed,
    /// <summary>More scanned pages than text recognition handles.</summary>
    PdfTooManyPages,
}

/// <summary>An import failure with a German, user-presentable message (JS errors with <c>err.code</c>).</summary>
public sealed class ImportError(ImportErrorCode code, string message, Exception? inner = null) : Exception(message, inner)
{
    public ImportErrorCode Code { get; } = code;

    /// <summary><c>Import abgebrochen.</c> (a new instance on every call).</summary>
    public static ImportError Aborted => new(ImportErrorCode.Aborted, ImportMessages.Aborted);

    public override string ToString() => $"{Code.Raw()}: {Message}";

    /// <summary>
    /// Maps any error of an import step: cancellation becomes Aborted, an ImportError stays, anything
    /// else becomes <paramref name="fallback"/>.
    /// </summary>
    internal static ImportError Wrap(Exception error, ImportError fallback, CancellationToken ct)
    {
        if (error is ImportError importError) return importError;
        if (error is OperationCanceledException || ct.IsCancellationRequested) return Aborted;
        return fallback;
    }

    /// <summary>Throws Aborted when <paramref name="ct"/> is cancelled (Swift <c>Task.checkImportCancellation</c>).</summary>
    internal static void CheckCancellation(CancellationToken ct)
    {
        if (ct.IsCancellationRequested) throw Aborted;
    }
}

/// <summary>The German messages of the web importers (Swiss spelling).</summary>
public static class ImportMessages
{
    public const string Unsupported = "Dieses Dateiformat wird nicht unterstützt.";
    public const string Document =
        Unsupported + " Kopiere den Text aus dem Dokument und füge ihn ins Textfeld ein – oder speichere es als PDF.";
    public const string Empty = "Die Datei ist leer.";
    public const string TooLarge = "Die Textdatei ist zu gross (maximal 5 MB).";
    public const string PdfEmpty = "In der PDF-Datei wurde kein Text gefunden.";
    public const string Read = "Die Datei konnte nicht gelesen werden. Ist sie noch vorhanden und vollständig heruntergeladen?";
    public const string Aborted = "Import abgebrochen.";
    public const string ImageEmpty =
        "Auf dem Bild wurde kein Text erkannt. Achte auf gutes Licht und eine scharfe Aufnahme und fotografiere die Seite möglichst gerade.";
    public const string OcrFailed =
        "Die Texterkennung ist fehlgeschlagen. Versuche es mit einem schärferen Foto oder einem Screenshot.";
    public const string Decode = "Das Bild konnte nicht geöffnet werden.";
    public const string PdfPassword =
        "Diese PDF-Datei ist passwortgeschützt. Entferne den Schutz oder kopiere den Text direkt aus der PDF.";
    public const string PdfInvalid = "Die PDF-Datei ist beschädigt oder keine gültige PDF.";
    public const string PdfFailed = "Die PDF-Datei konnte nicht gelesen werden.";
    /// <summary>Fallback for a failed file in a batch (editor-import.js).</summary>
    public const string FileFailed = "Die Datei konnte nicht gelesen werden.";

    public static string PdfTooManyPages(int count) =>
        $"Diese PDF-Datei enthält {count} gescannte Seiten. Die Texterkennung ist auf {PDFTextExtractor.MaxOCRPages} Seiten beschränkt – teile die Datei bitte auf.";

    // Progress lines.
    public const string ReadingFile = "Datei wird gelesen …";
    public const string FileRead = "Datei gelesen";
    public const string PreparingImage = "Bild wird vorbereitet …";
    public const string Recognizing = "Texterkennung läuft …";
    public const string Recognized = "Text erkannt";
    public const string OpeningPDF = "PDF wird geöffnet …";
    public const string ReadingPDF = "PDF wird gelesen …";
    public const string PdfRead = "PDF gelesen";
    public const string PdfReadPartially = "PDF gelesen – gescannte Seiten konnten nicht erkannt werden.";
}

/// <summary>
/// Clamps and forwards progress like the web <c>reporter()</c>: fractions are kept within 0…1 and a
/// sub-reporter maps its own 0…1 onto a slice of its parent.
/// </summary>
internal sealed class ProgressReporter
{
    readonly Action<ImportProgress>? _handler;
    readonly double _start;
    readonly double _span;
    readonly string _prefix;

    public ProgressReporter(Action<ImportProgress>? handler) : this(handler, 0, 1, "") { }

    ProgressReporter(Action<ImportProgress>? handler, double start, double span, string prefix)
    {
        _handler = handler;
        _start = start;
        _span = span;
        _prefix = prefix;
    }

    public void Report(double fraction, string message)
    {
        if (_handler is null) return;
        double value = _start + _span * Clamp(fraction);
        _handler(new ImportProgress(Clamp(value), _prefix + message));
    }

    /// <summary>A reporter whose 0…1 covers from…from + width of this one, with <paramref name="prefix"/> before every message.</summary>
    public ProgressReporter Slice(double from, double width, string prefix = "") =>
        new(_handler, _start + _span * Clamp(from), _span * Math.Max(0, width), _prefix + prefix);

    static double Clamp(double x) => double.IsNaN(x) ? 0 : Math.Min(1, Math.Max(0, x));
}
