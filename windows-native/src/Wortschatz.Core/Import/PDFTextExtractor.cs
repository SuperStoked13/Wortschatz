namespace Wortschatz.Core;

/// <summary>
/// Port of PDFTextExtractor.swift (<c>extractPdfText</c> in src/import/pdf.js), with PDFKit replaced by
/// <see cref="IPdfReader"/> / <see cref="IPdfDocument"/>.
///
/// Text-layer pages are read directly and their layout (table columns, paragraphs) is rebuilt with
/// <see cref="TextLayout.ItemsToLines"/>. Scanned pages without a text layer are rendered and passed
/// through text recognition: all pages when the document has no text at all (at most 30), otherwise the
/// nearly empty pages that contain images. Pages are separated by a blank line.
/// </summary>
public sealed class PDFTextExtractor(IPdfReader? reader, OCRService ocr)
{
    /// <summary>Text recognition is limited to this many scanned pages.</summary>
    public const int MaxOCRPages = 30;

    /// <summary>The extracted text and the German warnings about pages that could not be read.</summary>
    public sealed record Output(string Text, IReadOnlyList<string> Warnings);

    public IPdfReader? Reader { get; } = reader;
    public OCRService Ocr { get; } = ocr;

    /// <summary>
    /// Extracts the text of a PDF. <paramref name="languages"/> are the recognition languages for scanned
    /// pages (default French + German). Throws ImportError: pdfInvalid, pdfPassword, pdfTooManyPages (a scan
    /// with more than 30 pages), ocrFailed, aborted (pdfFailed when no reader is available).
    /// </summary>
    public Task<Output> ExtractTextAsync(byte[] data, IReadOnlyList<string>? languages = null, Action<ImportProgress>? progress = null, CancellationToken ct = default) =>
        ExtractTextAsync(data, languages ?? RecognitionLanguages.ForSet(Lang.Fr), new ProgressReporter(progress), ct);

    internal async Task<Output> ExtractTextAsync(byte[] data, IReadOnlyList<string> languages, ProgressReporter report, CancellationToken ct)
    {
        report.Report(0, ImportMessages.OpeningPDF);
        ImportError.CheckCancellation(ct);
        if (Reader is null) throw new ImportError(ImportErrorCode.PdfFailed, ImportMessages.PdfFailed);
        IPdfDocument document;
        try { document = Reader.Open(data); }
        catch (Exception error) { throw ImportError.Wrap(error, new ImportError(ImportErrorCode.PdfInvalid, ImportMessages.PdfInvalid, error), ct); }
        using (document) return await Extract(document, languages, report, ct).ConfigureAwait(false);
    }

    async Task<Output> Extract(IPdfDocument document, IReadOnlyList<string> languages, ProgressReporter report, CancellationToken ct)
    {
        int n = document.PageCount;
        var texts = new string[n];
        var chars = new int[n];
        double textShare = 1.0;
        for (int i = 0; i < n; i++)
        {
            ImportError.CheckCancellation(ct);
            report.Report((double)i / n * textShare, n > 1 ? $"Seite {i + 1} von {n} wird gelesen …" : ImportMessages.ReadingPDF);
            texts[i] = "";
            List<TextItem> items;
            try { items = document.Items(i); }
            catch (Exception error) when (error is not ImportError and not OperationCanceledException) { continue; } // like a missing page
            chars[i] = PDFPageText.VisibleCharacterCount(items);
            texts[i] = string.Join("\n", TextLayout.ItemsToLines(items));
            // A first page without text hints at a scan: leave room for the recognition phase.
            if (i == 0 && chars[0] < 3) textShare = 0.1;
        }

        // Pages to recognise: all of them when the document has no text layer at all, otherwise text-less
        // pages that contain images (scanned inserts).
        bool allEmpty = chars.All(c => c < 3);
        var ocrPages = new List<int>();
        for (int i = 0; i < n; i++)
        {
            if (allEmpty) ocrPages.Add(i);
            else if (chars[i] < 40)
            {
                ImportError.CheckCancellation(ct);
                if (PageHasImages(document, i)) ocrPages.Add(i);
            }
        }

        string doneMessage = ImportMessages.PdfRead;
        var warnings = new List<string>();
        if (ocrPages.Count > 0 && allEmpty)
        {
            if (ocrPages.Count > MaxOCRPages)
                throw new ImportError(ImportErrorCode.PdfTooManyPages, ImportMessages.PdfTooManyPages(ocrPages.Count));
            await Recognize(ocrPages, document, texts, new HashSet<int>(), languages, report, textShare, "PDF enthält keinen Text", ct).ConfigureAwait(false);
        }
        else if (ocrPages.Count > 0)
        {
            // Mixed document: scanned inserts are a bonus. If their recognition fails (or there are too
            // many), keep the text that was read and tell the learner which pages are missing.
            var done = new HashSet<int>();
            ImportError? failure = null;
            if (ocrPages.Count > MaxOCRPages) failure = new ImportError(ImportErrorCode.PdfTooManyPages, ImportMessages.PdfFailed);
            else
            {
                try
                {
                    await Recognize(ocrPages, document, texts, done, languages, report, 0.95, "Gescannte Seiten", ct).ConfigureAwait(false);
                }
                catch (ImportError error) when (error.Code != ImportErrorCode.Aborted)
                {
                    failure = error;
                }
            }
            if (failure is not null)
            {
                var missing = ocrPages.Where(p => !done.Contains(p)).Select(p => p + 1).ToList();
                if (missing.Count > 0)
                {
                    doneMessage = ImportMessages.PdfReadPartially;
                    warnings.Add(SkippedPagesMessage(missing, failure));
                }
            }
        }

        report.Report(1, doneMessage);
        var text = string.Join("\n\n", texts.Select(JSCompat.Trim).Where(t => t.Length > 0));
        return new Output(text, warnings);
    }

