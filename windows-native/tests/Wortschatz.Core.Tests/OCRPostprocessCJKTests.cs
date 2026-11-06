using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of OCRPostprocessCJKTests.swift (joinCjk and the plain-text fallback of ocrDataToText).
public class OCRPostprocessCJKTests
{
    [Theory]
    [InlineData("你 好 ， 朋 友", "你好，朋友")]
    [InlineData("谢 谢 xiè xie", "谢谢 xiè xie")]
    [InlineData("你好  朋友", "你好朋友")] // a run of spaces
    [InlineData("こん にち は", "こんにちは")] // kana
    [InlineData("你好 。", "你好。")] // CJK punctuation
    [InlineData("𠀀 𠀁", "𠀀𠀁")] // Extension B
    public void JoinsCJK(string input, string expected) => Assert.Equal(expected, OCRPostprocess.JoinCJK(input));

    [Theory]
    [InlineData("你好 nǐ hǎo")]
    [InlineData("nǐ 你")]
    [InlineData("你\t好")] // only plain spaces
    [InlineData("你\u00A0好")]
    [InlineData("le chat  noir")]
    [InlineData("كتاب قلم")]
    [InlineData("")]
    [InlineData(" 你 ")]
    public void KeepsOtherSpaces(string input) => Assert.Equal(input, OCRPostprocess.JoinCJK(input));

    [Fact]
    public void PlainText()
    {
        Assert.Equal(["你好，朋友", "谢谢 xiè xie"], OCRPostprocess.PlainTextLines("你 好 ， 朋 友\n谢 谢 xiè xie\n"));
        Assert.Equal(["die Tür", "la porte"], OCRPostprocess.PlainTextLines("die Tûr\nla porte\n"));
        Assert.Equal([""], OCRPostprocess.PlainTextLines(""));
        // CR stays in its line, like JS split('\n').
        Assert.Equal(["a\r", "b"], OCRPostprocess.PlainTextLines("a\r\nb"));
    }
}
