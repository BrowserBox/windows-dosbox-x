#!/usr/bin/env bash
# setup.sh
# Cross-platform (macOS + Linux) helper to prepare persistent DOSBox-X VMs
# for Windows 95, 98, NT4, and 2000. Requires: bash, curl, unzip.

set -euo pipefail

# ---- config roots -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${DOSBOXX_HOME:-$HOME/dosboxx}"
VMS="$BASE/vms"
ISOS="$VMS/isos"
BOOT="$VMS/boot"
BIN="$BASE/bin"

# ---- debug / logging --------------------------------------------------------
DEBUG="${DOSBOXX_DEBUG:-0}"
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
if [[ "$DEBUG" == "1" ]]; then set -x; fi

say()  { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
mkdirs() { mkdir -p "$VMS" "$ISOS" "$BOOT" "$BIN"; }

logfile_for() { echo "$1/last-dosboxx.log"; }

run_dbx() {
  # Capture all dosbox-x output.
  # $1 = vm dir (for log), rest are dosbox-x args
  local vm="$1"; shift
  local log; log="$(logfile_for "$vm")"
  : >"$log"
  {
    echo "=== $(date -Is) ==="
    echo "cmd: dosbox-x $*"
    echo "cwd: $(pwd)"
    echo "===================="
  } >>"$log"
  if [[ "$DEBUG" == "1" ]]; then
    dosbox-x "$@" 2>&1 | tee -a "$log"
  else
    dosbox-x "$@" >>"$log" 2>&1
  fi
  local rc=$?
  echo "=== exit $rc ===" >>"$log"
  return $rc
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo "mac";;
    Linux)  echo "linux";;
    *)      die "Unsupported OS: $(uname -s)";;
  esac
}

install_dosboxx() {
  if command -v dosbox-x >/dev/null 2>&1; then
    say "DOSBox-X already installed"
    return
  fi

  local os; os="$(detect_os)"
  if [ "$os" = "mac" ]; then
    if command -v brew >/dev/null 2>&1; then
      say "Installing DOSBox-X via Homebrew..."
      brew update >/dev/null || true
      brew install dosbox-x || brew install --cask dosbox-x-app
    else
      die "Homebrew not found. Install from https://brew.sh then re-run."
    fi
  else
    if command -v apt-get >/dev/null 2>&1; then
      say "Installing DOSBox-X via apt..."
      sudo apt-get update -y
      sudo apt-get install -y dosbox-x || {
        warn "apt failed; trying Snap."
        command -v snap >/dev/null 2>&1 || sudo apt-get install -y snapd
        sudo snap install dosbox-x
      }
    elif command -v dnf >/dev/null 2>&1; then
      say "Installing DOSBox-X via dnf..."
      sudo dnf install -y dosbox-x || {
        warn "dnf failed; trying Snap."
        command -v snap >/dev/null 2>&1 || sudo dnf install -y snapd
        sudo snap install dosbox-x
      }
    elif command -v pacman >/dev/null 2>&1; then
      say "Installing DOSBox-X via pacman..."
      sudo pacman -Sy --noconfirm dosbox-x || {
        warn "pacman failed; trying Snap."
        command -v snap >/dev/null 2>&1 || die "Install snapd, or install dosbox-x manually."
        sudo snap install dosbox-x
      }
    elif command -v snap >/dev/null 2>&1; then
      say "Installing DOSBox-X via Snap..."
      sudo snap install dosbox-x
    else
      die "No known package manager found. Install DOSBox-X manually, then re-run."
    fi
  fi

  command -v dosbox-x >/dev/null 2>&1 || die "dosbox-x not on PATH after install."
}

