using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of LearnTypeAheadTests.swift: matching and the typing keys of the Learn reducer.
// Ranges are UTF-16 offsets here, like Website/tests/typeahead.test.js (Swift: Character offsets).
public class LearnTypeAheadTests
{
    static int? Pick(string typed, string[] choices, Lang? lang = Lang.Fr) => LearnFlow.TypeAheadOf(typed, choices, lang).Selected;

    static LearnFlow.TextRange R(int start, int end) => new(start, end);

    [Fact]
    public void NeedsTwoLettersAfterTheArticle()
    {
        string[] choices = ["la voiture", "le chat", "la maison", "un arbre"];
        Assert.Null(Pick("la", choices));
        Assert.Null(Pick("la ", choices));
        Assert.Null(Pick("la v", choices));
        Assert.Equal(0, Pick("la vo", choices));
        Assert.Equal(0, Pick("la voiture", choices));
        Assert.Equal(0, Pick("La VOI", choices));
        // "la " narrows to the options with that article.
        var narrowed = LearnFlow.TypeAheadOf("la ", choices, Lang.Fr);
        Assert.Equal([0, 2], narrowed.Matching);
        Assert.True(narrowed.IsActive && !narrowed.HasEnoughLetters);
    }

    [Fact]
    public void AmbiguousNeedsMore()
    {
        string[] choices = ["la voiture", "la vache", "le vélo", "la maison"];
        Assert.Null(Pick("la v", choices));
        Assert.Equal([1], LearnFlow.TypeAheadOf("la va", choices, Lang.Fr).Matching);
        Assert.Equal(1, Pick("la va", choices));
        Assert.Equal(0, Pick("la vo", choices));
        // Without the article: "ve" fits only le vélo (accents do not matter).
        Assert.Equal(2, Pick("ve", choices));
        Assert.Null(Pick("v", choices));
    }

    [Fact]
    public void StartsInsideTheOption()
    {
        Assert.Equal(0, Pick("voi", ["la voiture", "le chat", "la maison", "un arbre"]));
        Assert.Equal(1, Pick("ch", ["la voiture", "le chat", "la maison", "un arbre"]));
        string[] alternatives = ["laid, laide", "beau", "joli", "moche"];
        Assert.Equal(0, Pick("lai", alternatives));
        Assert.Equal(R(6, 11), LearnFlow.TypeAheadOf("laide", alternatives, Lang.Fr).Ranges[0]);
        string[] verbs = ["se dépêcher", "se laver", "partir", "dormir"];
        Assert.Null(Pick("se d", verbs));
        Assert.Equal(0, Pick("se de", verbs));
        Assert.Equal(0, Pick("dep", verbs));
        string[] german = ["der Hund", "die Katze", "das Haus", "der Hase"];
        Assert.Null(Pick("der h", german, Lang.De));
        Assert.Equal(0, Pick("der hu", german, Lang.De));
        Assert.Null(Pick("ha", german, Lang.De));
        Assert.Equal(2, Pick("hau", german, Lang.De));
        Assert.Equal(0, Pick("der hu", german, null));
    }

    [Fact]
    public void Apostrophes()
    {
        string[] choices = ["l'été", "la tête", "le thé", "la fête"];
        Assert.Null(Pick("l'e", choices));
        Assert.Equal(0, Pick("l’et", choices));
        Assert.Equal(1, Pick("te", choices));
        Assert.Equal(2, Pick("the", choices));
    }

    [Fact]
    public void ArticleDecides()
    {
        string[] choices = ["le livre", "la livraison", "le lit", "la lune"];
        // Strong match "le liv" wins over "la livraison" (matching only after its article).
        Assert.Equal([0], LearnFlow.TypeAheadOf("le liv", choices, Lang.Fr).Matching);
        Assert.Equal(0, Pick("le liv", choices));
        // Another article than the option's still finds it when nothing else fits.
        Assert.Equal(0, Pick("le voi", ["la voiture", "le chat", "la maison", "un arbre"]));
    }

    [Fact]
    public void CompleteOptionWins()
    {
        string[] choices = ["le pain", "le pain de mie", "le lait", "l'eau"];
        Assert.Null(Pick("le pai", choices));
        Assert.Equal(0, Pick("le pain", choices));
        Assert.Equal(1, Pick("le pain d", choices));
        // A one-letter option typed in full.
        Assert.Equal(0, Pick("y", ["y", "en", "le", "lui"]));
    }

