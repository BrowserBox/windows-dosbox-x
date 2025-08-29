#!/usr/bin/env bash
# winpower.sh
# Cross-platform (macOS + Linux) helper to prepare persistent DOSBox-X VMs
# for Windows 95, 98, NT4, and 2000.
set -euo pipefail
# ---- config roots -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${DOSBOXX_HOME:-$HOME/dosboxx}"
VMS="$BASE/vms"
ISOS="$VMS/isos"
BOOT="$VMS/boot"
BIN="$BASE/bin"
AUTO_INSTALL_9X="${AUTO_INSTALL_9X:-1}"
# ---- debug / logging --------------------------------------------------------
DEBUG="${DOSBOXX_DEBUG:-0}"
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
if [[ "$DEBUG" == "1" ]]; then set -x; fi
say() { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die() { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
mkdirs() { mkdir -p "$VMS" "$ISOS" "$BOOT" "$BIN"; }
logfile_for() { echo "$1/last-dosboxx.log"; }
# Cross-platform ISO-8601 timestamp (UTC)
iso_now() {
  if command -v gdate >/dev/null 2>&1; then gdate -u '+%Y-%m-%dT%H:%M:%SZ'; else date -u '+%Y-%m-%dT%H:%M:%SZ'; fi
}
run_dbx() {
  # $1 = vm dir (for log), rest = dosbox-x args
  local vm="$1"; shift
  local log; log="$(logfile_for "$vm")"
  : >"$log"
  {
    echo "=== $(iso_now) ==="
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
    Linux) echo "linux";;
    *) die "Unsupported OS: $(uname -s)";;
  esac
}
install_dosboxx() {
  if command -v dosbox-x >/dev/null 2>&1; then
    say "DOSBox-X already installed"; return
  fi
  local os; os="$(detect_os)"
  if [ "$os" = "mac" ]; then
    command -v brew >/dev/null 2>&1 || die "Install Homebrew from https://brew.sh then re-run."
    say "Installing DOSBox-X via Homebrew..."
    brew update >/dev/null || true
    brew install dosbox-x || brew install --cask dosbox-x-app
  else
    if command -v apt-get >/dev/null 2>&1; then
      say "Installing DOSBox-X via apt..."
      sudo apt-get update -y
      sudo apt-get install -y dosbox-x || { warn "apt failed; trying Snap."; command -v snap >/dev/null 2>&1 || sudo apt-get install -y snapd; sudo snap install dosbox-x; }
    elif command -v dnf >/dev/null 2>&1; then
      say "Installing DOSBox-X via dnf..."
      sudo dnf install -y dosbox-x || { warn "dnf failed; trying Snap."; command -v snap >/dev/null 2>&1 || sudo dnf install -y snapd; sudo snap install dosbox-x; }
    elif command -v pacman >/dev/null 2>&1; then
      say "Installing DOSBox-X via pacman..."
      sudo pacman -Sy --noconfirm dosbox-x || { warn "pacman failed; trying Snap."; command -v snap >/dev/null 2>&1 || die "Install snapd, or install dosbox-x manually."; sudo snap install dosbox-x; }
    elif command -v snap >/dev/null 2>&1; then
      say "Installing DOSBox-X via Snap..."; sudo snap install dosbox-x
    else
      die "No known package manager found. Install DOSBox-X manually, then re-run."
    fi
  fi
  command -v dosbox-x >/dev/null 2>&1 || die "dosbox-x not on PATH after install."
}
# ---- ISO resolution ---------------------------------------------------------
require_iso() {
  # $1 = expected ISO filename under $ISOS
  local name="$1"; local path="$ISOS/$name"
  if [ -f "$path" ]; then echo "$path"; return; fi
  local envvar; envvar=$(echo "$name" | tr '[:lower:].' '[:upper:]_' | sed 's/\.ISO/_URL/')
  local url="${!envvar:-}"
  if [ -n "$url" ]; then
    say "Downloading $name from \$${envvar}..."
    curl -L --fail --progress-bar "$url" -o "$path"
    echo "$path"; return
  fi
  warn "Missing ISO: $path. Place your legally-obtained ISO there (or set \$$envvar)."
  exit 1
}
is_iso_bootable() {
  local iso="$1"
  local temp_vm="$BASE/temp_check"
  mkdir -p "$temp_vm"
  run_dbx "$temp_vm" -c "IMGMOUNT d \"$iso\" -t iso -ide 2m" -c "IMGMOUNT a -bootcd d" -c "EXIT" || true
  if grep -q "El Torito CD-ROM boot record not found" "$(logfile_for "$temp_vm")"; then
    rm -rf "$temp_vm"
    return 1  # not bootable
  else
    rm -rf "$temp_vm"
    return 0  # bootable
  fi
}
# ---- disk image creation (preformatted) -------------------------------------
# We create a READY-TO-USE C: (FAT) so Setup never targets Z:
make_hdd_img() {
  # $1 = vm dir, $2 = size_spec (MB number or hd_* template)
  local vm="$1" size="$2"
  local img="$vm/hdd.img"
  local log; log="$(logfile_for "$vm")"
  if [ -f "$img" ]; then say "HDD image already exists: $img"; return; fi
  mkdir -p "$vm" || die "Cannot create VM dir: $vm"
  ( : >"$vm/.write_test" ) 2>/dev/null || die "Directory not writable: $vm"; rm -f "$vm/.write_test"
  # Normalize templates to numeric MB
  if [[ "$size" =~ ^hd_ ]]; then
    case "$size" in
      hd_2gig) size="2048" ;;
      hd_4gig) size="4096" ;;
      hd_8gig) size="8192" ;;
      *) size="4096" ;;
    esac
  fi
  # Choose FAT type based on size
  local fattype="32"
  if [ "$size" -le 2048 ]; then fattype="16"; fi
  say "Creating preformatted HDD image ($size MB, FAT${fattype})..."
  # NOTE: we *do not* pass -nofs so DOSBox-X creates a FAT volume we can boot/mount as C:
  run_dbx "$vm" -c "IMGMAKE \"$img\" -t hd -size $size -fat $fattype" -c "EXIT" || true
  if [ ! -f "$img" ]; then
    die "Failed to create $img (see log: $log)"
  fi
}
# ---- conf writers -----------------------------------------------------------
write_conf() {
  # $1 = vm dir, $2 = oskey, $3 = mode (install|run), $4 = iso (opt), $5 = floppy (opt), $6 = bootable_iso (opt, for install)
  local vm="$1" oskey="$2" mode="$3" iso="${4:-}" floppy="${5:-}" bootable_iso="${6:-0}"
  local conf="$vm/${oskey}-${mode}.conf"
  local mem="64" ver="7.0" title="Windows 9x/NT VM" cpu="pentium_mmx" core="normal" vmem="8" voodoo="true"
  case "$oskey" in
    win95) mem="64"; ver="7.0"; title="Windows 95" ;;
    win98) mem="128"; ver="7.1"; title="Windows 98" ;;
    winnt4) mem="128"; ver="7.1"; title="Windows NT 4.0"; cpu="pentium"; voodoo="false" ;;
    win2000) mem="192"; ver="7.1"; title="Windows 2000"; cpu="pentium2"; voodoo="false" ;;
    *) die "Unknown OS key: $oskey" ;;
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
turbo=true
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
REM HDD (primary master) - preformatted FAT, appears as C:
IMGMOUNT c "$vm/hdd.img" -t hdd -ide 1m
EOF
  if [ "$mode" = "install" ]; then
    case "$oskey" in
      win2000)
        [ -n "$iso" ] || die "install mode needs ISO"
        cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
