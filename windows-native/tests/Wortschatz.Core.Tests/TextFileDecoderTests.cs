using System.Text;
using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of TextFileDecoderTests.swift (decodeText).
public class TextFileDecoderTests
{
    const string Sample = "le château\tdas Schloss\nla fille\tdas Mädchen\nl’œuvre\tdas Werk";

    static byte[] Utf16(string s, bool littleEndian, bool bom)
    {
        var bytes = new List<byte>();
        if (bom) bytes.AddRange(littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]);
        foreach (char unit in s)
        {
            byte hi = (byte)(unit >> 8), lo = (byte)(unit & 0xFF);
            bytes.AddRange(littleEndian ? [lo, hi] : [hi, lo]);
        }
        return bytes.ToArray();
    }

    static byte[] U8(string s) => Encoding.UTF8.GetBytes(s);

    /// <summary>Each character as one byte (Latin-1 / Windows-1252 for these characters).</summary>
    static byte[] Latin1(string s) => s.Select(c => (byte)c).ToArray();

    [Fact]
    public void Utf8()
    {
        Assert.Equal(Sample, TextFileDecoder.Decode(U8(Sample)));
        var bom = TextFileDecoder.DecodeDetectingEncoding([0xEF, 0xBB, 0xBF, .. U8(Sample)]);
        Assert.Equal(Sample, bom.Text);
        Assert.Equal(TextFileDecoder.Encoding.Utf8, bom.Encoding);
        // TextDecoder drops one more BOM after the stripped one.
        Assert.Equal("x", TextFileDecoder.Decode([0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, .. U8("x")]));
        // With a BOM, invalid bytes are replaced instead of switching to Windows-1252.
        Assert.Equal("a�b", TextFileDecoder.Decode([0xEF, 0xBB, 0xBF, 0x61, 0xFF, 0x62]));
    }

    [Fact]
    public void Utf16WithBom()
    {
        var le = TextFileDecoder.DecodeDetectingEncoding(Utf16(Sample, true, true));
        Assert.Equal(Sample, le.Text);
        Assert.Equal(TextFileDecoder.Encoding.Utf16LittleEndian, le.Encoding);
        var be = TextFileDecoder.DecodeDetectingEncoding(Utf16(Sample, false, true));
        Assert.Equal(Sample, be.Text);
        Assert.Equal(TextFileDecoder.Encoding.Utf16BigEndian, be.Encoding);
        // A dangling odd byte becomes a replacement character.
        Assert.Equal("ab�", TextFileDecoder.Decode([.. Utf16("ab", true, true), 0x63]));
        // Unpaired surrogates too.
        Assert.Equal("a�b", TextFileDecoder.Decode([0xFF, 0xFE, 0x61, 0, 0x00, 0xD8, 0x62, 0]));
    }

    [Fact]
    public void Utf16WithoutBom()
    {
        var le = TextFileDecoder.DecodeDetectingEncoding(Utf16(Sample, true, false));
        Assert.Equal(Sample, le.Text);
        Assert.Equal(TextFileDecoder.Encoding.Utf16LittleEndian, le.Encoding);
        var be = TextFileDecoder.DecodeDetectingEncoding(Utf16(Sample, false, false));
        Assert.Equal(Sample, be.Text);
        Assert.Equal(TextFileDecoder.Encoding.Utf16BigEndian, be.Encoding);
        // Too short to tell: read as UTF-8.
        Assert.Equal("a\0", TextFileDecoder.Decode([0x61, 0x00]));
    }

    [Fact]
    public void Windows1252()
    {
        // "le château – das Mädchen €" in Windows-1252.
        byte[] bytes = [.. U8("le ch"), 0xE2, .. U8("teau "), 0x96, .. U8(" das M"), 0xE4, .. U8("dchen "), 0x80];
        var result = TextFileDecoder.DecodeDetectingEncoding(bytes);
        Assert.Equal("le château – das Mädchen €", result.Text);
        Assert.Equal(TextFileDecoder.Encoding.Windows1252, result.Encoding);
        // French with only "é" reads the same in both: Windows-1252 wins the tie, like the web app.
        Assert.Equal("café", TextFileDecoder.Decode([.. U8("caf"), 0xE9]));
        // Unassigned Windows-1252 bytes map to C1 controls (WHATWG) ...
        var undefined = TextFileDecoder.DecodeDetectingEncoding([0xE4, 0xFC, 0xF6, 0x81]);
        Assert.Equal("äüö\u0081", undefined.Text);
        Assert.Equal(TextFileDecoder.Encoding.Windows1252, undefined.Encoding);
        // ... which alone make Mac OS Roman the better reading ("Å").
        Assert.Equal("aÅb", TextFileDecoder.Decode([0x61, 0x81, 0x62]));
    }

    [Fact]
    public void MacRoman()
    {
        // "le château – das Mädchen, schön, l’œuvre" in Mac OS Roman.
        byte[] bytes = [.. U8("le ch"), 0x89, .. U8("teau "), 0xD0, .. U8(" das M"), 0x8A, .. U8("dchen, sch"), 0x9A, .. U8("n, l"), 0xD5, 0xCF, .. U8("uvre")];
        var result = TextFileDecoder.DecodeDetectingEncoding(bytes);
        Assert.Equal("le château – das Mädchen, schön, l’œuvre", result.Text);
        Assert.Equal(TextFileDecoder.Encoding.MacRoman, result.Encoding);
    }

    [Fact]
    public void WindowsGerman()
    {
        const string text = "die Tür\tla porte\nmüde\tfatigué\nschön\tbeau\nder Bäcker\tle boulanger\nà côté de\tneben";
        var result = TextFileDecoder.DecodeDetectingEncoding(Latin1(text));
        Assert.Equal(text, result.Text);
        Assert.Equal(TextFileDecoder.Encoding.Windows1252, result.Encoding);
    }

    [Fact]
    public void WebFixture()
    {
        var text = TextFileDecoder.Decode(ImportResources.Read("windows-bom.txt"));
        Assert.StartsWith("le chien\u00A0-\u00A0der Hund\r\n", text);
        Assert.DoesNotContain('\uFEFF', text); // ordinal (the string overload ignores U+FEFF)
        Assert.False(TextFileDecoder.LooksBinary(text));
    }

    [Fact]
    public void LooksBinary()
    {
        Assert.False(TextFileDecoder.LooksBinary(""));
        Assert.False(TextFileDecoder.LooksBinary("le chat\tdie Katze\r\nle chien\tder Hund\n"));
        var png = TextFileDecoder.Decode([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]);
        Assert.True(TextFileDecoder.LooksBinary(png));
        // One stray control character in a long text is fine (≤ 2 %).
        Assert.False(TextFileDecoder.LooksBinary(new string('a', 100) + "\u0001"));
        Assert.True(TextFileDecoder.LooksBinary(new string('a', 40) + "\u0001"));
    }
}
