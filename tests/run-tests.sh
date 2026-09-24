#!/bin/bash
# shellcheck disable=SC2015  # "check && pass || fail" is intended throughout
#
# Automated tests for vectorworks-iodbc-fix.sh.
#
# Builds small stand-in Vectorworks installations in a temporary folder and
# runs the real script against them. The stand-in Support plug-in is compiled
# to depend on /usr/lib/libiodbc.2.dylib exactly as Vectorworks does, and calls
# a real iODBC function, so after the fix it is loaded and called to prove the
# bundled library works.
#
# Needs an Apple silicon Mac on macOS 27 with the Command Line Tools. Runs as
# a normal user; nothing outside the temporary folder is touched.
#
#   ./tests/run-tests.sh

set -u -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/vectorworks-iodbc-fix.sh"
EA="$ROOT/jamf/extension-attribute.sh"
T="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vwfix-tests.XXXXXX")"
trap '/bin/rm -rf "$T"' EXIT

export VWFIX_APPS_DIR="$T/Applications"
export VWFIX_STATE_DIR="$T/State"
export VWFIX_LOG_FILE="$T/fix.log"
export VWFIX_ALLOW_NON_ROOT=1

OLD_REF="/usr/lib/libiodbc.2.dylib"
NEW_REF="@loader_path/../Frameworks/libiodbc.2.dylib"
HOMEBREW_REF="/opt/homebrew/opt/libiodbc/lib/libiodbc.2.dylib"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | /usr/bin/sed 's/^/        /'; }

# Runs the script, capturing output in OUT and the exit code in CODE.
run() { OUT="$("$SCRIPT" "$@" </dev/null 2>&1)"; CODE=$?; }

expect_code() { if [ "$CODE" -eq "$2" ]; then pass "$1"; else fail "$1 (exit $CODE, expected $2)" "$OUT"; fi; }
expect_ea()   { local got; got="$(/bin/bash "$EA")"; if [ "$got" = "<result>$2</result>" ]; then pass "$1"; else fail "$1 (got $got)"; fi; }
expect_out()  { case "$OUT" in *"$2"*) pass "$1" ;; *) fail "$1 (output lacks: $2)" "$OUT" ;; esac; }

support_of() { printf '%s' "$VWFIX_APPS_DIR/$1/Plug-ins/Support.vwlibrary"; }
refs_of()    { /usr/bin/otool -arch "${2:-arm64}" -L "$(support_of "$1")/Contents/MacOS/Support" | /usr/bin/awk 'NR > 1 && /libiodbc/ {print $1}'; }

# ------------------------------------------------------------- fixtures ------

FIX="$T/fixture-src"
/bin/mkdir -p "$FIX"

# Stand-in for the old system library, used only to link the fake plug-in.
cat > "$FIX/stub.c" <<'EOF'
short SQLAllocHandle(short type, void *input, void **output) { (void)type; (void)input; *output = 0; return -1; }
short SQLFreeHandle(short type, void *handle) { (void)type; (void)handle; return 0; }
EOF

# Stand-in Support plug-in. vw_probe() allocates and frees an ODBC environment
# handle, which only succeeds against a real iODBC library.
cat > "$FIX/support.c" <<'EOF'
short SQLAllocHandle(short type, void *input, void **output);
short SQLFreeHandle(short type, void *handle);
int vw_probe(void) {
  void *env = 0;
  short rc = SQLAllocHandle(1, 0, &env);
  if (rc != 0 || env == 0) return 1;
  SQLFreeHandle(1, env);
  return 0;
}
EOF

cat > "$FIX/plain.c" <<'EOF'
int vw_probe(void) { return 0; }
EOF

# Loads a plug-in's executable and calls vw_probe().
cat > "$FIX/probe.c" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
  void *h = dlopen(argv[1], RTLD_NOW);
  if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
  int (*probe)(void) = (int (*)(void))dlsym(h, "vw_probe");
  if (!probe) { printf("vw_probe not found\n"); return 3; }
  return probe();
}
EOF