# ---- assets (FreeDOS floppies for 9x installs) ------------------------------
fetch_freedos_floppies() {
  local z="$BOOT/FD13-FloppyEdition.zip"
  local dest_dir="$BOOT/freedos-floppies"
  if [ -d "$dest_dir" ] && [ -n "$(ls -A "$dest_dir" 2>/dev/null || true)" ]; then
    say "FreeDOS floppies already present."
    return
  fi
  say "Downloading FreeDOS 1.3 Floppy Edition…"
  curl -L --fail --progress-bar \
    "https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/official/FD13-FloppyEdition.zip" \
    -o "$z"
  need unzip
  mkdir -p "$dest_dir"
  unzip -q "$z" -d "$dest_dir"
  say "FreeDOS floppies extracted to: $dest_dir"
}

# ---- ISO resolution ---------------------------------------------------------
require_iso() {
  # $1 = canonical ISO filename we expect in $ISOS (e.g., Win98SE.iso)
  local name="$1"
  local path="$ISOS/$name"
  if [ -f "$path" ]; then
    echo "$path"; return
  fi
  # Allow URL via env var (e.g., WIN98SE_ISO_URL). We do NOT provide URLs.
  local envvar; envvar=$(echo "$name" | tr '[:lower:].' '[:upper:]_' | sed 's/\.ISO/_URL/')
  local url="${!envvar:-}"
  if [ -n "$url" ]; then
    say "Downloading $name from \$${envvar}…"
    curl -L --fail --progress-bar "$url" -o "$path"
    echo "$path"; return
  fi
  warn "Missing ISO: $path. Place your legally-obtained ISO there (or set \$$envvar)."
  exit 1
}

# ---- disk image creation (with debug + fallback) ----------------------------
make_hdd_img() {
  # $1 = vm dir, $2 = size_spec (e.g., "2048" or "hd_2gig" or "hd_8gig")
  local vm="$1" size="$2"
  local img="$vm/hdd.img"
  local log; log="$(logfile_for "$vm")"

  if [ -f "$img" ]; then
    say "HDD image already exists: $img"
    return
  fi

  mkdir -p "$vm" || die "Cannot create VM dir: $vm"
  if ! ( : >"$vm/.write_test" ) 2>/dev/null; then
    die "Directory not writable: $vm (check permissions)"
  fi
  rm -f "$vm/.write_test"

  say "Creating HDD image via DOSBox-X IMGMAKE ($size)…"
  run_dbx "$vm" -c "IMGMAKE \"$img\" -t hd -size $size -nofs" -c "EXIT" || true

  if [ ! -f "$img" ]; then
    warn "IMGMAKE did not produce $img. See log: $log"
    if [[ "$size" =~ ^hd_ ]]; then
      local numeric="4096"
      case "$size" in
        hd_2gig)  numeric="2048" ;;
        hd_4gig)  numeric="4096" ;;
        hd_8gig)  numeric="8192" ;;
      esac
      warn "Retrying with numeric size ${numeric} MB…"
      run_dbx "$vm" -c "IMGMAKE \"$img\" -t hd -size $numeric -nofs" -c "EXIT" || true
    fi
  fi

  [ -f "$img" ] || die "Failed to create $img. Check log: $log"
}

# ---- conf writers -----------------------------------------------------------
write_conf() {
  # $1 = vm dir, $2 = os key, $3 = mode (install|run), $4 = iso path (opt), $5 = floppy path (opt)
  local vm="$1" oskey="$2" mode="$3" iso="${4:-}" floppy="${5:-}"
  local conf="$vm/${oskey}-${mode}.conf"

  local mem="64"
  local ver="7.0"
  local title="Windows 9x/NT VM"
  local cpu="pentium_mmx"
  local core="normal"
  local vmem="8"
  local voodoo="true"

  case "$oskey" in
    win95)   mem="64";  ver="7.0"; title="Windows 95";;
    win98)   mem="128"; ver="7.1"; title="Windows 98";;
    winnt4)  mem="128"; ver="7.1"; title="Windows NT 4.0"; cpu="pentium";   voodoo="false";;
    win2000) mem="192"; ver="7.1"; title="Windows 2000";  cpu="pentium2";  voodoo="false";;
    *) die "Unknown OS key: $oskey";;
  esac

  cat >"$conf" <<EOF
[sdl]
autolock=true

[dosbox]
title=$title
memsize=$mem
captures=$vm/capture

