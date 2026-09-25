# Vectorworks on macOS 27: Support Library Fix

Vectorworks 2025 and earlier stop at launch on Apple silicon Macs that have been upgraded to macOS 27, showing **"Failure loading Support library."** This repository contains a single script that gets Vectorworks starting again. It does not need Homebrew, does not turn off any macOS security feature, and can be undone completely.

Maintained by [Stabilise](https://stabilise.io), a London-based Apple IT managed service provider.

> [!IMPORTANT]
> This is an unofficial workaround. Stabilise is not affiliated with, endorsed by or supported by Vectorworks, Inc., Nemetschek or Apple. The script modifies one component inside the Vectorworks installation. It keeps a complete backup of that component and can restore it at any time, but you use it at your own risk. The proper long-term fix is an update from Vectorworks built for macOS 27.

**Testing status:** tested on a real Vectorworks 2025 Update 8 installation on macOS 27.0, where it fixed the launch failure and its rollback restored the original exactly. See [Compatibility](#compatibility).

## Contents

- [Is this for you?](#is-this-for-you)
- [Quick start](#quick-start)
- [What you will see](#what-you-will-see)
- [Commands and options](#commands-and-options)
- [Deploying with Jamf Pro](#deploying-with-jamf-pro)
- [After a Vectorworks update](#after-a-vectorworks-update)
- [How it works](#how-it-works)
- [What it changes and what it never touches](#what-it-changes-and-what-it-never-touches)
- [Undoing the fix](#undoing-the-fix)
- [Troubleshooting](#troubleshooting)
- [Compatibility](#compatibility)
- [Why not the Homebrew method?](#why-not-the-homebrew-method)
- [Checking the library yourself](#checking-the-library-yourself)
- [Development and tests](#development-and-tests)
- [Credits and licence](#credits-and-licence)

## Is this for you?

The script is intended for you if **all** of the following are true:

- The Mac has Apple silicon (M1 or newer).
- The Mac runs macOS 27 or later.
- Vectorworks is installed in its normal place, `/Applications/Vectorworks <year>`.
- Vectorworks quits at launch with "Failure loading Support library" (other languages show their own translation, for example "Error al cargar la biblioteca de compatibilidad").

You do not need to be sure of the cause yourself. The script checks it: it only changes an installation whose Support component asks for the exact library that macOS 27 removed. Anything else is reported and left alone.

**What you need:**

- An administrator account on the Mac.
- Apple's **Command Line Tools**, a free package of Apple developer tools. If they are missing, the script stops and tells you how to install them. To install them yourself beforehand, run `xcode-select --install` in Terminal and click Install in the window that appears.
- Vectorworks closed while the script runs.

## Quick start

1. **Download this repository.** On the repository's GitHub page, click **Code**, then **Download ZIP**, and open the downloaded file so that it unzips into your Downloads folder. If you use Git, `git clone https://github.com/Stabilise/vectorworks-macos27-fix.git` does the same thing.

2. **Quit Vectorworks.**

3. **Open Terminal** (press Command and Space, type `Terminal`, press Return) and go to the downloaded folder:

   ```bash
   cd ~/Downloads/vectorworks-macos27-fix-main
   ```

   If you cloned the repository with Git, the folder is called `vectorworks-macos27-fix` instead.

4. **Check first.** This reports what the script finds and changes nothing:

   ```bash
   sudo bash vectorworks-iodbc-fix.sh --check
   ```

   Terminal asks for your Mac password. Nothing appears on screen as you type it; this is normal. Press Return when you have finished typing.

5. **Apply the fix:**

   ```bash
   sudo bash vectorworks-iodbc-fix.sh
   ```

   The script lists the installations it will fix and asks you to confirm. Type `y` and press Return.

6. **Open Vectorworks** and check that it starts, that it is still licensed, and that you can open and save a file.

Running the script with `bash` in front of it, as shown, means macOS does not need to be told that the downloaded file is allowed to run, so there is no need to change its permissions or remove download warnings.

## What you will see

This is a real run on Vectorworks 2025 Update 8 on macOS 27.0, started with `--yes` so it did not stop to ask (the test Mac's clock was set to US Pacific time). Without `--yes`, the "Continue?" line waits for you to type `y`:

```text
Vectorworks macOS 27 iODBC fix 1.0.0 (Stabilise)
Started 24/09/2026 21:53:11 PDT, action: apply
Log: /Library/Logs/Stabilise/vectorworks-iodbc-fix.log

==> Checking this Mac
    OK      macOS 27.0
    OK      Apple silicon, running natively

==> Checking Apple's Command Line Tools
    OK      Command Line Tools present (/Library/Developer/CommandLineTools)

==> Looking for Vectorworks in /Applications
    ..      Vectorworks 2025, version 30.8.842584: Needs the fix

The fix will be applied to:
    Vectorworks 2025

Continue? [yes, unattended]

==> Making sure Vectorworks is closed
    OK      Vectorworks is not running

==> Building the iODBC library from OpenLink's source
    ..      Using the copy of the source included with this script
    OK      Source verified (SHA-256 matches OpenLink's release)
    ..      Compiling (this runs Apple's compiler; nothing is installed yet)
    OK      Library built: iODBC 3.52.16, Apple silicon, compatibility version 4.0.0

==> Fixing Vectorworks 2025
    OK      Original Support plug-in is intact and signed
    OK      All 28 iODBC functions the plug-in uses are present
    OK      Backup saved: /Library/Application Support/Stabilise/Vectorworks iODBC Fix/backups/Vectorworks 2025/20260925T045326Z
    OK      Library added and reference updated (in a staging copy)
    OK      Updated plug-in signed and verified
    OK      Vectorworks 2025 is fixed

==> Result

    Vectorworks 2025: fixed
```

The version and the number of functions may differ on your Mac. Every run is also written to `/Library/Logs/Stabilise/vectorworks-iodbc-fix.log`, which is the file to send if you need help.

## Commands and options

Run every command with `sudo bash vectorworks-iodbc-fix.sh` followed by the options you want.

| Action | What it does |
|---|---|
| *(none)* or `--apply` | Fixes every affected Vectorworks installation. This is the default. |
| `--check` | Reports the state of every installation and changes nothing. |
| `--rollback` | Puts the original Support component back from the most recent backup. |

| Option | What it does |
|---|---|
| `--only "Vectorworks 2025"` | Acts on one installation folder only. Give the folder name, not a full path. |
| `--yes` or `-y` | Does not ask for confirmation. Use this for unattended runs. |
| `--help` | Shows the built-in help. |
| `--version` | Shows the script's version number. |

**Exit codes**, useful for automation:

| Code | Meaning |
|---|---|
| `0` | Success, or nothing needed doing. |
| `1` | The script stopped. The message and the log explain why. Nothing is left half-changed. |
| `2` | An option was not recognised. |
| `10` | Only from `--check`: at least one installation needs the fix or needs attention. |

For each installation, `--check` reports one of these states:

| State | Meaning |
|---|---|
| Needs the fix | The Support component asks for the library macOS 27 removed. `--apply` will fix it. |
| Fixed | Fixed by this script, and the fix is intact. |
| Fixed, but damaged | Fixed by this script, but the added library is missing or the signature no longer checks out. Run `--rollback`, then `--apply`. |
| Patched by the community Homebrew method | Changed by the earlier community script. This script leaves it alone; see [below](#why-not-the-homebrew-method). |
| Not affected | This version does not use the library, or has no Apple silicon code. |
| Unrecognised setup | The Support component refers to the library in an unexpected way. Left alone. |

## Deploying with Jamf Pro

The script is designed to run unattended from a Jamf Pro policy.

**Before you start:** the Command Line Tools must be on each Mac. Deploy them with Jamf before this policy runs. One way is to download the Command Line Tools installer package from [Apple's developer downloads](https://developer.apple.com/download/all/) and deploy it as a package.

**1. Add the script.** In Jamf Pro, go to **Settings > Computer Management > Scripts**, create a script, and paste in the contents of `vectorworks-iodbc-fix.sh`. On the **Options** tab, set the label for **Parameter 4** to `Action` and for **Parameter 5** to `Only This Installation`.

When the script runs on its own like this, without the rest of the repository, it downloads the iODBC source from OpenLink's GitHub release page and checks it against the same fixed checksum. The Macs therefore need access to `github.com`. If they do not have it, deploy the whole repository folder as a package and run the script from there instead; it then uses the copy of the source in `vendor/`.

**2. Create the policy.** Add the script to a policy and set its parameters:

| Parameter | Value | Result |
|---|---|---|
| 4 (Action) | *(empty)* or `--apply` | Fixes every affected installation. |
| 4 (Action) | `--check` | Reports only. |
| 4 (Action) | `--rollback` | Undoes the fix. |
| 5 (Only This Installation) | *(empty)* | Acts on every installation. |
| 5 (Only This Installation) | `Vectorworks 2025` | Acts on that installation folder only. Type the name without quotation marks. |

The script recognises how Jamf passes its arguments and never waits for confirmation when run by Jamf. It refuses to run while Vectorworks is open and exits with code 1, which Jamf reports as a failure, so set the policy to run at a time when Vectorworks is usually closed (for example at login or check-in), or let it retry at the next check-in.

**3. Report which Macs need it (optional).** `jamf/extension-attribute.sh` is a Jamf extension attribute, a small script Jamf runs during inventory to collect a value. It reports `Needs Fix`, `Fixed`, `Patched By Homebrew Method`, `Not Affected` or `No Vectorworks` for each Mac and does not need the Command Line Tools. Add it under **Settings > Computer Management > Extension Attributes** with the input type set to Script, then build a smart group on `Needs Fix` and scope the policy to it.

## After a Vectorworks update

Vectorworks updates and reinstalls replace the Support component, which removes the fix, so Vectorworks fails to start again on macOS 27. Run the script again after any update. It detects the new version, takes a fresh backup and applies the fix. With Jamf, the extension attribute moves the Mac back into the `Needs Fix` smart group, so the policy fixes it automatically.

If Vectorworks releases an update that no longer depends on the missing library, the script reports that installation as **Not affected** and changes nothing.

## How it works

**The fault.** Vectorworks keeps much of its core code in a plug-in called `Support.vwlibrary`, inside the `Plug-ins` folder of the Vectorworks installation. That plug-in is linked against iODBC, an open-source library that lets applications talk to databases through the ODBC standard. Older versions of macOS included iODBC at `/usr/lib/libiodbc.2.dylib` (a `.dylib`, or dynamic library, is code that programs load when they start). macOS 27 no longer includes it. When Vectorworks starts, macOS cannot find the library the plug-in asks for, the plug-in fails to load, and Vectorworks stops.

macOS 27 also no longer looks for missing system libraries in other folders, so there is nowhere the library could simply be copied to. The plug-in itself has to be told where to find it.

**The fix.** The script builds iODBC from OpenLink's official source release, the same release and version that Homebrew distributes, and places the result inside the Support plug-in:

```text
Vectorworks 2025/
└── Plug-ins/
    └── Support.vwlibrary/
        └── Contents/
            ├── MacOS/
            │   └── Support              ← now asks for ../Frameworks/libiodbc.2.dylib
            └── Frameworks/
                └── libiodbc.2.dylib     ← added by this script
```

It then changes the plug-in's single reference to the library from `/usr/lib/libiodbc.2.dylib` to `@loader_path/../Frameworks/libiodbc.2.dylib`. `@loader_path` is a standard macOS instruction meaning "the folder of the file doing the loading", so the plug-in always finds the copy that sits inside it. `Contents/Frameworks` is where Apple's guidelines say a bundle's own libraries belong.

**Step by step**, the script:

1. Checks the Mac: macOS 27 or later, Apple silicon, running natively rather than through Rosetta (Apple's translation layer for Intel software), and the Command Line Tools present.
2. Finds every Vectorworks installation in `/Applications` and reads exactly which libraries each Support plug-in asks for.
3. Stops if Vectorworks is running.
4. Verifies the iODBC source file against a fixed SHA-256 checksum (a fingerprint that changes if a single byte changes), then compiles it with Apple's compiler in a clean environment, so that nothing else installed on the Mac, such as Homebrew, can influence the result.
5. Checks the built library: Apple silicon code, the compatibility version (4.0.0) that Vectorworks requires, the modern linking mode, and no dependencies beyond core parts of macOS.
6. For each affected installation:
   1. Confirms the plug-in's original Vectorworks signature is intact, which proves it has not been altered already.
   2. Confirms that every iODBC function the plug-in uses exists in the built library.
   3. Copies the whole plug-in to a backup and checks the copy file by file against the original.
   4. Makes a staging copy of the plug-in beside the original and applies all changes to that copy only.
   5. Signs the staging copy (see below) and verifies the signature.
   6. Swaps the staging copy into place. The swap is a rename within the same folder, so it is instantaneous, and the original is kept until the final check passes.
   7. Checks the installed result. If anything is wrong, it puts the original back.

**About signing.** macOS requires code to carry a valid code signature, which is a cryptographic seal that shows the code has not changed since it was signed. Changing the plug-in breaks Vectorworks' own signature, so the script re-signs the plug-in with an ad hoc signature, one that is made on the Mac itself and is not tied to any developer account. The earlier community fix does the same. Only the Support plug-in is re-signed; the Vectorworks application itself keeps its original signature.

## What it changes and what it never touches

**It changes**, for each affected installation only:

- `Plug-ins/Support.vwlibrary/Contents/MacOS/Support`: one library reference.
- `Plug-ins/Support.vwlibrary/Contents/Frameworks/libiodbc.2.dylib`: added.
- The Support plug-in's signature.

**It creates:**

- Backups in `/Library/Application Support/Stabilise/Vectorworks iODBC Fix/backups`, readable only by administrators.
- A log at `/Library/Logs/Stabilise/vectorworks-iodbc-fix.log`.

**It never:**

- Changes the Vectorworks application itself, your licence or serial number, your settings or your files.
- Writes to `/usr/lib` or any other part of macOS.
- Turns off System Integrity Protection, Gatekeeper or any other macOS security feature.
- Installs Homebrew or anything else system-wide. The compiler runs in a temporary folder that is deleted afterwards.
- Changes an installation it does not recognise with certainty.

If the script is interrupted part-way (for example the Mac loses power or the Terminal window is closed), the original plug-in is either still in place or is put back automatically, because the change is only swapped in once it is complete and verified.

## Undoing the fix

Quit Vectorworks, then run:

```bash
sudo bash vectorworks-iodbc-fix.sh --rollback
```

This restores the Support plug-in exactly as Vectorworks installed it, with its original signature, from the most recent backup. On macOS 27, Vectorworks will then fail to start again, as it did before the fix.

The script will not restore a backup that was taken from a different Vectorworks version than the one now installed, because that would mix components from two versions. After a Vectorworks update the fix is already gone, so there is nothing to roll back.

## Troubleshooting

| Message | What it means and what to do |
|---|---|
| "must run with administrator rights" | Put `sudo` in front of the command, as shown in the [quick start](#quick-start). |
| "Apple's Command Line Tools are not installed" | Run `xcode-select --install`, click Install, wait for it to finish, then run the script again. |
| "is running" | Save your work, quit Vectorworks, and run the script again. |
| "Terminal is running under Rosetta" | Quit Terminal, select it in Finder (Applications > Utilities), choose File > Get Info, untick "Open using Rosetta", and try again. |
| "original signature does not verify" | The Support plug-in has already been altered, possibly by another fix. Reinstall Vectorworks, or run the Vectorworks updater, then run the script again. |
| "Patched by the community Homebrew method" | See [Why not the Homebrew method?](#why-not-the-homebrew-method). |
| "does not match its published checksum" | The iODBC source file is not the genuine release. The script will not use it. Download this repository again. |
| "Could not download the iODBC source" | The Mac cannot reach `github.com`. Run the script from the full repository folder, which includes the source, or fix the connection. |
| "The iODBC library did not build" | The last lines of the compiler output are shown. Send the log to Stabilise. |
| Vectorworks still does not start after a successful fix | Run `--check`. If it says "Fixed", the startup problem has a different cause that this script does not address. Send the log to Stabilise. |

The log is at `/Library/Logs/Stabilise/vectorworks-iodbc-fix.log`. It contains no passwords, licence details or personal data.

## Compatibility

The script decides what to fix by inspecting each installation, not by its version number. It fixes any Vectorworks installation whose Support plug-in asks for exactly `/usr/lib/libiodbc.2.dylib` with compatibility version 4.0.0, and leaves everything else alone.

| Vectorworks version | Status |
|---|---|
| 2025 Update 8 (build 842584) | **Tested** on macOS 27.0 (26A428), Apple silicon, 25/09/2026. The fix applied, Vectorworks launched with the added library loaded, and a second run correctly did nothing. Rollback restored the original Support file byte for byte with its Vectorworks signature, and the original error returned. Refusal while Vectorworks was open, the Jamf Pro run, and the script run on its own (downloading and verifying the source from GitHub) also behaved as documented. |
| 2024, 2026 and earlier versions | Should work wherever the check above matches. Not yet tested on a real installation by Stabilise. |

The results of real-installation testing will be recorded here. If you use the script on a version not listed, we would be glad to hear how it went: [hello@stabilise.io](mailto:hello@stabilise.io).

## Why not the Homebrew method?

The first community fix, [created by Wagner R. Ponce (ANIFONIX)](https://github.com/wkrodrig/vectorworks-2025-2026-wont-launch-macos27-fix), diagnosed this fault and deserves the credit for it. It installs Homebrew, a third-party package manager, and points Vectorworks at Homebrew's copy of iODBC in `/opt/homebrew`. This script takes a different approach for three reasons:

- **Less to install.** Homebrew is a large, permanent addition to a Mac whose only purpose here would be to supply one library. This script builds that library once, puts it inside Vectorworks and leaves nothing else behind.
- **Easier to check.** The library this script adds is sealed into the Support plug-in's signature, so `--check` reports the fix as damaged if the library is changed or removed. A library in Homebrew's folder has no such link to Vectorworks. Note that neither method changes who can write to the files: Homebrew's folder belongs to the user who installed it, and a Vectorworks installation can belong to the user who installed it too, as it did on our test Mac. On such a Mac, a program running as that user could replace either library.
- **Self-contained.** The fix does not depend on anything outside Vectorworks, so updating or removing Homebrew cannot break Vectorworks, and a Vectorworks update removes the fix cleanly.

Placing the library inside the Support plug-in follows the approach [Mike Hayes reported working](https://github.com/wkrodrig/vectorworks-2025-2026-wont-launch-macos27-fix/issues/2) on Vectorworks 2022 SP6.

If an installation was already fixed with the Homebrew method, this script reports it and does not change it. To move it to this method, undo the Homebrew fix with that project's own `--rollback` option, or reinstall Vectorworks, then run this script.

## Checking the library yourself

You do not have to trust a file from this repository; the script builds the library from source every time it runs. You can check each step:

- **The source.** `vendor/libiodbc-3.52.16.tar.gz` is OpenLink's release file, unmodified. Its SHA-256 checksum is `3898b32d07961360f6f2cf36db36036b719a230e476469258a80f32243e845fa`, which matches both [OpenLink's release page](https://github.com/openlink/iODBC/releases/tag/v3.52.16) and the checksum pinned in [Homebrew's recipe](https://github.com/Homebrew/homebrew-core/blob/HEAD/Formula/lib/libiodbc.rb). Check it with:

  ```bash
  shasum -a 256 vendor/libiodbc-3.52.16.tar.gz
  ```

- **The build.** Before release, the library this script builds was compared with Homebrew's own macOS 27 build of the same version. Both declare compatibility version 4.0.0 and current version 4.31.0, both use the modern linking mode, both depend only on the same two parts of macOS, and both provide the same 152 functions.

- **A fixed plug-in.** On a fixed Mac:

  ```bash
  cd "/Applications/Vectorworks 2025/Plug-ins/Support.vwlibrary/Contents"
  otool -L MacOS/Support | grep iodbc            # shows @loader_path/../Frameworks/libiodbc.2.dylib
  otool -L Frameworks/libiodbc.2.dylib           # shows version 4.0.0 and its macOS dependencies
  codesign --verify --deep --strict --verbose=2 ..
  ```

## Development and tests

```text
vectorworks-iodbc-fix.sh     the script
vendor/                      OpenLink's iODBC 3.52.16 source release, unmodified
tests/run-tests.sh           automated tests
jamf/extension-attribute.sh  Jamf Pro inventory helper
docs/TESTING.md              how to test on a real Vectorworks installation
```

`tests/run-tests.sh` builds small stand-in Vectorworks installations in a temporary folder, including a stand-in Support plug-in that depends on `/usr/lib/libiodbc.2.dylib` exactly as the real one does, and runs the real script against them. It covers checking, applying, running a second time, detecting damage, rolling back, refusing when Vectorworks is running, refusing an already-altered plug-in, refusing a mismatched backup, refusing a tampered source file, leaving other setups alone and handling Jamf's arguments. After the fix, it loads the stand-in plug-in and calls a real iODBC function through the added library, to prove that the library is found and works.

The tests need an Apple silicon Mac running macOS 27 with the Command Line Tools. They run as a normal user and touch nothing outside their temporary folder:

```bash
./tests/run-tests.sh
```

For testing on a real installation, follow [docs/TESTING.md](docs/TESTING.md).

## Credits and licence

- **Wagner R. Ponce (ANIFONIX)** identified the cause and published the [first workaround](https://github.com/wkrodrig/vectorworks-2025-2026-wont-launch-macos27-fix).
- **Mike Hayes** reported the in-plug-in library approach working on Vectorworks 2022 SP6.
- **OpenLink Software** develops [iODBC](https://github.com/openlink/iODBC), which is available under the BSD or LGPL licence. See [NOTICE.md](NOTICE.md).

This script was written independently by Stabilise and does not reuse code from the projects above. It is released under the [MIT Licence](LICENSE).

Vectorworks is a trademark of Vectorworks, Inc. macOS is a trademark of Apple Inc.

**Stabilise Ltd**, 6-7 St Cross Street, London EC1N 8UB · [stabilise.io](https://stabilise.io) · [hello@stabilise.io](mailto:hello@stabilise.io)
