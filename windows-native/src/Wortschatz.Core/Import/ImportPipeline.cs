using static Wortschatz.Core.CoreText;

namespace Wortschatz.Core;

/// <summary>
/// Port of ImportPipeline.swift: turns dropped, picked or pasted files into text for the vocabulary
/// parser (<c>readImportFile</c> in src/import/files.js and the file loop of the web editor's import panel):
/// text files are decoded, PDFs go through the <see cref="IPdfReader"/>, photos and screenshots through
/// the <see cref="IImageDecoder"/> and the <see cref="ITextRecognizer"/>.
///
/// A missing component makes the files that need it fail with a message for the learner: no PDF reader →
/// pdfFailed («Die PDF-Datei konnte nicht gelesen werden.»), no image decoder → decode («Das Bild konnte
/// nicht geöffnet werden.»), no recognizer → ocrFailed (for scanned pages of a text PDF: a warning).
/// The work runs on the calling thread up to the first await of the recognizer; a UI calls it via Task.Run.
/// </summary>
public sealed class ImportPipeline
{
    /// <summary>Text files above this size are refused.</summary>
    public const int MaxTextBytes = 5 * 1024 * 1024;

    public ImportPipeline(IPdfReader? pdfReader = null, IImageDecoder? imageDecoder = null, ITextRecognizer? recognizer = null)
    {
        Ocr = new OCRService(recognizer, imageDecoder);
        Pdf = new PDFTextExtractor(pdfReader, Ocr);
    }

    public OCRService Ocr { get; }
    public PDFTextExtractor Pdf { get; }

    /// <summary>
    /// Reads one file. Text recognition uses the set's languages (<see cref="RecognitionLanguages.ForSet"/>).
    /// Throws ImportError with a message for the learner: unsupported, empty, tooLarge, read, noText, decode,
    /// ocrFailed, pdf…, or aborted when <paramref name="ct"/> is cancelled.
    /// </summary>
    public Task<ImportedFile> ReadAsync(ImportSource source, Lang? termLang = Lang.Fr, Lang? defLang = Lang.De,
        Action<ImportProgress>? progress = null, CancellationToken ct = default) =>
        ReadAsync(source, RecognitionLanguages.ForSet(termLang, defLang), new ProgressReporter(progress), ct);

    /// <summary>
    /// Reads several files one after another (the editor's drop and file picker). Texts are collected in
    /// order, failures and warnings get the file name as a «name»: prefix (none for pasted content). Only
    /// cancellation stops the batch: it throws ImportError aborted.
    /// </summary>
    public async Task<ImportBatch> ReadAllAsync(IReadOnlyList<ImportSource> sources, Lang? termLang = Lang.Fr, Lang? defLang = Lang.De,
        Action<ImportProgress>? progress = null, CancellationToken ct = default)
    {
        var languages = RecognitionLanguages.ForSet(termLang, defLang);
        var report = new ProgressReporter(progress);
        double count = sources.Count;
        var batch = new ImportBatch();
        for (int i = 0; i < sources.Count; i++)
        {
            ImportError.CheckCancellation(ct);
            var source = sources[i];
            string prefix = sources.Count > 1 ? L($"Datei {i + 1} von {sources.Count}") + ": " : "";
            string label = source.Name.Length == 0 ? "" : L($"«{source.Name}»: ");
            var fileReport = report.Slice(i / count, 1 / count, prefix);
            try
            {
                var file = await ReadAsync(source, languages, fileReport, ct).ConfigureAwait(false);
                batch.Files.Add(file);
                var text = JSCompat.Trim(file.Text);
                if (text.Length > 0)
                {
                    batch.Texts.Add(text);
                    if (batch.FirstName is null && file.Name.Length > 0) batch.FirstName = file.Name;
                }
                batch.Warnings.AddRange(file.Warnings.Select(w => label + w));
            }
            catch (ImportError error) when (error.Code != ImportErrorCode.Aborted)
            {
                batch.Failures.Add(new ImportFailure(source.Name, error, label + error.Message));
            }
        }
        return batch;
    }

    // MARK: - One file

    internal async Task<ImportedFile> ReadAsync(ImportSource source, IReadOnlyList<string> languages, ProgressReporter report, CancellationToken ct)
    {
        try
        {
            return await ReadFileAsync(source, languages, report, ct).ConfigureAwait(false);
        }
        catch (Exception error) when (error is not ImportError)
        {
            throw ImportError.Wrap(error, new ImportError(ImportErrorCode.Read, ImportMessages.FileFailed, error), ct);
        }
    }

