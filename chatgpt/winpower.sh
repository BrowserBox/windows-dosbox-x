#!/usr/bin/env bash
# winpower.sh — DOSBox-X automation for Win95/98/NT4/2000
# macOS & Linux. Requires: bash, curl, unzip (curl/unzip only if you use *_ISO_URL).
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="${DOSBOXX_HOME:-$HOME/dosboxx}"
VMS="$BASE/vms"
ISOS="$VMS/isos"
BOOT="$VMS/boot"
BIN="$BASE/bin"

# ── Defaults / knobs (env overrides) ──────────────────────────────────────────
AUTO_INSTALL_9X="${AUTO_INSTALL_9X:-1}"        # 1 = copy + run setup for Win9x
WIN98_METHOD="${WIN98_METHOD:-copy}"           # copy | bootcd
WIN95_METHOD="${WIN95_METHOD:-copy}"           # copy | bootcd (most 95 CDs aren’t bootable)
DOSBOXX_CORE_INSTALL="${DOSBOXX_CORE_INSTALL:-normal}"      # normal (per guide)
DOSBOXX_CORE_RUN="${DOSBOXX_CORE_RUN:-dynamic_x86}"         # faster after install
DOSBOXX_TURBO_RUN="${DOSBOXX_TURBO_RUN:-false}"             # true to fast-forward boot
NET_BACKEND="${NET_BACKEND:-}"                 # slirp | pcap | "" (disabled)
NET_IRQ="${NET_IRQ:-10}"                       # guide uses 10
DEBUG="${DOSBOXX_DEBUG:-0}"

# ── Small utils ───────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--debug" ]]; then DEBUG=1; shift; fi
if [[ "$DEBUG" == "1" ]]; then set -x; fi

say()  { printf "\033[1;32m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }
mkdirs(){ mkdir -p "$VMS" "$ISOS" "$BOOT" "$BIN"; }
logfile_for(){ echo "$1/last-dosboxx.log"; }

iso_now(){ if command -v gdate >/dev/null 2>&1; then gdate -u '+%Y-%m-%dT%H:%M:%SZ'; else date -u '+%Y-%m-%dT%H:%M:%SZ'; fi; }

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
  echo "=== exit $? ===" >>"$log"
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo mac;;
    Linux)  echo linux;;
    *) die "Unsupported OS: $(uname -s)";;
  esac
}

install_dosboxx() {
  if command -v dosbox-x >/dev/null 2>&1; then say "DOSBox-X already installed"; return; fi
  local os; os="$(detect_os)"
  if [[ $os == mac ]]; then
    command -v brew >/dev/null 2>&1 || die "Install Homebrew from https://brew.sh"
    say "Installing DOSBox-X (brew)…"
    brew update >/dev/null || true
    brew install dosbox-x || brew install --cask dosbox-x-app
  else
    if command -v apt-get >/dev/null 2>&1; then
      say "Installing DOSBox-X (apt)…"
      sudo apt-get update -y
      sudo apt-get install -y dosbox-x || { warn "apt failed; trying snap"; command -v snap >/dev/null 2>&1 || sudo apt-get install -y snapd; sudo snap install dosbox-x; }
    elif command -v dnf >/dev/null 2>&1; then
      say "Installing DOSBox-X (dnf)…"
      sudo dnf install -y dosbox-x || { warn "dnf failed; trying snap"; command -v snap >/dev/null 2>&1 || sudo dnf install -y snapd; sudo snap install dosbox-x; }
    elif command -v pacman >/dev/null 2>&1; then
      say "Installing DOSBox-X (pacman)…"
      sudo pacman -Sy --noconfirm dosbox-x || { warn "pacman failed; trying snap"; command -v snap >/dev/null 2>&1 || die "Install snapd manually"; sudo snap install dosbox-x; }
    elif command -v snap >/dev/null 2>&1; then
      say "Installing DOSBox-X (snap)…"; sudo snap install dosbox-x
    else
      die "No known package manager. Install DOSBox-X manually."
    fi
  fi
  command -v dosbox-x >/dev/null 2>&1 || die "dosbox-x not on PATH after install."
}

# ── ISO helper ────────────────────────────────────────────────────────────────
require_iso() {
  local name="$1"; local path="$ISOS/$name"
  if [[ -f "$path" ]]; then echo "$path"; return; fi
  local envvar; envvar=$(echo "$name" | tr '[:lower:].' '[:upper:]_' | sed 's/\.ISO/_URL/')
  local url="${!envvar:-}"
  if [[ -n "$url" ]]; then
    need curl
    say "Downloading $name from \$${envvar}…"
    curl -L --fail --progress-bar "$url" -o "$path"
    echo "$path"; return
  fi
  die "Missing ISO: $path (or set \$$envvar)"
}

