#Requires AutoHotkey v2.0
#SingleInstance Force
; Ahk2Exe build settings - these are what give Peek.exe its icon and the
; name Task Manager shows in its Description column. Rebuild with:
;   "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in Peek.ahk /out Peek.exe
;       /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
;@Ahk2Exe-SetMainIcon Peek.ico
;@Ahk2Exe-SetName Peek
;@Ahk2Exe-SetDescription Peek - instant top-process overlay
;@Ahk2Exe-SetProductName Peek
;@Ahk2Exe-SetVersion 1.0.0.0
;===============================================================================
;  Peek  -  press a hotkey, get an instant overlay of the top processes
;
;  Copyright (C) 2026  Arshit Vaghasiya
;
;  This program is free software: you can redistribute it and/or modify it
;  under the terms of the GNU General Public License as published by the Free
;  Software Foundation, either version 3 of the License, or (at your option)
;  any later version. It is distributed WITHOUT ANY WARRANTY; without even the
;  implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
;  See the GNU General Public License (LICENSE) for details.
;
;  DEFAULT HOTKEY:  Ctrl + Shift + X       (changeable in the settings window)
;
;  The overlay appears next to the mouse, refreshes itself while it is up, and
;  disappears on its own. Everything else is a dialog: right-click the tray icon
;  and pick "Settings...". The tray menu itself only carries what a dialog
;  cannot do - Peek now, Settings, Restart as administrator, Reload, Exit.
;
;  IN THE SETTINGS WINDOW:
;    Hotkey .......... captured by pressing the combination you want
;    Sort by ......... Network rate / Network session / Memory / Disk I/O / CPU
;    Columns ......... any combination, shown side by side. "Net *" columns are
;                      live rates; "Sess *" columns are the total bytes each
;                      process has moved since THIS SCRIPT was started.
;    Show ............ 5 / 10 / 15 / 20 rows
;    Stays up ........ 3 / 5 / 10 seconds, or until the hotkey is pressed again
;    Refresh ......... how fast the overlay re-samples while it is on screen
;    Follow cursor ... overlay drags with the mouse, or stays where you opened it
;    Group by name ... 40 chrome.exe processes collapse into one row
;    Show icons ...... each row gets the executable's own icon
;    Dark theme ...... dark or light overlay
;    Session totals .. whether the byte totals keep counting while the overlay
;                      is closed, and how often they are refreshed
;    Start with Windows  a logon task that starts Peek already elevated. A
;                      Startup-folder shortcut cannot do that - Windows has no
;                      "remember this" for consent, so it would ask at every
;                      boot. Ticking the box asks once; booting never asks.
;
;  COST WHEN IDLE: the process table is only read while the overlay is on
;  screen. The one thing that does run in the background is a TCP scan every
;  couple of seconds, and only because the "Sess *" totals would otherwise miss
;  every byte moved between peeks. Clear "Keep counting while the overlay is
;  closed" in the settings window for literally zero idle cost - the totals then
;  only count while the overlay is open.
;
;  SELF-CONTAINED: no #Include, no other script is read or launched, and the
;  only file touched is Peek.ini next to this one (Peek.exe when compiled).
;
;  ADMIN: per-process network needs elevation (the TCP EStats API refuses to
;  enable collection otherwise). Memory, disk and CPU work fine without it.
;===============================================================================

ListLines False
SetWinDelay -1
A_IconTip := "Peek  -  press the hotkey for a process overlay"

;-------------------------------------------------------------------------------
; 1. Column / option tables
;-------------------------------------------------------------------------------
; fmt: r = byte rate, b = byte size, p = percent, i = integer
; "Sess*" columns are cumulative BYTES since the script was launched; the Net*
; columns above them are per-second rates.
global COLS := [
    { key: "netIn",   title: "Net Dn",    w: 10, fmt: "r" },
    { key: "netOut",  title: "Net Up",    w: 10, fmt: "r" },
    { key: "netTot",  title: "Net Total", w: 10, fmt: "r" },
    { key: "sessIn",  title: "Sess Dn",   w:  9, fmt: "b" },
    { key: "sessOut", title: "Sess Up",   w:  9, fmt: "b" },
    { key: "sessTot", title: "Sess Total", w: 10, fmt: "b" },
    { key: "ws",      title: "Memory",    w: 10, fmt: "b" },
    { key: "disk",    title: "Disk I/O",  w: 10, fmt: "r" },
    { key: "cpu",     title: "CPU %",     w:  7, fmt: "p" },
    { key: "conn",    title: "Conn",      w:  5, fmt: "i" },
    { key: "pid",     title: "PID",       w:  7, fmt: "i" },
    { key: "count",   title: "Procs",     w:  6, fmt: "i" } ]

global SORTS := [ { key: "netTot",  title: "Network (rate)"   }
                , { key: "sessTot", title: "Network (session)" }
                , { key: "ws",      title: "Memory"  }
                , { key: "disk",    title: "Disk I/O" }
                , { key: "cpu",     title: "CPU"     } ]

global DURS   := [3000, 5000, 10000, 0]        ; 0 = until the hotkey is pressed again
global COUNTS := [5, 10, 15, 20]
global INI    := A_ScriptDir "\Peek.ini"

global gFreq := 0
DllCall("QueryPerformanceFrequency", "Int64*", &gFreq)
global gCores := DllCall("GetActiveProcessorCount", "UShort", 0xFFFF, "UInt") || 1

;-------------------------------------------------------------------------------
; 2. Settings
;-------------------------------------------------------------------------------
global Cfg := LoadSettings()
global gNetOK := A_IsAdmin && HasEStats()

if !A_IsAdmin && Cfg.askElevate && WantsNetwork()
    AskElevate()

; True when any selected column or the sort key needs the TCP EStats data.
WantsNetwork() {
    if InStr(Cfg.sortKey, "net") || InStr(Cfg.sortKey, "sess")
        return true
    for k in StrSplit(Cfg.cols, ",")
        if InStr(k, "net") || InStr(k, "sess")
            return true
    return false
}

AskElevate() {
    msg := "Peek is not running as administrator.`n`n"
         . "You have a NETWORK column selected, and per-process network usage is"
         . " the one thing that needs elevation: the TCP EStats API will not"
         . " enable per-connection byte counters without admin rights.`n`n"
         . "Memory, disk I/O and CPU all work fine without it.`n`n"
         . "Restart elevated now?`n`n"
         . "Yes    - relaunch with an elevation prompt`n"
         . "No     - continue; network columns will read n/a`n"
         . "Cancel - quit`n`n"
         . "(Silence this in Settings: Ask about elevation.)"
    switch MsgBox(msg, "Peek - administrator rights", "YesNoCancel Icon? 0x1000") {
        case "Yes":  Elevate()
        case "Cancel", "": ExitApp
    }
}

