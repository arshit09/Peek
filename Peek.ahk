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
;@Ahk2Exe-SetCompanyName Arshit Vaghasiya
;@Ahk2Exe-SetCopyright Copyright (C) 2026 Arshit Vaghasiya - GPL-3.0-or-later
;@Ahk2Exe-SetOrigFilename Peek.exe
;@Ahk2Exe-SetVersion 1.2.0.0
; Compile without /compress. A UPX- or MPRESS-packed AutoHotkey binary is what
; antivirus heuristics flag hardest, and the filled-in fields above are there so
; the executable at least carries a complete version-info resource. Neither is a
; cure: see "Antivirus false positives" in the README.
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
;  cannot do - Peek now, Settings, Check for updates, Restart as administrator,
;  Reload, Exit.
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
;    Updates ......... whether to ask GitHub once a day for a newer release,
;                      and a "Check now" button that asks straight away
;
;  COST WHEN IDLE: the process table is only read while the overlay is on
;  screen. The one thing that does run in the background is a TCP scan every
;  couple of seconds, and only because the "Sess *" totals would otherwise miss
;  every byte moved between peeks. Clear "Keep counting while the overlay is
;  closed" in the settings window for literally zero idle cost - the totals then
;  only count while the overlay is open.
;
;  SELF-CONTAINED: no #Include, and the only file touched in normal use is
;  Peek.ini next to this one (Peek.exe when compiled). Updating is the exception
;  and only while it is happening: it runs curl or PowerShell to fetch, certutil
;  to hash, and a generated PowerShell script to put the new executable in place
;  once Peek has exited, all out of a folder in %TEMP% that is removed at the
;  next start.
;
;  UPDATES: the newest GitHub release is compared with APPVER, and its Peek.exe
;  is checked against the size and SHA-256 that GitHub publishes before anything
;  is replaced. The previous executable is kept as Peek.exe.old until the new one
;  has started. A "Start with Windows" task is re-registered for the new
;  executable as part of the same step, which is also why the update may ask for
;  administrator rights once. Section 13 has the detail.
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

; Peek's own version and where its releases live. APPVER has to match the
; Ahk2Exe-SetVersion directive at the top of the file - it is what the updater
; (section 13) compares against the tag of the newest GitHub release. These are
; up here with the other constants rather than down with the updater because the
; startup code in section 5 reads them.
global APPVER  := "1.2.0"
global REPO    := "arshit09/Peek"
global UPD_API := "https://api.github.com/repos/" REPO "/releases/latest"
global UPD_UA  := "Peek/" APPVER
global UPD_DIR := A_Temp "\Peek-update"

global gFreq := 0
DllCall("QueryPerformanceFrequency", "Int64*", &gFreq)
global gCores := DllCall("GetActiveProcessorCount", "UShort", 0xFFFF, "UInt") || 1