ARCHS="-arch arm64 -arch x86_64"
# shellcheck disable=SC2086
{
  cc $ARCHS -dynamiclib -install_name "$OLD_REF" -compatibility_version 4.0.0 -current_version 4.31.0 \
     "$FIX/stub.c" -o "$FIX/libiodbc.2.dylib" &&
  cc $ARCHS -bundle -Wl,-headerpad_max_install_names "$FIX/support.c" "$FIX/libiodbc.2.dylib" -o "$FIX/Support.iodbc" &&
  cc $ARCHS -bundle "$FIX/plain.c" -o "$FIX/Support.plain" &&
  cc -arch arm64 "$FIX/probe.c" -o "$FIX/probe"
} || { printf 'Could not compile the test fixtures.\n'; exit 1; }

# make_install NAME BUILD SUPPORT_BINARY
make_install() {
  local dir="$VWFIX_APPS_DIR/$1" bundle
  bundle="$dir/Plug-ins/Support.vwlibrary"
  /bin/mkdir -p "$dir/$1.app/Contents" "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
  cat > "$dir/$1.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.vectorworks.app</string>
<key>CFBundleShortVersionString</key><string>${1##* }.0.8</string>
<key>CFBundleVersion</key><string>$2</string>
</dict></plist>
EOF
  cat > "$bundle/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Support</string>
<key>CFBundleIdentifier</key><string>test.vectorworks.support</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
EOF
  printf 'resource\n' > "$bundle/Contents/Resources/strings.txt"
  /bin/cp "$3" "$bundle/Contents/MacOS/Support"
  /usr/bin/codesign --force --sign - "$bundle" >/dev/null 2>&1
}

reset_installs() {
  /bin/rm -rf "$VWFIX_APPS_DIR" "$VWFIX_STATE_DIR"
  make_install "Vectorworks 2025" 790100 "$FIX/Support.iodbc"
  make_install "Vectorworks 2024" 700200 "$FIX/Support.plain"
}

set_build() {
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $2" "$VWFIX_APPS_DIR/$1/$1.app/Contents/Info.plist"
}

# ----------------------------------------------------------------- tests -----

printf 'Running tests in %s\n\n' "$T"
reset_installs
ORIGINAL_SHA="$(/usr/bin/shasum -a 256 "$(support_of "Vectorworks 2025")/Contents/MacOS/Support" | /usr/bin/awk '{print $1}')"

printf 'Safety checks\n'
OUT="$(env -u VWFIX_ALLOW_NON_ROOT "$SCRIPT" --check </dev/null 2>&1)"; CODE=$?
expect_code "refuses to run without administrator rights" 1
expect_out  "explains how to run it with sudo" "sudo"

run --bogus
expect_code "rejects an unknown option" 2

run --only "/Applications/Vectorworks 2025"
expect_code "rejects a path given to --only" 2

run --apply
expect_code "will not apply without confirmation when nobody can answer" 1
expect_out  "says --yes is needed for unattended use" "--yes"
[ "$(refs_of "Vectorworks 2025")" = "$OLD_REF" ] && pass "nothing changed after the refusal" || fail "nothing changed after the refusal"

printf '\nChecking\n'
run --check
expect_code "check reports that a fix is needed (exit 10)" 10
expect_out  "check lists the affected installation" "Vectorworks 2025, version 2025.0.8 (790100): Needs the fix"
expect_out  "check lists the unaffected installation" "Vectorworks 2024, version 2024.0.8 (700200): Not affected"

run / "TEST-MAC" "testuser" "--check"
expect_code "accepts Jamf Pro's argument layout" 10
expect_ea   "Jamf extension attribute reports Needs Fix" "Needs Fix"

run / "TEST-MAC" "testuser" "--check" "Vectorworks 2024"
expect_code "Jamf parameter 5 limits the run to one installation" 0
expect_out  "and handles the space in its name" "Vectorworks 2024, version"
case "$OUT" in *"Vectorworks 2025, version"*) fail "Jamf parameter 5 excludes other installations" "$OUT" ;; *) pass "Jamf parameter 5 excludes other installations" ;; esac

run / "TEST-MAC" "testuser" "" ""
expect_code "Jamf with no parameters applies the fix" 0
expect_out  "without waiting for an answer" "Continue? [yes, unattended]"
reset_installs

