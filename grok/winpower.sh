#!/usr/bin/env bash
# winpower.sh
# Cross-platform (macOS + Linux) helper to prepare persistent DOSBox-X VMs
# for Windows 95, 98, NT4, and 2000 + permanent Ultima 8 mounting
set -euo pipefail

# ---- config roots -----------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${DOSBOXX_HOME:-$HOME/dosboxx}"
VMS="$BASE/vms"
ISOS="$VMS/isos"
BOOT="$VMS/boot"
SHARED="$VMS/shared"          # NEW: permanent shared data (Ultima 8 CD, etc.)
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
mkdirs() { mkdir -p "$VMS" "$ISOS" "$BOOT" "$BIN" "$SHARED"; }
logfile_for() { echo "$1/last-dosboxx.log"; }

# Cross-platform ISO-8601 timestamp (UTC)
iso_now() {
  if command -v gdate >/dev/null 2>&1; then gdate -u '+%Y-%m-%dT%H:%M:%SZ'; else date -u '+%Y-%m-%dT%H:%M:%SZ'; fi
}

run_dbx() {
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
    return 1
  else
    rm -rf "$temp_vm"
    return 0
  fi
}

# ---- disk image creation ----------------------------------------------------
make_hdd_img() {
  local vm="$1" size="$2"
  local img="$vm/hdd.img"
  local log; log="$(logfile_for "$vm")"
  if [ -f "$img" ]; then say "HDD image already exists: $img"; return; fi
  mkdir -p "$vm" || die "Cannot create VM dir: $vm"
  ( : >"$vm/.write_test" ) 2>/dev/null || die "Directory not writable: $vm"; rm -f "$vm/.write_test"
  if [[ "$size" =~ ^hd_ ]]; then
    case "$size" in
      hd_2gig) size="2048" ;;
      hd_4gig) size="4096" ;;
      hd_8gig) size="8192" ;;
      *) size="4096" ;;
    esac
  fi
  local fattype="32"
  if [ "$size" -le 2048 ]; then fattype="16"; fi
  say "Creating preformatted HDD image ($size MB, FAT${fattype})..."
  run_dbx "$vm" -c "IMGMAKE \"$img\" -t hd -size $size -fat $fattype" -c "EXIT" || true
  if [ ! -f "$img" ]; then
    die "Failed to create $img (see log: $log)"
  fi
}

# ---- conf writers -----------------------------------------------------------
write_conf() {
  local vm="$1" oskey="$2" mode="$3" iso="${4:-}" floppy="${5:-}" bootable_iso="${6:-0}"
  local conf="$vm/${oskey}-${mode}.conf"
  local mem="64" ver="7.0" title="Windows 9x/NT VM" cpu="pentium_mmx" core="normal" vmem="8" voodoo="true"
  case "$oskey" in
    win95) mem="64"; ver="7.0"; title="Windows 95" ;;
    win98) mem="64"; ver="7.1"; title="Windows 98 + Ultima 8"; cpu="pentium_mmx"; core="dynamic_x86" ;;
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
cycles=max 95%
[sblaster]
sbtype=sb16vibra
sbbase=220
irq=7
dma=1
hdl=5
sbmixer=true
oplmode=auto
oplrate=49716
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
[ne2000]
ne2000=true
nicirq=10
backend=slirp
[autoexec]
@echo off
REM HDD (primary master)
IMGMOUNT c "$vm/hdd.img" -t hdd -ide 1m

REM === Permanent Ultima 8 CD (if present) ===
IF EXIST "$SHARED/ultima8-cd" MOUNT d "$SHARED/ultima8-cd" -t cdrom -label ULTIMA8
IF EXIST "$ISOS/Ultima8.iso" IMGMOUNT d "$ISOS/Ultima8.iso" -t iso

REM Floppy drives
IMGMOUNT 0 empty -fs none -t floppy
IMGMOUNT 1 empty -fs none -t floppy -size 512,15,2,80

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
          cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
IMGMOUNT a -bootcd d
BOOT a:
EOF
        else
          local nine_dir="WIN95"
          local setup_cmd="SETUP"
          if [ "$oskey" = "win98" ]; then
            nine_dir="WIN98"
            setup_cmd="SETUP /IS"
          fi
          if [ "${AUTO_INSTALL_9X:-0}" = "1" ]; then
            cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