# ── Disk images (pre-formatted FAT) ──────────────────────────────────────────
make_hdd_img() {
  local vm="$1" size="$2"
  local img="$vm/hdd.img"
  [[ -f "$img" ]] && { say "HDD exists: $img"; return; }
  mkdir -p "$vm" || die "Cannot create $vm"
  ( : >"$vm/.w" ) 2>/dev/null || die "VM dir not writable: $vm"; rm -f "$vm/.w"

  # Normalize templates
  if [[ "$size" =~ ^hd_ ]]; then
    case "$size" in
      hd_2gig) size=2048 ;;
      hd_4gig) size=4096 ;;
      hd_8gig) size=8192 ;;
      *)       size=4096 ;;
    esac
  fi
  local fattype=32; [[ "$size" -le 2048 ]] && fattype=16
  say "Creating HDD ($size MB, FAT$fattype)…"
  run_dbx "$vm" -c "IMGMAKE \"$img\" -t hd -size $size -fat $fattype" -c "EXIT"
  [[ -f "$img" ]] || die "IMGMAKE failed (see: $(logfile_for "$vm"))"
}

# ── Config writer ────────────────────────────────────────────────────────────
write_conf() {
  # $1 vmdir  $2 oskey  $3 mode install|run  $4 iso?  $5 floppy?
  local vm="$1" oskey="$2" mode="$3" iso="${4:-}" floppy="${5:-}"
  local conf="$vm/${oskey}-${mode}.conf"

  # Common knobs from the guide
  local mem=64 ver=7.0 title="Windows 9x/NT VM" cpu=pentium_mmx core="$DOSBOXX_CORE_INSTALL" vmem=8 voodoo=true turbo=false
  [[ "$mode" == run ]] && core="$DOSBOXX_CORE_RUN"
  [[ "$mode" == run && "$DOSBOXX_TURBO_RUN" == true ]] && turbo=true

  case "$oskey" in
    win95)   mem=64  ver=7.0 title="Windows 95" ;;
    win98)   mem=128 ver=7.1 title="Windows 98" ;;
    winnt4)  mem=128 ver=7.1 title="Windows NT 4.0"; cpu=pentium; voodoo=false ;;
    win2000) mem=192 ver=7.1 title="Windows 2000";  cpu=pentium2; voodoo=false ;;
    *) die "Unknown OS: $oskey" ;;
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
turbo=$turbo

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
EOF

  # Optional networking (per guide)
  if [[ -n "$NET_BACKEND" ]]; then
    cat >>"$conf" <<EOF

[ne2000]
ne2000=true
nicirq=$NET_IRQ
backend=$NET_BACKEND
EOF
    if [[ "$NET_BACKEND" == pcap ]]; then
      cat >>"$conf" <<'EOF'

[ethernet, pcap]
realnic=list
EOF
    fi
  fi

  # Autoexec differs per mode/OS
  echo -e "\n[autoexec]\n@echo off" >>"$conf"

  if [[ "$mode" == install ]]; then
    case "$oskey" in
      win98|win95)
        [[ -n "$iso" ]] || die "install mode needs ISO"

        local nine_dir=WIN95 setup_cmd="SETUP"
        [[ "$oskey" == win98 ]] && { nine_dir=WIN98; setup_cmd="SETUP /IS"; }

        if [[ "${AUTO_INSTALL_9X:-1}" == 1 && "${oskey}" == "win98" && "${WIN98_METHOD}" == "bootcd" ]] \
           || [[ "${AUTO_INSTALL_9X:-1}" == 1 && "${oskey}" == "win95" && "${WIN95_METHOD}" == "bootcd" ]]; then
          # Method 1 (guide): Bootable CD (OEM Full). Let the CD boot its DOS, partition/format, run setup.
          cat >>"$conf" <<EOF
REM Bootable CD install (El Torito)
IMGMOUNT D "$iso" -t iso -ide 2m
IMGMOUNT A -bootcd D
BOOT A:
EOF
        else
          # Method 2 (guide): Copy files to C and run setup from C (needs C: visible → mount FAT)
          cat >>"$conf" <<EOF
REM Non-bootable CD install: copy files to C and run setup
IMGMOUNT C "$vm/hdd.img" -t hdd -fs fat
IMGMOUNT D "$iso" -t iso -ide 2m
C:
IF NOT EXIST C:\\$nine_dir MD C:\\$nine_dir
IF EXIST D:\\$nine_dir\\SETUP.EXE XCOPY D:\\$nine_dir C:\\$nine_dir /I /E >NUL
C:
CD \\$nine_dir
$setup_cmd
PROMPT \$P\$G
EOF
        fi
        ;;
      win2000)
        [[ -n "$iso" ]] || die "install mode needs ISO"
        # Win2k boots from CD
        cat >>"$conf" <<EOF
IMGMOUNT D "$iso" -t iso -ide 2m
BOOT D:
EOF
        ;;
      winnt4)
        [[ -n "$iso" ]] || die "install mode needs ISO"
        [[ -n "${floppy:-}" ]] || die "Need NT4 boot floppy at $BOOT/nt4-boot.img"
        cat >>"$conf" <<EOF
IMGMOUNT D "$iso" -t iso -ide 2m
IMGMOUNT A "$floppy" -t floppy
BOOT A:
EOF
        ;;
    esac
  else
    # RUN mode: boot HDD (BIOS), and attach empty drives so Win9x keeps A:/D: (per guide)
    cat >>"$conf" <<'EOF'
