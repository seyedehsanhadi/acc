#!/system/bin/sh
# `acc -e` and `acc -d` stop the daemon to take the lock. Every other lock-taking path in the
# project puts it back (set-prop.sh three times, acc.sh's --test path); these two did not, so a
# bare `acc -e` printed "Charging enabled" and silently left the charge limit unenforced until
# reboot. Measured on a Pixel 6a and a Mi A3: no accd process afterwards, on both.
# The ARGUMENT forms are blocking overrides that end in disable_charging, and the README idiom
# restarts by hand after them (`acc -e 30m && acc -d 6h && acc -e 85 && accd`), so they must NOT
# be restarted. `acc -d` must not be either: a running daemon would undo it.
execDir=${execDir:-/data/adb/vr25/acc}
ACC=${ACC:-$execDir/acc.sh}
P=0; F=0
# Pin the scratch base once, to a directory that actually exists on this host: the device has
# /data/local/tmp, a workstation does not.
_TMPD0=${TMPDIR:-}
[ -d "${_TMPD0:-/nonexistent}" ] || _TMPD0=/data/local/tmp
[ -d "$_TMPD0" ] || _TMPD0=/tmp
[ -d "$_TMPD0" ] || _TMPD0=.
run(){ # $1=flag $2=arg $3=want-stopped $4=want-restarted $5=daemon-already-down
  # Always allocate from the ORIGINAL TMPDIR: a previous case set TMPDIR to its own
  # scratch dir, which is now deleted, and mktemp there fails silently.
  W=$(TMPDIR=$_TMPD0 mktemp -d)
  [ -d "$W" ] || { echo "  FAIL $1: mktemp -d failed"; F=$((F+1)); return; }; LOG=$W/log; : > "$LOG"
  execDir=$W; TMPDIR=$W; config=$W/config; : > "$config"; : > "$W/acquire-lock.sh"
  verbose=true; DOWN=${5:-0}; _ws=$3; _wr=$4
  daemon_ctrl(){ case "$1" in stop) [ "$DOWN" = 1 ] && return 1; echo STOP >> "$LOG"; return 0;; esac; }
  print_stopped(){ :; }
  enable_charging(){ echo "ENABLE $*" >> "$LOG"; }
  disable_charging(){ echo "DISABLE $*" >> "$LOG"; }
  # The real code calls $TMPDIR/accd, a FILE (service.sh). A shell-function stub never fires and
  # every arm then reads as "no restart" - which is how this looked green while broken.
  SHB=/system/bin/sh; [ -x "$SHB" ] || SHB=/bin/sh
  printf '#!%s\necho RESTART >> "%s"\n' "$SHB" "$LOG" > "$W/accd"; chmod 0755 "$W/accd"
  arm(){ awk -v lbl="$1" 'index($0, lbl)==3 {f=1; next} f && /^  ;;/ {exit} f {print}' "$ACC"; }
  # Name the flag and the argument BEFORE `set --`: the lifted arm body starts with `shift`, so
  # it needs the positional parameters, and setting them first overwrote $1 with the word "flag".
  _flag=$1; _arg=$2
  case $_flag in
    -e) BODY=$(arm '-e|--enable)');;
    -d) BODY=$(arm '-d|--disable)');;
  esac
  set -- flag $_arg
  [ -n "$BODY" ] || { echo "  FAIL $_flag $_arg: could not lift the arm from acc.sh"; F=$((F+1)); rm -rf "$W"; return; }
  eval "$BODY"
  s=no; r=no
  grep -q '^STOP$' "$LOG" && s=yes
  grep -q '^RESTART$' "$LOG" && r=yes
  if [ "$s" = "$_ws" ] && [ "$r" = "$_wr" ]; then P=$((P+1))
  else echo "  FAIL $_flag ${_arg:-bare}: stopped=$s want $_ws, restarted=$r want $_wr"; F=$((F+1)); fi
  rm -rf "$W"
}
run -e ""       yes yes
run -e 80       yes no
run -e 30m      yes no
run -e 4100mv   yes no
run -d ""       yes no
# Never resurrect a daemon the user deliberately stopped; only put back one we stopped ourselves.
run -e ""       no  no  1
echo "t-enable-daemon-restore: $P passed, $F failed"
[ "$F" = 0 ]
