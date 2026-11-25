using Avalonia.Controls;
using Avalonia.Media;
using Wortschatz.App.DesignSystem;

namespace Wortschatz.App.Features.Editor;

/// <summary>Symbols only the editor uses, drawn like <see cref="Icons"/> (24×24 stroke paths).</summary>
static class EditorGlyphs
{
    /// <summary>"arrow.left.arrow.right": swap term and definition.</summary>
    public static Control Swap(double size, Color color) => Glyph("M8 4L4 8l4 4M4 8h15M16 12l4 4-4 4M20 16H5", size, color);

    static Control Glyph(string data, double size, Color color)
    {
        var canvas = new Canvas { Width = 24, Height = 24 };
        canvas.Children.Add(new Avalonia.Controls.Shapes.Path
        {
            Data = Geometry.Parse(data),
            Stroke = WsTheme.B(color),
            StrokeThickness = 2,
            StrokeLineCap = PenLineCap.Round,
            StrokeJoin = PenLineJoin.Round,
        });
        return new Viewbox { Width = size, Height = size, Child = canvas, IsHitTestVisible = false };
    }
}