;-------------------------------------------------------------------------------
; 2. Settings
;-------------------------------------------------------------------------------
; The icon comes first. AutoHotkey hands each Gui the main icon at the moment
; the Gui is created, and the elevation question a few lines down can already
; put a dialog on screen, so a run from source has to claim the icon before
; either of those happens. Section 15 has the detail.
ApplyScriptIcon()

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
    switch Note(msg, "Peek - administrator rights", "YesNoCancel Icon? 0x1000") {
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
        Note "Elevation was cancelled or denied.", "Peek", "Icon! 0x1000"
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
; Getting this far means the executable runs, so the copy an update kept as a
; fallback is no longer needed. The daily check is armed for a minute from now.
CleanupUpdateFiles()
ArmUpdateTimer()
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
        Note "Could not register the hotkey '" hk "'.`n`n" e.Message,
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
    tray.Add("Check for updates...", (*) => CheckForUpdates("manual"))
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
    ; The updates box goes under the network one in the right column rather than
    ; under "Start with Windows" in the left: the right column is the shorter of
    ; the two, so putting it there costs the window the least extra height.
    updY  := adY + adH + 8
    updH  := 86
    btnY  := Max(438, updY + updH) + 12

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

    ;--- updates ---------------------------------------------------------------
    ; "Check now" applies first, so the box next to it is already saved and a
    ; version skipped earlier does not silence a check that was just asked for.
    SG.AddGroupBox("x306 y" updY " w250 h" updH, "Updates")
    SGc.autoUpdate := SG.AddCheckbox("x320 y" (updY + 22) " w222 h22",
                                     "Check GitHub for a new release daily")
    SGc.autoUpdate.Value := Cfg.autoUpdate
    SG.AddText("x320 y" (updY + 50) " w100 h24 +0x200", "Version " APPVER)
    SG.AddButton("x426 y" (updY + 48) " w116 h26", "Check now")
      .OnEvent("Click", (*) => (ApplySettings() && CheckForUpdates("manual")))

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
        Note "Pick at least one column.", "Peek", "Icon! 0x1000"
        return false
    }
    iv := NumOr(SGc.interval.Value, 0)
    if iv < 300 || iv > 5000 {
        Note "The refresh interval has to be between 300 and 5000 ms.",
               "Peek", "Icon! 0x1000"
        return false
    }
    bi := NumOr(SGc.bgInterval.Value, 0)
    if bi < 500 || bi > 60000 {
        Note "The background scan interval has to be between 500 and 60000 ms.",
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
    Cfg.autoUpdate := SGc.autoUpdate.Value

    ; A system-wide change, so like everything else here it waits for OK or
    ; Apply - and the checkbox is re-synced from the task afterwards, because
    ; the UAC prompt it needs can be declined.
    if SGc.startup.Value != gTaskOn {
        if SetStartup(SGc.startup.Value)
            gTaskOn := SGc.startup.Value
        else {
            Note (SGc.startup.Value
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
    ArmUpdateTimer()                             ; autoUpdate
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
        Note "Could not open a browser for:`n`n" URL, "Peek", "Icon! 0x1000"
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
        Note "Please include at least one modifier (Ctrl, Alt, Shift or Win),"
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
         , icons: 1, askElevate: 1, bgTrack: 1, bgInterval: 2000
         , autoUpdate: 1, skipVer: "", lastCheck: "" }
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
        c.autoUpdate := Integer(IniRead(INI, "Peek", "AutoUpdate", 1))
        c.skipVer    := IniRead(INI, "Peek", "SkipVersion", "")
        c.lastCheck  := IniRead(INI, "Peek", "LastCheck", "")
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
        IniWrite(Cfg.autoUpdate, INI, "Peek", "AutoUpdate")
        IniWrite(Cfg.skipVer,    INI, "Peek", "SkipVersion")
        IniWrite(Cfg.lastCheck,  INI, "Peek", "LastCheck")
    }
}

;-------------------------------------------------------------------------------
; 13. Updates
;-------------------------------------------------------------------------------
; Asks GitHub for the newest release, compares its tag with APPVER, downloads
; the Peek.exe asset from it and swaps it in. A running executable cannot
; overwrite itself, so the swap is done by a short PowerShell helper that waits
; for this process to exit, renames the old file aside, moves the new one into
; its place, re-registers the logon task when there is one, and starts Peek
; again.
;
; Transfers run in a separate process (curl, or PowerShell where curl is
; missing) that writes to a file in %TEMP%, and Peek polls that file. A
; synchronous WinHttp call would have been fewer lines but would freeze the tray
; icon and the hotkey for the whole transfer, and the file on disk is a
; byte-accurate progress bar for nothing.
;
; Checked before anything on disk is touched: the release is neither a draft nor
; a prerelease, its tag parses as a version newer than this one, the asset is a
; .exe, its size and SHA-256 match what GitHub publishes for it, and it starts
; with "MZ". Nothing is replaced unless all of that holds.

global UPD_EVERY := 24 * 60 * 60   ; seconds between automatic checks
global gJob      := ""             ; the transfer in flight, "" when idle
global gUpdWhy   := "manual"       ; "auto" keeps a pointless or failed check quiet
global gUpdRel   := ""             ; the release being installed
global UG        := ""             ; "update available" window while it is open
global PG        := ""             ; download progress window while it is open
global PGbar     := "", PGtxt := ""

RepoUrl() => "https://github.com/" REPO

;--- version numbers -----------------------------------------------------------
; "v1.2.3" -> [1,2,3]. Parsing stops at the first part that is not a number, so
; a tag like "v1.2.0-beta" compares as 1.2.0 and the prerelease flag in the
; release itself is what keeps it out of the way.
VerParts(v) {
    out := []
    for p in StrSplit(RegExReplace(v, "^\s*[vV]"), ".")
        if RegExMatch(p, "^(\d+)", &m)
            out.Push(Integer(m[1]))
        else
            break
    return out
}

; -1 when a is older, 0 when they are the same, 1 when a is newer. A missing
; trailing part counts as zero, so 1.2 and 1.2.0 are the same version.
VerCompare(a, b) {
    pa := VerParts(a), pb := VerParts(b)
    Loop Max(pa.Length, pb.Length) {
        x := pa.Has(A_Index) ? pa[A_Index] : 0
        y := pb.Has(A_Index) ? pb[A_Index] : 0
        if x != y
            return x < y ? -1 : 1
    }
    return 0
}

;--- transfers -----------------------------------------------------------------
; kind is "check" or "download" and decides who is told when the child process
; is gone. Returns false when a transfer is already running or no helper could
; be started; the caller says so, because what to say depends on the kind.
StartFetch(kind, url, out, hdrs, size := 0) {
    global gJob
    if gJob
        return false
    try DirCreate(UPD_DIR)
    try FileDelete(out)
    if !(pid := SpawnFetch(url, out, hdrs))
        return false
    gJob := { kind: kind, pid: pid, out: out, size: size, started: A_TickCount }
    SetTimer(FetchTick, 150)
    return true
}

; curl.exe has shipped with Windows since 10 1803 and needs no temporary script,
; so it is tried first; PowerShell is the fallback for anything older. Either
; way the transfer is a hidden child process.
SpawnFetch(url, out, hdrs) {
    pid := 0
    curl := A_WinDir "\System32\curl.exe"
    if FileExist(curl) {
        cmd := '"' curl '" -sS -L --fail --connect-timeout 15 --max-time 600'
             . ' -A "' UPD_UA '"'
        for h in hdrs
            cmd .= ' -H "' h '"'
        cmd .= ' -o "' out '" "' url '"'
        try {
            Run(cmd, UPD_DIR, "Hide", &pid)
            return pid
        }
    }
    ps := UPD_DIR "\fetch.ps1"
    try FileDelete(ps)
    body := "$ErrorActionPreference = 'Stop'`r`n"
          . "try { [Net.ServicePointManager]::SecurityProtocol = 3072 } catch { }`r`n"
          . "$c = New-Object Net.WebClient`r`n"
          . "$c.Headers.Add('User-Agent', '" PsQ(UPD_UA) "')`r`n"
    for h in hdrs {
        p := StrSplit(h, ":", " ", 2)
        if p.Length = 2
            body .= "$c.Headers.Add('" PsQ(p[1]) "', '" PsQ(p[2]) "')`r`n"
    }
    body .= "$c.DownloadFile('" PsQ(url) "', '" PsQ(out) "')`r`n"
    try {
        FileAppend(body, ps, "UTF-8")
        Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden'
          . ' -File "' ps '"', UPD_DIR, "Hide", &pid)
        return pid
    }
    return 0
}