run --check --only "Vectorworks 2030"
expect_code "fails clearly for an unknown --only name" 1

printf '\nRefusing to work on a running copy\n'
FAKE_BIN="$VWFIX_APPS_DIR/Vectorworks 2025/Vectorworks 2025.app/Contents/MacOS/Vectorworks 2025"
/bin/bash -c "exec -a \"$FAKE_BIN\" /bin/sleep 60" &
FAKE_PID=$!
sleep 1
run --apply --yes
kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null
expect_code "refuses while Vectorworks is running" 1
expect_out  "tells the user to quit Vectorworks" "quit Vectorworks"
[ "$(refs_of "Vectorworks 2025")" = "$OLD_REF" ] && pass "nothing changed while it was running" || fail "nothing changed while it was running"

printf '\nApplying the fix\n'
run --apply --yes
expect_code "apply succeeds" 0
expect_out  "apply reports the installation as fixed" "Vectorworks 2025: fixed"
[ "$(refs_of "Vectorworks 2025" arm64)" = "$NEW_REF" ] && pass "Apple silicon code points at the bundled library" || fail "Apple silicon code points at the bundled library" "$(refs_of "Vectorworks 2025")"
[ "$(refs_of "Vectorworks 2025" x86_64)" = "$NEW_REF" ] && pass "Intel code points at the bundled library too" || fail "Intel code points at the bundled library too"
[ -f "$(support_of "Vectorworks 2025")/Contents/Frameworks/libiodbc.2.dylib" ] && pass "library placed in Contents/Frameworks" || fail "library placed in Contents/Frameworks"
/usr/bin/codesign --verify --deep --strict "$(support_of "Vectorworks 2025")" 2>/dev/null && pass "fixed plug-in has a valid signature" || fail "fixed plug-in has a valid signature"
"$FIX/probe" "$(support_of "Vectorworks 2025")/Contents/MacOS/Support" >/dev/null 2>&1 && pass "fixed plug-in loads and calls real iODBC successfully" || fail "fixed plug-in loads and calls real iODBC successfully" "$("$FIX/probe" "$(support_of "Vectorworks 2025")/Contents/MacOS/Support" 2>&1)"
[ "$(refs_of "Vectorworks 2024")" = "" ] && [ ! -d "$(support_of "Vectorworks 2024")/Contents/Frameworks" ] && pass "unaffected installation left alone" || fail "unaffected installation left alone"
BACKUPS="$(/bin/ls -1 "$VWFIX_STATE_DIR/backups/Vectorworks 2025" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[ "$BACKUPS" = "1" ] && pass "one backup created" || fail "one backup created ($BACKUPS)"
B="$VWFIX_STATE_DIR/backups/Vectorworks 2025/$(/bin/ls -1 "$VWFIX_STATE_DIR/backups/Vectorworks 2025" | /usr/bin/tail -n 1)"
[ "$(/usr/bin/shasum -a 256 "$B/Support.vwlibrary/Contents/MacOS/Support" | /usr/bin/awk '{print $1}')" = "$ORIGINAL_SHA" ] && pass "backup holds the original Support file" || fail "backup holds the original Support file"
/usr/bin/grep -q '^vectorworks=2025.0.8 (790100)$' "$B/backup-info.txt" && pass "backup records the Vectorworks version" || fail "backup records the Vectorworks version"
LEFTOVER="$(/usr/bin/find "$VWFIX_APPS_DIR" -name '.vwfix-staging.*' | /usr/bin/head -n 1)"
[ -z "$LEFTOVER" ] && pass "no staging folders left behind" || fail "no staging folders left behind" "$LEFTOVER"

printf '\nRunning again\n'
run --apply --yes
expect_code "second apply succeeds" 0
expect_out  "second apply has nothing to do" "Nothing needs fixing."
BACKUPS="$(/bin/ls -1 "$VWFIX_STATE_DIR/backups/Vectorworks 2025" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[ "$BACKUPS" = "1" ] && pass "second apply creates no new backup" || fail "second apply creates no new backup ($BACKUPS)"
run --check
expect_code "check after the fix reports nothing to do (exit 0)" 0
expect_ea   "Jamf extension attribute reports Fixed" "Fixed"
expect_out  "check shows the installation as fixed" "Vectorworks 2025, version 2025.0.8 (790100): Fixed"