Elevate() {
    try {
        SaveSettings()
        if A_IsCompiled
            Run '*RunAs "' A_ScriptFullPath '" /restart'
        else
            Run '*RunAs "' A_AhkPath '" /restart "' A_ScriptFullPath '"'
        ExitApp
    } catch
        MsgBox "Elevation was cancelled or denied.", "Peek", "Icon! 0x1000"
}

HasEStats() {
    if !(h := DllCall("GetModuleHandle", "Str", "iphlpapi", "Ptr"))
        h := DllCall("LoadLibrary", "Str", "iphlpapi.dll", "Ptr")
    if !h
        return false
    for fn in ["SetPerTcpConnectionEStats", "GetPerTcpConnectionEStats"]
        if !DllCall("GetProcAddress", "Ptr", h, "AStr", fn, "Ptr")
            return false
    return true
}

;-------------------------------------------------------------------------------
; 3. Sampling state (only touched while the overlay is visible)
;-------------------------------------------------------------------------------
global gProc     := Map()       ; pid -> {name, prevCpu, prevIo, cpu, ws, disk, ...}
global gStamp    := 0
global gPrevConn := Map()       ; tcp connection key -> [bytesOut, bytesIn]
global gPrevQpc  := 0

; The process table is only read while the overlay is up, but network totals are
; supposed to cover the whole time the script has been running - so the network
; scan lives on its own ticker: slow while idle, fast while the overlay is open.
global gNetRates := Map()       ; pid -> { in, out, conn }  most recent rates
global gSessPid  := Map()       ; pid -> { in, out }        bytes since launch
global gNetQpc   := 0
global gVisible  := false
global gAnchor   := { x: 0, y: 0 }
global gHotkeyOn := false

;-------------------------------------------------------------------------------
; 4. The overlay window
;-------------------------------------------------------------------------------
; -Caption      : no title bar
; +E0x08000000  : WS_EX_NOACTIVATE - never steals focus from what you are doing
; +E0x20        : WS_EX_TRANSPARENT - clicks pass straight through it
; +0x800000     : WS_BORDER - a hairline edge so it reads as a panel
global TIP := Gui("-Caption +AlwaysOnTop +ToolWindow +E0x08000020 +0x800000",
                  "Peek overlay")
global TXT  := ""
global gPics := []              ; one reusable Picture control per possible row
BuildTip()

BuildTip() {
    global TXT
    TIP.BackColor := Cfg.dark ? "1C1C1C" : "FFFFE1"
    font := "s9 c" (Cfg.dark ? "E8E8E8" : "202020")
    TIP.SetFont(font, "Consolas")
    if TXT {
        TXT.SetFont(font, "Consolas")        ; Gui.SetFont only reaches new controls
        TXT.Value := ""
        return
    }
    TXT := TIP.AddText("x9 y7 w900 h400 BackgroundTrans", "")
    ; Icon holders are created once and reused. They are added AFTER the text
    ; control so they sit above it in z-order, and they live in the blank
    ; gutter the table leaves on the left when icons are switched on.
    Loop COUNTS[COUNTS.Length] {
        try gPics.Push(TIP.AddPicture("x0 y0 w16 h16 Hidden"))
    }
}

;-------------------------------------------------------------------------------
; 5. Startup: hotkey, tray, network ticker
;-------------------------------------------------------------------------------
ApplyHotkey(Cfg.hotkey)
BuildTray()
; Prime EStats immediately - enabling a connection only starts its counters from
; that moment - then start the background ticker so the session totals really do
; cover the whole time the script has been running.
if gNetOK {
    SampleNetwork(0)
    ApplyNetTimer()
}
OnExit((*) => SaveSettings())

; One timer, two speeds: overlay open -> fast enough for smooth rates; overlay
; closed -> just often enough to keep the totals honest. Costs one TCP table
; scan per tick (a couple of ms), or nothing at all if background tracking is off.
ApplyNetTimer() {
    SetTimer(NetTick, 0)
    if !gNetOK
        return
    if gVisible
        SetTimer(NetTick, Cfg.interval)
    else if Cfg.bgTrack
        SetTimer(NetTick, Cfg.bgInterval)
}

ApplyHotkey(hk) {
    global gHotkeyOn
    if gHotkeyOn {
        try Hotkey(Cfg.hotkey, "Off")
        gHotkeyOn := false
    }
    try {
        Hotkey(hk, (*) => TogglePeek(), "On")
        Cfg.hotkey := hk
        gHotkeyOn := true
        return true
    } catch as e {
        MsgBox "Could not register the hotkey '" hk "'.`n`n" e.Message,
               "Peek", "Icon! 0x1000"
        return false
    }
}

; Deliberately tiny: every option lives in the settings window (section 6), so
; the tray only keeps what a dialog cannot do.
BuildTray() {
    tray := A_TrayMenu
    tray.Delete()
    tray.Add("Peek now", (*) => TogglePeek())
    tray.Add("Settings...", (*) => ShowSettings())
    tray.Default := "Peek now"
    tray.Add()
    if !A_IsAdmin
        tray.Add("Restart as administrator", (*) => Elevate())
    tray.Add("Reload", (*) => Reload())
    tray.Add("Exit", (*) => ExitApp())
}

SelectedCols() {
    m := Map()
    for k in StrSplit(Cfg.cols, ",")
        if k != ""
            m[k] := true
    if !m.Count
        m["netIn"] := true, m["netOut"] := true
    return m
}

VisibleCols() {
    sel := SelectedCols()
    out := []
    for c in COLS
        if sel.Has(c.key)
            out.Push(c)
    return out
}

; "^+x" -> "Ctrl+Shift+X". A chain of StrReplace calls cannot do this: the "+"
; that "Ctrl+" just inserted gets replaced again and comes out as "CtrlShift+".
Pretty(hk) {
    static NAMES := Map("^", "Ctrl+", "!", "Alt+", "+", "Shift+", "#", "Win+")
    out := ""
    Loop Parse hk {
        if !NAMES.Has(A_LoopField) {            ; the rest of it is the key itself
            key := SubStr(hk, A_Index)
            return out (StrLen(key) = 1 ? StrUpper(key) : key)
        }
        out .= NAMES[A_LoopField]
    }
    return out
}

;-------------------------------------------------------------------------------
; 6. Settings window
;-------------------------------------------------------------------------------
; Everything customisable is in here. Nothing is committed until OK or Apply,
; so a half-typed interval cannot leave the overlay in a strange state, and an
; unusable value stops OK from closing the window instead of being swallowed.
;
; The dialog keeps the system theme even when the overlay is dark: drop-downs
; and edit fields cannot be recoloured without owner-drawing them, and a
; half-dark dialog looks broken.
global SG   := ""       ; the settings Gui while it is open, "" otherwise
global SGc  := {}       ; its controls, by option name
global SGhk := ""       ; hotkey captured in the window but not applied yet

