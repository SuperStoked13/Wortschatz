using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;
using Wortschatz.Core;

namespace Wortschatz.App.Features.Study;

/// <summary>
/// The box of a study screen's answer field (Lernen, Schreiben), port of StudyAnswerBox in LearnPromptCard.swift. It
/// stays where it is through a question and its answer and only changes colour: after a correct answer it turns green
/// and shows what was typed (with a bouncing check) in the field's place. Accent ring while the field has the keys, red
/// after a rejected copy; it shakes when an empty answer or a wrong copy is rejected.
/// </summary>
public static class StudyAnswerBox
{
    static Palette P => WsTheme.P;

    /// <summary>A text field without its own frame (the box draws it).</summary>
    public static TextBox Field(string placeholder)
    {
        var box = new TextBox
        {
            PlaceholderText = placeholder,
            FontSize = 22,
            FontFamily = WsTheme.UI,
            FontWeight = FontWeight.Medium,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0, 4),
            MinHeight = 36,
            Foreground = WsTheme.B(P.Text),
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        box.Classes.Add("bare");
        return box;
    }

    /// <param name="field">The answer or copy field (null after a correct answer).</param>
    /// <param name="correctAnswer">What was typed, after a correct answer.</param>
    /// <param name="shake">An answer was just rejected.</param>
    /// <param name="accepted">The answer was just accepted (the check bounces, the box cross-fades to green).</param>
    public static Control Create(Control? field, string? correctAnswer, Lang lang, bool isActive, bool isInvalid, bool shake, bool accepted)
    {
        Control content;
        if (correctAnswer is not null)
        {
            var text = StudyText.InLang(correctAnswer, lang, 22, FontWeight.Medium, P.Success.Text);
            text.MaxLines = 3;
            var check = StudyStatusPill.FeedbackSymbol(Study.StudyStatus.Kinds.Correct, P.Success.Fill, 22);
            var row = Ui.H(12, text, check);
            AutomationProperties.SetName(row, $"Deine Antwort, richtig: {correctAnswer}");
            if (accepted)
            {
                Effects.Of(row).Enter(new Placement(Opacity: 0), Curve.EaseOut(0.2));
                Effects.Pop(check, 1.25);
            }
            content = row;
        }
        else content = field ?? new Border();
        var (ring, width) = correctAnswer is not null ? (Palette.Hex(Ui.Rgb(P.Success.Fill), 0.55), 1.5)
            : isInvalid ? (P.Failure.Fill, 2.0)
            : isActive ? (P.Accent, 2.0)
            : (P.Hairline, 1.0);
        var box = new Border
        {
            Child = content,
            Padding = new Thickness(16, 10),
            CornerRadius = new CornerRadius(14),
            Background = WsTheme.B(correctAnswer is null ? (P.Dark ? Palette.Hex(0x1C1E28, 0.72) : Palette.Hex(0xFFFFFF, 0.72)) : P.Success.Soft),
            BorderBrush = WsTheme.B(ring),
            BorderThickness = new Thickness(width),
            MinHeight = 56,
        };
        if (shake) Effects.Shake(box, 8);
        return box;
    }
}
