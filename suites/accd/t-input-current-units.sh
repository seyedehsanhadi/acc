#!/system/bin/sh
execDir=${execDir:-install}
. "$execDir/state-export.sh"
eval "$(awk '/^_se_input_ma\(\) \{/,/^\}/' "$execDir/state-export.sh")"
check() {
  inputAmpFactor=$2
  _se_input_ma "$1"
  [ "$_sema" = "$3" ] || { echo "FAIL: $1 / $2 -> $_sema, expected $3"; exit 1; }
}
for ampFactor in 1000 1000000; do
  check 895000 '' 895
  check -895000 '' -895
  check 6163 '' null
  check 6163 1000000 6
  check -895 1000 -895
  check +00895 1000 895
  check 0 '' 0
  check 08 1000 8
  check 1-2 1000 null
  check '' 1000 null
  check 9999999999 1000000 null
  check 100000 bad null
done
echo 'input-current-units: 24 passed'
