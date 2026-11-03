using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of ExamTests.swift. Prüfungsmodus: the sheet, the marking with its tolerance and the Swiss grade.
public class ExamTests
{
    static readonly List<Card> Cards =
    [
        new("c1", "la maison", "das Haus", true),
        new("c2", "l'élève", "der Schüler", true),
        new("c3", "s'occuper de", "sich kümmern um"),
        new("c4", "aimable, gentil", "freundlich"),
        new("c5", "le cheval", "das Pferd"),
        new("c6", "", "leer"),
        new("c7", "le chien", "der Hund"),
    ];

    static ExamQuestion Question(string cardId, AskSide ask = AskSide.Term, int number = 1)
    {
        var card = Cards.First(c => c.Id == cardId);
        return new ExamQuestion(number, cardId, ask, ask == AskSide.Term ? card.Definition : card.Term, ask == AskSide.Term ? card.Term : card.Definition,
            ask == AskSide.Term ? Lang.De : Lang.Fr, ask == AskSide.Term ? Lang.Fr : Lang.De);
    }

    static ExamItemResult Mark(string given, string cardId, AskSide ask = AskSide.Term, ExamTolerance tolerance = ExamTolerance.Half) =>
        Exam.Mark(given, Question(cardId, ask), Cards, tolerance);

    [Fact]
    public void TheSheetAsksTheWantedNumberOfUsableCards()
    {
        var questions = Exam.MakeQuestions(Cards, new ExamSettings(Count: 4, AnswerWith: AnswerWith.Term), Lang.Fr, Lang.De, rng: Rand.Mulberry32(1u));
        Assert.Equal(4, questions.Count);
        Assert.Equal([1, 2, 3, 4], questions.Select(q => q.Number));
        Assert.Equal(4, questions.Select(q => q.CardId).Distinct().Count());
        Assert.DoesNotContain(questions, q => q.CardId == "c6");
        foreach (var q in questions)
        {
            var card = Cards.First(c => c.Id == q.CardId);
            Assert.Equal(AskSide.Term, q.Ask);
            Assert.Equal(card.Definition, q.Prompt);
            Assert.Equal(card.Term, q.Expected);
            Assert.True(q.PromptLang == Lang.De && q.AnswerLang == Lang.Fr);
        }
        Assert.Equal(6, Exam.MakeQuestions(Cards, new ExamSettings(Count: 0), Lang.Fr, Lang.De, rng: Rand.Mulberry32(2u)).Count);
    }

    [Fact]
    public void StarredRetakesAndBothDirections()
    {
        var starred = Exam.MakeQuestions(Cards, new ExamSettings(Count: 0, StarredOnly: true), Lang.Fr, Lang.De, rng: Rand.Mulberry32(3u));
        Assert.Equal(new[] { "c1", "c2" }, starred.Select(q => q.CardId).Order());
        var retake = Exam.MakeQuestions(Cards, new ExamSettings(Count: 2, StarredOnly: true), Lang.Fr, Lang.De, ["c5", "c7", "c6"], Rand.Mulberry32(3u));
        Assert.Equal(new[] { "c5", "c7" }, retake.Select(q => q.CardId).Order());
        var both = Exam.MakeQuestions(Cards, new ExamSettings(Count: 0, AnswerWith: AnswerWith.Both), Lang.Fr, Lang.De, rng: Rand.Mulberry32(5u));
        Assert.Equal(2, both.Select(q => q.Ask).Distinct().Count());
        foreach (var q in both.Where(q => q.Ask == AskSide.Definition)) Assert.True(q.PromptLang == Lang.Fr && q.AnswerLang == Lang.De);
        Assert.Equal(6, Exam.QuestionCount(new ExamSettings(Count: 20), 6));
    }

    [Fact]
    public void RightAnswersAndFormsThatAreNoMistake()
    {
        Assert.Equal(ExamMark.Correct, Mark("la maison", "c1").Mark);
        Assert.Equal(ExamMark.Correct, Mark("  La maison ", "c1").Mark);
        Assert.Equal(1, Mark("gentil", "c4").Points);
        Assert.Equal(ExamMark.Correct, Mark("das Haus", "c1", AskSide.Definition).Mark);
    }

