# Peek

Press a hotkey, get an instant overlay of your top processes. It appears next to
the cursor, refreshes while it is up, and disappears on its own.

![Peek overlay](screenshot.png)

## Install

There are two ways in, and the second one exists because Windows Defender tends
to object to the compiled executable. They are the same program either way.

### Run the script (no executable involved)

1. Install [AutoHotkey v2](https://www.autohotkey.com/) - the installer from
   autohotkey.com, nothing else.
2. Download [`Peek.ahk`](Peek.ahk) from this repository.
3. Double-click it.

That is all of it. `Peek.ahk` is a text file, and the executable that runs it is
AutoHotkey's own interpreter - the same copy millions of machines already have,
with the Defender reputation that comes of that. Every feature behaves the same:
the hotkey, the settings window, "Restart as administrator", "Start with
Windows". The one difference is that an update opens the release page rather
than replacing anything, because there is no executable here to replace.

### Download the executable

Download `Peek.exe` from the [latest release](../../releases/latest) and run it.
No installer, no dependencies - but expect Defender to take it away, and read
the next section before going this way.

Either way, settings are written to `Peek.ini` next to whichever file you run,
and nothing else on the machine is touched.

## Antivirus false positives

Windows Defender quarantines `Peek.exe` on a good many machines, usually as
something generic like `Trojan:Win32/Wacatac.B!ml` or
`Program:Win32/Wacapew.C!ml`. The `!ml` suffix is the tell: that is a
machine-learning guess, not a signature match against known malware.

The guess is not a mystery either. A compiled AutoHotkey script is the
AutoHotkey interpreter and the script itself bundled into one unsigned
executable, which is a shape plenty of real malware also has. Then Peek goes
and does, in order: a global keyboard hotkey, a walk of every process on the
machine, per-process network counters that need elevation, a scheduled task for
autostart, and an update that downloads an executable and overwrites itself.
Every one of those is a heuristic trigger on its own. What settles it in the end
is reputation - a code-signing certificate and enough downloads of the same
binary for Defender to have an opinion about it. Peek has neither; AutoHotkey's
interpreter has the second, which is why running the script sidesteps all of
this.

Pick whichever of these suits you.

**Run `Peek.ahk` instead.** The route above. No compiled executable, so there is
nothing to flag. This is the recommendation if you simply want it working.

**Check the file, then exclude it.** Every release publishes a SHA-256 for
`Peek.exe` - the same digest Peek's own updater verifies before it replaces
anything. Confirm your copy matches it first:

```powershell
Get-FileHash .\Peek.exe -Algorithm SHA256
```

If it matches, restore the file and exclude it: **Windows Security** -> **Virus
& threat protection** -> **Protection history** -> the Peek entry ->
**Actions** -> **Restore**, then **Virus & threat protection settings** ->
**Manage settings** -> **Exclusions** -> **Add an exclusion**. Exclude the
folder you keep Peek in rather than the one file, or the next update will be
quarantined as a new file. If you use the updater, the download lands in
`%TEMP%\Peek-update` first.

An exclusion is a real hole in your protection, so keep it to that one folder,
and do not take this step on the word of a README - the hash check above is
there so you do not have to.

**Report it to Microsoft.** A [false-positive
submission](https://www.microsoft.com/en-us/wdsi/filesubmission) is what gets a
detection withdrawn for everybody rather than just for you. Pick "Microsoft
Defender Antivirus", then "Incorrectly detected as malware", and attach the
file. Turnaround is usually a day or two.

**Build it yourself.** See [Build from source](#build-from-source). An
executable compiled on your own machine can still be flagged, but you know
exactly what went into it.

## Use

- **Ctrl + Shift + X** toggles the overlay. The combination is changeable.
- Right-click the tray icon for: Peek now, Settings, Check for updates, Restart
  as administrator, Reload, Exit. Everything else lives in the settings window.

## Settings

| | |
|---|---|
| Hotkey | Captured by pressing the combination you want |
| Sort by | Network rate, network session, memory, disk I/O or CPU |
| Columns | Any combination, shown side by side |
| Show | 5, 10, 15 or 20 rows |
| Stays up | 3, 5 or 10 seconds, or until the hotkey is pressed again |
| Refresh | How fast the overlay re-samples while on screen |
| Follow cursor | Drag with the mouse, or stay where it opened |
| Group by name | 40 `chrome.exe` processes collapse into one row |
| Show icons | Each row gets the executable's own icon |
| Dark theme | Dark or light overlay |
| Session totals | Whether byte totals keep counting while the overlay is closed |
| Start with Windows | A logon task that starts Peek already elevated |
| Updates | Whether to ask GitHub for a newer release once a day, plus "Check now" |

`Net *` columns are live rates. `Sess *` columns are total bytes each process
has moved since Peek was started.

## Updates

Peek can update itself. "Check for updates" in the tray menu, or "Check now" in
the settings window, asks GitHub for the newest release; with the box in the
settings window ticked it also asks once a day on its own and only speaks up
when there is something newer. Drafts and prereleases are ignored, and a version
you press **Skip** on stays quiet until a newer one appears.

Pressing **Install** downloads `Peek.exe` from the release, checks it against the
size and SHA-256 that GitHub publishes for it, and only then replaces the running
executable. The swap itself is done after Peek exits, because Windows holds a
lock on a running program, and Peek starts itself again afterwards. The previous
executable is kept as `Peek.exe.old` until the new one has started.

If "Start with Windows" is on, the logon task is re-registered for the new
executable in the same step. That needs administrator rights, so an update will
ask for consent once when the task exists, or when Peek sits somewhere its own
folder is not writable.

Running from `Peek.ahk` rather than the compiled exe, there is nothing to
replace: the release page is opened instead.

## Administrator rights

Per-process network figures need elevation, because the TCP EStats API refuses
to enable byte collection otherwise. Memory, disk I/O, CPU and process counts
all work without it.

A Startup-folder shortcut cannot launch an elevated program, since Windows has
no "remember this" for UAC and would prompt at every boot. "Start with Windows"
registers a scheduled task instead, so booting never prompts.

## Idle cost

The process table is only read while the overlay is on screen. The one thing
that runs in the background is a TCP scan every couple of seconds, and only so
the `Sess *` totals do not miss bytes moved between peeks. Clear "Keep counting
while the overlay is closed" in settings for zero idle cost.

The update check is the other thing on a timer, but it is one request a day and
only if you leave it on.

## Build from source

Requires [AutoHotkey v2](https://www.autohotkey.com/).

```
"C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in Peek.ahk /out Peek.exe ^
    /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
```

No `/compress`. A UPX- or MPRESS-packed AutoHotkey binary is flagged harder
than a plain one, and the megabyte it saves is not worth it. Releases are built
exactly as above.

## License

[GNU General Public License v3.0](LICENSE). Use it anywhere, commercially or
privately, and modify it however you like. If you distribute it or anything
derived from it, the source has to be published under the same license.