ShowSettings() {
    global SG, SGc, SGhk, gTaskOn
    if SG {                                      ; already open - just raise it
        try {
            if WinExist("ahk_id " SG.Hwnd) {
                WinActivate("ahk_id " SG.Hwnd)
                return
            }
        }
        SG := ""
    }

    sel := SelectedCols()
    ; The column grid is derived from COLS, so adding a column in section 1
    ; needs no change here; the window just grows a row.
    gRows := Ceil(COLS.Length / 2)
    colsH := 26 + gRows * 23 + 10
    hkY   := 8 + colsH + 10
    adY   := hkY + 120
    adH   := A_IsAdmin ? 76 : 112
    btnY  := Max(438, adY + adH) + 12

    SG   := Gui("+AlwaysOnTop +OwnDialogs -MinimizeBox -MaximizeBox", "Peek settings")
    SGc  := {}
    SGhk := Cfg.hotkey
    SG.SetFont("s9", "Segoe UI")
    SG.OnEvent("Close",  (*) => CloseSettings())
    SG.OnEvent("Escape", (*) => CloseSettings())

    ;--- overlay ---------------------------------------------------------------
    SG.AddGroupBox("x10 y8 w286 h250", "Overlay")

    names := []
    for s in SORTS
        names.Push(s.title)
    SG.AddText("x24 y32 w86 h22 +0x200", "Sort by")
    SGc.sort := SG.AddDropDownList("x112 y30 w172", names)
    SGc.sort.Value := IdxOfKey(SORTS, Cfg.sortKey)

    names := []
    for n in COUNTS
        names.Push("Top " n " processes")
    SG.AddText("x24 y60 w86 h22 +0x200", "Show")
    SGc.count := SG.AddDropDownList("x112 y58 w172", names)
    SGc.count.Value := IdxOfVal(COUNTS, Cfg.count)

    names := []
    for d in DURS
        names.Push(d ? (d // 1000) " seconds" : "Until I press the hotkey again")
    SG.AddText("x24 y88 w86 h22 +0x200", "Stays up")
    SGc.duration := SG.AddDropDownList("x112 y86 w172", names)
    SGc.duration.Value := IdxOfVal(DURS, Cfg.duration)

    SG.AddText("x24 y116 w86 h22 +0x200", "Refresh")
    SGc.interval := SG.AddEdit("x112 y114 w56 h22 Number Limit5", Cfg.interval)
    SG.AddText("x174 y116 w112 h22 +0x200", "ms  (300 - 5000)")

    SGc.follow := SG.AddCheckbox("x24 y146 w262 h22", "Follow the cursor while open")
    SGc.group  := SG.AddCheckbox("x24 y170 w262 h22", "Group processes by name")
    SGc.icons  := SG.AddCheckbox("x24 y194 w262 h22", "Show process icons")
    SGc.dark   := SG.AddCheckbox("x24 y218 w262 h22", "Dark theme")
    SGc.follow.Value := Cfg.follow
    SGc.group.Value  := Cfg.group
    SGc.icons.Value  := Cfg.icons
    SGc.dark.Value   := Cfg.dark

    ;--- background tracking ---------------------------------------------------
    SG.AddGroupBox("x10 y266 w286 h112", "Session totals")
    SGc.bgTrack := SG.AddCheckbox("x24 y290 w262 h22",
                                  "Keep counting while the overlay is closed")
    SGc.bgTrack.Value := Cfg.bgTrack
    SG.AddText("x24 y316 w86 h22 +0x200", "Scan every")
    SGc.bgInterval := SG.AddEdit("x112 y314 w56 h22 Number Limit5", Cfg.bgInterval)
    SG.AddText("x174 y316 w112 h22 +0x200", "ms  (500 - 60000)")
    SGc.askElevate := SG.AddCheckbox("x24 y342 w262 h22",
                                     "Ask about elevation at startup")
    SGc.askElevate.Value := Cfg.askElevate

    ;--- start with windows ----------------------------------------------------
    ; Read from the task itself rather than from the ini: the task is the state,
    ; and it can be removed from Task Scheduler behind Peek's back.
    gTaskOn := TaskExists()
    SG.AddGroupBox("x10 y386 w286 h52", "Start with Windows")
    SGc.startup := SG.AddCheckbox("x24 y408 w262 h22",
                                  "Start at logon, already elevated")
    SGc.startup.Value := gTaskOn

    ;--- columns ---------------------------------------------------------------
    SG.AddGroupBox("x306 y8 w250 h" colsH, "Columns")
    SGc.col := Map()
    for i, c in COLS {
        cb := SG.AddCheckbox("x" (320 + ((i - 1) // gRows) * 114)
                           . " y" (34 + Mod(i - 1, gRows) * 23) " w112 h22", c.title)
        cb.Value := sel.Has(c.key) ? 1 : 0
        SGc.col[c.key] := cb
    }

    ;--- hotkey ----------------------------------------------------------------
    SG.AddGroupBox("x306 y" hkY " w250 h110", "Hotkey")
    SG.SetFont("s10 bold")
    SGc.hkText := SG.AddText("x320 y" (hkY + 24) " w222 h24 +0x200", Pretty(Cfg.hotkey))
    SG.SetFont("s9 norm")
    SG.AddButton("x320 y" (hkY + 52) " w130 h28", "Change...")
      .OnEvent("Click", (*) => ChangeHotkey())
    SG.AddText("x320 y" (hkY + 84) " w222 h20", "At least one modifier is required.")

    ;--- per-process network ---------------------------------------------------
    SG.AddGroupBox("x306 y" adY " w250 h" adH, "Per-process network")
    SG.AddText("x320 y" (adY + 22) " w222 h46", A_IsAdmin
        ? (gNetOK ? "Elevated and TCP EStats is available, so the Net and Sess"
                  . " columns are live."
                  : "Elevated, but this system does not expose TCP EStats; the"
                  . " Net and Sess columns read n/a.")
        : "Not elevated. TCP EStats will not count bytes without administrator"
        . " rights, so the Net and Sess columns read n/a.")
    if !A_IsAdmin
        SG.AddButton("x320 y" (adY + 72) " w222 h28", "Restart as administrator")
          .OnEvent("Click", (*) => (ApplySettings() && Elevate()))

    ;--- buttons ---------------------------------------------------------------
    ; Bottom left, away from OK/Cancel/Apply so it never gets hit by accident.
    SG.AddButton("x10 y" btnY " w254 h28", "Check out more tech stuff @geek_updates")
      .OnEvent("Click", (*) => OpenPromo())
    SG.AddButton("x274 y" btnY " w90 h28 +Default", "OK")
      .OnEvent("Click", (*) => (ApplySettings() && CloseSettings()))
    SG.AddButton("x370 y" btnY " w90 h28", "Cancel").OnEvent("Click", (*) => CloseSettings())
    SG.AddButton("x466 y" btnY " w90 h28", "Apply").OnEvent("Click", (*) => ApplySettings())

    SG.Show("w566 h" (btnY + 40))
}

; Reads the window into Cfg and re-applies everything that can change while the
; script runs. Returns false - having said why - when a value is unusable,
; which is what stops OK from closing on a bad entry.
ApplySettings() {
    global SG, SGc, SGhk, gTaskOn
    if !SG
        return false

    keys := []
    for c in COLS
        if SGc.col[c.key].Value
            keys.Push(c.key)                     ; canonical order, not click order
    if !keys.Length {
        MsgBox "Pick at least one column.", "Peek", "Icon! 0x1000"
        return false
    }
    iv := NumOr(SGc.interval.Value, 0)
    if iv < 300 || iv > 5000 {
        MsgBox "The refresh interval has to be between 300 and 5000 ms.",
               "Peek", "Icon! 0x1000"
        return false
    }
    bi := NumOr(SGc.bgInterval.Value, 0)
    if bi < 500 || bi > 60000 {
        MsgBox "The background scan interval has to be between 500 and 60000 ms.",
               "Peek", "Icon! 0x1000"
        return false
    }
    ; The hotkey is the one setting Windows can refuse, so it is tried first and
    ; the old combination is put back if the new one fails.
    if SGhk != Cfg.hotkey && !ApplyHotkey(SGhk) {
        ApplyHotkey(Cfg.hotkey)
        SGhk := Cfg.hotkey
        SGc.hkText.Value := Pretty(Cfg.hotkey)
        return false
    }

    Cfg.cols       := JoinArr(keys, ",")
    Cfg.sortKey    := SORTS[SGc.sort.Value].key
    Cfg.count      := COUNTS[SGc.count.Value]
    Cfg.duration   := DURS[SGc.duration.Value]
    Cfg.interval   := iv
    Cfg.bgInterval := bi
    Cfg.follow     := SGc.follow.Value
    Cfg.group      := SGc.group.Value
    Cfg.icons      := SGc.icons.Value
    Cfg.dark       := SGc.dark.Value
    Cfg.bgTrack    := SGc.bgTrack.Value
    Cfg.askElevate := SGc.askElevate.Value

    ; A system-wide change, so like everything else here it waits for OK or
    ; Apply - and the checkbox is re-synced from the task afterwards, because
    ; the UAC prompt it needs can be declined.
    if SGc.startup.Value != gTaskOn {
        if SetStartup(SGc.startup.Value)
            gTaskOn := SGc.startup.Value
        else {
            MsgBox (SGc.startup.Value
                 ? "Could not create the startup task.`n`nIt needs administrator"
                 . " rights - the consent prompt may have been declined."
                 : "Could not remove the startup task.`n`nIt needs administrator"
                 . " rights - the consent prompt may have been declined."),
                   "Peek", "Icon! 0x1000"
            gTaskOn := TaskExists()
            SGc.startup.Value := gTaskOn
        }
    }

    BuildTip()                                   ; theme
    ApplyNetTimer()                              ; bgTrack / both intervals
    SetTimer(FollowCursor, (Cfg.follow && gVisible) ? 30 : 0)
    if gVisible {
        SetTimer(UpdatePeek, Cfg.interval)
        SetTimer(HidePeek, Cfg.duration ? -Cfg.duration : 0)
        UpdatePeek()
    }
    SaveSettings()
    return true
}

; Run() hands the URL to whatever is registered for https, so it lands in the
; default browser instead of a hardcoded one. It throws when nothing is
; registered at all, in which case the URL is at least shown to copy.
OpenPromo() {
    static URL := "https://www.instagram.com/geek_updates"
    try
        Run URL
    catch
        MsgBox "Could not open a browser for:`n`n" URL, "Peek", "Icon! 0x1000"
}

CloseSettings() {
    global SG
    if SG {
        try SG.Destroy()
        SG := ""
    }
    return true
}

ChangeHotkey() {
    global SGhk
    if (hk := CaptureHotkey()) != "" {
        SGhk := hk
        SGc.hkText.Value := Pretty(hk)
    }
}

; Capture a real key combination rather than making anyone type AHK syntax.
; Returns "" when it was cancelled or had no modifier. The live hotkey is
; switched off for the duration, or it would eat the very keystroke being read.
CaptureHotkey() {
    global gHotkeyOn
    cg := Gui("+AlwaysOnTop +ToolWindow" (SG ? " +Owner" SG.Hwnd : ""),
              "Peek - set hotkey")
    cg.SetFont("s10", "Segoe UI")
    cg.AddText("x16 y14 w300 h44",
               "Hold the modifiers you want and press a key.`nEsc cancels.")
    cg.Show("w330 h80")

    if gHotkeyOn {
        try Hotkey(Cfg.hotkey, "Off")
        gHotkeyOn := false
    }
    ih := InputHook("V")
    ih.KeyOpt("{All}", "E")
    ih.Start()
    ih.Wait()
    key := ih.EndKey
    mods := (GetKeyState("Ctrl")  ? "^" : "")
          . (GetKeyState("Alt")   ? "!" : "")
          . (GetKeyState("Shift") ? "+" : "")
          . (GetKeyState("LWin") || GetKeyState("RWin") ? "#" : "")
    cg.Destroy()
    ApplyHotkey(Cfg.hotkey)                      ; put the live hotkey back

    if key = "Escape" || key = ""
        return ""
    if mods = "" {
        MsgBox "Please include at least one modifier (Ctrl, Alt, Shift or Win),"
             . " otherwise the key would be swallowed system-wide.",
               "Peek", "Icon! 0x1000"
        return ""
    }
    return mods key
}

IdxOfKey(arr, key) {
    for i, o in arr
        if o.key = key
            return i
    return 1
}

IdxOfVal(arr, v) {
    for i, x in arr
        if x = v
            return i
    return 1
}

NumOr(s, def) => (s = "" || !IsNumber(s)) ? def : Integer(s)

;-------------------------------------------------------------------------------
; 7. Start with Windows
;-------------------------------------------------------------------------------
; Per-process network needs elevation, and an elevated program cannot be started
; from the Startup folder without consent: UAC has no "remember this", so every
; boot would put a prompt on screen. A logon task registered to run with the
; highest privileges available is the supported way round it - Task Scheduler
; launches it elevated, with no prompt, because consent was given once when the
; task was created.
;
; The task is written from scratch each time the box is ticked, so moving
; Peek.exe and re-ticking is all it takes to repoint it.
global TASK    := "Peek"
global gTaskOn := false         ; refreshed whenever the settings window opens

TaskExists() {
    try
        return RunWait('schtasks.exe /Query /TN "' TASK '"', , "Hide") = 0
    catch
        return false
}

SetStartup(on) {
    try {
        if on {
            xml := A_Temp "\" TASK "-task.xml"
            try FileDelete(xml)
            FileAppend(TaskXml(), xml, "UTF-16")   ; schtasks wants UTF-16 + BOM
            RunElevated('schtasks.exe /Create /TN "' TASK '" /XML "' xml '" /F')
            try FileDelete(xml)
        } else
            RunElevated('schtasks.exe /Delete /TN "' TASK '" /F')
    }
    return TaskExists() = on                       ; the task itself is the truth
}

; schtasks needs administrator rights to create or delete a task. When Peek is
; not already elevated, this is where the one and only consent prompt happens.
RunElevated(cmd) {
    try {
        if A_IsAdmin
            RunWait(A_ComSpec " /c " cmd, , "Hide")
        else
            RunWait("*RunAs " cmd, , "Hide")
    }
}

; Built as XML rather than passed to "schtasks /Create /SC ONLOGON" because the
; two defaults that matter cannot be set on the command line: ExecutionTimeLimit
; (72 hours by default - it would kill the tray icon after three days) and the
; battery rules (a laptop on battery would never start it).
TaskXml() {
    uid := (dom := EnvGet("USERDOMAIN")) ? dom "\" A_UserName : A_UserName
    cmd := XmlEsc(A_IsCompiled ? A_ScriptFullPath : A_AhkPath)
    arg := A_IsCompiled ? "" : XmlEsc('"' A_ScriptFullPath '"')
    return JoinArr([
        '<?xml version="1.0" encoding="UTF-16"?>',
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
        '  <RegistrationInfo>',
        '    <Description>Starts Peek at logon, already elevated, so Windows does not ask at every boot.</Description>',
        '  </RegistrationInfo>',
        '  <Triggers>',
        '    <LogonTrigger>',
        '      <Enabled>true</Enabled>',
        '      <UserId>' XmlEsc(uid) '</UserId>',
        '      <Delay>PT10S</Delay>',
        '    </LogonTrigger>',
        '  </Triggers>',
        '  <Principals>',
        '    <Principal id="Author">',
        '      <UserId>' XmlEsc(uid) '</UserId>',
        '      <LogonType>InteractiveToken</LogonType>',
        '      <RunLevel>HighestAvailable</RunLevel>',
        '    </Principal>',
        '  </Principals>',
        '  <Settings>',
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
        '    <AllowHardTerminate>true</AllowHardTerminate>',
        '    <StartWhenAvailable>false</StartWhenAvailable>',
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>',
        '    <IdleSettings>',
        '      <StopOnIdleEnd>false</StopOnIdleEnd>',
        '      <RestartOnIdle>false</RestartOnIdle>',
        '    </IdleSettings>',
        '    <AllowStartOnDemand>true</AllowStartOnDemand>',
        '    <Enabled>true</Enabled>',
        '    <Hidden>false</Hidden>',
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>',
        '    <WakeToRun>false</WakeToRun>',
        '    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>',
        '    <Priority>7</Priority>',
        '  </Settings>',
        '  <Actions Context="Author">',
        '    <Exec>',
        '      <Command>' cmd '</Command>',
        (arg = "" ? "" : '      <Arguments>' arg '</Arguments>'),
        '      <WorkingDirectory>' XmlEsc(A_ScriptDir) '</WorkingDirectory>',
        '    </Exec>',
        '  </Actions>',
        '</Task>' ], "`r`n")
}

XmlEsc(s) {
    for pair in [["&", "&amp;"], ["<", "&lt;"], [">", "&gt;"], ['"', "&quot;"]]
        s := StrReplace(s, pair[1], pair[2])      ; "&" first, or it double-escapes
    return s
}

;-------------------------------------------------------------------------------
; 8. Show / update / hide
;-------------------------------------------------------------------------------
TogglePeek() {
    if gVisible && !Cfg.duration {
        HidePeek()
        return
    }
    ShowPeek()
}

ShowPeek() {
    global gVisible, gAnchor, gPrevQpc
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    gAnchor := { x: mx, y: my }

    gPrevQpc := 0                                ; force a fresh CPU/disk baseline
    gVisible := true
    ApplyNetTimer()                              ; switch the ticker to fast
    Sample()                                     ; baseline: no CPU/disk rates yet
    Render("  Measuring...")

    SetTimer(UpdatePeek, Cfg.interval)
    SetTimer(FollowCursor, Cfg.follow ? 30 : 0)
    if Cfg.duration
        SetTimer(HidePeek, -Cfg.duration)
}

UpdatePeek() {
    if !gVisible
        return
    Sample()
    Render(BuildTable())
}

HidePeek() {
    global gVisible
    gVisible := false
    SetTimer(UpdatePeek, 0)
    SetTimer(FollowCursor, 0)
    TIP.Hide()
    ; Drop the process table so nothing heavy is retained while idle. Network
    ; totals live in gSessPid and deliberately survive.
    gProc.Clear()
    ApplyNetTimer()                              ; back to the slow tick
}

FollowCursor() {
    global gAnchor              ; must be declared, or the assignment below would
    if !gVisible                ; silently create a local and the panel never moves
        return
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    gAnchor := { x: mx, y: my }
    Position()
}

Render(tbl) {
    text := IsObject(tbl) ? tbl.text : tbl
    TXT.Value := text
    ext := MeasureText(text)
    TXT.Move(, , ext.w + 4, ext.h + 2)
    if IsObject(tbl) && Cfg.icons
        LayoutIcons(tbl, text, ext)
    else
        HideIcons()
    Position(ext.w + 22, ext.h + 16)
}

; Line height is derived from the measured block rather than assumed, so the
; icons stay aligned at any font size or DPI.
LayoutIcons(tbl, text, ext) {
    HideIcons()
    if !tbl.rows.Length
        return
    lines := StrSplit(text, "`n").Length
    if lines < 1
        return
    lineH := ext.h / lines
    for i, r in tbl.rows {
        if i > gPics.Length
            break
        if !(hIcon := IconFor(r))
            continue
        y := 7 + Round((tbl.header + i - 1) * lineH + (lineH - 16) / 2)
        try {
            gPics[i].Value := "HICON:*" hIcon
            gPics[i].Move(12, y, 16, 16)
            gPics[i].Visible := true
        }
    }
}

HideIcons() {
    for p in gPics
        try p.Visible := false
}

; Resolved only for the handful of rows actually on screen, then cached, so
; turning icons on costs a few OpenProcess calls once per process - not per tick.
IconFor(r) {
    static byProc := Map(), byPath := Map()
    key := r.pid "|" (r.HasOwnProp("created") ? r.created : 0)
    if !byProc.Has(key) {
        path := ""
        if h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", r.pid, "Ptr") {
            buf := Buffer(65536, 0), len := 32768
            if DllCall("QueryFullProcessImageNameW", "Ptr", h, "UInt", 0,
                       "Ptr", buf, "UInt*", &len)
                path := StrGet(buf, len, "UTF-16")
            DllCall("CloseHandle", "Ptr", h)
        }
        byProc[key] := path
    }
    path := byProc[key]
    if path = ""
        return 0
    if byPath.Has(path)
        return byPath[path]
    hLarge := 0, hSmall := 0
    DllCall("shell32\ExtractIconExW", "WStr", path, "Int", 0,
            "Ptr*", &hLarge, "Ptr*", &hSmall, "UInt", 1, "UInt")
    if hLarge
        DllCall("DestroyIcon", "Ptr", hLarge)     ; only the 16 px one is needed
    byPath[path] := hSmall
    return hSmall
}

; Ask GDI how big the text actually is, using the control's own font, so the
; panel fits exactly at any DPI or font size.
MeasureText(text) {
    static DT_CALCRECT := 0x400, DT_NOPREFIX := 0x800
    hFont := SendMessage(0x31, 0, 0, TXT.Hwnd)          ; WM_GETFONT
    hdc   := DllCall("GetDC", "Ptr", 0, "Ptr")
    old   := DllCall("SelectObject", "Ptr", hdc, "Ptr", hFont, "Ptr")
    rc    := Buffer(16, 0)
    DllCall("DrawTextW", "Ptr", hdc, "WStr", text, "Int", -1, "Ptr", rc,
            "UInt", DT_CALCRECT | DT_NOPREFIX)
    w := NumGet(rc, 8, "Int"), h := NumGet(rc, 12, "Int")
    DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdc)
    return { w: w, h: h }
}

Position(w := 0, h := 0) {
    static lastW := 200, lastH := 100
    if w
        lastW := w, lastH := h
    w := lastW, h := lastH
    GetWorkArea(gAnchor.x, gAnchor.y, &l, &t, &r, &b)
    x := gAnchor.x + 18
    y := gAnchor.y + 18
    if x + w > r
        x := gAnchor.x - w - 12
    if y + h > b
        y := gAnchor.y - h - 12
    x := Max(l, Min(x, r - w))
    y := Max(t, Min(y, b - h))
    TIP.Show("NoActivate x" x " y" y " w" w " h" h)
}

; Work area of whichever monitor the cursor is on, so the panel never lands
; under the taskbar or off the edge of a multi-monitor desktop.
GetWorkArea(px, py, &l, &t, &r, &b) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if px >= ml && px < mr && py >= mt && py < mb {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            return
        }
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
}

;-------------------------------------------------------------------------------
; 9. Table building
;-------------------------------------------------------------------------------
; Returns { text, rows, header } - `header` is how many lines sit above the
; first data row, which is what lets the icons line up with their rows.
BuildTable() {
    cols := VisibleCols()
    rows := TopN(Aggregate(), Cfg.sortKey, Cfg.count)
    pad  := Cfg.icons ? "    " : ""            ; blank gutter the icons sit in

    nameW := 18
    for r in rows
        nameW := Max(nameW, StrLen(r.name))
    nameW := Min(nameW, 34)

    head := pad Format("{:-3}", "#") " " Format("{:-" nameW "}", "Process")
    for c in cols
        head .= " " Format("{:" c.w "}", c.title)
    sep := ""
    Loop StrLen(head)
        sep .= "-"

    body := ""
    for i, r in rows {
        line := pad Format("{:-3}", i ".") " " Format("{:-" nameW "}", Clip(r.name, nameW))
        for c in cols
            line .= " " Format("{:" c.w "}", FmtCell(r, c))
        body .= "`n" line
    }
    if !rows.Length
        body := "`n" pad "  (nothing measurable right now)"

    title := pad "Top " Cfg.count " by " SortTitle()
           . (Cfg.group ? "   (grouped by name)" : "")
    foot := ""
    if WantsNetwork() && !gNetOK
        foot := "`n" sep "`n" pad
              . (A_IsAdmin ? "TCP EStats is unavailable here - network columns read n/a"
                           : "Network needs administrator - tray menu > Restart as administrator")
    return { text: title "`n" sep "`n" head "`n" sep body foot, rows: rows, header: 4 }
}

SortTitle() {
    for s in SORTS
        if s.key = Cfg.sortKey
            return s.title
    return Cfg.sortKey
}

Clip(s, n) => StrLen(s) > n ? SubStr(s, 1, n - 1) "~" : s

FmtCell(r, c) {
    v := r.%c.key%
    switch c.fmt {
        case "r": return v < 64 ? "-" : FmtRate(v)
        case "b": return FmtSize(v)
        case "p": return v < 0.05 ? "-" : Format("{:.1f}", v)
        default:  return v ? v : "-"
    }
}

; Collapse per-PID rows into one row per executable name when grouping is on.
Aggregate() {
    if !Cfg.group {
        out := []
        for pid, r in gProc {
            r.count := 1
            out.Push(r)
        }
        return out
    }
    byName := Map()
    for pid, r in gProc {
        if byName.Has(r.name) {
            g := byName[r.name]
            g.cpu += r.cpu, g.ws += r.ws, g.disk += r.disk
            g.netIn += r.netIn, g.netOut += r.netOut, g.netTot += r.netTot
            g.sessIn += r.sessIn, g.sessOut += r.sessOut, g.sessTot += r.sessTot
            g.conn += r.conn, g.count += 1
        } else
            byName[r.name] := { name: r.name, pid: r.pid, cpu: r.cpu, ws: r.ws
                              , disk: r.disk, netIn: r.netIn, netOut: r.netOut
                              , netTot: r.netTot, sessIn: r.sessIn
                              , sessOut: r.sessOut, sessTot: r.sessTot
                              , conn: r.conn, count: 1 }
    }
    out := []
    for name, g in byName
        out.Push(g)
    return out
}

TopN(rows, key, n) {
    if !rows.Length
        return rows
    lines := ""
    for i, r in rows {
        v := r.%key%
        if v <= 0
            continue                             ; idle rows are noise in a top-N
        lines .= Format("{:024.3f}", v + 0.0) "`t" i "`n"
    }
    if lines = ""
        return []
    out := []
    for line in StrSplit(Sort(RTrim(lines, "`n"), "R"), "`n") {
        if line = ""
            continue
        out.Push(rows[Integer(StrSplit(line, "`t")[2])])
        if out.Length >= n
            break
    }
    return out
}

;-------------------------------------------------------------------------------
; 10. Sampling - one NtQuerySystemInformation call plus, optionally, TCP EStats
;-------------------------------------------------------------------------------
Sample() {
    global gPrevQpc, gStamp
    static x64 := (A_PtrSize = 8)
    static oThreads := 4, oCreate := 32, oUser := 40, oKernel := 48, oName := 56
    static oPid  := x64 ? 80  : 68
    static oWs   := x64 ? 144 : 104
    static oRead := x64 ? 232 : 160, oWrite := x64 ? 240 : 168
    static bufSize := 1024 * 1024

    DllCall("QueryPerformanceCounter", "Int64*", &qpc := 0)
    elapsed := gPrevQpc ? (qpc - gPrevQpc) / gFreq : 0
    gPrevQpc := qpc

    buf := 0
    Loop 8 {
        buf := Buffer(bufSize, 0)
        st := DllCall("ntdll\NtQuerySystemInformation", "UInt", 5, "Ptr", buf,
                      "UInt", bufSize, "UInt*", &need := 0, "UInt")
        if st = 0
            break
        if st != 0xC0000004                       ; STATUS_INFO_LENGTH_MISMATCH
            return
        bufSize := Max(need + 65536, bufSize * 2)
        buf := 0
    }
    if !buf
        return

    stamp := ++gStamp
    off   := 0
    Loop {
        p    := buf.Ptr + off
        next := NumGet(p, 0, "UInt")
        pid  := NumGet(p, oPid, "UPtr")
        if pid {
            created := NumGet(p, oCreate, "Int64")
            if gProc.Has(pid) {
                r := gProc[pid]
                if r.created != created {
                    gProc[pid] := r := NewRow(pid, created)
                    gSessPid.Delete(pid)          ; totals belonged to the old process
                }
            } else
                gProc[pid] := r := NewRow(pid, created)
            r.stamp := stamp
            if r.name = "" {
                nl := NumGet(p, oName, "UShort")
                np := NumGet(p, oName + (x64 ? 8 : 4), "Ptr")
                r.name := (nl && np) ? StrGet(np, nl // 2, "UTF-16") : "?"
            }
            r.ws := NumGet(p, oWs, "UPtr")

            cpuT := NumGet(p, oUser, "Int64") + NumGet(p, oKernel, "Int64")
            r.cpu := 0.0
            if elapsed > 0 && r.prevCpu >= 0 && (d := cpuT - r.prevCpu) > 0
                r.cpu := Min(100.0, d / 10000000.0 / elapsed / gCores * 100.0)
            r.prevCpu := cpuT

            ioT := NumGet(p, oRead, "Int64") + NumGet(p, oWrite, "Int64")
            r.disk := 0.0
            if elapsed > 0 && r.prevIo >= 0 && (d := ioT - r.prevIo) > 0
                r.disk := d / elapsed
            r.prevIo := ioT

            ; Rates and totals both come from the network ticker, so they are
            ; unaffected by gProc being cleared between peeks.
            if gNetRates.Has(pid) {
                n := gNetRates[pid]
                r.netIn := n.in, r.netOut := n.out, r.netTot := n.in + n.out
                r.conn := n.conn
            } else
                r.netIn := 0.0, r.netOut := 0.0, r.netTot := 0.0, r.conn := 0
            if gSessPid.Has(pid) {
                s := gSessPid[pid]
                r.sessIn := s.in, r.sessOut := s.out, r.sessTot := s.in + s.out
            }
        }
        if !next
            break
        off += next
    }
    dead := []
    for pid, r in gProc
        if r.stamp != stamp
            dead.Push(pid)
    for pid in dead
        gProc.Delete(pid)
}

NewRow(pid, created) {
    return { pid: pid, created: created, name: "", ws: 0, cpu: 0.0, disk: 0.0
           , netIn: 0.0, netOut: 0.0, netTot: 0.0, conn: 0, count: 1
           , sessIn: 0, sessOut: 0, sessTot: 0
           , prevCpu: -1, prevIo: -1, stamp: 0 }
}

;-------------------------------------------------------------------------------
; 11. Per-process network via TCP EStats
;-------------------------------------------------------------------------------
; Called by the network ticker. Computes live rates AND folds the raw byte
; deltas into the since-launch totals, which is what makes "Sess *" meaningful
; even for traffic that happened while no overlay was on screen.
NetTick() {
    global gNetRates, gNetQpc
    if !gNetOK
        return
    DllCall("QueryPerformanceCounter", "Int64*", &q := 0)
    elapsed := gNetQpc ? (q - gNetQpc) / gFreq : 0
    gNetQpc := q
    gNetRates := SampleNetwork(elapsed)
}

SampleNetwork(elapsed) {
    out  := Map()
    seen := Map()
    ScanTcpTable(2,  out, seen, elapsed)
    ScanTcpTable(23, out, seen, elapsed)
    for key in gPrevConn.Clone()
        if !seen.Has(key)
            gPrevConn.Delete(key)
    for pid, n in out {
        if !(n.bytesIn || n.bytesOut)
            continue
        if !gSessPid.Has(pid)
            gSessPid[pid] := { in: 0, out: 0 }
        gSessPid[pid].in  += n.bytesIn
        gSessPid[pid].out += n.bytesOut
    }
    return out
}

ScanTcpTable(af, out, seen, elapsed) {
    static ESTATS_DATA := 1, ST_ESTABLISHED := 5
    static SANE_TOTAL := 281474976710656
    size := 0
    DllCall("iphlpapi\GetExtendedTcpTable", "Ptr", 0, "UInt*", &size, "Int", 0,
            "UInt", af, "Int", 5, "UInt", 0, "UInt")
    if !size
        return
    buf := Buffer(size + 8192, 0)
    size := buf.Size
    if DllCall("iphlpapi\GetExtendedTcpTable", "Ptr", buf, "UInt*", &size, "Int", 0,
               "UInt", af, "Int", 5, "UInt", 0, "UInt") != 0
        return

    n     := NumGet(buf, 0, "UInt")
    rowSz := (af = 2) ? 24 : 56
    rw    := Buffer(1, 1)
    rod   := Buffer(96, 0)
    row6  := Buffer(52, 0)
    setFn := (af = 2) ? "SetPerTcpConnectionEStats" : "SetPerTcp6ConnectionEStats"
    getFn := (af = 2) ? "GetPerTcpConnectionEStats" : "GetPerTcp6ConnectionEStats"

    Loop n {
        p := buf.Ptr + 4 + (A_Index - 1) * rowSz
        if af = 2 {
            state := NumGet(p, 0, "UInt")
            pid   := NumGet(p, 20, "UInt")
            pRow  := p                            ; first 20 bytes == MIB_TCPROW
            key   := "4|" NumGet(p, 4, "UInt") "|" NumGet(p, 8, "UInt")
                   . "|" NumGet(p, 12, "UInt") "|" NumGet(p, 16, "UInt")
        } else {
            state := NumGet(p, 48, "UInt")
            pid   := NumGet(p, 52, "UInt")
            NumPut("UInt", state, row6, 0)
            DllCall("RtlMoveMemory", "Ptr", row6.Ptr +  4, "Ptr", p,      "UPtr", 16)
            NumPut("UInt", NumGet(p, 16, "UInt"), row6, 20)
            NumPut("UInt", NumGet(p, 20, "UInt"), row6, 24)
            DllCall("RtlMoveMemory", "Ptr", row6.Ptr + 28, "Ptr", p + 24, "UPtr", 16)
            NumPut("UInt", NumGet(p, 40, "UInt"), row6, 44)
            NumPut("UInt", NumGet(p, 44, "UInt"), row6, 48)
            pRow := row6.Ptr
            key  := "6|" Hex16(p) "|" NumGet(p, 20, "UInt")
                  . "|" Hex16(p + 24) "|" NumGet(p, 44, "UInt")
        }

        if !out.Has(pid)
            out[pid] := { in: 0.0, out: 0.0, conn: 0, bytesIn: 0, bytesOut: 0 }
        out[pid].conn += 1
        if state != ST_ESTABLISHED
            continue
        seen[key] := true

        if !gPrevConn.Has(key)
            DllCall("iphlpapi\" setFn, "Ptr", pRow, "Int", ESTATS_DATA,
                    "Ptr", rw, "UInt", 0, "UInt", 1, "UInt", 0, "UInt")

        ; Get can report success without writing anything, so clear the buffer
        ; first or the previous connection's bytes leak into this row.
        DllCall("RtlZeroMemory", "Ptr", rod, "UPtr", 96)
        if DllCall("iphlpapi\" getFn, "Ptr", pRow, "Int", ESTATS_DATA,
                   "Ptr", 0,   "UInt", 0, "UInt", 0,
                   "Ptr", 0,   "UInt", 0, "UInt", 0,
                   "Ptr", rod, "UInt", 0, "UInt", 96, "UInt") != 0
            continue

        bOut := NumGet(rod, 0,  "Int64")
        bIn  := NumGet(rod, 16, "Int64")
        if bOut < 0 || bIn < 0 || bOut > SANE_TOTAL || bIn > SANE_TOTAL
            continue                              ; implausible - discard entirely

        ; A connection whose collection was only just enabled legitimately reads
        ; 0/0. That zero MUST still be stored as the baseline: skipping it (an
        ; earlier version did) means the next sample has nothing to subtract
        ; from, so traffic stays invisible for an extra interval - which on a
        ; short-lived overlay looked like "network never works".
        if gPrevConn.Has(key) && elapsed > 0 {
            prev := gPrevConn[key]
            dOut := bOut - prev[1], dIn := bIn - prev[2]
            cap  := elapsed * 2000000000
            if dOut > 0 && dOut < cap {
                out[pid].out      += dOut / elapsed
                out[pid].bytesOut += dOut
            }
            if dIn > 0 && dIn < cap {
                out[pid].in      += dIn / elapsed
                out[pid].bytesIn += dIn
            }
        }
        gPrevConn[key] := [bOut, bIn]
    }
}

Hex16(ptr) {
    s := ""
    Loop 16
        s .= Format("{:02x}", NumGet(ptr, A_Index - 1, "UChar"))
    return s
}

;-------------------------------------------------------------------------------
; 12. Formatting / settings
;-------------------------------------------------------------------------------
FmtSize(b) {
    if !b
        return "-"
    if b < 1048576
        return Format("{:.0f} KB", b / 1024)
    if b < 1073741824
        return Format("{:.0f} MB", b / 1048576)
    return Format("{:.2f} GB", b / 1073741824)
}

FmtRate(bps) {
    if bps < 1048576
        return Format("{:.0f} KB/s", bps / 1024)
    return Format("{:.2f} MB/s", bps / 1048576)
}

JoinArr(a, sep) {
    s := ""
    for i, v in a
        s .= (i > 1 ? sep : "") v
    return s
}

LoadSettings() {
    c := { hotkey: "^+x", sortKey: "netTot", cols: "netIn,netOut,netTot,sessTot", count: 10
         , duration: 5000, interval: 700, follow: 1, group: 1, dark: 1
         , icons: 1, askElevate: 1, bgTrack: 1, bgInterval: 2000 }
    try {
        c.hotkey     := IniRead(INI, "Peek", "Hotkey", "^+x")
        c.sortKey    := IniRead(INI, "Peek", "SortKey", "netTot")
        c.cols       := IniRead(INI, "Peek", "Cols", "netIn,netOut,netTot,sessTot")
        c.count      := Integer(IniRead(INI, "Peek", "Count", 10))
        c.duration   := Integer(IniRead(INI, "Peek", "Duration", 5000))
        c.interval   := Integer(IniRead(INI, "Peek", "Interval", 700))
        c.follow     := Integer(IniRead(INI, "Peek", "Follow", 1))
        c.group      := Integer(IniRead(INI, "Peek", "Group", 1))
        c.dark       := Integer(IniRead(INI, "Peek", "Dark", 1))
        c.icons      := Integer(IniRead(INI, "Peek", "Icons", 1))
        c.askElevate := Integer(IniRead(INI, "Peek", "AskElevate", 1))
        c.bgTrack    := Integer(IniRead(INI, "Peek", "BgTrack", 1))
        c.bgInterval := Integer(IniRead(INI, "Peek", "BgInterval", 2000))
    }
    ok := false
    for s in SORTS
        ok := ok || (s.key = c.sortKey)
    if !ok
        c.sortKey := "netTot"
    valid := false
    for n in COUNTS
        valid := valid || (n = c.count)
    if !valid
        c.count := 10
    valid := false
    for d in DURS
        valid := valid || (d = c.duration)
    if !valid
        c.duration := 5000
    if c.interval < 300 || c.interval > 5000
        c.interval := 700
    if c.bgInterval < 500 || c.bgInterval > 60000
        c.bgInterval := 2000
    return c
}

SaveSettings() {
    try {
        IniWrite(Cfg.hotkey,     INI, "Peek", "Hotkey")
        IniWrite(Cfg.sortKey,    INI, "Peek", "SortKey")
        IniWrite(Cfg.cols,       INI, "Peek", "Cols")
        IniWrite(Cfg.count,      INI, "Peek", "Count")
        IniWrite(Cfg.duration,   INI, "Peek", "Duration")
        IniWrite(Cfg.interval,   INI, "Peek", "Interval")
        IniWrite(Cfg.follow,     INI, "Peek", "Follow")
        IniWrite(Cfg.group,      INI, "Peek", "Group")
        IniWrite(Cfg.dark,       INI, "Peek", "Dark")
        IniWrite(Cfg.icons,      INI, "Peek", "Icons")
        IniWrite(Cfg.askElevate, INI, "Peek", "AskElevate")
        IniWrite(Cfg.bgTrack,    INI, "Peek", "BgTrack")
        IniWrite(Cfg.bgInterval, INI, "Peek", "BgInterval")
    }
}
