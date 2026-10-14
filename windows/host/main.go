//go:build windows

// Wortschatz for Windows: one window that shows the web app (index.html, src/, styles/) in
// WebView2, the Edge engine that comes with Windows 10 and 11. Sets and progress stay in
// WebView2's storage under %LOCALAPPDATA%\Wortschatz.
package main

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"

	"github.com/jchv/go-webview2/pkg/edge"
	"github.com/jchv/go-webview2/webviewloader"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"wortschatz/windows/webfiles"
)

const (
	appName   = "Wortschatz"
	className = "WortschatzWindow"
	// The page's origin. Never change it: WebView2 keeps the sets and the progress per origin.
	appHost = "wortschatz.example"
	appURL  = "https://" + appHost + "/index.html"

	webView2Download = "https://go.microsoft.com/fwlink/p/?LinkId=2124703"

	// Window size in 96-dpi pixels.
	defaultWidth, defaultHeight = 1200, 820
	minWidth, minHeight         = 600, 600
)

// hostScript runs before the page's own scripts on every load: it tells the web app that it
// runs in the Windows app, lets it report its theme (the title bar follows) and whether the
// editor holds unsaved changes (closing the window asks first). A reload starts clean.
const hostScript = `(function () {
  function post(message) { try { window.chrome.webview.postMessage(message); } catch (e) {} }
  window.wortschatzHost = Object.freeze({
    platform: 'windows',
    setTheme: function (theme) { post('theme:' + theme); },
    setUnsaved: function (on) { post(on ? 'unsaved:1' : 'unsaved:0'); },
  });
  post('unsaved:0');
})();`

var (
	mainWindow uintptr
	browser    *edge.Chromium
	ready      bool
	unsaved    bool // the editor has changes that are not saved yet
)

