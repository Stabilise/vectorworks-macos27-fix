#!/bin/bash
#
# vectorworks-iodbc-fix.sh
#
# Gets Vectorworks launching again on Apple silicon Macs running macOS 27.
#
# macOS 27 no longer includes /usr/lib/libiodbc.2.dylib. Vectorworks' Support
# plug-in (Support.vwlibrary) still refers to it, so Vectorworks stops at
# startup with "Failure loading Support library". This script builds the same
# iODBC library from OpenLink's official source release, places it inside the
# Support plug-in, points the plug-in at that copy and re-signs the plug-in.
# A complete backup is taken first and every change can be rolled back.
#
# Usage: sudo ./vectorworks-iodbc-fix.sh [--check | --apply | --rollback]
#        [--only "Vectorworks 2025"] [--yes]
#
# Full documentation: README.md, or
# https://github.com/Stabilise/vectorworks-macos27-fix
#
# Copyright (c) 2026 Stabilise Ltd. Released under the MIT Licence.
# Not affiliated with, endorsed by or supported by Vectorworks, Inc. or Apple.

set -u -o pipefail

readonly SCRIPT_VERSION="1.0.0"

readonly IODBC_VERSION="3.52.16"
readonly IODBC_TARBALL="libiodbc-${IODBC_VERSION}.tar.gz"
readonly IODBC_URL="https://github.com/openlink/iODBC/releases/download/v${IODBC_VERSION}/${IODBC_TARBALL}"
# SHA-256 of OpenLink's release file. Homebrew pins the same value.
readonly IODBC_SHA256="3898b32d07961360f6f2cf36db36036b719a230e476469258a80f32243e845fa"

readonly OLD_REF="/usr/lib/libiodbc.2.dylib"
readonly NEW_REF="@loader_path/../Frameworks/libiodbc.2.dylib"
readonly HOMEBREW_REF="/opt/homebrew/opt/libiodbc/lib/libiodbc.2.dylib"
readonly REQUIRED_COMPAT="4.0.0"
readonly MIN_MACOS_MAJOR=27

# These VWFIX_ variables, and VWFIX_ALLOW_NON_ROOT, exist for the automated
# tests only.
APPS_DIR="${VWFIX_APPS_DIR:-/Applications}"
STATE_DIR="${VWFIX_STATE_DIR:-/Library/Application Support/Stabilise/Vectorworks iODBC Fix}"
LOG_FILE="${VWFIX_LOG_FILE:-/Library/Logs/Stabilise/vectorworks-iodbc-fix.log}"
BACKUP_DIR="$STATE_DIR/backups"

readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2
readonly EXIT_NEEDS_FIX=10