    async Task<ImportedFile> ReadFileAsync(ImportSource source, IReadOnlyList<string> languages, ProgressReporter report, CancellationToken ct)
    {
        ImportError.CheckCancellation(ct);
        var file = new SourceBytes(source);
        if (file.Size == 0) throw new ImportError(ImportErrorCode.Empty, ImportMessages.Empty);

        var sniffed = ImportFileType.Sniff(file.Head);
        var kind = ImportFileType.ResolveKind(source.Name, source.MimeType, sniffed)
            ?? throw new ImportError(ImportErrorCode.Unsupported, ImportFileType.UnsupportedMessage(source.Name));

        switch (kind)
        {
            case ImportFileKind.Text:
            {
                if (file.Size > MaxTextBytes) throw new ImportError(ImportErrorCode.TooLarge, ImportMessages.TooLarge);
                report.Report(0, ImportMessages.ReadingFile);
                var data = file.Contents();
                ImportError.CheckCancellation(ct);
                var text = TextFileDecoder.Decode(data);
                if (text.Length > 0 && text[0] == '\uFEFF') text = text[1..];
                if (TextFileDecoder.LooksBinary(text)) throw new ImportError(ImportErrorCode.Unsupported, ImportMessages.Unsupported);
                report.Report(1, ImportMessages.FileRead);
                return new ImportedFile(text, ImportFileKind.Text, source.Name);
            }
            case ImportFileKind.Pdf:
            {
                var data = file.Contents();
                var output = await Pdf.ExtractTextAsync(data, languages, report, ct).ConfigureAwait(false);
                if (JSCompat.Trim(output.Text).Length == 0) throw new ImportError(ImportErrorCode.NoText, ImportMessages.PdfEmpty);
                return new ImportedFile(output.Text, ImportFileKind.Pdf, source.Name, output.Warnings);
            }
            default:
            {
                var data = file.Contents();
                var text = await Ocr.RecognizeImageAsync(data, languages, report, ct).ConfigureAwait(false);
                if (JSCompat.Trim(text).Length == 0) throw new ImportError(ImportErrorCode.NoText, ImportMessages.ImageEmpty);
                return new ImportedFile(text, ImportFileKind.Image, source.Name);
            }
        }
    }

    /// <summary>Access to the bytes of an import source: size and the first bytes without reading the whole file.</summary>
    sealed class SourceBytes
    {
        public long Size { get; }
        public byte[] Head { get; }
        readonly Func<byte[]> _load;

        public SourceBytes(ImportSource source)
        {
            if (source.Data is { } data)
            {
                Size = data.Length;
                Head = data[..Math.Min(16, data.Length)];
                _load = () => data;
                return;
            }
            var path = source.FilePath;
            try
            {
                // A dropped folder (or a source without a payload) cannot be imported.
                if (path is null || Directory.Exists(path)) throw new ImportError(ImportErrorCode.Read, ImportMessages.Read);
                var info = new FileInfo(path);
                Size = info.Length;
                using var stream = File.OpenRead(path);
                var head = new byte[16];
                int read = 0, n;
                while (read < head.Length && (n = stream.Read(head, read, head.Length - read)) > 0) read += n;
                Head = head[..read];
            }
            catch (Exception error) when (error is not ImportError)
            {
                throw new ImportError(ImportErrorCode.Read, ImportMessages.Read, error);
            }
            _load = () =>
            {
                try { return File.ReadAllBytes(path); }
                catch (Exception error) { throw new ImportError(ImportErrorCode.Read, ImportMessages.Read, error); }
            };
        }

        public byte[] Contents() => _load();
    }
}

/// <summary>The result of importing several files.</summary>
public sealed class ImportBatch
{
    /// <summary>Every file that was read, in order.</summary>
    public List<ImportedFile> Files { get; } = [];
    /// <summary>The trimmed, non-empty texts of Files.</summary>
    public List<string> Texts { get; } = [];
    /// <summary>Files that could not be read.</summary>
    public List<ImportFailure> Failures { get; } = [];
    /// <summary>Problems that did not stop an import (e.g. scanned PDF pages), with a «name»: prefix.</summary>
    public List<string> Warnings { get; } = [];
    /// <summary>The name of the first file that gave text (a set title suggestion); null for pasted content.</summary>
    public string? FirstName { get; set; }

    /// <summary>All texts, separated by blank lines.</summary>
    public string Text => string.Join("\n\n", Texts);

    /// <summary>The failure messages («name»: message), e.g. for error toasts.</summary>
    public List<string> ErrorMessages => Failures.Select(f => f.Message).ToList();

    /// <summary>
    /// The import text after this batch: the existing text (trimmed) first, then the new texts, separated
    /// by blank lines.
    /// </summary>
    public string AppendedTo(string existing)
    {
        var current = JSCompat.Trim(existing);
        return string.Join("\n\n", (current.Length == 0 ? [] : new[] { current }).Concat(Texts));
    }
}

/// <summary>A file of a batch that could not be read. Message: for the learner, with a «name»: prefix when the file has a name.</summary>
public sealed record ImportFailure(string Name, ImportError Error, string Message);