func main() {
	runtime.LockOSThread()

	base := os.Getenv("LOCALAPPDATA")
	if base == "" {
		base = os.TempDir()
	}
	dataDir := filepath.Join(base, appName)
	os.MkdirAll(dataDir, 0o755)
	if f, err := os.Create(filepath.Join(dataDir, "wortschatz.log")); err == nil {
		log.SetOutput(f)
		defer f.Close()
	}

	// One window: starting Wortschatz again brings the open window to the front.
	mutex, err := windows.CreateMutex(nil, false, utf16(`Local\Wortschatz.App`))
	if err == windows.ERROR_ALREADY_EXISTS {
		focusRunningInstance()
		return
	}
	defer windows.CloseHandle(mutex)

	// Sharp text on scaled displays (the manifest says the same; this covers a missing one).
	call(procSetProcessDpiAwarenessContext, dpiAwarenessPerMonitorV2)

	webDir, err := webfiles.Unpack(webfiles.Files(), filepath.Join(dataDir, "App"))
	if err != nil {
		fail("Wortschatz konnte seine Programmdateien nicht entpacken.", err)
	}

	if version, err := webviewloader.GetInstalledVersion(); err != nil || version == "" {
		log.Printf("WebView2 version: %q, %v", version, err)
		missingWebView2()
	}

	dark := systemUsesDarkTheme()
	createWindow(dark)

	browser = edge.NewChromium()
	browser.DataPath = filepath.Join(dataDir, "WebView2")
	browser.MessageCallback = onMessage
	// Ctrl+V of a screenshot in the editor reads the clipboard.
	browser.SetPermission(edge.CoreWebView2PermissionKindClipboardRead, edge.CoreWebView2PermissionStateAllow)
	if !browser.Embed(mainWindow) {
		missingWebView2()
		return
	}
	ready = true
	configure(dark)

	view3 := browser.GetICoreWebView2_3()
	if view3 == nil {
		missingWebView2()
		return
	}
	if err := view3.SetVirtualHostNameToFolderMapping(appHost, webDir, edge.COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW); err != nil {
		log.Printf("SetVirtualHostNameToFolderMapping: %v", err)
	}
	browser.Init(hostScript)
	browser.Resize()
	browser.Navigate(appURL)
	browser.Focus()

	var m msg
	for {
		r := call(procGetMessageW, uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		call(procTranslateMessage, uintptr(unsafe.Pointer(&m)))
		call(procDispatchMessageW, uintptr(unsafe.Pointer(&m)))
	}
}

func createWindow(dark bool) {
	var instance windows.Handle
	windows.GetModuleHandleEx(0, nil, &instance)

	wc := wndClassEx{
		Instance:   instance,
		WndProc:    windows.NewCallback(wndProc),
		Icon:       loadIcon(instance, 0, 0),
		IconSm:     loadIcon(instance, int32(call(procGetSystemMetrics, smCxSmIcon)), int32(call(procGetSystemMetrics, smCySmIcon))),
		Cursor:     call(procLoadCursorW, 0, idcArrow),
		Background: call(procCreateSolidBrush, colorRef(dark)),
		ClassName:  utf16(className),
	}
	wc.Size = uint32(unsafe.Sizeof(wc))
	call(procRegisterClassExW, uintptr(unsafe.Pointer(&wc)))

	// Centred on the main screen's work area, never larger than it.
	dpi := dpiForWindow(0)
	w, h := scale(defaultWidth, dpi), scale(defaultHeight, dpi)
	x, y := cwUseDefault, cwUseDefault
	var work rect
	if call(procSystemParametersInfoW, spiGetWorkArea, 0, uintptr(unsafe.Pointer(&work)), 0) != 0 {
		ww, wh := work.Right-work.Left, work.Bottom-work.Top
		w, h = min(w, ww), min(h, wh)
		x, y = work.Left+(ww-w)/2, work.Top+(wh-h)/2
	}

	mainWindow = call(procCreateWindowExW, 0,
		uintptr(unsafe.Pointer(utf16(className))), uintptr(unsafe.Pointer(utf16(appName))),
		wsOverlappedWindow, uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		0, 0, uintptr(instance), 0)
	if mainWindow == 0 {
		fail("Das Fenster von Wortschatz konnte nicht geöffnet werden.", syscall.GetLastError())
	}
	setDarkTitleBar(mainWindow, dark)
	call(procShowWindow, mainWindow, swShowNormal)
	call(procUpdateWindow, mainWindow)
}

func wndProc(hwnd, message, wparam, lparam uintptr) uintptr {
	switch message {
	case wmSize:
		if browser != nil {
			// A minimised window hides the page, so its study clock stops counting.
			if wparam == sizeMinimized {
				browser.Hide()
			} else {
				browser.Show()
				browser.Resize()
			}
		}
	case wmMove:
		if browser != nil {
			browser.NotifyParentWindowPositionChanged()
		}
	case wmActivate:
		// Keys go straight to the page (Wortschatz is used with the Enter key alone).
		if wparam&0xFFFF != 0 && browser != nil {
			browser.Focus()
		}
	case wmGetMinMaxInfo:
		info := (*minMaxInfo)(unsafe.Pointer(lparam))
		dpi := dpiForWindow(hwnd)
		info.MinTrackSize = point{scale(minWidth, dpi), scale(minHeight, dpi)}
		return 0
	case wmDpiChanged:
		r := (*rect)(unsafe.Pointer(lparam))
		call(procSetWindowPos, hwnd, 0, uintptr(r.Left), uintptr(r.Top),
			uintptr(r.Right-r.Left), uintptr(r.Bottom-r.Top), swpNoZOrder|swpNoActivate)
		return 0
	case wmClose:
		if unsaved {
			text := "Dein Lernset ist noch nicht gespeichert. Wenn du Wortschatz jetzt schliesst, gehen die Änderungen verloren.\n\nTrotzdem schliessen?"
			if messageBox(hwnd, text, appName, mbYesNo|mbIconWarning|mbDefButton2) != idYes {
				return 0
			}
		}
		call(procDestroyWindow, hwnd)
		return 0
	case wmDestroy:
		if !ready {
			// Closed while WebView2 was still starting: Embed's own message loop is running.
			os.Exit(0)
		}
		call(procPostQuitMessage, 0)
		return 0
	}
	return call(procDefWindowProcW, hwnd, message, wparam, lparam)
}

// configure turns off what belongs to a browser rather than an app.
func configure(dark bool) {
	if settings, err := browser.GetSettings(); err == nil && settings != nil {
		settings.PutAreDevToolsEnabled(os.Getenv("WORTSCHATZ_DEVTOOLS") == "1")
		// Text fields keep Cut/Copy/Paste and spelling suggestions; the page itself hides
		// the menu elsewhere (src/lib/host.js).
		settings.PutAreDefaultContextMenusEnabled(true)
		// No address bubble when the pointer rests on a link.
		settings.PutIsStatusBarEnabled(false)
		// A sideways swipe must not leave a lesson (and belongs to the flashcards).
		if supports(unsafe.Pointer(settings), iidSettings6) {
			settings.PutIsSwipeNavigationEnabled(false)
		}
		// Ctrl+R, Ctrl+D, Ctrl+K, Ctrl+E, F5 … belong to the app (Vorlesen, Markieren, Optionen,
		// Bearbeiten), not to a browser (reload, bookmark, search). Copy and paste stay.
		if os.Getenv("WORTSCHATZ_DEVTOOLS") != "1" && supports(unsafe.Pointer(settings), iidSettings3) {
			settings.PutAreBrowserAcceleratorKeysEnabled(false)
		}
	} else {
		log.Printf("GetSettings: %v", err)
	}
	setBackground(dark)
}

func setBackground(dark bool) {
	controller := browser.GetController()
	if controller == nil {
		return
	}
	if c2 := controller.GetICoreWebView2Controller2(); c2 != nil {
		c := edge.COREWEBVIEW2_COLOR{A: 255, R: 0xF5, G: 0xF6, B: 0xFA}
		if dark {
			c = edge.COREWEBVIEW2_COLOR{A: 255, R: 0x0E, G: 0x10, B: 0x16}
		}
		c2.PutDefaultBackgroundColor(c)
	}
}

// colorRef is the window background before the page paints (the page's own colours).
func colorRef(dark bool) uintptr {
	if dark {
		return 0x16100E // 0x00BBGGRR of #0E1016
	}
	return 0xFAF6F5 // #F5F6FA
}

// onMessage receives the page's messages (see hostScript).
func onMessage(message string) {
	switch message {
	case "theme:dark":
		setDarkTitleBar(mainWindow, true)
		setBackground(true)
	case "theme:light":
		setDarkTitleBar(mainWindow, false)
		setBackground(false)
	case "unsaved:1":
		unsaved = true
	case "unsaved:0":
		unsaved = false
	}
}

func systemUsesDarkTheme() bool {
	key, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer key.Close()
	light, _, err := key.GetIntegerValue("AppsUseLightTheme")
	return err == nil && light == 0
}

func focusRunningInstance() {
	hwnd := call(procFindWindowW, uintptr(unsafe.Pointer(utf16(className))), 0)
	if hwnd == 0 {
		return
	}
	if call(procIsIconic, hwnd) != 0 {
		call(procShowWindow, hwnd, swRestore)
	}
	call(procSetForegroundWindow, hwnd)
}

func missingWebView2() {
	log.Print("WebView2 runtime missing or too old")
	text := "Wortschatz braucht die WebView2-Runtime von Microsoft. Sie gehört zu Windows 11 und ist auf den meisten Windows-10-Computern installiert, fehlt hier aber oder ist veraltet.\n\nDownload-Seite jetzt öffnen? Nach der Installation Wortschatz neu starten."
	if messageBox(mainWindow, text, appName, mbYesNo|mbIconWarning) == idYes {
		openURL(webView2Download)
	}
	os.Exit(1)
}

func fail(text string, err error) {
	log.Printf("%s %v", text, err)
	messageBox(mainWindow, fmt.Sprintf("%s\n\n%v", text, err), appName, mbOK|mbIconError)
	os.Exit(1)
}

// IID_ICoreWebView2Settings3 (browser accelerator keys).
var iidSettings3 = windows.GUID{Data1: 0xfdb5ab74, Data2: 0xaf33, Data3: 0x4854, Data4: [8]byte{0x84, 0xf0, 0x0a, 0x63, 0x1d, 0xeb, 0x5e, 0xba}}

// IID_ICoreWebView2Settings6 (swipe navigation).
var iidSettings6 = windows.GUID{Data1: 0x11cb3acd, Data2: 0x9bc8, Data3: 0x43b8, Data4: [8]byte{0x83, 0xbf, 0xf4, 0x07, 0x53, 0x71, 0x4f, 0x87}}

// supports asks a COM object whether it implements an interface (older WebView2 runtimes
// lack the newer settings, and calling them would crash).
func supports(object unsafe.Pointer, iid windows.GUID) bool {
	type unknownVtbl struct{ QueryInterface, AddRef, Release uintptr }
	vtbl := *(**unknownVtbl)(object)
	var out uintptr
	hr, _, _ := syscall.SyscallN(vtbl.QueryInterface, uintptr(object), uintptr(unsafe.Pointer(&iid)), uintptr(unsafe.Pointer(&out)))
	if hr != 0 || out == 0 {
		return false
	}
	outVtbl := *(**unknownVtbl)(unsafe.Pointer(out))
	syscall.SyscallN(outVtbl.Release, out)
	return true
}