case "$0" in
  /*) SCRIPT_DIR="$(dirname "$0")" ;;
  *)  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" ;;
esac
readonly SCRIPT_DIR

MODE="apply"
ASSUME_YES=0
ONLY=""
WORK_DIR=""
BUILT_LIB=""

# Set while a plug-in is being swapped, so an interrupted run puts the
# original back instead of leaving Vectorworks without its Support plug-in.
SWAP_BUNDLE=""
SWAP_PREVIOUS=""
STAGING_DIRS=""
NEW_STAGING=""

OTOOL="" INSTALL_NAME_TOOL="" NM="" LIPO="" CLANG="" MAKE=""

# ------------------------------------------------------------------ output ---

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '    OK      %s\n' "$*"; }
info() { printf '    ..      %s\n' "$*"; }
warn() { printf '    WARNING %s\n' "$*"; }

die() {
  printf '\nSTOPPED: %s\n' "$1"
  shift
  while [ $# -gt 0 ]; do printf '%s\n' "$1"; shift; done
  [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ] && printf '\nLog: %s\n' "$LOG_FILE"
  exit "$EXIT_ERROR"
}

usage() {
  cat <<'EOF'
Vectorworks macOS 27 iODBC fix (Stabilise)

Usage:
  sudo ./vectorworks-iodbc-fix.sh [action] [options]

Actions:
  --check       Report the state of every Vectorworks installation. Changes nothing.
                Exit code 0 means nothing needs fixing, 10 means at least one
                installation needs the fix or needs attention.
  --apply       Fix every affected installation (the default action).
  --rollback    Restore the original Support plug-in from the most recent backup.

Options:
  --only NAME   Act on one installation folder only, for example "Vectorworks 2025".
  --yes, -y     Do not ask for confirmation (for Jamf and other unattended runs).
  --help, -h    Show this help.
  --version     Show the script version.

Quit Vectorworks before applying or rolling back.
EOF
}

# ------------------------------------------------------------- arguments -----

parse_args() {
  # Jamf Pro passes the mount point, computer name and user name as the first
  # three arguments. Parameter 4 is the action and parameter 5 the name of a
  # single installation, which may contain spaces.
  if [ $# -ge 3 ] && [ "$1" = "/" ]; then
    local jamf_action="${4:-}" jamf_only="${5:-}"
    set --
    [ -n "$jamf_action" ] && set -- "$jamf_action"
    [ -n "$jamf_only" ] && set -- "$@" --only "$jamf_only"
    ASSUME_YES=1
  fi

  while [ $# -gt 0 ]; do
    case "$1" in
      --check)    MODE="check" ;;
      --apply)    MODE="apply" ;;
      --rollback) MODE="rollback" ;;
      --only)
        [ $# -ge 2 ] || { usage; exit "$EXIT_USAGE"; }
        ONLY="$2"; shift ;;
      --only=*)   ONLY="${1#*=}" ;;
      --yes|-y)   ASSUME_YES=1 ;;
      --version)  say "$SCRIPT_VERSION"; exit "$EXIT_OK" ;;
      --help|-h)  usage; exit "$EXIT_OK" ;;
      "")         ;;
      *)          usage; printf '\nUnknown option: %s\n' "$1"; exit "$EXIT_USAGE" ;;
    esac
    shift
  done

  case "$ONLY" in
    */*) printf 'Give --only the folder name, for example "Vectorworks 2025", not a path.\n'
         exit "$EXIT_USAGE" ;;
  esac
}

# ------------------------------------------------------ cleanup and logging --

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  local status=$?
  # If we stopped between moving the original plug-in out and the new one in,
  # put the original back before anything else.
  if [ -n "$SWAP_BUNDLE" ] && [ ! -e "$SWAP_BUNDLE" ] && [ -d "$SWAP_PREVIOUS" ]; then
    /bin/mv "$SWAP_PREVIOUS" "$SWAP_BUNDLE" && \
      printf '\nThe run was interrupted. The original Support plug-in has been put back.\n'
  fi
  if [ -n "$STAGING_DIRS" ]; then
    printf '%s\n' "$STAGING_DIRS" | while IFS= read -r dir; do
      [ -n "$dir" ] && [ -d "$dir" ] && /bin/rm -rf "$dir"
    done
  fi
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && /bin/rm -rf "$WORK_DIR"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

start_log() {
  /bin/mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  if /usr/bin/touch "$LOG_FILE" 2>/dev/null; then
    exec > >(/usr/bin/tee -a "$LOG_FILE") 2>&1
  else
    LOG_FILE=""
  fi
  say ""
  say "Vectorworks macOS 27 iODBC fix $SCRIPT_VERSION (Stabilise)"
  say "Started $(/bin/date '+%d/%m/%Y %H:%M:%S %Z'), action: $MODE"
  [ -n "$LOG_FILE" ] && say "Log: $LOG_FILE"
}