IMGMOUNT 0 empty -fs none -t floppy
IMGMOUNT 1 empty -fs none -t floppy -size 512,15,2,80
IMGMOUNT 2 "hdd.img" -t hdd -fs none -ide 1m
IMGMOUNT D empty -t iso -ide 2m
BOOT C:
EOF
  fi

  say "Wrote config: $conf"
}

write_launchers() {
  local vm="$1" oskey="$2"
  local inst="$BIN/${oskey}-install.sh" run="$BIN/${oskey}-start.sh"
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

# ── VM creation ───────────────────────────────────────────────────────────────
make_vm() {
  local oskey="$1" size="${2:-}"
  local vm="$VMS/$oskey"
  mkdir -p "$vm/capture"

  case "$oskey" in
    win95)   size="${size:-2048}";;   # 2GB FAT16 (guide OK)
    win98)   size="${size:-8192}";;   # 8GB FAT32 (guide example)
    winnt4)  size="${size:-4096}";;
    win2000) size="${size:-8192}";;
    *) die "Unknown os: $oskey";;
  esac

  make_hdd_img "$vm" "$size"
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd_setup() {
  mkdirs
  install_dosboxx
  say "Place ISOs in: $ISOS"
  say "  Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso"
}

cmd_new() {
  local oskey="${1:-}"; shift || true
  [[ -n "$oskey" ]] || die "Usage: $0 new <win95|win98|winnt4|win2000> [size_mb]"
  make_vm "$oskey" "${1:-}"
  write_conf "$VMS/$oskey" "$oskey" run            # run config (post-install)
  write_launchers "$VMS/$oskey" "$oskey"
}

cmd_install() {
  local oskey="${1:-}"; [[ -n "$oskey" ]] || die "Usage: $0 install <oskey>"
  mkdirs; install_dosboxx; make_vm "$oskey"

  local iso="" floppy=""
  case "$oskey" in
    win95)   iso="$(require_iso Win95.iso)" ;;
    win98)   iso="$(require_iso Win98SE.iso)" ;;
    winnt4)  iso="$(require_iso WinNT4.iso)";  floppy="$BOOT/nt4-boot.img" ;;
    win2000) iso="$(require_iso Win2000.iso)" ;;
  esac

  write_conf "$VMS/$oskey" "$oskey" install "$iso" "${floppy:-}"
  write_conf "$VMS/$oskey" "$oskey" run
  write_launchers "$VMS/$oskey" "$oskey"

  say "Launching installer…"
  exec dosbox-x -conf "$VMS/$oskey/${oskey}-install.conf"
}

cmd_start() {
  local oskey="${1:-}"; [[ -n "$oskey" ]] || die "Usage: $0 start <oskey>"
  exec dosbox-x -conf "$VMS/$oskey/${oskey}-run.conf"
}

cmd_help() {
  cat <<EOF
Usage: $0 [--debug] <command> [args]

Commands
  setup                                Install DOSBox-X, create folders
  new <win95|win98|winnt4|win2000> [size_mb]
                                       Create VM and preformatted HDD image
  install <oskey>                      Write install/run configs & start installer
  start <oskey>                        Boot from installed HDD

Environment knobs
  DOSBOXX_HOME                         Base dir (default: $HOME/dosboxx)
  DOSBOXX_DEBUG=1                      Verbose shell + DOSBox-X logging
  AUTO_INSTALL_9X=1                    Win95/98: auto copy files to C: and run setup
  WIN98_METHOD=copy|bootcd             Choose guide's Method 2 or Method 1 (default copy)
  WIN95_METHOD=copy|bootcd             Same for Win95 (most CDs not bootable)
  DOSBOXX_CORE_INSTALL=normal          Install with normal core (guide recommendation)
  DOSBOXX_CORE_RUN=dynamic_x86         Run with dynamic_x86 after install
  DOSBOXX_TURBO_RUN=true|false         Enable turbo fast-forward on boot
  NET_BACKEND=slirp|pcap               Enable NE2000 (IRQ=$NET_IRQ)
  *_ISO_URL                            Optional per-ISO URLs, e.g. WIN98SE_ISO_URL

Notes (from DOSBox-X guide)
  • For Win98 OEM Full, bootable CD install (El Torito) is supported (WIN98_METHOD=bootcd).
  • After install, RUN config boots HDD via BIOS and attaches empty A:/D: drives so Win9x keeps them.
  • S3 Trio64 is used; you can later install VBEMP for higher VESA modes (perf trade-off).
  • For networking: NET_BACKEND=slirp (easy) or pcap (legacy protocols; needs promiscuous support).

Configs & logs
  • VM path: $VMS/<oskey>/
  • ISOs:    $ISOS
  • Logs:    $VMS/<oskey>/last-dosboxx.log
EOF
}

# ── Main ─────────────────────────────────────────────────────────────────────
cmd="${1:-help}"; shift || true
case "$cmd" in
  setup)  cmd_setup ;;
  new)    cmd_new "$@" ;;
  install)cmd_install "$@" ;;
  start)  cmd_start "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "Unknown command: $cmd (try: help)";;
esac

