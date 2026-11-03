using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml.Styling;
using Avalonia.Styling;
using Avalonia.Themes.Simple;

namespace Wortschatz.App;

/// <summary>The application (Mac: WortschatzApp.swift). Controls come from Avalonia's Simple theme, restyled in AppStyles.</summary>
public sealed class App : Application
{
    /// <summary>Set by the snapshot tool: no window, a model it provides.</summary>
    public static Func<AppModel>? ModelFactory { get; set; }

    public override void Initialize()
    {
        Styles.Add(new SimpleTheme());
        Styles.Add(DesignSystem.AppStyles.Create());
        Name = "Wortschatz";
    }

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var model = ModelFactory?.Invoke() ?? AppModel.OpenDefault();
            desktop.MainWindow = new MainWindow(model);
            desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;
        }
        base.OnFrameworkInitializationCompleted();
    }
}

public static class Program
{
    [STAThread]
    public static void Main(string[] args) => BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
}
