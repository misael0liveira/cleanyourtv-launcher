#!/usr/bin/env bash
# Build the CleanYourTV launcher and install it on an Android/Google TV over ADB.
#
# Two things this script does that the repo's own build-and-install.sh does not:
#   1. It can build on an ARM64 (aarch64) machine, where Google's aapt2 binary
#      is x86_64-only and the Gradle build dies with "AAPT2 Daemon startup failed".
#      It installs qemu-user and stages a private x86_64 sysroot, then points
#      Gradle at a wrapper that runs aapt2 under emulation.
#   2. It disables the previously installed third-party launcher (e.g. FLauncher)
#      after the new home is confirmed working, so the TV is not left with two
#      launchers fighting over the Home button.
#
# Usage:
#   TV_HOST=192.168.0.4 ./install-launcher.sh
#
# Environment:
#   TV_HOST            TV IP address (required)
#   TV_PORT            ADB port (default 5555)
#   REPO               path to the cleanyourtv checkout (default: ./cleanyourtv)
#   DISABLE_PREV_LAUNCHER   set to 0 to keep the old launcher enabled
#   EXTRA_DISABLE      space-separated packages to disable after the install
#   SKIP_BUILD         set to 1 to install an APK that is already built
#   APK                APK to install when SKIP_BUILD=1
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")" && pwd)/cleanyourtv}"
TV_HOST="${TV_HOST:-}"
TV_PORT="${TV_PORT:-5555}"
DISABLE_PREV_LAUNCHER="${DISABLE_PREV_LAUNCHER:-1}"
EXTRA_DISABLE="${EXTRA_DISABLE:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$TV_HOST" ] || die "Set TV_HOST to the TV's IP, e.g. TV_HOST=192.168.0.4 $0"
[ -d "$REPO" ] || die "cleanyourtv checkout not found at $REPO (set REPO=...)"
[ -d "$REPO/launcher" ] || die "$REPO does not look like a cleanyourtv checkout"

# ---------------------------------------------------------------- architecture

ARCH="$(uname -m)"
AAPT2_WRAPPER=""
QEMU_SYSROOT=""

# Google's aapt2 (as shipped by AGP 8.x) is a linux-x86_64 binary. On any other
# architecture the Gradle build fails at mergeResources with
# "AAPT2 ... Daemon startup failed", which reads like a corrupt SDK but is just
# a missing ELF loader. Detect the mismatch and set up emulation.
detect_aapt2() {
  local cache="$HOME/.gradle/caches"
  [ -d "$cache" ] || return 1
  # Any aapt2 under the Gradle cache is the one the build will use.
  find "$cache" -path '*aapt2*' -name aapt2 -type f 2>/dev/null | head -1
}

aapt2_machine() {
  # e_machine at ELF offset 18: 3 = i386, 62 = x86_64, 183 = aarch64
  od -An -j 18 -N 2 -t u2 "$1" 2>/dev/null | tr -d ' \n'
}