BOOT d:
EOF
        ;;
      winnt4)
        [ -n "$iso" ] || die "install mode needs ISO"
        [ -n "$floppy" ] || die "install mode needs a boot floppy for NT4"
        cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
IMGMOUNT a "$floppy" -t floppy
BOOT a:
EOF
        ;;
      win95|win98)
        [ -n "$iso" ] || die "install mode needs ISO"
        if [ "$bootable_iso" = "1" ]; then
          # Method 1: Boot from bootable ISO
          cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
IMGMOUNT a -bootcd d
BOOT a:
EOF
        else
          # Method 2: Non-bootable, copy and run setup
          # Decide 9x subdir and setup command from oskey
          local nine_dir="WIN95"
          local setup_cmd="SETUP"
          if [ "$oskey" = "win98" ]; then
            nine_dir="WIN98"
            setup_cmd="SETUP /IS"
          fi
          if [ "${AUTO_INSTALL_9X:-0}" = "1" ]; then
            # Auto-install path: copy files to C:\WIN9x and run setup
            cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
c:
ECHO Checking for $nine_dir on D:
IF NOT EXIST D:\\$nine_dir\\SETUP.EXE ECHO No SETUP.EXE in D:\\$nine_dir - check ISO contents or dir name
IF NOT EXIST C:\\$nine_dir MD C:\\$nine_dir
IF EXIST D:\\$nine_dir\\SETUP.EXE ECHO Starting xcopy from D:\\$nine_dir to C:\\$nine_dir
IF EXIST D:\\$nine_dir\\SETUP.EXE XCOPY D:\\$nine_dir C:\\$nine_dir /I /E >NUL
ECHO xcopy complete or skipped
c:
CD \\$nine_dir
ECHO Starting setup: $setup_cmd
$setup_cmd
PROMPT \$P\$G
EOF
          else
            # Manual path: mount and show instructions
            cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
