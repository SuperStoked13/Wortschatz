//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// The few Win32 calls the window needs.

var (
	user32  = windows.NewLazySystemDLL("user32.dll")
	dwmapi  = windows.NewLazySystemDLL("dwmapi.dll")
	gdi32   = windows.NewLazySystemDLL("gdi32.dll")
	shell32 = windows.NewLazySystemDLL("shell32.dll")

	procRegisterClassExW              = user32.NewProc("RegisterClassExW")
	procCreateWindowExW               = user32.NewProc("CreateWindowExW")
	procDefWindowProcW                = user32.NewProc("DefWindowProcW")
	procDestroyWindow                 = user32.NewProc("DestroyWindow")
	procShowWindow                    = user32.NewProc("ShowWindow")
	procUpdateWindow                  = user32.NewProc("UpdateWindow")
	procGetMessageW                   = user32.NewProc("GetMessageW")
	procTranslateMessage              = user32.NewProc("TranslateMessage")
	procDispatchMessageW              = user32.NewProc("DispatchMessageW")
	procPostQuitMessage               = user32.NewProc("PostQuitMessage")
	procLoadImageW                    = user32.NewProc("LoadImageW")
	procLoadCursorW                   = user32.NewProc("LoadCursorW")
	procFindWindowW                   = user32.NewProc("FindWindowW")
	procSetForegroundWindow           = user32.NewProc("SetForegroundWindow")
	procIsIconic                      = user32.NewProc("IsIconic")
	procSetWindowPos                  = user32.NewProc("SetWindowPos")
	procGetSystemMetrics              = user32.NewProc("GetSystemMetrics")
	procSystemParametersInfoW         = user32.NewProc("SystemParametersInfoW")
	procGetDpiForWindow               = user32.NewProc("GetDpiForWindow")
	procGetDpiForSystem               = user32.NewProc("GetDpiForSystem")
	procSetProcessDpiAwarenessContext = user32.NewProc("SetProcessDpiAwarenessContext")
	procMessageBoxW                   = user32.NewProc("MessageBoxW")
	procDwmSetWindowAttribute         = dwmapi.NewProc("DwmSetWindowAttribute")
	procCreateSolidBrush              = gdi32.NewProc("CreateSolidBrush")
	procSetAppUserModelID             = shell32.NewProc("SetCurrentProcessExplicitAppUserModelID")
)

const (
	wmDestroy       = 0x0002
	wmMove          = 0x0003
	wmSize          = 0x0005
	wmActivate      = 0x0006
	wmClose         = 0x0010
	wmGetMinMaxInfo = 0x0024
	wmDpiChanged    = 0x02E0

	sizeMinimized = 1

	wsOverlappedWindow       = 0x00CF0000
	swShowNormal             = 1
	swRestore                = 9
	cwUseDefault       int32 = -0x80000000

	imageIcon      = 1
	lrDefaultSize  = 0x0040
	lrShared       = 0x8000
	idcArrow       = 32512
	smCxSmIcon     = 49
	smCySmIcon     = 50
	spiGetWorkArea = 0x0030

	swpNoZOrder   = 0x0004
	swpNoActivate = 0x0010

	mbOK          = 0x00000000
	mbYesNo       = 0x00000004
	mbIconError   = 0x00000010
	mbIconWarning = 0x00000030
	mbDefButton2  = 0x00000100
	idYes         = 6

	// DWMWA_USE_IMMERSIVE_DARK_MODE; Windows 10 before 20H1 used 19.
	dwmwaUseImmersiveDarkMode    = 20
	dwmwaUseImmersiveDarkModeOld = 19

	dpiAwarenessPerMonitorV2 = ^uintptr(3) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = (HANDLE)-4
)

type point struct{ X, Y int32 }

type rect struct{ Left, Top, Right, Bottom int32 }

type msg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      point
	Private uint32
}

type minMaxInfo struct {
	Reserved     point
	MaxSize      point
	MaxPosition  point
	MinTrackSize point
	MaxTrackSize point
}

type wndClassEx struct {
	Size       uint32
	Style      uint32
	WndProc    uintptr
	ClsExtra   int32
	WndExtra   int32
	Instance   windows.Handle
	Icon       uintptr
	Cursor     uintptr
	Background uintptr
	MenuName   *uint16
	ClassName  *uint16
	IconSm     uintptr
}

func utf16(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}

// call ignores the error value of syscalls: Win32 leaves stale last-error codes around.
func call(p *windows.LazyProc, args ...uintptr) uintptr {
	if p.Find() != nil {
		return 0
	}
	r, _, _ := p.Call(args...)
	return r
}

func messageBox(hwnd uintptr, text, title string, flags uintptr) uintptr {
	return call(procMessageBoxW, hwnd, uintptr(unsafe.Pointer(utf16(text))), uintptr(unsafe.Pointer(utf16(title))), flags)
}

func loadIcon(instance windows.Handle, cx, cy int32) uintptr {
	flags := uintptr(lrShared)
	if cx == 0 {
		flags |= lrDefaultSize
	}
	return call(procLoadImageW, uintptr(instance), uintptr(unsafe.Pointer(utf16("APP"))), imageIcon, uintptr(cx), uintptr(cy), flags)
}

func dpiForWindow(hwnd uintptr) uint32 {
	if hwnd != 0 {
		if d := call(procGetDpiForWindow, hwnd); d != 0 {
			return uint32(d)
		}
	}
	if d := call(procGetDpiForSystem); d != 0 {
		return uint32(d)
	}
	return 96
}

func scale(v int32, dpi uint32) int32 { return v * int32(dpi) / 96 }

func setDarkTitleBar(hwnd uintptr, dark bool) {
	var value int32
	if dark {
		value = 1
	}
	if call(procDwmSetWindowAttribute, hwnd, dwmwaUseImmersiveDarkMode, uintptr(unsafe.Pointer(&value)), 4) != 0 {
		call(procDwmSetWindowAttribute, hwnd, dwmwaUseImmersiveDarkModeOld, uintptr(unsafe.Pointer(&value)), 4)
	}
}

func openURL(url string) {
	windows.ShellExecute(0, utf16("open"), utf16(url), nil, nil, swShowNormal)
}