setup_arm64_aapt2() {
  [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ] || return 1
  log "Host is ARM64; Google's aapt2 is x86_64-only. Setting up qemu emulation."

  if ! command -v qemu-x86_64 >/dev/null 2>&1; then
    log "Installing qemu-user"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y qemu-user
    else
      die "Install qemu-user manually (e.g. 'apt-get install qemu-user') and re-run"
    fi
  fi

  # A private x86_64 sysroot: the host's own libc is ARM64 and cannot be used to
  # run an x86_64 binary. Nothing is installed into the host's /usr.
  QEMU_SYSROOT="${QEMU_SYSROOT:-/root/x86_64-root}"
  if [ ! -e "$QEMU_SYSROOT/lib64/ld-linux-x86-64.so.2" ]; then
    log "Staging x86_64 sysroot in $QEMU_SYSROOT"
    mkdir -p "$QEMU_SYSROOT"
    local tmp; tmp="$(mktemp -d)"
    (
      cd "$tmp"
      # Ubuntu's arm64 ports mirror has no amd64 packages, so pull them from the
      # main archive instead.
      local base="http://archive.ubuntu.com/ubuntu"
      local libc_ver libgcc_ver
      libc_ver=$(curl -s "$base/dists/resolute/main/binary-amd64/Packages.gz" \
        | zcat | awk '/^Package: libc6$/,/^$/' | awk '/^Version:/{print $2; exit}')
      libgcc_ver=$(curl -s "$base/dists/resolute/main/binary-amd64/Packages.gz" \
        | zcat | awk '/^Package: libgcc-s1$/,/^$/' | awk '/^Version:/{print $2; exit}')
      [ -n "$libc_ver" ] || { echo "could not find libc6 version"; exit 1; }
      curl -sSL -o libc6.deb "$base/pool/main/g/glibc/libc6_${libc_ver}_amd64.deb"
      ar x libc6.deb && tar -xf data.tar.* -C "$QEMU_SYSROOT" && rm -f data.tar.*
      # libgcc_s.so.1 lives in libgcc-s1, not in gcc-15; the version string differs.
      local libgcc_path
      libgcc_path=$(curl -s "$base/dists/resolute/main/binary-amd64/Packages.gz" \
        | zcat | awk '/^Package: libgcc-s1$/,/^$/' | awk '/^Filename:/{print $2; exit}')
      if [ -n "$libgcc_path" ]; then
        curl -sSL -o libgcc.deb "$base/$libgcc_path"
        ar x libgcc.deb && tar -xf data.tar.* -C "$QEMU_SYSROOT" && rm -f data.tar.*
      fi
    )
    rm -rf "$tmp"
    mkdir -p "$QEMU_SYSROOT/lib64"
    ln -sf "$QEMU_SYSROOT/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" \
            "$QEMU_SYSROOT/lib64/ld-linux-x86-64.so.2"
  fi

  local real_aapt2; real_aapt2="$(detect_aapt2)"
  [ -n "$real_aapt2" ] || die "Could not find aapt2 in the Gradle cache; run a build first"

  log "Writing aapt2 wrapper for $real_aapt2"
  AAPT2_WRAPPER="/usr/local/bin/aapt2"
  cat > "$AAPT2_WRAPPER" <<EOF
#!/bin/bash
# Generated by install-launcher.sh: run the x86_64 aapt2 under qemu on ARM64.
exec qemu-x86_64 -L "$QEMU_SYSROOT" "$real_aapt2" "\$@"
EOF
  chmod +x "$AAPT2_WRAPPER"

  # Global Gradle property: no change to the repo's own gradle.properties.
  mkdir -p "$HOME/.gradle"
  printf 'android.aapt2FromMavenOverride=%s\n' "$AAPT2_WRAPPER" \
    > "$HOME/.gradle/gradle.properties"
  log "Gradle aapt2 override set in ~/.gradle/gradle.properties"
}

setup_aapt2() {
  local real; real="$(detect_aapt2)"
  if [ -z "$real" ]; then
    log "No cached aapt2 yet; the first build will download one."
    return 0
  fi
  local machine; machine="$(aapt2_machine "$real")"
  case "$ARCH" in
    x86_64) log "Host is x86_64; aapt2 matches." ;;
    *)
      if [ "$machine" = "62" ]; then
        setup_arm64_aapt2
      else
        warn "aapt2 machine type is $machine, host is $ARCH; not a known mismatch."
      fi ;;
  esac
}

# ------------------------------------------------------------------- adb bits

adb_cmd() {
  if command -v adb >/dev/null 2>&1; then
    adb -s "$TV_HOST:$TV_PORT" "$@"
  else
    # Fall back to the repo's pure-python client (needs tools/venv).
    local py="$REPO/tools/venv/bin/python"
    [ -x "$py" ] || py="$REPO/tools/venv/Scripts/python.exe"
    [ -x "$py" ] || die "No adb binary and no tools/venv. Install adb or run: python3 -m venv tools/venv && tools/venv/bin/pip install -r tools/requirements.txt"
    TV_HOST="$TV_HOST" TV_PORT="$TV_PORT" "$py" -I "$REPO/tools/tv.py" "$@"
  fi
}

connect_tv() {
  log "Connecting to $TV_HOST:$TV_PORT"
  if command -v adb >/dev/null 2>&1; then
    adb connect "$TV_HOST:$TV_PORT" >/dev/null 2>&1 || true
    # "No route to host" is usually a stale adb server rather than a real
    # network problem: the socket is open but the server holds a bad route.
    if ! adb -s "$TV_HOST:$TV_PORT" get-state >/dev/null 2>&1; then
      warn "adb could not reach the TV; restarting the adb server"
      adb kill-server >/dev/null 2>&1 || true
      sleep 2
      adb start-server >/dev/null 2>&1
      adb connect "$TV_HOST:$TV_PORT" >/dev/null 2>&1 || true
    fi
    adb -s "$TV_HOST:$TV_PORT" get-state >/dev/null 2>&1 \
      || die "Cannot reach the TV at $TV_HOST:$TV_PORT. Check the IP and that USB debugging is on."
    echo "Connected: $(adb -s "$TV_HOST:$TV_PORT" shell getprop ro.product.model | tr -d '\r')"
  else
    die "tv.py fallback needs tools/venv; see the message above."
  fi
}