c:
IF NOT EXIST C:\\$nine_dir MD C:\\$nine_dir
IF EXIST D:\\$nine_dir\\SETUP.EXE XCOPY D:\\$nine_dir C:\\$nine_dir /I /E >NUL
c:
CD \\$nine_dir
$setup_cmd
PROMPT \$P\$G
EOF
          else
            cat >>"$conf" <<EOF
IMGMOUNT d "$iso" -t iso -ide 2m
ECHO.
ECHO === Windows 9x Install ===
ECHO Type: d:
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
    cat >>"$conf" <<EOF
BOOT -l c
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
    win95) size="${size:-2048}";;
    win98) size="${size:-8192}";;
    winnt4) size="${size:-4096}";;
    win2000) size="${size:-8192}";;
    *) die "Unknown oskey $oskey";;
  esac
  make_hdd_img "$vm" "$size"
}

# ---- NEW: Ultima 8 permanent mount command (IMPROVED) -----------------------
cmd_ultima8_mount() {
  local src="${1:-}"
  [[ -n "$src" ]] || die "Usage: $0 ultima8-mount </path/to/GOG-folder-or-Ultima8.iso>"

  mkdirs
  local target_folder="$SHARED/ultima8-cd"

  # 1. If source is a folder → copy it (this is the preferred way)
  if [[ -d "$src" ]]; then
    say "Copying Ultima 8 GOG folder → permanent location..."
    rm -rf "$target_folder"
    cp -a "$src" "$target_folder"
    say "Ultima 8 CD permanently available at $target_folder"

  # 2. If source is an .iso → copy it
  elif [[ -f "$src" && "$src" =~ \.iso$ ]]; then
    say "Copying Ultima 8 ISO → $ISOS/Ultima8.iso"
    cp -f "$src" "$ISOS/Ultima8.iso"
    say "ISO ready at $ISOS/Ultima8.iso"

  else
    die "Source must be a folder (GOG install) or an .iso file"
  fi

  # 3. ALWAYS regenerate win98-run.conf with the CORRECT priority
  if [[ -d "$VMS/win98" ]]; then
    say "Regenerating win98-run.conf with correct Ultima 8 mount order..."
    write_conf "$VMS/win98" "win98" "run"
  else
    warn "No win98 VM found yet – create one first with: $0 new win98"
  fi

  say "PERMANENTLY FIXED! D: will now always be your Ultima 8 CD/ISO."
}

# ---- commands ---------------------------------------------------------------
cmd_setup() {
  need curl; need unzip
  mkdirs
  install_dosboxx
  say "Setup complete. Put your Windows ISOs in: $ISOS"
}

cmd_new() {
  local oskey="${1:-}"; shift || true
  [ -n "$oskey" ] || die "Usage: $0 new <win95|win98|winnt4|win2000> [size_mb]"
  make_vm "$oskey" "${1:-}"
  write_conf "$VMS/$oskey" "$oskey" "run"
  write_launchers "$VMS/$oskey" "$oskey"
}

cmd_attach_iso() {
  local oskey="${1:-}"; local iso_path="${2:-}"
  [ -n "$oskey" ] && [ -n "$iso_path" ] || die "Usage: $0 attach-iso <oskey> </path/to.iso>"
  [ -f "$iso_path" ] || die "ISO not found: $iso_path"
  cp -f "$iso_path" "$ISOS/" || die "Copy failed"
  say "Copied ISO to $ISOS"
}

cmd_install() {
  local oskey="${1:-}"; [ -n "$oskey" ] || die "Usage: $0 install <oskey>"
  mkdirs; install_dosboxx
  make_vm "$oskey"
  local iso="" floppy="" bootable_iso=0
  case "$oskey" in
    win95)
      iso="$(require_iso Win95.iso)"
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
  setup                 Install DOSBox-X + create folders
  new <oskey> [size]    Create new VM + HDD
  attach-iso <oskey> <path>
  install <oskey>       Write install config + launch
  start <oskey>         Boot installed VM
  ultima8-mount </path/to/GOG-folder-or-Ultima8.iso>
                        Permanently mount Ultima 8 as D: in your Win98 VM
  help                  This help
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
  ultima8-mount) cmd_ultima8_mount "$@" ;;
  help|--help|-h) cmd_help ;;
  *) die "Unknown command: $cmd (try: help)";;
esac