printf '\nDetecting damage\n'
LIB="$(support_of "Vectorworks 2025")/Contents/Frameworks/libiodbc.2.dylib"
/bin/mv "$LIB" "$T/lib.aside"
run --check
expect_code "check flags a fix whose library has gone" 10
expect_out  "check describes it as damaged" "Fixed, but damaged"
/bin/mv "$T/lib.aside" "$LIB"

printf '\nRolling back\n'
set_build "Vectorworks 2025" 790999
run --rollback --yes
expect_code "rollback refuses when Vectorworks has changed version" 1
expect_out  "rollback explains the version mismatch" "Restoring it would mix versions"
[ "$(refs_of "Vectorworks 2025")" = "$NEW_REF" ] && pass "fix still in place after the refusal" || fail "fix still in place after the refusal"
set_build "Vectorworks 2025" 790100

run --rollback --yes
expect_code "rollback succeeds" 0
[ "$(refs_of "Vectorworks 2025")" = "$OLD_REF" ] && pass "original library reference restored" || fail "original library reference restored"
[ "$(/usr/bin/shasum -a 256 "$(support_of "Vectorworks 2025")/Contents/MacOS/Support" | /usr/bin/awk '{print $1}')" = "$ORIGINAL_SHA" ] && pass "original Support file restored exactly" || fail "original Support file restored exactly"
[ ! -d "$(support_of "Vectorworks 2025")/Contents/Frameworks" ] && pass "bundled library removed" || fail "bundled library removed"
/usr/bin/codesign --verify --deep --strict "$(support_of "Vectorworks 2025")" 2>/dev/null && pass "original signature valid again" || fail "original signature valid again"
run --check
expect_code "check after rollback reports a fix is needed again" 10

printf '\nOther setups\n'
reset_installs
HB="$(support_of "Vectorworks 2025")/Contents/MacOS/Support"
/usr/bin/install_name_tool -change "$OLD_REF" "$HOMEBREW_REF" "$HB" 2>/dev/null
/usr/bin/codesign --force --sign - "$(support_of "Vectorworks 2025")" >/dev/null 2>&1
run --apply --yes
expect_code "a Homebrew-patched install is not an error" 0
expect_out  "a Homebrew-patched install is reported" "Patched by the community Homebrew method"
[ "$(refs_of "Vectorworks 2025")" = "$HOMEBREW_REF" ] && pass "a Homebrew-patched install is left alone" || fail "a Homebrew-patched install is left alone"
expect_ea   "Jamf extension attribute reports the Homebrew method" "Patched By Homebrew Method"

reset_installs
printf 'altered\n' >> "$(support_of "Vectorworks 2025")/Contents/Resources/strings.txt"
run --apply --yes
expect_code "apply refuses a plug-in whose signature is broken" 1
expect_out  "and says why" "original signature does not verify"
[ "$(refs_of "Vectorworks 2025")" = "$OLD_REF" ] && pass "the altered plug-in is unchanged" || fail "the altered plug-in is unchanged"

printf '\nSource integrity\n'
reset_installs
COPY="$T/tampered"
/bin/mkdir -p "$COPY/vendor"
/bin/cp "$SCRIPT" "$COPY/"
printf 'not the real source\n' > "$COPY/vendor/libiodbc-3.52.16.tar.gz"
OUT="$("$COPY/vectorworks-iodbc-fix.sh" --apply --yes </dev/null 2>&1)"; CODE=$?
expect_code "refuses source that fails its checksum" 1
expect_out  "explains the checksum failure" "does not match its published checksum"
[ "$(refs_of "Vectorworks 2025")" = "$OLD_REF" ] && pass "nothing changed with bad source" || fail "nothing changed with bad source"

/bin/rm -rf "$VWFIX_APPS_DIR"
/bin/mkdir -p "$VWFIX_APPS_DIR"
expect_ea   "Jamf extension attribute reports No Vectorworks" "No Vectorworks"
make_install "Vectorworks 2024" 700200 "$FIX/Support.plain"
expect_ea   "Jamf extension attribute reports Not Affected" "Not Affected"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