; A PowerShell single-quoted string escapes a quote by doubling it and treats
; everything else literally, which is why every value handed to a generated
; script goes inside one.
PsQ(s) => StrReplace(s, "'", "''")

; The child process disappearing is the only signal that a transfer has
; finished, so the file is read after it is gone rather than guessed at while it
; is still being written.
FetchTick() {
    global gJob
    if !gJob {
        SetTimer(FetchTick, 0)
        return
    }
    got := 0
    try got := FileGetSize(gJob.out)
    UpdProgress(got, gJob.size)
    if ProcessExist(gJob.pid) {
        if A_TickCount - gJob.started < 900000      ; 15 minutes is long enough
            return
        kind := gJob.kind
        CancelFetch()
        if kind = "download"
            Note "The download did not finish within 15 minutes and was"
                 . " stopped.`n`nNothing has been changed.",
                   "Peek - update", "Icon! 0x1000"
        else
            UpdFail("GitHub did not answer in time.")
        return
    }
    SetTimer(FetchTick, 0)
    job := gJob, gJob := ""
    if job.kind = "check"
        CheckArrived(job)
    else
        DownloadArrived(job)
}

CancelFetch() {
    global gJob
    if gJob {
        try ProcessClose(gJob.pid)
        try FileDelete(gJob.out)
        gJob := ""
    }
    SetTimer(FetchTick, 0)
    CloseUpdProgress()
}

;--- checking ------------------------------------------------------------------
CheckForUpdates(why := "manual") {
    global gUpdWhy
    if gJob {
        if why = "manual"
            Note "A check is already running.", "Peek - update", "Iconi 0x1000"
        return
    }
    gUpdWhy := why
    if !StartFetch("check", UPD_API, UPD_DIR "\latest.json",
                   ["Accept: application/vnd.github+json",
                    "X-GitHub-Api-Version: 2022-11-28"])
        UpdFail("Could not start a helper to reach GitHub.`n`nNeither curl.exe"
              . " nor PowerShell could be run.")
}