    [Fact]
    public void NoMatchAndRanges()
    {
        string[] choices = ["La Voiture", "le chat", "la maison", "un arbre"];
        var none = LearnFlow.TypeAheadOf("xyz", choices, Lang.Fr);
        Assert.True(none.IsActive && none.Matching.Count == 0 && none.Selected is null);
        Assert.Equal(R(0, 5), LearnFlow.TypeAheadOf("la vo", choices, Lang.Fr).Ranges[0]);
        Assert.Equal(R(3, 6), LearnFlow.TypeAheadOf("voi", choices, Lang.Fr).Ranges[0]);
        Assert.Equal(LearnFlow.TypeAhead.None, LearnFlow.TypeAheadOf("  ", choices, Lang.Fr));
        // Several spaces count as one.
        Assert.Equal(0, Pick("la   vo", choices));
    }

    [Fact]
    public void RangesAreOffsetsIntoTheOriginalText()
    {
        // "e" + combining acute: one character, two code units.
        const string decomposed = "le thé";
        var r = LearnFlow.TypeAheadOf("the", [decomposed, "la tete"], Lang.Fr).Ranges[0];
        Assert.Equal("thé", decomposed[r.Start..r.End]);
        Assert.Equal(0, Pick("strasse", ["die Straße", "der Weg"], Lang.De));
        Assert.Equal(R(0, 9), LearnFlow.TypeAheadOf("die stras", ["die Straße", "der Weg"], Lang.De).Ranges[0]);
    }

    [Fact]
    public void ArabicMarks()
    {
        Assert.Equal(0, Pick("كتا", ["كِتَابٌ", "قلم", "بيت"], Lang.Ar));
        Assert.Equal(0, Pick("كِتَا", ["كتاب", "قلم", "بيت"], Lang.Ar));
        Assert.Equal(0, Pick("كتـا", ["كتاب", "قلم", "بيت"], Lang.Ar));
        Assert.Equal(0, Pick("كتا", ["كتـــاب", "قلم", "بيت"], Lang.Ar));
        Assert.Equal(0, Pick("مد", ["ﻣﺪﺭﺳﺔ", "قلم", "بيت"], Lang.Ar));
        // The typed part is underlined over the original characters, marks included.
        Assert.Equal(R(0, 5), LearnFlow.TypeAheadOf("كتا", ["كِتَابٌ"], Lang.Ar).Ranges[0]);
    }

    [Fact]
    public void ArabicVariants()
    {
        Assert.Equal(0, Pick("اب", ["أب", "أم", "بيت"], Lang.Ar));
        Assert.Equal(0, Pick("اس", ["إسلام", "قلم"], Lang.Ar));
        Assert.Equal(0, Pick("اسم", ["ٱسم", "قلم"], Lang.Ar));
        Assert.Equal(0, Pick("مسو", ["مسؤول", "قلم"], Lang.Ar));
        Assert.Equal(0, Pick("ريي", ["رئيس", "قلم"], Lang.Ar));
        Assert.Equal(0, Pick("مدرسه", ["مدرسة", "مدرس", "قلم"], Lang.Ar));
        Assert.Equal(0, Pick("مستشفي", ["مستشفى", "قلم"], Lang.Ar));
    }

    [Fact]
    public void ArabicArticle()
    {
        string[] choices = ["الكتاب", "المدرسة", "قلم", "بيت"];
        Assert.Equal(["ال"], ExtendedSynonyms.ArticlePrefixes(Lang.Ar));
        Assert.Contains("ال", ExtendedSynonyms.ArticlePrefixes(null));
        Assert.Contains("la ", ExtendedSynonyms.ArticlePrefixes(null));
        // Without the article.
        Assert.Equal(0, Pick("كت", choices, Lang.Ar));
        Assert.Equal(R(2, 4), LearnFlow.TypeAheadOf("كت", choices, Lang.Ar).Ranges[0]);
        Assert.Equal(1, Pick("مد", choices, Lang.Ar));
        // The article alone picks nothing; two letters after it do.
        Assert.Null(Pick("ال", choices, Lang.Ar));
        Assert.Equal([0, 1], LearnFlow.TypeAheadOf("ال", choices, Lang.Ar).Matching);
        Assert.Null(Pick("الك", choices, Lang.Ar));
        Assert.Equal(0, Pick("الكت", choices, Lang.Ar));
        // Any language (null) knows it too.
        Assert.Equal(0, Pick("كت", choices, null));
    }

    [Fact]
    public void ArabicComma()
    {
        Assert.Equal(0, Pick("دف", ["كتاب، دفتر", "قلم", "بيت"], Lang.Ar));
        Assert.Equal(R(6, 8), LearnFlow.TypeAheadOf("دف", ["كتاب، دفتر"], Lang.Ar).Ranges[0]);
    }