ECHO.
ECHO === Windows 9x Install ===
ECHO Type the following commands to start setup:
ECHO d:
ECHO CD \\$nine_dir
ECHO $setup_cmd
ECHO.
PROMPT \$P\$G
EOF
          fi
        fi
        ;;
    esac
  else
    cat >>"$conf" <<'EOF'
IMGMOUNT 0 empty -fs none -t floppy
IMGMOUNT 1 empty -fs none -t floppy -size 512,15,2,80
IMGMOUNT d empty -t iso -ide 2m
BOOT c:
EOF
  fi
  say "Wrote config: $conf"
}
write_launchers() {
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
  say "Launchers: $inst | $run"
}
# ---- VM creation ------------------------------------------------------------
make_vm() {
  local oskey="$1" size="${2:-}"
  local vm="$VMS/$oskey"
  mkdir -p "$vm/capture"
  case "$oskey" in
    win95) size="${size:-2048}";; # 2GB FAT16 default
    win98) size="${size:-8192}";; # 8GB FAT32 default
    winnt4) size="${size:-4096}";; # 4GB FAT (depends on NT formatting later)
    win2000) size="${size:-8192}";; # 8GB, NT/2k formats during setup
    *) die "Unknown oskey $oskey";;
  esac
  make_hdd_img "$vm" "$size"
}
# ---- commands ---------------------------------------------------------------
cmd_setup() {
  need curl; need unzip
  mkdirs
  install_dosboxx
  say "Setup complete. Put your Windows ISOs in: $ISOS"
  say " Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso"
}
cmd_new() {
  local oskey="${1:-}"; shift || true
  [ -n "${oskey:-}" ] || die "Usage: $0 new <win95|win98|winnt4|win2000> [size_mb]"
  make_vm "$oskey" "${1:-}"
  write_conf "$VMS/$oskey" "$oskey" "run"
  write_launchers "$VMS/$oskey" "$oskey"
}
cmd_attach_iso() {
  local oskey="${1:-}"; local iso_path="${2:-}"
  [ -n "$oskey" ] && [ -n "$iso_path" ] || die "Usage: $0 attach-iso <oskey> </path/to.iso>"
  [ -f "$iso_path" ] || die "ISO not found: $iso_path"
  cp -f "$iso_path" "$ISOS/" || die "Copy failed"
  local copied_name="$(basename "$iso_path")"
  local expected=""
  case "$oskey" in
    win95) expected="Win95.iso" ;;
    win98) expected="Win98SE.iso" ;;
    winnt4) expected="WinNT4.iso" ;;
    win2000) expected="Win2000.iso" ;;
    *) die "Unknown oskey for expected ISO name: $oskey" ;;
  esac
  if [ "$copied_name" != "$expected" ]; then
    mv "$ISOS/$copied_name" "$ISOS/$expected" || die "Rename failed"
    say "Renamed to $ISOS/$expected for consistency"
  fi
  say "Copied ISO to $ISOS/$expected"
}
cmd_install() {
  local oskey="${1:-}"; [ -n "$oskey" ] || die "Usage: $0 install <oskey>"
  mkdirs; install_dosboxx
  make_vm "$oskey"
  local iso="" floppy="" bootable_iso=0
  case "$oskey" in
    win95)
      iso="$(require_iso Win95.iso)"
      # Force method 2 for Win95 per guide
      bootable_iso=0
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso" "" "$bootable_iso"
      ;;
    win98)
      iso="$(require_iso Win98SE.iso)"
      is_iso_bootable "$iso" && bootable_iso=1
      write_conf "$VMS/$oskey" "$oskey" "install" "$iso" "" "$bootable_iso"
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
  setup Install DOSBox-X, create folders
  new <win95|win98|winnt4|win2000> [size_mb]
                              Create a new VM folder and preformatted HDD image
  attach-iso <oskey> </path/to.iso>
                              Copy a local ISO into $ISOS
  install <oskey> Write install config and start the installer
  start <oskey> Boot from the installed HDD image
  help Show this help
Environment:
  DOSBOXX_HOME Base directory (default: $HOME/dosboxx)
  DOSBOXX_DEBUG=1 Verbose shell + DOSBox-X logging
  AUTO_INSTALL_9X=1 For Win95/98: auto copy setup files to C: and run SETUP
  *_ISO_URL Optional per-ISO URLs, e.g. WIN98SE_ISO_URL
Notes:
  • ISOs go in $ISOS (Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso)
  • NT4 needs a boot floppy at $BOOT/nt4-boot.img
  • Logs: $VMS/<oskey>/last-dosboxx.log
EOF
}
# ---- main -------------------------------------------------------------------
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup) cmd_setup ;;
  new) cmd_new "$@" ;;
  attach-iso) cmd_attach_iso "$@" ;;
  install) cmd_install "$@" ;;
  start) cmd_start "$@" ;;
  help|--help|-h) cmd_help ;;
  *) die "Unknown command: $cmd (try: help)";;
esac
