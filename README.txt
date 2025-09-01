

Usage: ./grok/winpower.sh [--debug] <command> [args]
Commands:
  setup Install DOSBox-X, create folders
  new <win95|win98|winnt4|win2000> [size_mb]
                              Create a new VM folder and preformatted HDD image
  attach-iso <oskey> </path/to.iso>
                              Copy a local ISO into /Users/cris/dosboxx/vms/isos
  install <oskey> Write install config and start the installer
  start <oskey> Boot from the installed HDD image
  help Show this help
Environment:
  DOSBOXX_HOME Base directory (default: /Users/cris/dosboxx)
  DOSBOXX_DEBUG=1 Verbose shell + DOSBox-X logging
  AUTO_INSTALL_9X=1 For Win95/98: auto copy setup files to C: and run SETUP
  *_ISO_URL Optional per-ISO URLs, e.g. WIN98SE_ISO_URL
Notes:
  • ISOs go in ~/dosboxx/vms/isos (Win95.iso, Win98SE.iso, WinNT4.iso, Win2000.iso)
  • NT4 needs a boot floppy at ~/dosboxx/vms/boot/nt4-boot.img
  • Logs: ~/dosboxx/vms/<oskey>/last-dosboxx.log