[video]
vmemsize=$vmem
vesa modelist width limit=0
vesa modelist height limit=0

[dos]
ver=$ver
hard drive data rate limit=0
floppy drive data rate limit=0

[cpu]
cputype=$cpu
core=$core
turbo=false

[sblaster]
sbtype=sb16vibra

[voodoo]
voodoo_card=$voodoo

[fdc, primary]
int13fakev86io=true

[ide, primary]
int13fakeio=true
int13fakev86io=true

[ide, secondary]
int13fakeio=true
int13fakev86io=true
cd-rom insertion delay=4000

[render]
scaler=none

[autoexec]
@echo off
REM HDD (primary master)
IMGMOUNT 2 "$vm/hdd.img" -t hdd -fs none -ide 1m
REM Default empty secondary CD (override in install mode)
REM IMGMOUNT D empty -t iso -ide 2m
EOF

  if [ "$mode" = "install" ]; then
    case "$oskey" in
      win2000)
        [ -n "$iso" ] || die "install mode needs ISO"
        cat >>"$conf" <<EOF
IMGMOUNT D "$iso" -t iso -ide 2m
BOOT D:
EOF
        ;;
      winnt4)
        [ -n "$iso" ] || die "install mode needs ISO"
        [ -n "$floppy" ] || die "install mode needs a boot floppy for NT4"
        cat >>"$conf" <<EOF
IMGMOUNT D "$iso" -t iso -ide 2m
IMGMOUNT A "$floppy" -t floppy
BOOT A:
EOF
        ;;
      win95|win98)
        [ -n "$iso" ] || die "install mode needs ISO"
        [ -n "$floppy" ] || die "install mode needs a boot floppy"
        cat >>"$conf" <<EOF
IMGMOUNT D "$iso" -t iso -ide 2m
IMGMOUNT A "$floppy" -t floppy
BOOT A:
ECHO.
ECHO When at a DOS prompt, run:
ECHO   D:
ECHO   CD \\WIN95 (or \\WIN98)
ECHO   SETUP      (or: SETUP /IS for Win98)
ECHO.
PAUSE
EOF
        ;;
    esac
  else
    cat >>"$conf" <<'EOF'
IMGMOUNT D empty -t iso -ide 2m
BOOT C:
EOF
  fi

  say "Wrote config: $conf"
}

write_launchers() {
  # $1 = vm dir, $2 = oskey
  local vm="$1" oskey="$2"
  local inst="$BIN/${oskey}-install.sh"
  local run="$BIN/${oskey}-start.sh"
  cat >"$inst" <<EOF
#!/usr/bin/env bash
exec dosbox-x -conf "$vm/${oskey}-install.conf"
EOF
  cat >"$run" <<EOF
#!/usr/bin/env bash
exec dosbox-x -conf "$vm/${oskey}-run.conf"
EOF
  chmod +x "$inst" "$run"
  say "Launchers: $inst  |  $run"
}

# ---- VM creation ------------------------------------------------------------
make_vm() {
  # $1=oskey  $2=size_spec
  local oskey="$1" size="${2:-}"
  local vm="$VMS/$oskey"
  mkdir -p "$vm/capture"

  case "$oskey" in
    win95)   size="${size:-hd_2gig}";;
    win98)   size="${size:-8192}";;     # numeric default for portability
    winnt4)  size="${size:-4096}";;
    win2000) size="${size:-8192}";;
    *) die "Unknown oskey $oskey";;
  esac

  make_hdd_img "$vm" "$size"
}

# ---- commands ---------------------------------------------------------------
cmd_setup() {
  need curl; need unzip
  mkdirs
  install_dosboxx
  fetch_freedos_floppies
  say "Setup complete. Put your Windows ISOs in: $ISOS"
  say "  Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso"
}