    [Fact]
    public void ChinesePinyin()
    {
        string[] choices = ["你好 (nǐ hǎo)", "谢谢 (xiè xie)", "再见（zài jiàn）", "您好 nín hǎo"];
        Assert.Equal(1, Pick("xie", choices, Lang.Zh));
        Assert.Equal(2, Pick("zai", choices, Lang.Zh));
        Assert.Equal(3, Pick("nin", choices, Lang.Zh));
        // "ni" starts nǐ hǎo and nín hǎo.
        Assert.Null(Pick("ni", choices, Lang.Zh));
        Assert.Equal([0, 3], LearnFlow.TypeAheadOf("ni", choices, Lang.Zh).Matching);
        Assert.Equal(0, Pick("nih", choices, Lang.Zh));
        Assert.Equal(0, Pick("ni hao", choices, Lang.Zh));
        Assert.Equal(0, Pick("nihao", choices, Lang.Zh));
        Assert.Equal(2, Pick("zaijian", choices, Lang.Zh));
        Assert.Equal(R(4, 8), LearnFlow.TypeAheadOf("nih", choices, Lang.Zh).Ranges[0]);
        // The characters still work.
        Assert.Equal(0, Pick("你好", choices, Lang.Zh));
        Assert.Equal(0, Pick("你 好", choices, Lang.Zh));
    }

    [Fact]
    public void ChineseSpaces()
    {
        Assert.Equal(0, Pick("你好", ["你 好", "谢谢"], Lang.Fr));
        Assert.Null(Pick("xiexie", ["谢谢 (xiè xie)", "你好 (nǐ hǎo)"], Lang.Fr));
        Assert.Equal(0, Pick("xie xie", ["谢谢 (xiè xie)", "你好 (nǐ hǎo)"], Lang.Fr));
    }

    [Fact]
    public void LatinBrackets()
    {
        Assert.Null(Pick("fr", ["le pain (frais)", "le vin"], Lang.Fr));
        Assert.Null(Pick("fr", ["le pain (frais)", "le vin"], Lang.Zh));
    }

    [Theory]
    [InlineData("É", "e")]
    [InlineData("ß", "ss")]
    [InlineData("ǜ", "u")]
    [InlineData("أ", "ا")]
    [InlineData("ٱ", "ا")]
    [InlineData("ة", "ه")]
    [InlineData("ى", "ي")]
    [InlineData("كِ", "ك")]
    [InlineData("ـ", "")]
    [InlineData("（", "(")]
    [InlineData("’", "'")]
    public void Folding(string ch, string folded) => Assert.Equal(folded, TypeAheadText.Fold(ch));

    [Fact]
    public void ArabicIndicDigitsAreDigits()
    {
        Assert.Equal(3, LearnFlow.DigitValue("3"));
        Assert.Equal(0, LearnFlow.DigitValue("٠"));
        Assert.Equal(1, LearnFlow.DigitValue("١"));
        Assert.Equal(9, LearnFlow.DigitValue("٩"));
        Assert.Equal(0, LearnFlow.DigitValue("۰"));
        Assert.Equal(4, LearnFlow.DigitValue("۴"));
        foreach (var x in new[] { "a", "", "12", "١٢", " " }) Assert.Null(LearnFlow.DigitValue(x));
    }
    // MARK: Reducer (the typing keys of LearnFlowReducer)

    /// <summary>A Learn session over four new cards: the first question is multiple choice.</summary>
    sealed class Session
    {
        public LearnFlow.State State;
        public double Now = 1_760_000_000_000;
        public readonly RNG Rng = Rand.Mulberry32(7u);

        public Session()
        {
            List<Card> cards = [new("c1", "la voiture", "das Auto"), new("c2", "le chat", "die Katze"), new("c3", "la maison", "das Haus"), new("c4", "un arbre", "der Baum")];
            var set = new VocabSet { Id = "s", Title = "Wörter", TermLang = Lang.Fr, DefLang = Lang.De, Cards = cards, CreatedAt = Now };
            State = LearnFlow.Start(set, new Dictionary<string, CardProgress>(), StudyOptions.Default, rng: Rng, now: Now).State;
        }

        public void Send(LearnFlow.Event e)
        {
            Now += 1000;
            State = LearnFlow.Reduce(State, e, new LearnFlow.Env(Rng, Now)).State;
        }

        public void Key(KeyInput key, bool isRepeat = false) => Send(new LearnFlow.Event.Key(key, isRepeat));

        public void Type(string text)
        {
            foreach (var ch in JSCompat.CodePoints(text)) Key(KeyInput.Character(ch));
        }

        public string CorrectText => State.Question is { } q ? q.Choices.First(c => c.CardId == q.CardId).Text : "";
        public int CorrectIndex => State.Question is { } q ? q.Choices.ToList().FindIndex(c => c.CardId == q.CardId) : -1;
    }

    static readonly LearnFlow.Phase Mc = LearnFlow.Phase.Mc;

