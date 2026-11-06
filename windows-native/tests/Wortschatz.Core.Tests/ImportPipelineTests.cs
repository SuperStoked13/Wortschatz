using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of ImportPipelineTests.swift (readImportFile of src/import/files.js and the editor's
// multi-file loop of editor-import.js), with a scripted recognizer, a fake image decoder and fake PDFs.
public class ImportPipelineTests
{
    static ImportPipeline Pipeline(ScriptedRecognizer? recognizer = null) =>
        new(new FakePdfReader(), new FakeImageDecoder(), recognizer ?? new ScriptedRecognizer(_ => FakeOCR.Table([("la gare", "der Bahnhof")])));

    static byte[] U8(string s) => Encoding.UTF8.GetBytes(s);

    // MARK: - Text files

    [Fact]
    public async Task TextFile()
    {
        using var dir = new TempDirectory();
        var path = dir.File("Unité 3.txt", [0xEF, 0xBB, 0xBF, .. U8("le chat\tdie Katze\n")]);
        var progress = new ProgressLog();
        var file = await Pipeline().ReadAsync(ImportSource.FromFile(path), progress: progress.Handler);
        Assert.Equal("le chat\tdie Katze\n", file.Text);
        Assert.Equal(ImportFileKind.Text, file.Kind);
        Assert.Equal("Unité 3.txt", file.Name);
        Assert.Empty(file.Warnings);
        Assert.Equal(["Datei wird gelesen …", "Datei gelesen"], progress.Messages);
        Assert.Equal([0.0, 1.0], progress.Fractions);
    }

    [Fact]
    public async Task WebFixture()
    {
        var file = await Pipeline().ReadAsync(ImportSource.FromData(ImportResources.Read("windows-bom.txt"), "windows-bom.txt"));
        Assert.Equal(ImportFileKind.Text, file.Kind);
        Assert.StartsWith("le chien", file.Text);
    }

    [Fact]
    public async Task LegacyCsv()
    {
        const string text = "la fenêtre;das Fenster\r\nle rôle;die Rolle\r\nmûr;reif\r\nà côté;daneben";
        var file = await Pipeline().ReadAsync(ImportSource.FromData(text.Select(c => (byte)c).ToArray(), "export.csv"));
        Assert.Equal(text, file.Text);
    }

    // MARK: - Errors

    [Fact]
    public async Task Errors()
    {
        using var dir = new TempDirectory();
        var pipeline = Pipeline(new ScriptedRecognizer(_ => []));
        await ImportAssert.Throws(ImportErrorCode.Empty, ImportMessages.Empty, () => pipeline.ReadAsync(ImportSource.FromFile(dir.File("leer.txt", []))));
        await ImportAssert.Throws(ImportErrorCode.Read, ImportMessages.Read, () => pipeline.ReadAsync(ImportSource.FromFile(dir.Path)));
        await ImportAssert.Throws(ImportErrorCode.Read, ImportMessages.Read, () => pipeline.ReadAsync(ImportSource.FromFile(Path.Combine(dir.Path, "fehlt.pdf"))));
        await ImportAssert.Throws(ImportErrorCode.Read, ImportMessages.Read, () => pipeline.ReadAsync(new ImportSource("nichts")));
        await ImportAssert.Throws(ImportErrorCode.Unsupported, ImportMessages.Document,
            () => pipeline.ReadAsync(ImportSource.FromFile(dir.File("brief.docx", U8("PK\u0003\u0004")))));
        await ImportAssert.Throws(ImportErrorCode.Unsupported, ImportMessages.Unsupported,
            () => pipeline.ReadAsync(ImportSource.FromFile(dir.File("logo.svg", U8("<svg/>")))));
        // A "text" file full of binary data.
        await ImportAssert.Throws(ImportErrorCode.Unsupported, ImportMessages.Unsupported,
            () => pipeline.ReadAsync(ImportSource.FromData(Enumerable.Range(0, 200).Select(i => (byte)(i % 9)).ToArray(), "daten.txt")));
        await ImportAssert.Throws(ImportErrorCode.TooLarge, ImportMessages.TooLarge,
            () => pipeline.ReadAsync(ImportSource.FromFile(dir.File("gross.txt", Enumerable.Repeat((byte)0x61, ImportPipeline.MaxTextBytes + 1).ToArray()))));
        await ImportAssert.Throws(ImportErrorCode.NoText, ImportMessages.PdfEmpty,
            () => pipeline.ReadAsync(ImportSource.FromData(FakePdf.Encode(FakePdf.BlankPage()), "leer.pdf")));
        await ImportAssert.Throws(ImportErrorCode.Decode, ImportMessages.Decode,
            () => pipeline.ReadAsync(ImportSource.FromData([0x89, 0x50, 0x4E, 0x47, 1, 2, 3], "kaputt.png")));
    }

    [Fact]
    public async Task ImageErrors()
    {
        var png = FakeImages.Png();
        await ImportAssert.Throws(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed,
            () => Pipeline(ScriptedRecognizer.Failing()).ReadAsync(ImportSource.FromData(png, mimeType: "image/png")));
        await ImportAssert.Throws(ImportErrorCode.NoText, ImportMessages.ImageEmpty,
            () => Pipeline(new ScriptedRecognizer(_ => [])).ReadAsync(ImportSource.FromData(png, mimeType: "image/png")));
    }

    [Fact]
    public async Task MissingComponents()
    {
        var empty = new ImportPipeline();
        // Text files need nothing.
        Assert.Equal("le chat", (await empty.ReadAsync(ImportSource.FromData(U8("le chat"), "a.txt"))).Text);
        await ImportAssert.Throws(ImportErrorCode.PdfFailed, ImportMessages.PdfFailed,
            () => empty.ReadAsync(ImportSource.FromData(FakePdf.Encode(PDFTextExtractorTests.TextPage()), "a.pdf")));
        await ImportAssert.Throws(ImportErrorCode.Decode, ImportMessages.Decode, () => empty.ReadAsync(ImportSource.FromData(FakeImages.Png(), "a.png")));
        var noOcr = new ImportPipeline(new FakePdfReader(), new FakeImageDecoder());
        await ImportAssert.Throws(ImportErrorCode.OcrFailed, ImportMessages.OcrFailed, () => noOcr.ReadAsync(ImportSource.FromData(FakeImages.Png(), "a.png")));
        // A text PDF still reads; its scanned page becomes a warning.
        var mixed = await noOcr.ReadAsync(ImportSource.FromData(FakePdf.Encode(PDFTextExtractorTests.TextPage(), FakePdf.ScannedPage()), "a.pdf"));
        Assert.Contains("le chat", mixed.Text);
        Assert.StartsWith("Seite 2 ist gescannt", Assert.Single(mixed.Warnings));
    }

    // MARK: - Kinds

    [Fact]
    public async Task Sniffing()
    {
        using var dir = new TempDirectory();
        var pdf = await Pipeline().ReadAsync(ImportSource.FromFile(dir.File("scan", FakePdf.Encode(FakePdf.TablePage(TestRows)))));
        Assert.Equal(ImportFileKind.Pdf, pdf.Kind);
        Assert.Equal(string.Join("\n", TestRows.Select(r => $"{r.Item1}\t{r.Item2}")), pdf.Text);
        var image = await Pipeline().ReadAsync(ImportSource.FromFile(dir.File("liste.txt", FakeImages.Png())));
        Assert.Equal(ImportFileKind.Image, image.Kind);
        Assert.Equal("la gare\tder Bahnhof", image.Text);
    }

    /// <summary>A French → German vocabulary table (TestDocuments.rows, Swiss spelling).</summary>
    static readonly (string, string)[] TestRows =
    [
        ("le château", "das Schloss"), ("la fille", "das Mädchen"), ("beau, belle", "schön"), ("la porte", "die Tür"),
        ("fatigué", "müde"), ("avoir lieu", "stattfinden"), ("la rue", "die Strasse"), ("le garçon", "der Junge"),
    ];

    [Fact]
    public async Task PastedImage()
    {
        var recognizer = new ScriptedRecognizer(_ => FakeOCR.Table([("el tren", "der Zug")]));
        var progress = new ProgressLog();
        var file = await Pipeline(recognizer).ReadAsync(ImportSource.FromData(FakeImages.Png(), mimeType: "image/png"), Lang.Es, Lang.De, progress.Handler);
        Assert.Equal("el tren\tder Zug", file.Text);
        Assert.Equal(ImportFileKind.Image, file.Kind);
        Assert.Equal("", file.Name);
        Assert.Equal([["es-ES", "de-DE"]], recognizer.Languages);
        Assert.Equal("Bild wird vorbereitet …", progress.Messages[0]);
        Assert.Contains("Texterkennung läuft …", progress.Messages);
        Assert.Equal(1, progress.Fractions[^1]);
    }

    // MARK: - Several files

    [Fact]
    public async Task Batch()
    {
        using var dir = new TempDirectory();
        var mixed = FakePdf.Encode(PDFTextExtractorTests.TextPage(), FakePdf.ScannedPage());
        List<ImportSource> sources =
        [
            ImportSource.FromFile(dir.File("liste.txt", U8("  le vélo\tdas Velo  \n"))),
            ImportSource.FromFile(dir.File("brief.docx", U8("PK"))),
            ImportSource.FromFile(dir.File("unite.pdf", mixed)),
            ImportSource.FromFile(dir.File("leer.txt", U8("   \n"))),
        ];
        var progress = new ProgressLog();
        var batch = await Pipeline(ScriptedRecognizer.Failing()).ReadAllAsync(sources, progress: progress.Handler);
        Assert.Equal(["le vélo\tdas Velo", string.Join("\n", PDFTextExtractorTests.TextRows.Select(r => $"{r.Item1}\t{r.Item2}"))], batch.Texts);
        Assert.Equal(string.Join("\n\n", batch.Texts), batch.Text);
        Assert.Equal(["liste.txt", "unite.pdf", "leer.txt"], batch.Files.Select(f => f.Name).ToList());
        Assert.Equal("liste.txt", batch.FirstName);
        Assert.Equal([$"«brief.docx»: {ImportMessages.Document}"], batch.ErrorMessages);
        Assert.Equal([ImportErrorCode.Unsupported], batch.Failures.Select(f => f.Error.Code).ToList());
        Assert.StartsWith("«unite.pdf»: Seite 2 ist gescannt", Assert.Single(batch.Warnings));
        Assert.Equal("Datei 1 von 4: Datei wird gelesen …", progress.Messages[0]);
        Assert.Contains("Datei 3 von 4: PDF wird geöffnet …", progress.Messages);
        Assert.Equal(progress.Fractions.OrderBy(f => f).ToList(), progress.Fractions);
        Assert.Equal("la gare\tder Bahnhof\n\n" + batch.Text, batch.AppendedTo("  la gare\tder Bahnhof \n"));
        Assert.Equal(batch.Text, batch.AppendedTo(" \n "));
    }

    [Fact]
    public async Task PastedBatch()
    {
        var png = FakeImages.Png();
        var failing = await Pipeline(ScriptedRecognizer.Failing()).ReadAllAsync([ImportSource.FromData(png, mimeType: "image/png")]);
        Assert.Equal([ImportMessages.OcrFailed], failing.ErrorMessages);
        var ok = await Pipeline().ReadAllAsync([ImportSource.FromData(png, mimeType: "image/png")]);
        Assert.Equal(["la gare\tder Bahnhof"], ok.Texts);
        Assert.Null(ok.FirstName);
    }

    // MARK: - Cancellation

    [Fact]
    public async Task AlreadyCancelled()
    {
        var recognizer = new ScriptedRecognizer(_ => []);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await ImportAssert.Aborted(() => Pipeline(recognizer).ReadAllAsync([ImportSource.FromData(FakeImages.Png(), mimeType: "image/png")], ct: cts.Token));
        await ImportAssert.Aborted(() => Pipeline(recognizer).ReadAsync(ImportSource.FromData(U8("le chat"), "a.txt"), ct: cts.Token));
        Assert.Equal(0, recognizer.Calls);
    }

    [Fact]
    public async Task CancelBatch()
    {
        var recognizer = ScriptedRecognizer.Hanging();
        List<ImportSource> sources = [ImportSource.FromData(U8("le chat\tdie Katze"), "a.txt"), ImportSource.FromData(FakeImages.Png(), "b.png")];
        using var cts = new CancellationTokenSource();
        var task = Pipeline(recognizer).ReadAllAsync(sources, ct: cts.Token);
        while (recognizer.Calls == 0) await Task.Delay(1);
        cts.Cancel();
        await ImportAssert.Aborted(() => task);
    }
}
