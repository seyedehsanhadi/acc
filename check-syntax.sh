#!/usr/bin/env sh
# Basic Shell Syntax Checker
# Copyright 2018-2020, VR25
# License: GPLv3+

(echo
cd ${0%/*} 2>/dev/null
exitCode=0

# .scratch holds whole archived copies of this repo - hundreds of megabytes, thousands of
# scripts, none of which ship. Checking them forked bash once per file and made every build take
# minutes without ever reaching the packaging step.
for f in $(find . \( -path ./_builds -o -path ./_resources -o -path ./META-INF -o -path ./.scratch \) \
  -prune -o -type f -name '*.sh')
do
  [ -f "$f" ] && {
    bash -n $f || exitCode=$?
  }
done

[ $exitCode -eq 0 ] || echo
exit $exitCode)
