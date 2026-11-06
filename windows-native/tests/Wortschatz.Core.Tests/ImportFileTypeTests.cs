using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of ImportFileTypeTests.swift (the detectFileKind / ACCEPT cases of tests/layout.test.js plus
// the sniffing of files.js). The UTType checks become checks of SupportedExtensions / MimeTypeFor.
public class ImportFileTypeTests
{
    [Theory]
    [InlineData("vokabeln.txt", "text/plain", ImportFileKind.Text)]
    [InlineData("export.csv", "application/vnd.ms-excel", ImportFileKind.Text)]
    [InlineData("liste.TSV", "", ImportFileKind.Text)]
    [InlineData("README", "", ImportFileKind.Text)]
    [InlineData("notes.md", "text/markdown", ImportFileKind.Text)]
    [InlineData("unite3.pdf", "", ImportFileKind.Pdf)]
    [InlineData("scan", "application/pdf", ImportFileKind.Pdf)]
    [InlineData("IMG_0412.HEIC", "", ImportFileKind.Image)]
    [InlineData("foto.jpg", "image/jpeg", ImportFileKind.Image)]
    [InlineData("image.png", "image/png", ImportFileKind.Image)]
    [InlineData("bild.webp", "", ImportFileKind.Image)]
    [InlineData("logo.svg", "image/svg+xml", null)]
    [InlineData("brief.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", null)]
    [InlineData("text.rtf", "text/rtf", null)]
    [InlineData("seite.html", "text/html", null)]
    // Additional cases of the same rules.
    [InlineData("liste.tab", "", ImportFileKind.Text)]
    [InlineData("liste", "text/csv; charset=utf-8", ImportFileKind.Text)]
    [InlineData("daten", "application/tab-separated-values", ImportFileKind.Text)]
    [InlineData(".bashrc", "", ImportFileKind.Text)]
    [InlineData("archiv.zip", "application/zip", null)]
    [InlineData("seite.", "", ImportFileKind.Text)]
    [InlineData("Tabelle.numbers", "", null)]
    [InlineData("scan.TIFF", "", ImportFileKind.Image)]
    [InlineData("foto", "image/heic", ImportFileKind.Image)]
    [InlineData("stil.css", "text/css", null)]
    public void DetectKind(string name, string type, ImportFileKind? expected) => Assert.Equal(expected, ImportFileType.DetectKind(name, type));

    static byte[] B(string ascii) => Encoding.Latin1.GetBytes(ascii);

    [Fact]
    public void Sniff()
    {
        Assert.Equal(ImportFileType.Sniffed.Pdf, ImportFileType.Sniff(B("%PDF-1.7\n")));
        Assert.Equal(ImportFileType.Sniffed.Image, ImportFileType.Sniff([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]));
        Assert.Equal(ImportFileType.Sniffed.Image, ImportFileType.Sniff([0xFF, 0xD8, 0xFF, 0xE0]));
        Assert.Equal(ImportFileType.Sniffed.Image, ImportFileType.Sniff(B("GIF89a")));
        Assert.Equal(ImportFileType.Sniffed.Image, ImportFileType.Sniff(B("RIFF\0\0\0\0WEBPVP8 ")));
        Assert.Equal(ImportFileType.Sniffed.Heic, ImportFileType.Sniff([0, 0, 0, 0x18, .. B("ftypheic"), 0, 0, 0, 0]));
        Assert.Equal(ImportFileType.Sniffed.Heic, ImportFileType.Sniff([0, 0, 0, 0x18, .. B("ftypmif1")]));
        Assert.Equal(ImportFileType.Sniffed.Image, ImportFileType.Sniff([0, 0, 0, 0x18, .. B("ftypavif")]));
        Assert.Null(ImportFileType.Sniff([0, 0, 0, 0x18, .. B("ftypisom")]));
        Assert.Null(ImportFileType.Sniff(Encoding.UTF8.GetBytes("le chat\tdie Katze")));
        Assert.Null(ImportFileType.Sniff([]));
        Assert.Null(ImportFileType.Sniff(B("%PDF")));
    }

    [Fact]
    public void ResolveKind()
    {
        Assert.Equal(ImportFileKind.Pdf, ImportFileType.ResolveKind("scan", "", ImportFileType.Sniffed.Pdf));
        Assert.Equal(ImportFileKind.Image, ImportFileType.ResolveKind("liste.txt", "text/plain", ImportFileType.Sniffed.Image));
        Assert.Equal(ImportFileKind.Image, ImportFileType.ResolveKind("foto.dat", "", ImportFileType.Sniffed.Heic));
        Assert.Null(ImportFileType.ResolveKind("brief.docx", "", null));
        Assert.Equal(ImportFileKind.Text, ImportFileType.ResolveKind("liste.txt", "", null));
    }

    [Fact]
    public void UnsupportedMessage()
    {
        Assert.Equal(ImportMessages.Document, ImportFileType.UnsupportedMessage("brief.docx"));
        Assert.Equal(ImportMessages.Document, ImportFileType.UnsupportedMessage("Vokabeln.pages"));
        Assert.Equal(ImportMessages.Unsupported, ImportFileType.UnsupportedMessage("logo.svg"));
        Assert.StartsWith(ImportMessages.Unsupported, ImportMessages.Document);
    }

    [Fact]
    public void SupportedExtensions()
    {
        foreach (var ext in new[] { "txt", "csv", "tsv", "pdf", "heic" }) Assert.Contains(ext, ImportFileType.AcceptedExtensions);
        foreach (var ext in new[] { "txt", "csv", "tsv", "tab", "md", "markdown", "pdf", "png", "jpg", "jpeg", "heic", "webp", "tiff" })
            Assert.Contains(ext, ImportFileType.SupportedExtensions);
        Assert.DoesNotContain("svg", ImportFileType.SupportedExtensions);
        Assert.DoesNotContain("docx", ImportFileType.SupportedExtensions);
    }

    [Fact]
    public void SourceFromFile()
    {
        var source = ImportSource.FromFile(Path.Combine(Path.GetTempPath(), "Unité 3.pdf"));
        Assert.Equal("Unité 3.pdf", source.Name);
        Assert.Equal("application/pdf", source.MimeType);
        Assert.Null(source.Data);
        Assert.Equal("image/png", ImportSource.FromFile("/tmp/Bild.PNG").MimeType);
        Assert.Equal("", ImportSource.FromFile("/tmp/scan").MimeType);
        var pasted = ImportSource.FromData([1, 2], mimeType: "image/png");
        Assert.Equal("", pasted.Name);
        Assert.Equal("image/png", pasted.MimeType);
    }

    [Fact]
    public void SwissSpelling()
    {
        string[] messages =
        [
            ImportMessages.Unsupported, ImportMessages.Document, ImportMessages.Empty, ImportMessages.TooLarge,
            ImportMessages.PdfEmpty, ImportMessages.Read, ImportMessages.Aborted, ImportMessages.ImageEmpty,
            ImportMessages.OcrFailed, ImportMessages.Decode, ImportMessages.PdfPassword, ImportMessages.PdfInvalid,
            ImportMessages.PdfFailed, ImportMessages.FileFailed, ImportMessages.PdfTooManyPages(31),
            PDFTextExtractor.SkippedPagesMessage([2], new ImportError(ImportErrorCode.OcrFailed, "")),
            PDFTextExtractor.SkippedPagesMessage(Enumerable.Range(1, 9).ToList(), new ImportError(ImportErrorCode.PdfTooManyPages, "")),
        ];
        foreach (var message in messages) Assert.DoesNotContain("ß", message);
        Assert.Equal("Die Textdatei ist zu gross (maximal 5 MB).", ImportMessages.TooLarge);
    }

    [Fact]
    public void ErrorCodesHaveTheJsNames()
    {
        Assert.Equal("ocrFailed", ImportErrorCode.OcrFailed.Raw());
        Assert.Equal("pdfTooManyPages", ImportErrorCode.PdfTooManyPages.Raw());
        Assert.Equal("tooLarge", ImportErrorCode.TooLarge.Raw());
        Assert.Equal("image", ImportFileKind.Image.Raw());
        Assert.Equal("aborted: Import abgebrochen.", ImportError.Aborted.ToString());
    }
}