CheckArrived(job) {
    Cfg.lastCheck := A_Now
    SaveSettings()
    txt := ""
    try txt := FileRead(job.out, "UTF-8")
    try FileDelete(job.out)
    if txt = "" {
        UpdFail("GitHub could not be reached, so there is nothing to compare"
              . " against.`n`nThe releases are at " RepoUrl() "/releases/latest")
        return
    }
    ; Whatever comes back is someone else's document, so nothing it can contain
    ; is allowed to reach the user as a crash: a throw in here reads the same as
    ; a release that could not be understood.
    rel := ""
    try rel := ParseRelease(txt)
    if !rel {
        UpdFail("GitHub answered, but no usable release with a Peek.exe was"
              . " found in it.`n`nThe releases are at "
              . RepoUrl() "/releases/latest")
        return
    }
    if VerCompare(rel.ver, APPVER) <= 0 {
        if gUpdWhy = "manual"
            Note "Peek " APPVER " is the newest release.", "Peek - up to date",
                   "Iconi 0x1000"
        return
    }
    ; A skipped version stays quiet on its own, but a check that was asked for
    ; still shows it - otherwise "Check now" would look broken.
    if gUpdWhy = "auto" && rel.ver = Cfg.skipVer
        return
    ShowUpdateDialog(rel)
}

UpdFail(msg) {
    if gUpdWhy = "manual"
        Note msg, "Peek - update", "Icon! 0x1000"
}