confirm() {
  local answer=""
  if [ "$ASSUME_YES" -eq 1 ]; then
    printf '\n%s [yes, unattended]\n' "$1"
    return 0
  fi
  if [ ! -t 0 ]; then
    die "This needs a yes or no answer, but it is not running in an interactive Terminal." \
        "Run it in Terminal, or add --yes for unattended use."
  fi
  printf '\n%s [y/N]: ' "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# -------------------------------------------------------------- preflight ----

check_root() {
  [ "$(/usr/bin/id -u)" -eq 0 ] && return 0
  [ "${VWFIX_ALLOW_NON_ROOT:-0}" = "1" ] && return 0
  printf 'This script changes files inside /Applications and must run with administrator rights.\n'
  printf 'Run it again with sudo:\n\n    sudo "%s/%s"\n' "$SCRIPT_DIR" "$(basename "$0")"
  exit "$EXIT_ERROR"
}

check_mac() {
  step "Checking this Mac"
  local os_version os_major
  os_version="$(/usr/bin/sw_vers -productVersion)"
  os_major="${os_version%%.*}"
  if [ "$os_major" -lt "$MIN_MACOS_MAJOR" ] 2>/dev/null; then
    die "This Mac is running macOS $os_version." \
        "The fault this script fixes only exists on macOS $MIN_MACOS_MAJOR and later. Nothing has been changed."
  fi
  ok "macOS $os_version"

  if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]; then
    die "This is not an Apple silicon Mac." "The fix applies to Apple silicon Macs only."
  fi
  if [ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
    die "Terminal is running under Rosetta, Apple's Intel translation layer." \
        "Quit Terminal, turn off \"Open using Rosetta\" in its Get Info window, and run this again."
  fi
  ok "Apple silicon, running natively"
}

find_tool() {
  /usr/bin/xcrun --find "$1" 2>/dev/null
}

check_tools() {
  step "Checking Apple's Command Line Tools"
  local missing=""
  OTOOL="$(find_tool otool)"                         || missing="$missing otool"
  INSTALL_NAME_TOOL="$(find_tool install_name_tool)" || missing="$missing install_name_tool"
  NM="$(find_tool nm)"                               || missing="$missing nm"
  LIPO="$(find_tool lipo)"                           || missing="$missing lipo"
  CLANG="$(find_tool clang)"                         || missing="$missing clang"
  MAKE="$(find_tool make)"                           || missing="$missing make"
  if [ -n "$missing" ]; then
    die "Apple's Command Line Tools are not installed (missing:$missing)." \
        "Install them, then run this script again:" "" \
        "    xcode-select --install" "" \
        "On a managed Mac they can be deployed with Jamf instead. See the README."
  fi
  ok "Command Line Tools present ($(/usr/bin/xcode-select -p))"
}

# ------------------------------------------------------ inspecting installs --

# Each Vectorworks folder in /Applications that contains a real (not linked)
# Support plug-in, one per line.
list_installs() {
  local dir
  for dir in "$APPS_DIR"/Vectorworks*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    [ -n "$(support_bundle_of "$dir")" ] || continue
    if [ -n "$ONLY" ] && [ "$(basename "$dir")" != "$ONLY" ]; then
      continue
    fi
    printf '%s\n' "$dir"
  done
}

support_bundle_of() {
  local plugins
  for plugins in "$1/Plug-ins" "$1/Plug-Ins"; do
    if [ -d "$plugins/Support.vwlibrary" ] && [ ! -L "$plugins" ] && \
       [ ! -L "$plugins/Support.vwlibrary" ]; then
      printf '%s' "$plugins/Support.vwlibrary"
      return 0
    fi
  done
  return 1
}

support_exec_of() {
  local name
  name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null)"
  case "$name" in ""|*/*|.|..) name="Support" ;; esac
  printf '%s' "$1/Contents/MacOS/$name"
}

app_of() {
  local app
  for app in "$1"/Vectorworks*.app; do
    [ -d "$app" ] && { printf '%s' "$app"; return 0; }
  done
  return 1
}

app_build_of() {
  local app
  app="$(app_of "$1")" || { printf 'unknown'; return; }
  local short build
  short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)"
  build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null)"
  printf '%s (%s)' "${short:-unknown}" "${build:-unknown}"
}

# Prints "path compatibility-version" for every iODBC reference in the arm64
# part of a Mach-O file. Output is captured before parsing so that an early
# exit in the parser can never be mistaken for an otool failure.
iodbc_refs() {
  local listing
  listing="$("$OTOOL" -arch arm64 -L "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$listing" | /usr/bin/awk 'NR > 1 && $1 ~ /libiodbc/ {
    compat = ""
    for (i = 2; i < NF; i++) if ($i == "(compatibility" && $(i+1) == "version") { compat = $(i+2); sub(/,$/, "", compat) }
    print $1, compat
  }'
}

# Prints one word describing an installation:
#   affected    refers to the missing system library and can be fixed
#   fixed       already fixed by this script and intact
#   damaged     fixed by this script, but the library or signature is broken
#   homebrew    patched by the community Homebrew method
#   unaffected  does not use iODBC at all
#   no-arm64    has no Apple silicon code
#   unexpected  refers to iODBC in some other way; left alone
classify() {
  local bundle executable refs archs
  bundle="$(support_bundle_of "$1")"
  executable="$(support_exec_of "$bundle")"
  [ -f "$executable" ] || { printf 'unexpected'; return; }
  archs="$("$LIPO" -archs "$executable" 2>/dev/null)"
  case " $archs " in *" arm64 "*) ;; *) printf 'no-arm64'; return ;; esac
  refs="$(iodbc_refs "$executable")" || { printf 'unexpected'; return; }

  if [ -z "$refs" ]; then
    printf 'unaffected'
  elif [ "$refs" = "$OLD_REF $REQUIRED_COMPAT" ]; then
    printf 'affected'
  elif [ "$refs" = "$NEW_REF $REQUIRED_COMPAT" ]; then
    if [ -f "$bundle/Contents/Frameworks/libiodbc.2.dylib" ] && \
       /usr/bin/codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
      printf 'fixed'
    else
      printf 'damaged'
    fi
  elif [ "${refs%% *}" = "$HOMEBREW_REF" ]; then
    printf 'homebrew'
  else
    printf 'unexpected'
  fi
}

describe_state() {
  case "$1" in
    affected)   printf 'Needs the fix' ;;
    fixed)      printf 'Fixed' ;;
    damaged)    printf 'Fixed, but damaged: run --rollback, then --apply' ;;
    homebrew)   printf 'Patched by the community Homebrew method: left alone (see README)' ;;
    unaffected) printf 'Not affected: does not use iODBC' ;;
    no-arm64)   printf 'Not affected: no Apple silicon code' ;;
    *)          printf 'Unrecognised setup: left alone' ;;
  esac
}

vectorworks_running() {
  local procs
  procs="$(/bin/ps -axo command= 2>/dev/null)"
  case "$procs" in *"$1/"*) return 0 ;; esac
  return 1
}

# SHA-256 of every file in a folder, with paths relative to it, sorted.
manifest_of() {
  (cd "$1" && /usr/bin/find . -type f -print0 | LC_ALL=C /usr/bin/sort -z | \
     /usr/bin/xargs -0 /usr/bin/shasum -a 256)
}

# ------------------------------------------------------- building iODBC -----

build_library() {
  step "Building the iODBC library from OpenLink's source"
  WORK_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vwfix.XXXXXX")" || die "Could not create a temporary folder."

  local tarball="$SCRIPT_DIR/vendor/$IODBC_TARBALL"
  if [ -f "$tarball" ]; then
    info "Using the copy of the source included with this script"
  else
    info "Downloading $IODBC_URL"
    tarball="$WORK_DIR/$IODBC_TARBALL"
    /usr/bin/curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$IODBC_URL" -o "$tarball" || \
      die "Could not download the iODBC source." "Check this Mac's internet connection. Nothing has been changed."
  fi

  local actual
  actual="$(/usr/bin/shasum -a 256 "$tarball" | /usr/bin/awk '{print $1}')"
  if [ "$actual" != "$IODBC_SHA256" ]; then
    die "The iODBC source file does not match its published checksum." \
        "Expected: $IODBC_SHA256" "Found:    $actual" \
        "It will not be used. Nothing has been changed."
  fi
  ok "Source verified (SHA-256 matches OpenLink's release)"

  local src="$WORK_DIR/src" build_log="$WORK_DIR/build.log"
  if ! /bin/mkdir -p "$src" || ! /usr/bin/tar -xzf "$tarball" -C "$src" --strip-components 1; then
    die "Could not unpack the iODBC source."
  fi

  # A clean environment keeps anything else installed on the Mac, such as
  # Homebrew, out of the build. The deployment target makes the build tools
  # use the modern (two-level) linking mode rather than a legacy one.
  local tool_path cpus
  tool_path="$(dirname "$CLANG"):$(dirname "$MAKE"):/usr/bin:/bin:/usr/sbin:/sbin"
  cpus="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || printf '4')"
  info "Compiling (this runs Apple's compiler; nothing is installed yet)"
  if ! (cd "$src" && /usr/bin/env -i HOME="$WORK_DIR" PATH="$tool_path" TMPDIR="$WORK_DIR" \
          MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS_MAJOR}.0" \
          ./configure --disable-gui --disable-static --prefix="$WORK_DIR/prefix" >"$build_log" 2>&1 && \
        /usr/bin/env -i HOME="$WORK_DIR" PATH="$tool_path" TMPDIR="$WORK_DIR" \
          MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS_MAJOR}.0" \
          "$MAKE" -j"$cpus" >>"$build_log" 2>&1); then
    say "    Last lines of the build output:"
    /usr/bin/tail -n 25 "$build_log" | /usr/bin/sed 's/^/      /'
    die "The iODBC library did not build." "Nothing has been changed."
  fi

  BUILT_LIB="$WORK_DIR/libiodbc.2.dylib"
  /bin/cp "$src/iodbc/.libs/libiodbc.2.dylib" "$BUILT_LIB" || die "The build did not produce libiodbc.2.dylib."
  "$INSTALL_NAME_TOOL" -id "$NEW_REF" "$BUILT_LIB" 2>/dev/null || die "Could not set the library's name."
  /usr/bin/codesign --force --sign - "$BUILT_LIB" >/dev/null 2>&1 || die "Could not sign the library."
  check_library "$BUILT_LIB"
}

check_library() {
  local lib="$1" archs header listing id_line deps
  archs="$("$LIPO" -archs "$lib" 2>/dev/null)"
  case " $archs " in *" arm64 "*) ;; *) die "The built library has no Apple silicon code ($archs)." ;; esac

  header="$("$OTOOL" -hv "$lib" 2>/dev/null)"
  case "$header" in *TWOLEVEL*) ;; *) die "The built library uses the legacy linking mode. It will not be used." ;; esac

  listing="$("$OTOOL" -L "$lib" 2>/dev/null)"
  id_line="$(printf '%s\n' "$listing" | /usr/bin/sed -n 2p)"
  case "$id_line" in
    *"$NEW_REF (compatibility version $REQUIRED_COMPAT,"*) ;;
    *) die "The built library does not declare compatibility version $REQUIRED_COMPAT, which Vectorworks requires." ;;
  esac

  # The library may only depend on core parts of macOS.
  deps="$(printf '%s\n' "$listing" | /usr/bin/awk 'NR > 2 {print $1}' | \
          /usr/bin/grep -v -x -e /usr/lib/libSystem.B.dylib \
                              -e /System/Library/Frameworks/Carbon.framework/Versions/A/Carbon)"
  [ -z "$deps" ] || die "The built library depends on something unexpected: $deps"

  /usr/bin/codesign --verify --strict "$lib" >/dev/null 2>&1 || die "The built library's signature is not valid."
  ok "Library built: iODBC $IODBC_VERSION, Apple silicon, compatibility version $REQUIRED_COMPAT"
}

# Every iODBC function the Support plug-in uses must exist in the library we
# built, otherwise Vectorworks would fail at launch with a missing symbol.
check_symbols() {
  local executable="$1" lib="$2" imports exports missing
  imports="$("$NM" -arch arm64 -m "$executable" 2>/dev/null)" || die "Could not read the Support plug-in's imports."
  imports="$(printf '%s\n' "$imports" | /usr/bin/awk '/\(from libiodbc\)/ {
      for (i = 1; i <= NF; i++) if ($i == "(from") print $(i-1) }' | LC_ALL=C /usr/bin/sort -u)"
  [ -n "$imports" ] || die "Could not find which iODBC functions the Support plug-in uses. Nothing has been changed."
  exports="$("$NM" -gU "$lib" 2>/dev/null | /usr/bin/awk '{print $3}' | LC_ALL=C /usr/bin/sort -u)"
  missing="$(LC_ALL=C /usr/bin/comm -23 <(printf '%s\n' "$imports") <(printf '%s\n' "$exports"))"
  if [ -n "$missing" ]; then
    die "The library is missing functions the Support plug-in needs:" "$missing" "Nothing has been changed."
  fi
  ok "All $(printf '%s\n' "$imports" | /usr/bin/wc -l | /usr/bin/tr -d ' ') iODBC functions the plug-in uses are present"
}

# ---------------------------------------------------- swapping the plug-in ---

# Creates a hidden staging folder beside the plug-in and puts its path in
# NEW_STAGING. It is not called in a subshell, so cleanup can track it.
new_staging_dir() {
  NEW_STAGING="$(/usr/bin/mktemp -d "$(dirname "$1")/.vwfix-staging.XXXXXX")" || return 1
  STAGING_DIRS="$STAGING_DIRS
$NEW_STAGING"
}

# Replaces $1 (the installed plug-in) with $2, keeping the original at $3.
# Both moves are renames within the same folder, so each is instantaneous.
swap_bundle() {
  local bundle="$1" replacement="$2" previous="$3"
  SWAP_BUNDLE="$bundle"
  SWAP_PREVIOUS="$previous"
  /bin/mv "$bundle" "$previous" || { SWAP_BUNDLE=""; return 1; }
  if ! /bin/mv "$replacement" "$bundle"; then
    /bin/mv "$previous" "$bundle"
    SWAP_BUNDLE=""
    return 1
  fi
  return 0
}

undo_swap() {
  local bundle="$1" previous="$2" failed="$3"
  /bin/mv "$bundle" "$failed" && /bin/mv "$previous" "$bundle"
}

# --------------------------------------------------------------- backups -----

make_backup() {
  local install="$1" bundle="$2" executable="$3" root dir
  root="$BACKUP_DIR/$(basename "$install")"
  /bin/mkdir -p "$root" && /bin/chmod 700 "$STATE_DIR" "$BACKUP_DIR" 2>/dev/null
  dir="$root/$(/bin/date -u '+%Y%m%dT%H%M%SZ')"
  [ -e "$dir" ] && dir="$dir-$$"
  /bin/mkdir -p "$dir" || return 1
  /usr/bin/ditto "$bundle" "$dir/Support.vwlibrary" || return 1
  manifest_of "$dir/Support.vwlibrary" > "$dir/manifest.sha256" || return 1
  [ "$(manifest_of "$bundle")" = "$(/bin/cat "$dir/manifest.sha256")" ] || return 1
  {
    printf 'install=%s\n' "$install"
    printf 'plugin=%s\n' "$bundle"
    printf 'vectorworks=%s\n' "$(app_build_of "$install")"
    printf 'support_sha256=%s\n' "$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
    printf 'created_utc=%s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'script_version=%s\n' "$SCRIPT_VERSION"
  } > "$dir/backup-info.txt"
  printf '%s' "$dir"
}

latest_backup() {
  local root latest
  root="$BACKUP_DIR/$(basename "$1")"
  [ -d "$root" ] || return 1
  latest="$(/bin/ls -1 "$root" 2>/dev/null | LC_ALL=C /usr/bin/sort | /usr/bin/tail -n 1)"
  [ -n "$latest" ] && [ -d "$root/$latest/Support.vwlibrary" ] || return 1
  printf '%s' "$root/$latest"
}

backup_value() {
  /usr/bin/sed -n "s/^$2=//p" "$1/backup-info.txt" 2>/dev/null | /usr/bin/head -n 1
}

# ----------------------------------------------------------------- apply -----

# Copies the built library into the staged plug-in, owned like the plug-in.
add_library() {
  local staged="$1" owner="$2" frameworks="$1/Contents/Frameworks"
  /bin/mkdir -p "$frameworks" || return 1
  /bin/cp "$BUILT_LIB" "$frameworks/libiodbc.2.dylib" || return 1
  /bin/chmod 755 "$frameworks" "$frameworks/libiodbc.2.dylib" || return 1
  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    /usr/sbin/chown -R "$owner" "$frameworks" || return 1
  fi
}

apply_one() {
  local install="$1" name bundle executable owner backup staging staged
  name="$(basename "$install")"
  bundle="$(support_bundle_of "$install")"
  executable="$(support_exec_of "$bundle")"
  step "Fixing $name"

  if ! /usr/bin/codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
    warn "The Support plug-in's original signature does not verify, so it may already have been altered."
    warn "Reinstall or update Vectorworks $name, then run this again."
    return 1
  fi
  ok "Original Support plug-in is intact and signed"

  check_symbols "$executable" "$BUILT_LIB"

  backup="$(make_backup "$install" "$bundle" "$executable")" || { warn "Could not create a verified backup. $name has not been changed."; return 1; }
  ok "Backup saved: $backup"

  new_staging_dir "$bundle" || { warn "Could not create a staging folder. $name has not been changed."; return 1; }
  staging="$NEW_STAGING"
  staged="$staging/Support.vwlibrary"
  /usr/bin/ditto "$bundle" "$staged" || { warn "Could not copy the plug-in. $name has not been changed."; return 1; }

  owner="$(/usr/bin/stat -f '%u:%g' "$executable")"
  if ! add_library "$staged" "$owner"; then
    warn "Could not add the library to the plug-in. $name has not been changed."
    return 1
  fi

  if ! "$INSTALL_NAME_TOOL" -change "$OLD_REF" "$NEW_REF" "$(support_exec_of "$staged")" 2>/dev/null; then
    warn "Could not update the plug-in's library reference. $name has not been changed."
    return 1
  fi
  if [ "$(iodbc_refs "$(support_exec_of "$staged")")" != "$NEW_REF $REQUIRED_COMPAT" ]; then
    warn "The plug-in's library reference did not update as expected. $name has not been changed."
    return 1
  fi
  ok "Library added and reference updated (in a staging copy)"

  # Sign from the inside out: the library first, then the plug-in that contains it.
  if ! /usr/bin/codesign --force --sign - "$staged/Contents/Frameworks/libiodbc.2.dylib" >/dev/null 2>&1 || \
     ! /usr/bin/codesign --force --sign - "$staged" >/dev/null 2>&1 || \
     ! /usr/bin/codesign --verify --deep --strict "$staged" >/dev/null 2>&1; then
    warn "Could not sign the updated plug-in. $name has not been changed."
    return 1
  fi
  ok "Updated plug-in signed and verified"

  if ! swap_bundle "$bundle" "$staged" "$staging/Support.vwlibrary.original"; then
    warn "Could not put the updated plug-in in place. $name has not been changed."
    return 1
  fi
  if [ "$(classify "$install")" != "fixed" ]; then
    undo_swap "$bundle" "$staging/Support.vwlibrary.original" "$staging/Support.vwlibrary.failed"
    SWAP_BUNDLE=""
    warn "The installed plug-in did not pass the final check. The original has been put back."
    return 1
  fi
  SWAP_BUNDLE=""
  /bin/rm -rf "$staging"
  ok "$name is fixed"
  return 0
}

do_apply() {
  local targets="$1" install failed=0 results=""
  step "Making sure Vectorworks is closed"
  while IFS= read -r install; do
    [ -n "$install" ] || continue
    if vectorworks_running "$install"; then
      die "$(basename "$install") is running." \
          "Save your work, quit Vectorworks, and run this again. Nothing has been changed."
    fi
  done <<EOF
$targets
EOF
  ok "Vectorworks is not running"

  build_library

  while IFS= read -r install; do
    [ -n "$install" ] || continue
    if apply_one "$install"; then
      results="$results
    $(basename "$install"): fixed"
    else
      results="$results
    $(basename "$install"): NOT FIXED (unchanged, see above)"
      failed=1
    fi
  done <<EOF
$targets
EOF

  step "Result"
  say "$results"
  if [ "$failed" -ne 0 ]; then
    say ""
    say "Something did not complete. Do not edit Vectorworks by hand; send the log to Stabilise."
    exit "$EXIT_ERROR"
  fi
  cat <<EOF

Open Vectorworks and check that it starts, is still licensed, and can open
and save a file. A Vectorworks update replaces the Support plug-in and undoes
this fix; run the script again after any update.

Backups: $BACKUP_DIR
EOF
}

# -------------------------------------------------------------- rollback -----

rollback_one() {
  local install="$1" name bundle backup recorded current staging staged
  name="$(basename "$install")"
  bundle="$(support_bundle_of "$install")"
  step "Rolling back $name"

  backup="$(latest_backup "$install")" || { warn "No backup was found for $name in $BACKUP_DIR."; return 1; }
  info "Using backup: $backup"

  recorded="$(backup_value "$backup" vectorworks)"
  current="$(app_build_of "$install")"
  if [ "$recorded" != "$current" ]; then
    warn "The backup was taken from Vectorworks $recorded, but $current is installed now."
    warn "Restoring it would mix versions. Reinstall or update Vectorworks instead."
    return 1
  fi

  if [ "$(manifest_of "$backup/Support.vwlibrary")" != "$(/bin/cat "$backup/manifest.sha256" 2>/dev/null)" ]; then
    warn "The backup's contents do not match its checksums. Nothing has been restored."
    return 1
  fi
  ok "Backup is complete and unaltered"

  new_staging_dir "$bundle" || { warn "Could not create a staging folder."; return 1; }
  staging="$NEW_STAGING"
  staged="$staging/Support.vwlibrary"
  /usr/bin/ditto "$backup/Support.vwlibrary" "$staged" || { warn "Could not copy the backup."; return 1; }
  if ! /usr/bin/codesign --verify --deep --strict "$staged" >/dev/null 2>&1; then
    warn "The backup's original signature does not verify. Nothing has been restored."
    return 1
  fi

  if ! swap_bundle "$bundle" "$staged" "$staging/Support.vwlibrary.fixed"; then
    warn "Could not put the original plug-in back. $name has not been changed."
    return 1
  fi
  if [ "$(classify "$install")" != "affected" ]; then
    undo_swap "$bundle" "$staging/Support.vwlibrary.fixed" "$staging/Support.vwlibrary.failed"
    SWAP_BUNDLE=""
    warn "The restored plug-in did not pass the final check. The fixed version has been put back."
    return 1
  fi
  SWAP_BUNDLE=""
  /bin/rm -rf "$staging"
  ok "$name has its original Support plug-in again"
  return 0
}

do_rollback() {
  local targets="$1" install failed=0
  while IFS= read -r install; do
    [ -n "$install" ] || continue
    if vectorworks_running "$install"; then
      die "$(basename "$install") is running." \
          "Save your work, quit Vectorworks, and run this again. Nothing has been changed."
    fi
  done <<EOF
$targets
EOF

  while IFS= read -r install; do
    [ -n "$install" ] || continue
    rollback_one "$install" || failed=1
  done <<EOF
$targets
EOF

  step "Result"
  if [ "$failed" -ne 0 ]; then
    say "At least one rollback did not complete. See the messages above."
    exit "$EXIT_ERROR"
  fi
  say "Rollback complete. On macOS $MIN_MACOS_MAJOR, Vectorworks will fail to start again until it is fixed or updated."
}

# ------------------------------------------------------------------ main -----

main() {
  parse_args "$@"
  check_root
  start_log
  check_mac
  check_tools

  step "Looking for Vectorworks in $APPS_DIR"
  local installs install state line affected="" fixed="" attention=0
  installs="$(list_installs)"
  if [ -z "$installs" ]; then
    if [ -n "$ONLY" ]; then
      die "No Vectorworks installation called \"$ONLY\" was found in $APPS_DIR."
    fi
    say "    No Vectorworks installation was found. Nothing to do."
    exit "$EXIT_OK"
  fi

  while IFS= read -r install; do
    [ -n "$install" ] || continue
    state="$(classify "$install")"
    line="$(basename "$install"), version $(app_build_of "$install"): $(describe_state "$state")"
    case "$state" in
      affected) affected="$affected
$install"; attention=1; info "$line" ;;
      fixed)    fixed="$fixed
$install"; ok "$line" ;;
      damaged)  fixed="$fixed
$install"; attention=1; warn "$line" ;;
      homebrew|unexpected) warn "$line" ;;
      *)        ok "$line" ;;
    esac
  done <<EOF
$installs
EOF

  case "$MODE" in
    check)
      step "Result"
      if [ "$attention" -eq 1 ]; then
        say "At least one installation needs the fix or needs attention. Run with --apply to fix it."
        exit "$EXIT_NEEDS_FIX"
      fi
      say "Nothing needs fixing."
      exit "$EXIT_OK"
      ;;
    apply)
      if [ -z "$affected" ]; then
        step "Result"
        say "Nothing needs fixing."
        exit "$EXIT_OK"
      fi
      say ""
      say "The fix will be applied to:"
      printf '%s\n' "$affected" | /usr/bin/sed -n 's|.*/|    |p'
      confirm "Continue?" || die "Cancelled. Nothing has been changed."
      do_apply "$affected"
      ;;
    rollback)
      if [ -z "$fixed" ]; then
        step "Result"
        say "No installation fixed by this script was found, so there is nothing to roll back."
        exit "$EXIT_OK"
      fi
      say ""
      say "The original Support plug-in will be restored for:"
      printf '%s\n' "$fixed" | /usr/bin/sed -n 's|.*/|    |p'
      say "On macOS $MIN_MACOS_MAJOR, Vectorworks will then fail to start again."
      confirm "Continue?" || die "Cancelled. Nothing has been changed."
      do_rollback "$fixed"
      ;;
  esac
  exit "$EXIT_OK"
}

main "$@"
