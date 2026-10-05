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
2. Download `Peek.ahk` - either from the
   [latest release](../../releases/latest) or
   [straight out of this repository](Peek.ahk).
3. Double-click it.

That is all of it. `Peek.ahk` is a text file, and the executable that runs it is
AutoHotkey's own interpreter - the same copy millions of machines already have,
with the Defender reputation that comes of that. Every feature behaves the same:
the hotkey, the settings window, "Restart as administrator", "Start with
Windows". Peek's own icon comes too - the script carries a copy of it, so the
tray and every window look the same as they do from the executable, with nothing
to download alongside. The one difference is that an update opens the release
page rather than replacing anything, because there is no executable here to
replace.

### Download the executable

Download `Peek.exe` from the [latest release](../../releases/latest) and run it.
No installer, no dependencies - but expect Defender to take it away, and read
the next section before going this way.

Either way, settings are written to `Peek.ini` next to whichever file you run,
and nothing else on the machine is touched.

## Antivirus false positives

Windows Defender deletes `Peek.exe` on a good many machines, usually calling it
something like `Trojan:Win32/Wacatac.B!ml`. The `!ml` on the end is the tell: a
machine guessed. It is not a match against any known malware.

In plain terms: Peek is a small script, and `Peek.exe` is that script glued
together with the program that runs scripts, in one file nobody paid to sign.
Peek then listens for a hotkey, looks at every program running, reads how much
network each one is using, starts itself at logon, and replaces its own file
when it updates. All of that is ordinary for a tool like this - and all of it is
also what a snooping program would do. Defender cannot tell the two apart from
the outside, so it guesses, and sometimes it guesses wrong.

No change to the code fixes that; a code-signing certificate would, and Peek has
none. So pick whichever of these suits you:

- **Run `Peek.ahk` instead** - see Install above. No executable, nothing to
  flag. This is the easy answer.
- **Check it, then exclude it.** Compare your copy against the SHA-256 on the
  release page: `Get-FileHash .\Peek.exe -Algorithm SHA256`. If it matches,
  restore the file in **Windows Security** -> **Protection history**, then
  exclude Peek's folder - there is a script for that, below. The folder, not
  the file, otherwise the next update is flagged as a new file. An exclusion is
  a real hole in your protection, so keep it to that one folder, and do not
  take the step on the word of a README: the hash check is there so you do not
  have to.
- **Report it** on [Microsoft's false-positive
  form](https://www.microsoft.com/en-us/wdsi/filesubmission) - "Microsoft
  Defender Antivirus", "Incorrectly detected as malware". That gets the
  detection dropped for everybody, not just for you.
- **Build it yourself** - see [Build from source](#build-from-source).

### The exclusion scripts

Two scripts next to `Peek.exe` do the exclusion for you, so you do not have to
pick your way through the Windows Security pages:

| | |
|---|---|
| `Add-PeekExclusion.ps1` | Tells Defender to leave Peek's folder alone |
| `Remove-PeekExclusion.ps1` | Puts it back to watching that folder |

Right-click either one and choose **Run with PowerShell**. It asks Windows for
administrator rights itself and shows you a prompt to accept - changing
Defender's settings needs them, and nothing happens if you decline. If
right-clicking does not offer it, open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Add-PeekExclusion.ps1
```

Each script excludes **the folder it is sitting in**, so keep all of Peek
together in a folder of its own and run the script from there. It will refuse to
exclude your Downloads folder, Desktop, user profile or a drive root, because
excluding one of those would stop Defender looking at a great deal more than
Peek. Run `Add-PeekExclusion.ps1 -Force` if you genuinely meant one of those.

Neither script touches anything but Defender's exclusion list, and
`Remove-PeekExclusion.ps1` undoes exactly what the other one added. Once the
exclusion is gone Defender may quarantine `Peek.exe` again - running `Peek.ahk`
avoids the question entirely.

## Use

- The first launch puts a small note beside the tray icon to say Peek is there
  and running. There is nothing else to see until the hotkey is pressed, so it
  would otherwise look like nothing had started. It appears once, and goes on
  its own.
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
replace: the release page is opened instead, and `Peek.ahk` is attached there
alongside `Peek.exe` so the newer script is one download away.

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