    /// <summary>Errors count as "has images" (like the CoreGraphics probe).</summary>
    static bool PageHasImages(IPdfDocument document, int index)
    {
        try { return document.PageHasImages(index); }
        catch (Exception error) when (error is not OperationCanceledException) { return true; }
    }

    /// <summary>
    /// Renders the given pages (0-based) and replaces their text with the recognition result. Recognised
    /// pages are added to <paramref name="done"/> (also when a later page fails).
    /// </summary>
    async Task Recognize(List<int> pages, IPdfDocument document, string[] texts, HashSet<int> done, IReadOnlyList<string> languages,
        ProgressReporter report, double start, string label, CancellationToken ct)
    {
        double span = 1 - start;
        report.Report(start, $"{label} – {ImportMessages.Recognizing}");
        for (int k = 0; k < pages.Count; k++)
        {
            ImportError.CheckCancellation(ct);
            int index = pages[k];
            double width = span / pages.Count;
            string prefix = pages.Count > 1 ? $"Seite {k + 1} von {pages.Count} – " : "";
            var pageReport = report.Slice(start + span * k / pages.Count, width, prefix);
            OcrBitmap image;
            try
            {
                var (w, h) = document.PageSize(index);
                image = document.Render(index, PDFPageRenderer.Scale(w, h));
            }
            catch (Exception error)
            {
                throw ImportError.Wrap(error, new ImportError(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed, error), ct);
            }
            var text = await Ocr.RecognizeAsync(image, languages, false, pageReport, ct).ConfigureAwait(false);
            // Keep any real text the page had (e.g. a header) if recognition found nothing.
            if (JSCompat.Trim(text).Length > 0) texts[index] = text;
            done.Add(index);
        }
    }

    /// <summary>Shown when scanned pages (1-based numbers) of an otherwise readable PDF could not be recognised.</summary>
    public static string SkippedPagesMessage(IReadOnlyList<int> pages, ImportError cause)
    {
        string which = pages.Count switch
        {
            1 => $"Seite {pages[0]} ist gescannt und konnte",
            >= 2 and <= 6 => $"Die Seiten {string.Join(", ", pages.Take(pages.Count - 1))} und {pages[^1]} sind gescannt und konnten",
            _ => $"{pages.Count} Seiten sind gescannt und konnten",
        };
        string reason = cause.Code == ImportErrorCode.PdfTooManyPages
            ? $"Die Texterkennung ist auf {MaxOCRPages} Seiten beschränkt – teile die Datei bitte auf."
            : "Versuche es später noch einmal.";
        return $"{which} nicht gelesen werden – die Vokabeln darauf fehlen. {reason}";
    }
}
