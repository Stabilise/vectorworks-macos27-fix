# Testing on a Real Vectorworks Installation

The automated tests in `tests/run-tests.sh` prove the script's logic against stand-in installations. This guide covers the test that matters most: a real Vectorworks installation that fails to launch on macOS 27, in a virtual machine that can be thrown away afterwards.

## 1. Prepare the virtual machine

1. In UTM, create a macOS virtual machine on an Apple silicon Mac and install a macOS version that Vectorworks 2025 supports.
2. Install Vectorworks 2025 and apply its latest update. Note the exact version and build shown in **Vectorworks > About Vectorworks**.
3. Upgrade the virtual machine to macOS 27.
4. Confirm the fault: launching Vectorworks shows "Failure loading Support library" and it quits.
5. Install Apple's Command Line Tools: run `xcode-select --install` in Terminal and click Install.
6. Shut the virtual machine down and make a copy of it in UTM (right-click the machine, then **Clone**). The copy is the clean broken state to return to between test runs.

Licensing: activating Vectorworks inside a virtual machine may use one of your licence activations. Check this with your licence administrator before activating, and deactivate the licence before deleting the machine.

## 2. Allow remote testing over SSH

On the virtual machine:

1. Turn on **System Settings > General > Sharing > Remote Login**.
2. Note the machine's IP address (**System Settings > Network**).
3. For this disposable test machine only, allow the test account to use `sudo` without typing a password, so the script can be run remotely. Replace `alan` with the account name:

   ```bash
   echo 'alan ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/vwfix-testing
   sudo chmod 440 /etc/sudoers.d/vwfix-testing
   ```

   Remove it when testing is complete with `sudo rm /etc/sudoers.d/vwfix-testing`. Never do this on a real client Mac.

From the host Mac, copy an SSH key across so no password is needed: `ssh-copy-id alan@<ip-address>`.

## 3. Test plan

Stay logged in to the virtual machine's desktop throughout, so that Vectorworks can be opened. Run each step over SSH and record the result.

| # | Step | Command or action | Expected result |
|---|---|---|---|
| 1 | Copy the repository to the machine | `git clone https://github.com/Stabilise/vectorworks-macos27-fix.git && cd vectorworks-macos27-fix` | Repository present |
| 2 | Record the original state | `otool -L "/Applications/Vectorworks 2025/Plug-ins/Support.vwlibrary/Contents/MacOS/Support" \| grep iodbc` and `ls -la "/Applications/Vectorworks 2025/Plug-ins"` | Shows `/usr/lib/libiodbc.2.dylib (compatibility version 4.0.0, ...)`; note the owner of `Support.vwlibrary` |
| 3 | Check | `sudo bash vectorworks-iodbc-fix.sh --check; echo "exit $?"` | "Needs the fix", exit 10 |
| 4 | Jamf extension attribute before | `bash jamf/extension-attribute.sh` | `<result>Needs Fix</result>` |
| 5 | Apply | `sudo bash vectorworks-iodbc-fix.sh --yes` | Every step OK, "Vectorworks 2025: fixed", exit 0 |
| 6 | Launch | Open Vectorworks on the machine's desktop | Starts without the Support library error |
| 7 | Licence | Check **Vectorworks > About Vectorworks** or the licence dialog | Still licensed, same serial |
| 8 | Basic use | Create a drawing, draw a few objects, save, close, reopen | All work |
| 9 | Wider use | Open a real project file, export a PDF, render a 3D view, open a worksheet | All work |
| 10 | Refuse while running | Leave Vectorworks open and run `sudo bash vectorworks-iodbc-fix.sh --rollback --yes` | "is running", exit 1, nothing changed. Then quit Vectorworks |
| 11 | Run again | `sudo bash vectorworks-iodbc-fix.sh --yes` | "Nothing needs fixing.", exit 0, no new backup |
| 12 | Check after the fix | `sudo bash vectorworks-iodbc-fix.sh --check; echo "exit $?"` | "Fixed", exit 0 |
| 13 | Jamf extension attribute after | `bash jamf/extension-attribute.sh` | `<result>Fixed</result>` |
| 14 | Roll back | `sudo bash vectorworks-iodbc-fix.sh --rollback --yes` | Original restored, exit 0; step 2's `otool` command shows the original reference again |
| 15 | Launch after rollback | Open Vectorworks | Fails with the original Support library error, proving the rollback is exact |
| 16 | Apply as Jamf would | `sudo bash vectorworks-iodbc-fix.sh / TEST-MAC alan "" ""` | Fixed without asking, exit 0 |
| 17 | Standalone script | `cp vectorworks-iodbc-fix.sh /tmp/ && sudo bash /tmp/vectorworks-iodbc-fix.sh --rollback --yes && sudo bash /tmp/vectorworks-iodbc-fix.sh --yes` | Downloads the source from GitHub, verifies it, fixes, exit 0 |
| 18 | Launch again | Open Vectorworks | Starts |
| 19 | Collect evidence | `cat /Library/Logs/Stabilise/vectorworks-iodbc-fix.log` and `ls -la "/Applications/Vectorworks 2025/Plug-ins/Support.vwlibrary/Contents/Frameworks"` | Log and file ownership recorded for the README |

## 4. Record the results

Update the [compatibility table](../README.md#compatibility) with the Vectorworks version and build, the macOS version and build, the date, and any steps that did not pass. Replace the example output in the README's [What you will see](../README.md#what-you-will-see) section with the real output from step 5.
