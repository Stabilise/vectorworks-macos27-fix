#!/bin/bash
#
# Jamf Pro extension attribute: Vectorworks macOS 27 Support Library Fix
#
# Reports one of:
#   Needs Fix                   an installation needs vectorworks-iodbc-fix.sh
#   Patched By Homebrew Method  an installation was changed by the community Homebrew fix
#   Fixed                       every affected installation is fixed
#   Not Affected                Vectorworks is installed but nothing needs fixing
#   No Vectorworks              no Vectorworks installation was found
#
# Reads files only and changes nothing. Does not need the Command Line Tools:
# it looks for the library path text inside each Support plug-in, which is
# where macOS stores the reference that the fix changes.
#
# Part of https://github.com/Stabilise/vectorworks-macos27-fix (MIT Licence).

OLD_REF="/usr/lib/libiodbc.2.dylib"
NEW_REF="@loader_path/../Frameworks/libiodbc.2.dylib"
HOMEBREW_REF="/opt/homebrew/opt/libiodbc/lib/libiodbc.2.dylib"
APPS_DIR="${VWFIX_APPS_DIR:-/Applications}"  # the override is for the automated tests

contains() { LC_ALL=C /usr/bin/grep -q -a -F "$2" "$1" 2>/dev/null; }

found=0 needs=0 homebrew=0 fixed=0

os_major="$(/usr/bin/sw_vers -productVersion)"
os_major="${os_major%%.*}"
arm64="$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)"

for dir in "$APPS_DIR"/Vectorworks*; do
  [ -d "$dir" ] || continue
  for support in "$dir/Plug-ins/Support.vwlibrary/Contents/MacOS/Support" \
                 "$dir/Plug-Ins/Support.vwlibrary/Contents/MacOS/Support"; do
    [ -f "$support" ] || continue
    found=1
    if contains "$support" "$OLD_REF"; then
      needs=1
    elif contains "$support" "$HOMEBREW_REF"; then
      homebrew=1
    elif contains "$support" "$NEW_REF"; then
      fixed=1
    fi
    break
  done
done

# The fault only exists on Apple silicon Macs running macOS 27 or later.
if [ "$needs" -eq 1 ] && { [ "$arm64" != "1" ] || [ "$os_major" -lt 27 ] 2>/dev/null; }; then
  needs=0
fi

if [ "$found" -eq 0 ]; then
  result="No Vectorworks"
elif [ "$needs" -eq 1 ]; then
  result="Needs Fix"
elif [ "$homebrew" -eq 1 ]; then
  result="Patched By Homebrew Method"
elif [ "$fixed" -eq 1 ]; then
  result="Fixed"
else
  result="Not Affected"
fi

printf '<result>%s</result>\n' "$result"