    [Fact]
    public void SmallMistakesCostWhatTheToleranceSays()
    {
        // Missing article, missing accent, a typo.
        foreach (var given in new[] { "maison", "l'eleve", "la maisson" })
        {
            var id = given.Contains("lev") ? "c2" : "c1";
            Assert.Equal(ExamMark.Minor, Mark(given, id).Mark);
            Assert.Equal(0.5, Mark(given, id).Points);
            Assert.Equal(0, Mark(given, id, tolerance: ExamTolerance.Strict).Points);
            Assert.Equal(1, Mark(given, id, tolerance: ExamTolerance.Lenient).Points);
        }
        Assert.Equal("Artikel fehlte", Mark("maison", "c1").Note);
        Assert.Equal("Akzente", Mark("l'eleve", "c2").Note);
        Assert.Equal("Tippfehler", Mark("la maisson", "c1").Note);
        // A German noun's small first letter.
        var small = Mark("das haus", "c1", AskSide.Definition);
        Assert.Equal(ExamMark.Minor, small.Mark);
        Assert.Equal("Gross-/Kleinschreibung", small.Note);
    }

    [Fact]
    public void WrongAndBlankAnswers()
    {
        var article = Mark("le maison", "c1");
        Assert.Equal(ExamMark.Wrong, article.Mark);
        Assert.Equal(0, article.Points);
        Assert.Equal("Falscher Artikel", article.Note);
        Assert.Equal(ExamMark.Wrong, Mark("le chat", "c7").Mark);
        var blank = Mark("   ", "c1");
        Assert.Equal(ExamMark.Blank, blank.Mark);
        Assert.Equal("", blank.Given);
    }

    [Fact]
    public void TheWholeSheet()
    {
        var questions = new[] { "c1", "c2", "c5", "c7" }.Select((id, i) => Question(id, number: i + 1)).ToList();
        var result = Exam.Evaluate(questions, new Dictionary<int, string> { [1] = "la maison", [2] = "l'eleve", [3] = "le cheval" }, Cards,
            ExamTolerance.Half, 90_000);
        Assert.Equal(2.5, result.Points);
        Assert.Equal(4, result.MaxPoints);
        Assert.Equal(2, result.Count(ExamMark.Correct));
        Assert.Equal(1, result.Count(ExamMark.Minor));
        Assert.Equal(1, result.Count(ExamMark.Blank));
        Assert.Equal(4.1, result.Grade);
        Assert.Equal(["c2", "c7"], result.CardIdsToPractise);
        Assert.Equal("2.5 von 4 Punkten", ExamCopy.ScoreLine(result));
        Assert.Equal("Halber Punkt", ExamCopy.MarkLabel(result.Items[1]));
    }

    [Fact]
    public void TheSwissGrade()
    {
        Assert.Equal(6, Exam.Grade(20, 20));
        Assert.Equal(1, Exam.Grade(0, 20));
        Assert.Equal(3.5, Exam.Grade(10, 20));
        Assert.Equal(4, Exam.Grade(12, 20));
        Assert.Equal(5.3, Exam.Grade(17, 20));
        Assert.Equal(5.4, Exam.Grade(17.5, 20));
        Assert.Equal(1, Exam.Grade(3, 0));
        // Exact halves round up.
        Assert.Equal(4.5, Exam.Grade(34.5, 50));
        Assert.Equal(5.2, Exam.Grade(41.5, 50));
        Assert.Equal(4.5, Exam.Grade(69, 100));
        Assert.Equal(6, Exam.Grade(25, 20));
        Assert.Equal(1, Exam.Grade(-2, 20));
        Assert.Equal("5.3", Exam.GradeText(5.3));
        Assert.Equal("6.0", Exam.GradeText(6));
        Assert.Equal("4.0", Exam.GradeText(4));
        Assert.Equal("17.5", Exam.PointsText(17.5));
        Assert.Equal("18", Exam.PointsText(18));
        Assert.True(Exam.Passes(4));
        Assert.False(Exam.Passes(3.9));
        Assert.Equal("Perfekt!", Exam.Verdict(6));
        Assert.Equal("Noch nicht genügend", Exam.Verdict(3.5));
    }

