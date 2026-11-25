using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Styling;
using Avalonia.Themes.Simple;

namespace Wortschatz.App;

/// <summary>The application (Mac: WortschatzApp.swift). Controls come from Avalonia's Simple theme, restyled in AppStyles.</summary>
public sealed class App : Application
{
    /// <summary>Set by the snapshot tool (a model it provides) and the Android app (its data folder).</summary>
    public static Func<AppModel>? ModelFactory { get; set; }

    public override void Initialize()
    {
        Styles.Add(new SimpleTheme());
        // The app's own styles come with the palette: MainView adds them (ApplyAppearance) before anything is shown.
        Name = "Wortschatz";
    }

    public override void OnFrameworkInitializationCompleted()
    {
        MainView.TrackMenus();
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            var model = ModelFactory?.Invoke() ?? AppModel.OpenDefault();
            desktop.MainWindow = new MainWindow(model);
            desktop.ShutdownMode = ShutdownMode.OnMainWindowClose;
        }
        else if (ApplicationLifetime is ISingleViewApplicationLifetime single)
        {
            // Android: one view in the activity, the same MainView as in the Windows window. The activity asks for it
            // again when Android recreates it (rotation, dark mode, back from the background): the same view moves over,
            // so the open screen and its state stay.
            var model = ModelFactory?.Invoke() ?? AppModel.OpenDefault();
            var view = new MainView(model);
            if (ApplicationLifetime is IActivityApplicationLifetime activity)
                activity.MainViewFactory = () =>
                {
                    switch (view.Parent)
                    {
                        case ContentControl holder: holder.Content = null; break;
                        case Decorator decorator: decorator.Child = null; break;
                        case Panel panel: panel.Children.Remove(view); break;
                    }
                    return view;
                };
            else single.MainView = view;
            // The app goes to the background: save at once (Android may end it there without asking).
            if (this.TryGetFeature<IActivatableLifetime>() is { } activatable)
            {
                activatable.Deactivated += (_, _) =>
                {
                    view.HostActivityChanged(false);
                    model.Flush();
                    model.Speech.Stop();
                };
                activatable.Activated += (_, _) => view.HostActivityChanged(true);
            }
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
