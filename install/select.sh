# "Select" For Shells That Lack It
# Copyright 2019-2020, VR25
# License: GPLv3+
#
# usage
#  . $0
#  select_ <var> <list>
#
# ${PS3:-#?} is used.


select_() {

  local item=
  local list=
  local menu=
  local lastItem=
  local tries=0
  local n=
  local _var_="$1"

  shift
  [ $# -gt 9 ] || n="-n 1"

  for item in "$@"; do
    menu="$(printf "$menu\n$item")"
    lastItem="$item"
  done

  menu="$(echo "$menu" | grep -v '^$' | nl -s ") " -w 2 -v 0)"

  # rc21: an unmatched keystroke used to leave $_var_ empty, and set-prop.sh read
  # that empty value as "Automatic" -- silently wiping a hand-picked charging
  # switch and rewriting config.txt with exit 0. Re-prompt instead of returning
  # nothing. 'z' and EOF resolve to $lastItem, which is Exit at every call site,
  # so the numbered menus share the wizard's hotkey. $lastItem is the literal
  # argument rather than an nl/sed lookup, so a busybox whose nl numbers
  # differently degrades to Exit instead of never matching. The retry cap keeps
  # that same case from spinning forever on a terminal nobody is watching.
  while :; do
    printf "$menu\n\n${PS3:-#? }"
    # read returns non-zero at EOF even when it did set $item (a final line with
    # no trailing newline), so only treat a failed read as "exit" when nothing
    # was actually read; otherwise a piped "5" with no newline would select Exit.
    read $n item || [ -n "$item" ] || item=z
    case "$item" in
      [zZ]) list="$lastItem"; break;;
      ""|*[!0-9]*) list=;;
      *) list="$(echo "$menu" | sed 's/^ //' | sed -n "s|^${item}. ||p")";;
    esac
    [ -n "$list" ] && break
    tries=$((tries+1))
    [ $tries -ge 5 ] && { list="$lastItem"; break; }
    echo
  done

  eval "$_var_=\"$list\""
}