    [Fact]
    public void SettingsAreReadLeniently()
    {
        var s = ExamSettings.FromJson(JSONValue.Parse("""{"minutes": 15.7, "count": -3, "answerWith": "both", "tolerance": "nope", "examples": true}"""));
        // Unknown keys ("examples" of an earlier version) are ignored.
        Assert.Equal(new ExamSettings(15, 0, AnswerWith.Both, ExamTolerance.Half), s);
        Assert.Equal(s, ExamSettings.FromJson(JSONValue.Parse(s.ToJson().ToJsonString())));
        Assert.Equal("Ohne Zeitlimit", ExamCopy.Minutes(0));
        Assert.Equal("1 Minute", ExamCopy.Minutes(1));
    }

    [Fact]
    public void StoredNumbersSnapToTheChoicesOffered()
    {
        static ExamSettings Decode(string json) => ExamSettings.FromJson(JSONValue.Parse(json));
        Assert.Equal(5, Decode("""{"minutes": 7, "count": 25}""").Minutes);
        Assert.Equal(20, Decode("""{"minutes": 7, "count": 25}""").Count);
        Assert.Equal(new ExamSettings(45, 30), Decode("""{"minutes": 600, "count": 9999}"""));
        Assert.Equal(new ExamSettings(0, 0), Decode("""{"minutes": 0, "count": 0}"""));
        Assert.Equal(new ExamSettings(5, 10), Decode("""{"minutes": 2, "count": 1}"""));
    }

    [Fact]
    public void ASynonymWithASmallMistakeIsComparedWithItsOwnWord()
    {
        List<Card> cards = [new("v1", "la voiture", "das Auto"), new("v2", "l'automobile", "das Auto")];
        var question = new ExamQuestion(1, "v1", AskSide.Term, "das Auto", "la voiture", Lang.De, Lang.Fr);
        var typo = Exam.Mark("l'automobil", question, cards, ExamTolerance.Half);
        Assert.Equal(ExamMark.Minor, typo.Mark);
        Assert.True(typo.Synonym);
        Assert.Equal("l'automobile", typo.Matched);
        var own = Exam.Mark("la voitur", question, cards, ExamTolerance.Half);
        Assert.Equal(ExamMark.Minor, own.Mark);
        Assert.Null(own.Matched);
    }

    [Fact]
    public void ArabicAndChinese()
    {
        List<Card> cards = [new("z1", "你好 (nǐ hǎo)", "Hallo"), new("a1", "مدرسة", "Schule"), new("a2", "الكتاب", "das Buch")];
        ExamItemResult M(string given, string cardId, Lang answerLang)
        {
            var card = cards.First(c => c.Id == cardId);
            return Exam.Mark(given, new ExamQuestion(1, cardId, AskSide.Term, card.Definition, card.Term, Lang.De, answerLang), cards, ExamTolerance.Half);
        }
        Assert.Contains(GradeNote.Tones, Exam.SmallMistakes);
        Assert.DoesNotContain(GradeNote.Variant, Exam.SmallMistakes);
        Assert.DoesNotContain(GradeNote.Pinyin, Exam.SmallMistakes);
        var han = M("你好", "z1", Lang.Zh);
        Assert.True(han.Mark == ExamMark.Correct && han.Points == 1 && han.Note is null);
        var pinyin = M("ni3 hao3", "z1", Lang.Zh);
        Assert.True(pinyin.Mark == ExamMark.Correct && pinyin.Points == 1 && pinyin.Note is null);
        var tones = M("ni hao", "z1", Lang.Zh);
        Assert.True(tones.Mark == ExamMark.Minor && tones.Points == 0.5 && tones.Note == "Töne");
        var variant = M("مدرسه", "a1", Lang.Ar);
        Assert.True(variant.Mark == ExamMark.Correct && variant.Points == 1 && variant.Note is null);
        // A missing ال is a missing article (small); the variant adds nothing.
        var article = M("كتاب", "a2", Lang.Ar);
        Assert.True(article.Mark == ExamMark.Minor && article.Note == "Artikel fehlte");
        Assert.Equal(ExamMark.Wrong, M("谢谢", "z1", Lang.Zh).Mark);
    }
}
