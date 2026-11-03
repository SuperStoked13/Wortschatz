using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Wortschatz.App.DesignSystem;

/// <summary>
/// The window background of the Glas design: a soft mesh of four radial colour blobs (violet top left, pink top
/// right, blue bottom right, lilac bottom left) on a pale lavender (dark: near-black) base. Mac: the mesh
/// backdrop in GlassSurfaces.swift.
/// </summary>
public sealed class Backdrop : Control
{
    // (centre x, centre y, radius x, radius y) as fractions of the window, like the CSS of the design.
    static readonly (double X, double Y, double Rx, double Ry)[] Blobs =
    [
        (0.12, 0.08, 0.60, 0.55),
        (0.92, 0.18, 0.45, 0.50),
        (0.70, 0.95, 0.55, 0.60),
        (0.25, 0.85, 0.40, 0.45),
    ];

    public override void Render(DrawingContext context)
    {
        var p = WsTheme.P;
        var rect = new Rect(Bounds.Size);
        context.FillRectangle(WsTheme.B(p.Backdrop), rect);
        for (int i = 0; i < Blobs.Length && i < p.BackdropBlobs.Length; i++)
        {
            var (x, y, rx, ry) = Blobs[i];
            var c = p.BackdropBlobs[i];
            var brush = new RadialGradientBrush
            {
                Center = new RelativePoint(x, y, RelativeUnit.Relative),
                GradientOrigin = new RelativePoint(x, y, RelativeUnit.Relative),
                RadiusX = new RelativeScalar(rx, RelativeUnit.Relative),
                RadiusY = new RelativeScalar(ry, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(c, 0),
                    new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 0.7),
                },
            };
            context.FillRectangle(brush, rect);
        }
    }
}