# ------------------------------------------------------------------- the steps

build_apk() {
  log "Building the launcher (release)"
  setup_aapt2
  cd "$REPO/launcher"
  ./gradlew assembleRelease --console=plain
  APK="$REPO/launcher/app/build/outputs/apk/release/app-release.apk"
  [ -f "$APK" ] || die "Build finished but $APK is missing"
  log "Built $APK ($(du -h "$APK" | cut -f1))"
}

install_apk() {
  log "Installing the launcher"
  adb_cmd push "$APK" /data/local/tmp/tvhome.apk >/dev/null
  local out; out="$(adb_cmd shell 'pm install -r /data/local/tmp/tvhome.apk; rm -f /data/local/tmp/tvhome.apk' | tr -d '\r')"
  echo "$out"
  case "$out" in
    *Success*) ;;
    *) die "pm install failed; nothing else was changed." ;;
  esac
}

start_launcher() {
  log "Starting the launcher"
  local out; out="$(adb_cmd shell 'am start -W -n com.gathin.tvhome/.MainActivity' | tr -d '\r')"
  echo "$out"
  case "$out" in
    *"Status: ok"*) ;;
    *) die "The launcher did not start; the old launcher was left enabled." ;;
  esac
}

set_home() {
  log "Setting the launcher as the default Home"
  adb_cmd shell 'cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity' | tr -d '\r'
  local now; now="$(adb_cmd shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' 2>/dev/null | tail -n 1 | tr -d '\r')"
  case "$now" in
    com.gathin.tvhome/*) log "Home now resolves to $now" ;;
    *) warn "Home resolves to '${now:-nothing}', not to the new launcher." ;;
  esac
}

disable_package() {
  local pkg="$1"
  adb_cmd shell "pm disable-user --user 0 $pkg" 2>/dev/null | tr -d '\r' | sed 's/^/    /'
}

disable_prev_launcher() {
  [ "$DISABLE_PREV_LAUNCHER" = "1" ] || { log "Keeping the previous launcher enabled"; return 0; }
  log "Looking for another launcher to disable"
  local prev
  prev="$(adb_cmd shell 'cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME' 2>/dev/null \
    | tr -d '\r' | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+' | cut -d/ -f1 | sort -u \
    | grep -vE '^(com\.gathin\.tvhome|com\.android\.tv\.settings)$' || true)"
  if [ -z "$prev" ]; then
    log "No other launcher claims Home; nothing to disable."
    return 0
  fi
  for pkg in $prev; do
    log "Disabling $pkg"
    disable_package "$pkg"
  done
}

disable_extra() {
  [ -n "$EXTRA_DISABLE" ] || return 0
  log "Disabling extra packages: $EXTRA_DISABLE"
  for pkg in $EXTRA_DISABLE; do
    disable_package "$pkg"
  done
}

verify() {
  log "Verifying"
  local resumed home
  resumed="$(adb_cmd shell 'dumpsys activity activities | grep topResumedActivity' 2>/dev/null | tr -d '\r')"
  home="$(adb_cmd shell 'cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME' 2>/dev/null | tail -n 1 | tr -d '\r')"
  echo "    Home:       $home"
  echo "    Foreground: $resumed"
  adb_cmd shell 'input keyevent KEYCODE_HOME' >/dev/null 2>&1 || true
  sleep 2
  resumed="$(adb_cmd shell 'dumpsys activity activities | grep topResumedActivity' 2>/dev/null | tr -d '\r')"
  echo "    After HOME: $resumed"
  case "$resumed" in
    *com.gathin.tvhome*) log "The HOME key opens the new launcher." ;;
    *) warn "The HOME key did not open the new launcher." ;;
  esac
  local crashes
  crashes="$(adb_cmd shell 'logcat -d -b crash -t 50 2>/dev/null | grep -i gathin' 2>/dev/null || true)"
  if [ -n "$crashes" ]; then
    warn "Crash log mentions the launcher:"
    echo "$crashes"
  else
    log "No crashes in the crash buffer."
  fi
}

# ----------------------------------------------------------------------- main

APK="${APK:-}"
if [ "$SKIP_BUILD" = "1" ]; then
  [ -n "$APK" ] || die "SKIP_BUILD=1 needs APK=<path to apk>"
  [ -f "$APK" ] || die "APK not found: $APK"
  log "Skipping build; using $APK"
else
  build_apk
fi

connect_tv
install_apk
start_launcher
set_home
disable_prev_launcher
disable_extra
verify

log "Done. Press Home on the remote."
