using Wortschatz.Core;
using Xunit;

namespace Wortschatz.Core.Tests;

// Port of SynonymsParityTests.swift.
public class SynonymsParityTests
{
    static AskSide Ask(JSONValue v) => v.StringValue == "term" ? AskSide.Term : AskSide.Definition;

    static Tolerance TolOf(int mask)
    {
        bool On(string key) => (mask & (1 << Math.Max(0, Array.IndexOf(Tolerance.Keys, key)))) != 0;
        return new Tolerance(On("articles"), On("abbreviations"), On("multipleAnswers"), On("parentheses"), On("ignoreCase"), On("ignoreAccents"), On("typos"));
    }

    [Fact]
    public void Fixture() => ParityRunner.Run("synonyms", c =>
    {
        switch (c.Fn)
        {
            case "sides":
                if (Card.FromJson(c.Arg(0)) is not { } card) return null;
                var ask = Ask(c.Arg(1));
                return JSONValue.Array(Synonyms.PromptSide(card, ask), Synonyms.AnswerSide(card, ask));
            case "synonymSet":
                var cards = (c.Arg(0).ArrayValue ?? []).Select(Card.FromJson).OfType<Card>().ToList();
                var ask2 = Ask(c.Arg(1));
                var lang = Grading.ResolveLang(c.Arg(2).StringValue);
                var synonyms = cards.Select(cd => Synonyms.FindSynonymCards(cards, cd, ask2).Select(x => x.Id).ToJsonArray());
                var results = (c.Arg(3).ArrayValue ?? []).Select(q =>
                {
                    var a = q.ArrayValue!;
                    return Synonyms.GradeWithSynonyms(a[1].StringValue!, cards[a[0].IntegerValue!.Value], cards, ask2, TolOf(a[2].IntegerValue!.Value), lang).ToJson();
                });
                return JSONValue.Obj(("synonyms", JSONValue.Array(synonyms)), ("results", JSONValue.Array(results)));
            default: return null;
        }
    });
}
