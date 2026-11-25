using Wortschatz.Core;

namespace Wortschatz.App.Services;

// The updates of the app (AppUpdater, Mac: Sparkle's UserDefaults keys and UpdateNoticeStore): this device only.
public sealed partial class AppPreferences : IUpdateStorage
{
    JSONValue? IUpdateStorage.GetUpdateValue(string key) => Get(key);

    void IUpdateStorage.SetUpdateValue(string key, JSONValue? value) => Set(key, value);

    /// <summary>Einstellungen › Daten › «Automatisch aktualisieren» (on by default): check daily, install on quit.</summary>
    public bool UpdatesAutomatically
    {
        get => Get("update.automatic")?.BoolValue ?? true;
        set => Set("update.automatic", value ? null : (JSONValue)false);
    }

    /// <summary>When the app last looked for an update (ms since 1970).</summary>
    public double? UpdateLastCheck
    {
        get => Get("update.lastCheck")?.FiniteNumber;
        set => Set("update.lastCheck", value is { } ms ? (JSONValue)ms : null);
    }

    /// <summary>The update waiting to be installed (null: none).</summary>
    public PendingUpdate? PendingUpdate
    {
        get => Core.PendingUpdate.FromJson(Get("update.pending"));
        set => Set("update.pending", value?.ToJson());
    }

    /// <summary>What went wrong last (English, for whoever looks into preferences.json; null after a good look).</summary>
    public string? UpdateError
    {
        get => Get("update.error")?.StringValue;
        set => Set("update.error", value is null ? null : (JSONValue)value);
    }
}
