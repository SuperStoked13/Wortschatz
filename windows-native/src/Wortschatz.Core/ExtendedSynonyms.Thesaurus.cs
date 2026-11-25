namespace Wortschatz.Core;

// Windows and Android: "Weitere Synonyme erkennen" with the built-in thesauri (SynonymLexicon) instead of the Mac's
// language model. The Mac translates the prompt; here the expected answer's synonyms in its own language count.
public static partial class ExtendedSynonyms
{
    /// <summary>At most this many extra answers per question (an answer is graded against each).</summary>
    const int MaxThesaurusAnswers = 80;

    static readonly TextMemo<IReadOnlyList<string>> ThesaurusMemo = new(2_000);

    /// <summary>
    /// The synonyms of a written question's expected answer from the answer language's thesaurus, as extra answers for
    /// <see cref="Synonyms.GradeWithSynonyms"/> (which shows them as "Synonym – nicht im Set" and still refuses the
    /// prompt itself and answers of other cards). Empty for languages without data.
    /// </summary>
    public static IReadOnlyList<string> ThesaurusAnswers(SynonymQuery query) =>
        SynonymLexicon.Languages.Contains(query.AnswerLang) && HasLetters(query.Expected)
            ? ThesaurusMemo.Value($"{query.AnswerLang.Raw()}\u0001{query.Expected}",
                _ => ThesaurusAnswers(query.Expected, SynonymLexicon.For(query.AnswerLang)))
            : [];

    /// <summary>
    /// The extra answers for <paramref name="expected"/> from <paramref name="lexicon"/>. Per alternative of the
    /// expected answer («lieb, nett»): the synonyms of the matching word class – a noun's when the card shows one (an
    /// article; German: a capital; English: no «to»), else the others' –, a noun with the article of its own gender
    /// when the card gives one («das Fahrrad» → «das Velo», never «der Velo»), and with the card's placeholders
    /// («etw. verbieten» → «etw. untersagen»).
    /// </summary>
    public static IReadOnlyList<string> ThesaurusAnswers(string expected, SynonymLexicon? lexicon)
    {
        if (lexicon is null) return [];
        var lang = lexicon.Lang;
        var alternatives = Grading.SplitAlternatives(expected, lang);
        if (alternatives.Count == 0) alternatives = [expected];
        var own = new HashSet<string>(alternatives.Select(a => SynonymLexicon.KeyOf(a, lang)), StringComparer.Ordinal);
        var output = new List<string>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        void Add(string text)
        {
            if (output.Count < MaxThesaurusAnswers && seen.Add(text)) output.Add(text);
        }
        foreach (var alternative in alternatives.Take(6))
        {
            var card = CardForm.Of(StripBracketed(alternative), lang);
            if (card.Word.Length == 0) continue;
            foreach (var entry in lexicon.Lookup(card.Word))
            {
                if (!Fits(entry, card, lang)) continue;
                foreach (var synonym in entry.Synonyms)
                {
                    if (own.Contains(SynonymLexicon.KeyOf(synonym.Text, lang))) continue;
                    foreach (var form in card.Forms(synonym, lang)) Add(form);
                }
            }
        }
        return output;
    }

    /// <summary>Whether a word's list fits the card: same word class, and German nouns stay apart from other words.</summary>
    static bool Fits(LexiconEntry entry, CardForm card, Lang lang)
    {
        switch (lang)
        {
            case Lang.En:
                // «to sign» gets the verb's synonyms, «sign» the noun's and adjective's.
                return card.Verb ? entry.Class == 'v' : entry.Class != 'v';
            case Lang.De:
                // A capital marks a noun: «Steuern» (Abgaben) is not «steuern» (navigieren).
                return char.IsUpper(entry.Head, 0) == card.Capitalized;
            default:
                // «la bête» is the animal; «bête» without an article the adjective (unless the word is only a noun).
                return card.Article is not null ? entry.Class == 'n' : entry.Class != 'n' || entry.HeadClasses == "n";
        }
    }

    /// <summary>
    /// An alternative of the expected answer taken apart: its article, the word, its placeholders around the word
    /// («to», «etw.», «sth»).
    /// </summary>
    sealed record CardForm(string? Article, string Word, string Prefix, string Suffix, bool Verb, bool Capitalized)
    {
        static readonly HashSet<string> Placeholders = new(StringComparer.OrdinalIgnoreCase)
        {
            "etw.", "etw", "jmdn.", "jmdm.", "jmds.", "jmd.", "jdn.", "jdm.", "jds.", "jd.", "sth", "sth.", "sb", "sb.",
            "sb/sth", "sth/sb", "smth", "smb", "qc", "qc.", "qch", "qqch", "qqch.", "qn", "qn.", "qqn", "qqn.", "algo",
            "alguien", "qlco", "qlcu", "qualcosa", "qualcuno",
        };