    [Fact]
    public void TypeAndReturn()
    {
        var s = new Session();
        Assert.Equal(Mc, s.State.Phase);
        var answer = s.CorrectText;
        s.Type(answer[..2]);
        // An article (or two letters of it) is not enough.
        Assert.Null(s.State.Highlighted);
        Assert.Null(LearnFlow.ReturnAction(s.State));
        s.Type(answer[2..]);
        Assert.Equal(answer, s.State.Typed);
        Assert.Equal(s.CorrectIndex, s.State.Highlighted);
        Assert.Equal("Auswählen", LearnFlow.ReturnAction(s.State));
        Assert.Equal(LearnFlow.OptionState.Highlighted, LearnFlow.OptionStateOf(s.State, s.CorrectIndex));
        s.Key(KeyInput.Return);
        Assert.Equal(LearnFlow.Phase.FeedbackOf(LearnFlow.FeedbackKind.Correct), s.State.Phase);
        Assert.Equal("", s.State.Typed);
    }

    [Fact]
    public void FilterDeleteAndEscape()
    {
        var s = new Session();
        s.Type("la ");
        var texts = s.State.Question!.Choices.Select(c => c.Text).ToList();
        var filtered = Enumerable.Range(0, 4).Where(i => LearnFlow.OptionStateOf(s.State, i) == LearnFlow.OptionState.Filtered);
        Assert.Equal(["le chat", "un arbre"], filtered.Select(i => texts[i]).Order());
        s.Type("vo");
        Assert.Equal("la voiture", s.State.Highlighted is { } h ? texts[h] : null);
        s.Key(KeyInput.DeleteBackward);
        Assert.Equal("la v", s.State.Typed);
        Assert.Null(s.State.Highlighted);
        s.Key(KeyInput.Escape);
        Assert.Equal("", s.State.Typed);
        Assert.Equal(Mc, s.State.Phase);
        // Nothing typed: Esc leaves.
        var effects = LearnFlow.Reduce(s.State, new LearnFlow.Event.Key(KeyInput.Escape), new LearnFlow.Env(s.Rng, s.Now + 1000)).Effects;
        Assert.Contains(new LearnFlow.Effect.Navigate(LearnFlow.Destination.Set), effects);
    }

    [Fact]
    public void DeletingWhileHeld()
    {
        var s = new Session();
        s.Type("la voi");
        s.Key(KeyInput.DeleteWordBackward);
        Assert.Equal("la ", s.State.Typed);
        s.Type("vo");
        Assert.NotNull(s.State.Highlighted);
        // Held Backspace: the repeats delete too, one letter each.
        s.Key(KeyInput.DeleteBackward);
        s.Key(KeyInput.DeleteBackward, isRepeat: true);
        Assert.Equal("la ", s.State.Typed);
        Assert.Null(s.State.Highlighted);
        s.Key(KeyInput.DeleteBackward, isRepeat: true);
        s.Key(KeyInput.DeleteBackward, isRepeat: true);
        s.Key(KeyInput.DeleteBackward, isRepeat: true);
        Assert.Equal("", s.State.Typed);
        // More Backspace on nothing typed does nothing (and never leaves the question).
        s.Key(KeyInput.DeleteBackward, isRepeat: true);
        s.Key(KeyInput.DeleteWordBackward);
        Assert.Equal(Mc, s.State.Phase);
        // A held letter still types only once.
        s.Key(KeyInput.Character("x"));
        s.Key(KeyInput.Character("x"), isRepeat: true);
        Assert.Equal("x", s.State.Typed);
        // Ctrl+Backspace over trailing spaces takes the word before them.
        s.Type("ab cd  ");
        s.Key(KeyInput.DeleteWordBackward);
        Assert.Equal("xab ", s.State.Typed);
    }

    [Fact]
    public void RejectAndOtherKeys()
    {
        var s = new Session();
        s.Type("xq");
        int rejections = s.State.Rejections;
        s.Key(KeyInput.Return);
        Assert.Equal(Mc, s.State.Phase);
        Assert.Equal(rejections + 1, s.State.Rejections);
        // Arrows take over from typing.
        s.Key(KeyInput.Arrow(Direction.Down));
        Assert.Equal("", s.State.Typed);
        Assert.Equal(0, s.State.Highlighted);
        // A digit still chooses directly.
        s.Type("la");
        s.Key(KeyInput.DigitKey(s.CorrectIndex + 1));
        Assert.Equal(LearnFlow.Phase.FeedbackOf(LearnFlow.FeedbackKind.Correct), s.State.Phase);
    }

    [Fact]
    public void ResetsBetweenQuestions()
    {
        var s = new Session();
        s.Type(" ");
        Assert.Equal("", s.State.Typed);
        s.Type("zz");
        s.Send(new LearnFlow.Event.Choose(s.CorrectIndex));
        Assert.Equal("", s.State.Typed);
        s.Key(KeyInput.Return);
        Assert.Equal("", s.State.Typed);
        Assert.Null(s.State.Highlighted);
    }
}