; A whole JSON parser is not worth carrying for six fields of one document whose
; shape is pinned by the API version Peek asks for. Returns "" when the answer
; is not a release that can be installed.
ParseRelease(j) {
    if RegExMatch(j, '"draft"\s*:\s*true') || RegExMatch(j, '"prerelease"\s*:\s*true')
        return ""
    if !RegExMatch(j, '"tag_name"\s*:\s*"([^"]+)"', &m)
        return ""
    tag := JsonStr(m[1])
    if !VerParts(tag).Length
        return ""
    page := RegExMatch(j, '"html_url"\s*:\s*"(https://github\.com/[^"]+/releases/tag/[^"]+)"', &m)
          ? JsonStr(m[1]) : RepoUrl() "/releases/latest"
    ; Possessive quantifiers, and they are not decoration. Written the ordinary
    ; greedy way - (?:[^"\\]|\\.)* - this leaves PCRE a backtracking position
    ; per character of the release notes, and a few thousand characters of them
    ; is enough to exhaust its JIT stack and throw. "++" and "*+" consume each
    ; run of plain characters without leaving anywhere to go back to, which is
    ; both correct here and what keeps the stack flat however long the notes get.
    body := RegExMatch(j, '"body"\s*:\s*"((?:[^"\\]++|\\.)*+)"', &m) ? JsonStr(m[1]) : ""

    ; Everything below reads from the assets array onwards: the release carries a
    ; "name" of its own, and one named like a file would otherwise be mistaken
    ; for an asset. Inside an asset GitHub writes name before size, digest and
    ; browser_download_url, and the nested uploader object has none of those
    ; keys, so reading forward from a name cannot stray into another asset.
    if RegExMatch(j, '"assets"\s*:\s*\[', &m)
        j := SubStr(j, m.Pos)
    asset := "", pos := 1
    while RegExMatch(j, '"name"\s*:\s*"([^"]*\.(?i:exe))"', &m, pos) {
        pos  := m.Pos + m.Len
        rest := SubStr(j, pos)
        if !RegExMatch(rest, '"browser_download_url"\s*:\s*"([^"]+)"', &u)
            continue
        a := { name: JsonStr(m[1]), url: JsonStr(u[1]), size: 0, sha: "" }
        if RegExMatch(rest, '"size"\s*:\s*(\d+)', &s)
            a.size := Integer(s[1])
        if RegExMatch(rest, '"digest"\s*:\s*"sha256:([0-9a-fA-F]{64})"', &d)
            a.sha := StrLower(d[1])
        if !asset || a.name = "Peek.exe"           ; the real one wins over extras
            asset := a
    }
    if !asset
        return ""
    return { ver: RegExReplace(tag, "^\s*[vV]"), tag: tag, page: page
           , body: body, asset: asset }
}

; Undoes the string escapes GitHub actually emits. A lone surrogate from \u is
; dropped rather than paired up: release notes are shown, not round-tripped.
JsonStr(s) {
    if !InStr(s, "\")
        return s
    out := "", i := 1, n := StrLen(s)
    while i <= n {
        if (c := SubStr(s, i, 1)) != "\" {
            out .= c, i += 1
            continue
        }
        e := SubStr(s, i + 1, 1), i += 2
        switch e {
            case "n": out .= "`n"
            case "r": out .= "`r"
            case "t": out .= "`t"
            case "b", "f":                         ; nothing sensible to show
            case "u":
                code := SubStr(s, i, 4), i += 4
                if RegExMatch(code, "^[0-9a-fA-F]{4}$") && (v := Integer("0x" code))
                    out .= (v >= 0xD800 && v <= 0xDFFF) ? "" : Chr(v)
            default: out .= e                      ; \" \\ \/ and the unexpected
        }
    }
    return out
}

;--- the "update available" window ---------------------------------------------
ShowUpdateDialog(rel) {
    global UG
    CloseUpdateDialog()
    UG := Gui("+AlwaysOnTop +OwnDialogs -MinimizeBox -MaximizeBox",
              "Peek - update available")
    UG.SetFont("s9", "Segoe UI")
    UG.OnEvent("Close",  (*) => CloseUpdateDialog())
    UG.OnEvent("Escape", (*) => CloseUpdateDialog())

    UG.SetFont("s12 bold")
    UG.AddText("x14 y12 w452 h26", "Peek " rel.ver " is available")
    UG.SetFont("s9 norm")
    UG.AddText("x14 y42 w452 h20", "You are running " APPVER ".    Download: "
             . rel.asset.name ", " FmtSize(rel.asset.size) ".")
    UG.AddText("x14 y70 w452 h18", "Release notes")
    UG.AddEdit("x14 y90 w452 h146 ReadOnly Multi +VScroll"
             , rel.body != "" ? rel.body : "Nothing was published with this release.")

    UG.AddButton("x14 y248 w150 h28", "Open the release page")
      .OnEvent("Click", (*) => OpenUrl(rel.page))
    UG.AddButton("x172 y248 w110 h28", "Skip " rel.ver)
      .OnEvent("Click", (*) => SkipVersion(rel.ver))
    UG.AddButton("x290 y248 w84 h28", "Later")
      .OnEvent("Click", (*) => CloseUpdateDialog())
    go := UG.AddButton("x382 y248 w84 h28 +Default", "Install")
    go.OnEvent("Click", (*) => (CloseUpdateDialog(), StartInstall(rel)))
    UG.Show("w480 h292")
    go.Focus()          ; or the notes take it and open with everything selected
}

CloseUpdateDialog() {
    global UG
    if UG {
        try UG.Destroy()
        UG := ""
    }
    return true
}

; Remembered in the ini, so a version said no to stays quiet across restarts
; until a newer one appears or the check is run by hand.
SkipVersion(ver) {
    Cfg.skipVer := ver
    SaveSettings()
    CloseUpdateDialog()
}

; Run() hands the URL to whatever is registered for https, so it lands in the
; default browser rather than a hardcoded one.
OpenUrl(url) {
    try
        Run url
    catch
        Note "Could not open a browser for:`n`n" url, "Peek", "Icon! 0x1000"
}

;--- downloading ---------------------------------------------------------------
StartInstall(rel) {
    global gUpdRel
    ; Running from source there is no Peek.exe here to replace, and silently
    ; writing one next to the script would be a surprise.
    if !A_IsCompiled {
        Note "Peek is running from Peek.ahk, so there is no Peek.exe here for"
             . " the update to replace.`n`nThe new Peek.exe is on the release"
             . " page, which is about to open; from source, pull the new"
             . " Peek.ahk and rebuild instead.", "Peek - update", "Iconi 0x1000"
        OpenUrl(rel.page)
        return
    }
    if gJob {
        Note "A transfer is already running.", "Peek - update", "Iconi 0x1000"
        return
    }
    gUpdRel := rel
    ShowUpdProgress(rel)
    if !StartFetch("download", rel.asset.url, UPD_DIR "\" rel.asset.name, []
                 , rel.asset.size) {
        CloseUpdProgress()
        Note "Could not start a helper to download the update.`n`nNeither"
             . " curl.exe nor PowerShell could be run.", "Peek - update",
               "Icon! 0x1000"
    }
}

ShowUpdProgress(rel) {
    global PG, PGbar, PGtxt
    CloseUpdProgress()
    PG := Gui("+AlwaysOnTop +OwnDialogs +ToolWindow -MinimizeBox -MaximizeBox",
              "Peek - downloading")
    PG.SetFont("s9", "Segoe UI")
    PG.OnEvent("Close",  (*) => CancelFetch())
    PG.OnEvent("Escape", (*) => CancelFetch())
    PG.AddText("x14 y12 w372 h20", "Downloading Peek " rel.ver " from GitHub")
    PGbar := PG.AddProgress("x14 y38 w372 h18 Range0-1000", 0)
    PGtxt := PG.AddText("x14 y62 w372 h20", "Starting...")
    PG.AddButton("x296 y88 w90 h28", "Cancel").OnEvent("Click", (*) => CancelFetch())
    PG.Show("w400 h128")
}

UpdProgress(got, total) {
    if !PG
        return
    try {
        PGbar.Value := total ? Min(1000, Round(got * 1000 / total)) : 0
        PGtxt.Value := (got ? FmtSize(got) : "0 KB")
                     . (total ? " of " FmtSize(total) : " so far")
    }
}

CloseUpdProgress() {
    global PG
    if PG {
        try PG.Destroy()
        PG := ""
    }
}

DownloadArrived(job) {
    rel := gUpdRel
    CloseUpdProgress()
    if !rel {
        try FileDelete(job.out)
        return
    }
    if (why := VerifyDownload(job.out, rel.asset)) != "" {
        try FileDelete(job.out)
        Note "The download did not arrive intact, so nothing was replaced.`n`n"
             . why, "Peek - update", "Icon! 0x1000"
        return
    }
    ApplyUpdate(rel, job.out)
}

; Everything that can be checked without running the file is checked, because
; what happens next overwrites Peek.exe. The digest is the one that matters -
; size and the MZ signature only catch a truncated or redirected download.
VerifyDownload(path, asset) {
    if !FileExist(path)
        return "It is no longer on disk. Antivirus software taking it away"
             . " moments after the download is the usual reason, and the README"
             . " section on false positives covers what to do about it."
    sz := 0
    try sz := FileGetSize(path)
    if !sz
        return "Nothing was written to disk."
    if asset.size && sz != asset.size
        return "It is " sz " bytes, and GitHub lists " asset.size "."
    try {
        f := FileOpen(path, "r")
        a := f.ReadUChar(), b := f.ReadUChar()
        f.Close()
        if a != 0x4D || b != 0x5A                  ; "MZ"
            return "It is not a Windows executable."
    } catch
        return "It could not be read back."
    if asset.sha != "" {
        if (h := Sha256(path)) = ""
            return "Its SHA-256 could not be worked out to compare with the one"
                 . " GitHub publishes."
        if h != asset.sha
            return "Its SHA-256 is " SubStr(h, 1, 16) "..., and GitHub publishes"
                 . " " SubStr(asset.sha, 1, 16) "..."
    }
    return ""
}

; certutil is the one hasher present on every supported Windows. Its output is a
; header line, the digits, and a success line; older builds print the digits as
; space-separated byte pairs, which is why the spaces come back out.
Sha256(path) {
    tmp := UPD_DIR "\hash.txt"
    out := ""
    try FileDelete(tmp)
    try {
        RunWait(A_ComSpec ' /c certutil.exe -hashfile "' path '" SHA256 > "' tmp '"'
              , UPD_DIR, "Hide")
        out := FileRead(tmp)
    }
    try FileDelete(tmp)
    if RegExMatch(out, "m)^\s*((?:[0-9a-fA-F]{2}[ \t]*){32})\s*$", &m)
        return StrLower(RegExReplace(m[1], "\s"))
    return ""
}

;--- installing ----------------------------------------------------------------
; The swap itself, which this process cannot do to itself: Windows holds a lock
; on a running executable. A PowerShell helper is written out, Peek asks once,
; then exits and leaves the helper to it.
;
; Elevation: the helper needs administrator rights when the logon task has to be
; rewritten, because schtasks will not touch a task without them, or when Peek's
; own folder is not writable, which is the Program Files case. Deciding it here
; means one consent prompt for the whole update instead of one per step.
ApplyUpdate(rel, newFile) {
    target := A_ScriptFullPath
    xml    := ""
    ; The task is rewritten rather than left alone: it is the thing that will
    ; launch the new executable at the next logon, and regenerating it from the
    ; running Peek is what repoints it if the exe was renamed or moved since.
    if TaskExists() {
        xml := UPD_DIR "\" TASK "-task.xml"
        try FileDelete(xml)
        try FileAppend(TaskXml(), xml, "UTF-16")   ; schtasks wants UTF-16 + BOM
        if !FileExist(xml)
            xml := ""
    }
    needAdmin := !A_IsAdmin && (xml != "" || !DirWritable(A_ScriptDir))

    msg := "Peek " rel.ver " has been downloaded and checked.`n`n"
         . "Peek will close, the new Peek.exe will be put in place of the"
         . " current one, and Peek will start again. The previous executable is"
         . " kept as Peek.exe.old until the new one has started."
         . (xml != "" ? "`n`nThe 'Start with Windows' task will be re-registered"
                      . " for the new executable." : "")
         . (needAdmin ? "`n`nWindows will ask for administrator rights once." : "")
         . "`n`nInstall it now?"
    if Note(msg, "Peek - install update", "OkCancel Iconi 0x1000") != "OK" {
        try FileDelete(newFile)
        if xml != ""
            try FileDelete(xml)
        return
    }

    if !(ps := WriteUpdater(target, newFile, xml)) {
        Note "The update helper could not be written to " UPD_DIR
             . ".`n`nNothing has been changed.", "Peek - update", "Icon! 0x1000"
        return
    }
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden'
         . ' -File "' ps '"'
    try {
        SaveSettings()
        Run((needAdmin ? "*RunAs " : "") cmd, UPD_DIR, "Hide")
    } catch {
        Note "The update helper could not be started"
             . (needAdmin ? ", or the elevation prompt was declined" : "")
             . ".`n`nNothing has been changed.", "Peek - update", "Icon! 0x1000"
        return
    }
    ExitApp
}

; Trying is the only reliable test: an ACL can allow or deny in ways the folder
; attributes do not show.
DirWritable(dir) {
    probe := dir "\peek-write-test.tmp"
    try {
        FileAppend("x", probe)
        FileDelete(probe)
        return true
    }
    return false
}

; PowerShell rather than a batch file: waiting on a pid, retrying a locked move,
; putting the old file back when the new one will not go in, and calling
; schtasks - all legible in one script - is not something cmd does well.
;
; The paths and the pid are written as assignments above a fixed body, so no
; value is ever substituted into the middle of the script. The body carries no
; double quotes on purpose: single-quoted PowerShell strings are literal apart
; from a doubled quote, which is exactly the escaping PsQ does.
WriteUpdater(target, newFile, xml) {
    ps   := UPD_DIR "\install.ps1"
    head := "$log    = Join-Path $env:TEMP 'Peek-update.log'`n"
          . "$target = '" PsQ(target)  "'`n"
          . "$new    = '" PsQ(newFile) "'`n"
          . "$xml    = '" PsQ(xml)     "'`n"
          . "$task   = '" PsQ(TASK)    "'`n"
          . "$ppid   = " DllCall("GetCurrentProcessId", "UInt") "`n"
    body := "
(
# Peek update helper. Written by Peek, runs once, removes itself.
$ErrorActionPreference = 'Continue'
$backup = $target + '.old'
$dir    = Split-Path -Parent $target

function Log($m) {
((Get-Date).ToString('s') + '  ' + $m) | Out-File -FilePath $log -Append -Encoding utf8
}

function Restart() {
Start-Process -FilePath $target -WorkingDirectory $dir
Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
}

try { Wait-Process -Id $ppid -Timeout 90 -ErrorAction SilentlyContinue } catch { }

$moved = $false
for ($i = 0; $i -lt 40; $i++) {
if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
try { Move-Item -LiteralPath $target -Destination $backup -Force -ErrorAction Stop; $moved = $true; break }
catch { Start-Sleep -Milliseconds 500 }
}

if (-not $moved) {
Log ('Peek was still holding its executable after 20 seconds, so nothing was replaced.')
Restart
exit 1
}

try { Move-Item -LiteralPath $new -Destination $target -Force -ErrorAction Stop }
catch {
Log ('The new file could not be moved into place, putting the old one back: ' + $_.Exception.Message)
Move-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
Restart
exit 1
}

if ($xml.Length -gt 0 -and (Test-Path -LiteralPath $xml)) {
& schtasks.exe /Create /TN $task /XML $xml /F 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Log ('schtasks could not re-register the ' + $task + ' task, exit code ' + $LASTEXITCODE + '.') }
Remove-Item -LiteralPath $xml -Force -ErrorAction SilentlyContinue
}

Restart
)"
    try FileDelete(ps)
    try {
        FileAppend(head . body, ps, "UTF-8")
        return FileExist(ps) ? ps : ""
    }
    return ""
}

;--- housekeeping and the daily check ------------------------------------------
; Reaching here means this executable started, so the copy the helper kept as a
; fallback has done its job. The scratch folder goes with it.
CleanupUpdateFiles() {
    if A_IsCompiled
        try FileDelete(A_ScriptFullPath ".old")
    try DirDelete(UPD_DIR, true)
}

; Never in the first minute after a logon: the task starts Peek while Windows is
; still busy, and a transfer then only competes with everything else that wants
; the disk and the network.
ArmUpdateTimer() {
    SetTimer(UpdateTick, 0)
    if Cfg.autoUpdate
        SetTimer(UpdateTick, -60000)
}

UpdateTick() {
    if !Cfg.autoUpdate
        return
    ; The length test is not belt and braces: DateDiff reads a blank timestamp as
    ; A_Now and answers nothing at all, so a fresh ini - which has no stamp yet -
    ; would look like a check made this second and never come due.
    due := true
    if RegExMatch(Cfg.lastCheck, "^\d{14}$")
        try due := DateDiff(A_Now, Cfg.lastCheck, "Seconds") >= UPD_EVERY
    if due
        CheckForUpdates("auto")
    SetTimer(UpdateTick, -3600000)                 ; and look again in an hour
}

;-------------------------------------------------------------------------------
; 14. Message boxes
;-------------------------------------------------------------------------------
; Every Gui Peek opens carries the tray icon in its title bar, because
; AutoHotkey hands one to each Gui it creates. A MsgBox is not a Gui - it is a
; plain Win32 dialog - and Windows leaves an unowned dialog with no icon at all,
; so Peek's message boxes came up blank beside windows that were not.
;
; There is no MsgBox option for this, and giving the dialog an owner does not do
; it either: an owned dialog still answers WM_GETICON with nothing. The icon has
; to be set on the dialog itself, which can only be done once it exists - hence
; the timer. A MsgBox blocks the thread that opened it, but timers keep running
; while one is on screen, so a short one gets in, finds the dialog by its class
; and sets the icon. Failing to find it costs nothing: the title bar is then
; just as blank as it used to be.
;
; The icons are read from a Gui created once and never shown. AutoHotkey hands
; every Gui the same pair of handles it uses for the tray, so this follows the
; icon the executable was compiled with - and any later TraySetIcon - without
; naming an icon resource or reading the file back off disk. Both sizes are
; copied: the big one is the title bar and Alt-Tab, the small one is the taskbar.

; Everything Peek has to say goes through here, so no dialog can be left looking
; like it belongs to something else. The arguments are MsgBox's own, passed
; straight through.
Note(text, title := "Peek", opts := "") {
    SetTimer(DressDialog.Bind(title, 1), -30)
    return MsgBox(text, title, opts)
}

DressDialog(title, tries) {
    static src := ""
    ; Hidden windows are deliberately left undetected here: the dialog is either
    ; on screen or it has not been created yet, and waiting is the right answer.
    if !(hwnd := WinExist(title " ahk_class #32770")) {
        if tries < 40                       ; keep looking for two seconds
            SetTimer(DressDialog.Bind(title, tries + 1), -50)
        return
    }
    if !src
        src := Gui()                        ; never shown - it is here for its icons
    DetectHiddenWindows True                ; thread-local, and src is hidden
    try {
        big := SendMessage(0x7F, 1, 0, , "ahk_id " src.Hwnd)   ; WM_GETICON, ICON_BIG
        sml := SendMessage(0x7F, 0, 0, , "ahk_id " src.Hwnd)   ;             ICON_SMALL
        if big
            SendMessage(0x80, 1, big, , "ahk_id " hwnd)        ; WM_SETICON
        if sml
            SendMessage(0x80, 0, sml, , "ahk_id " hwnd)
    }
}

;-------------------------------------------------------------------------------
; 15. The icon when Peek runs from source
;-------------------------------------------------------------------------------
; Compiled, Peek.exe carries its icon in its own resources, and Windows uses it
; for the tray, the windows and the dialogs alike. Run as Peek.ahk it would show
; AutoHotkey's icon instead - and since the README now suggests running the
; script in preference to the executable, that is the ordinary case rather than
; the odd one.
;
; So the icon travels inside this file. A Peek.ico sitting next to the script
; wins when there is one, which is the repository checkout, where that file is
; the thing being edited; otherwise the embedded copy is written to %TEMP% once
; and loaded from there, because TraySetIcon wants a path rather than bytes.
; Writing it per version means a new icon is picked up instead of a stale copy
; being reused forever.
;
; Only the sizes something actually asks for at run time are embedded - 16
; through 64 - which is 7 KB rather than the 19 KB the full Peek.ico would cost
; for 128 and 256 pixel images nothing here will ever request.

ApplyScriptIcon() {
    if A_IsCompiled                              ; already in its own resources
        return
    ico := A_ScriptDir "\Peek.ico"               ; the repository checkout
    if !FileExist(ico) {
        ico := A_Temp "\Peek-icon-" APPVER ".ico"
        if !FileExist(ico) {
            try {
                f := FileOpen(ico, "w")
                f.RawWrite(B64Decode(IconData()))
                f.Close()
            }
        }
    }
    if FileExist(ico)
        try TraySetIcon(ico)
}

; CryptStringToBinary rather than arithmetic of my own: it ships with every
; Windows and it is the same decoder certificates go through.
B64Decode(s) {
    size := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "Str", s, "UInt", 0, "UInt", 1
              , "Ptr", 0, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw Error("The embedded icon could not be measured.")
    bin := Buffer(size)
    if !DllCall("crypt32\CryptStringToBinaryW", "Str", s, "UInt", 0, "UInt", 1
              , "Ptr", bin, "UInt*", &size, "Ptr", 0, "Ptr", 0)
        throw Error("The embedded icon could not be decoded.")
    return bin
}

; Peek.ico with the 128 and 256 pixel images dropped, base64. To regenerate it
; after changing the icon, run tools\Embed-Icon.ps1 and paste what it prints.
IconData() {
    static B64 := "
(Join
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
)"
    return B64
}