        public static CardForm Of(string text, Lang lang)
        {
            var words = JSCompat.Trim(text).Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).ToList();
            string? article = null;
            bool verb = false;
            var prefix = new List<string>();
            var suffix = new List<string>();
            if (words.Count > 1 && lang == Lang.En && words[0].Equals("to", StringComparison.OrdinalIgnoreCase))
            {
                // «to» needs no copy: the grading treats it like an article.
                verb = true;
                words.RemoveAt(0);
            }
            else if (words.Count > 0 && ArticleOf(words[0], lang) is { } found)
            {
                article = found;
                if (found.EndsWith('\'')) words[0] = words[0][found.Length..];
                else words.RemoveAt(0);
            }
            while (words.Count > 1 && Placeholders.Contains(words[0]))
            {
                prefix.Add(words[0]);
                words.RemoveAt(0);
            }
            while (words.Count > 1 && Placeholders.Contains(words[^1]))
            {
                suffix.Insert(0, words[^1]);
                words.RemoveAt(words.Count - 1);
            }
            var word = string.Join(' ', words);
            return new CardForm(article, word, string.Join(' ', prefix), string.Join(' ', suffix), verb,
                word.Length > 0 && char.IsUpper(word, 0));
        }

        /// <summary>The article a card's word starts with («der», «l'», «una»), or null.</summary>
        static string? ArticleOf(string first, Lang lang)
        {
            if (lang == Lang.En || !Grading.ARTICLES.TryGetValue(lang, out var articles)) return null;
            var low = JSCompat.Lower(first).Replace('’', '\'');
            foreach (var a in articles)
            {
                if (a.Contains(' ')) continue;
                if (a.EndsWith('\'') ? low.StartsWith(a, StringComparison.Ordinal) && low.Length > a.Length : low == a) return a;
            }
            return null;
        }

        /// <summary>How a synonym is written as an answer to this card.</summary>
        public IEnumerable<string> Forms(LexiconWord synonym, Lang lang)
        {
            var bodies = new List<string>();
            if (Article is not null && lang != Lang.En)
            {
                // The card asks for the article: only the synonym's own gender counts. Without a known gender the
                // synonym is left out rather than accepted with any article.
                foreach (var article in ArticlesFor(synonym, lang)) bodies.Add(article.EndsWith('\'') ? article + synonym.Text : $"{article} {synonym.Text}");
            }
            else bodies.Add(synonym.Text);
            foreach (var body in bodies)
            {
                yield return body;
                if (Prefix.Length > 0 || Suffix.Length > 0)
                    yield return JSCompat.Trim($"{Prefix} {body} {Suffix}");
            }
        }

        /// <summary>The articles that go with a noun's gender (definite and indefinite).</summary>
        static IEnumerable<string> ArticlesFor(LexiconWord noun, Lang lang)
        {
            bool vowel = noun.Text.Length > 0 && "aeiouhàâäéèêëîïôöùûüAEIOUHÀÂÄÉÈÊËÎÏÔÖÙÛÜ".Contains(noun.Text[0]);
            foreach (var g in noun.Genders.Distinct())
            {
                string[] articles = (lang, g) switch
                {
                    (Lang.De, 'm') => ["der", "ein"],
                    (Lang.De, 'f') => ["die", "eine"],
                    (Lang.De, 'n') => ["das", "ein"],
                    (Lang.De, 'p') => ["die"],
                    (Lang.Fr, 'm') => vowel ? ["l'", "le", "un"] : ["le", "un"],
                    (Lang.Fr, 'f') => vowel ? ["l'", "la", "une"] : ["la", "une"],
                    (Lang.Fr, 'p') => ["les", "des"],
                    (Lang.Es, 'm') => ["el", "un"],
                    (Lang.Es, 'f') => vowel ? ["la", "una", "el"] : ["la", "una"],
                    (Lang.Es, 'p') => ["los", "las", "unos", "unas"],
                    (Lang.It, 'm') => vowel ? ["l'", "il", "lo", "un", "uno"] : ["il", "lo", "un", "uno"],
                    (Lang.It, 'f') => vowel ? ["l'", "la", "una", "un'"] : ["la", "una"],
                    (Lang.It, 'p') => ["i", "gli", "le"],
                    _ => [],
                };
                foreach (var a in articles) yield return a;
            }
        }
    }
}