cmd_new() {
  local oskey="${1:-}"; shift || true
  [ -n "${oskey:-}" ] || die "Usage: $0 new <win95|win98|winnt4|win2000> [size_spec]"
  make_vm "$oskey" "${1:-}"
  case "$oskey" in
    win95|win98)
      write_conf "$VMS/$oskey" "$oskey" "run"
      ;;
    winnt4|win2000)
      write_conf "$VMS/$oskey" "$oskey" "run"
      ;;
  esac
  write_launchers "$VMS/$oskey" "$oskey"
}

cmd_attach_iso() {
  local oskey="${1:-}"; local iso_path="${2:-}"
  [ -n "$oskey" ] && [ -n "$iso_path" ] || die "Usage: $0 attach-iso <oskey> </path/to.iso>"
  [ -f "$iso_path" ] || die "ISO not found: $iso_path"
  cp -f "$iso_path" "$ISOS/" || die "Copy failed"
  say "Copied ISO to $ISOS/$(basename "$iso_path")"
}

cmd_install() {
  local oskey="${1:-}"; [ -n "$oskey" ] || die "Usage: $0 install <oskey>"
  mkdirs; install_dosboxx
  make_vm "$oskey"

  local iso="" floppy=""
  case "$oskey" in
    win95)
      iso="$(require_iso Win95.iso)"
      floppy="$(find "$BOOT/freedos-floppies" -type f -name '*.img' | head -n 1 || true)"
      [ -n "$floppy" ] || die "No FreeDOS floppy image found. Run '$0 setup' again."
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso" "$floppy"
      ;;
    win98)
      iso="$(require_iso Win98SE.iso)"
      floppy="$(find "$BOOT/freedos-floppies" -type f -name '*.img' | head -n 1 || true)"
      [ -n "$floppy" ] || die "No FreeDOS floppy image found. Run '$0 setup' again."
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso" "$floppy"
      ;;
    winnt4)
      iso="$(require_iso WinNT4.iso)"
      floppy="$BOOT/nt4-boot.img"
      [ -f "$floppy" ] || die "Provide an NT4 boot floppy at $floppy (or edit the conf)."
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso" "$floppy"
      ;;
    win2000)
      iso="$(require_iso Win2000.iso)"
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso"
      ;;
    *) die "Unknown OS key: $oskey";;
  esac

  write_conf "$VMS/$oskey" "$oskey" "run"
  write_launchers "$VMS/$oskey" "$oskey"

  say "Launching installer now..."
  exec dosbox-x -conf "$VMS/$oskey/${oskey}-install.conf"
}

cmd_start() {
  local oskey="${1:-}"; [ -n "$oskey" ] || die "Usage: $0 start <oskey>"
  exec dosbox-x -conf "$VMS/$oskey/${oskey}-run.conf"
}

cmd_help() {
  cat <<EOF
Usage: $0 [--debug] <command> [args]

Commands:
  setup                       Install DOSBox-X, create folders, fetch FreeDOS floppies
  new <win95|win98|winnt4|win2000> [size_spec]
                              Create a new VM folder and HDD image (size MB or IMGMAKE template)
  attach-iso <oskey> </path/to.iso>
                              Copy a local ISO into $ISOS
  install <oskey>             Write install config and start the installer
  start <oskey>               Boot from the installed HDD image
  help                        Show this help

Environment:
  DOSBOXX_HOME                Base directory (default: $HOME/dosboxx)
  DOSBOXX_DEBUG=1             Enable verbose shell + DOSBox-X logging
  *_ISO_URL                   Optional per-ISO URLs, e.g. WIN98SE_ISO_URL

Notes:
  • Put your ISOs in: $ISOS
    Expected names: Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso
  • For NT4 installs, supply a boot floppy image at $BOOT/nt4-boot.img
  • HDD images live under $VMS/<oskey>/hdd.img
  • DOSBox-X logs: $VMS/<oskey>/last-dosboxx.log

EOF
}

# ---- main -------------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)       cmd_setup ;;
  new)         cmd_new "$@" ;;
  attach-iso)  cmd_attach_iso "$@" ;;
  install)     cmd_install "$@" ;;
  start)       cmd_start "$@" ;;
  help|--help|-h) cmd_help ;;
  *)           die "Unknown command: $cmd (try: help)";;
esac

