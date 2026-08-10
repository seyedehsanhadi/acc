#!/system/bin/sh
# baseline.sh - persist what each run measured, and judge the next run against history.
#
# WHY
#   Until now every arm result was printed once and thrown away. That makes exactly one class of
#   problem invisible: the slow one. A release that costs 5% more than the last, four times in a row,
#   passes every single run and doubles the idle cost across four releases. It also means a run can
#   only compare rc22 against an rc21 arm measured minutes earlier - fine for a same-session A/B,
#   useless for "is this build worse than what we shipped in June".
#
#   Baselines are stored per DEVICE, because the two phones are not comparable to each other: laurus
#   is a Snapdragon 665 on Android 10 with an input-cut switch, bluejay a Tensor on Android 16 with a
#   firmware level limit. Their tick counts have no shared meaning.
#
# FILE FORMAT (one record per line, append-only, newest last)
#   <epoch> <versionCode> <metric> <value>
#
# Everything here degrades quietly: a missing or corrupt baseline file means "no history", never a
# failed run. A test harness that fails because its own bookkeeping is missing teaches people to
# ignore it.

BASEDIR=${BASEDIR:-$dataDir/baselines}
DEV=$(getprop ro.product.device 2>/dev/null)
[ -n "${DEV:-}" ] || DEV=unknown
BASEFILE=$BASEDIR/$DEV.txt

baseline_record() {  # $1 metric, $2 value
  [ -n "${2:-}" ] || return 0
  case "$2" in ''|*[!0-9-]*) return 0;; esac
  mkdir -p $BASEDIR 2>/dev/null || return 0
  _vc=$(grep -m1 '^versionCode=' $execDir/module.prop 2>/dev/null | cut -d= -f2)
  echo "$(date +%s 2>/dev/null) ${_vc:-0} $1 $2" >> $BASEFILE 2>/dev/null || :
}

# Median of the stored values for a metric, ignoring the current run. Median rather than mean because
# one wedged-daemon reading of 0, or one thermal-throttled outlier, should not move the reference.
baseline_median() {  # $1 metric -> prints median, or nothing when there is no history
  [ -f "$BASEFILE" ] || return 1
  _vals=$(awk -v m="$1" '$3==m {print $4}' $BASEFILE 2>/dev/null | sort -n)
  [ -n "${_vals:-}" ] || return 1
  _n=$(printf '%s\n' "$_vals" | wc -l)
  [ "${_n:-0}" -ge 1 ] 2>/dev/null || return 1
  _mid=$(( (_n + 1) / 2 ))
  printf '%s\n' "$_vals" | sed -n "${_mid}p"
}

baseline_count() { [ -f "$BASEFILE" ] || { echo 0; return; }; awk -v m="$1" '$3==m' $BASEFILE 2>/dev/null | wc -l; }

# Compare a fresh value against stored history. tolerance is a PERCENT, and the caller passes the
# run's own measured noise floor where it has one - a fixed percentage would either cry wolf on a
# quiet metric or wave through a real regression on a noisy one.
baseline_check() {  # $1 metric, $2 fresh value, $3 tolerance percent, $4 human label
  _m=$1; _v=$2; _tol=${3:-25}; _lbl=${4:-$1}
  case "${_v:-x}" in ''|*[!0-9-]*) skip "$_lbl: no value measured"; return 0;; esac
  _n=$(baseline_count "$_m")
  if ! _hist=$(baseline_median "$_m"); then
    baseline_record "$_m" "$_v"
    ok "$_lbl: ${_v} recorded as the FIRST baseline for $DEV (nothing to compare yet)"
    return 0
  fi
  # Guard the division: a stored median of 0 (e.g. the ACC-OFF arm) has no meaningful percentage.
  if [ "${_hist:-0}" -eq 0 ] 2>/dev/null; then
    baseline_record "$_m" "$_v"
    if [ "${_v:-0}" -eq 0 ] 2>/dev/null; then
      ok "$_lbl: 0, matching a baseline of 0 over ${_n} run(s)"
    else
      no "$_lbl: ${_v} against a baseline of 0 over ${_n} run(s) - something now costs what it used to not"
    fi
    return 0
  fi
  _delta=$(( _v - _hist ))
  _pct=$(( (_delta * 100) / _hist ))
  baseline_record "$_m" "$_v"
  _abs=${_pct#-}
  if [ "${_abs:-0}" -le "${_tol:-25}" ] 2>/dev/null; then
    ok "$_lbl: ${_v} vs baseline ${_hist} over ${_n} run(s) (${_pct}%, within ${_tol}%)"
  elif [ "${_delta:-0}" -lt 0 ] 2>/dev/null; then
    ok "$_lbl: ${_v} vs baseline ${_hist} (${_pct}%) - IMPROVED beyond the ${_tol}% band"
  else
    no "$_lbl: ${_v} vs baseline ${_hist} over ${_n} run(s) - ${_pct}% WORSE, beyond the ${_tol}% band"
  fi
}

baseline_summary() {
  [ -f "$BASEFILE" ] || { note "no baseline history for $DEV yet"; return 0; }
  note "baseline history for $DEV ($(wc -l < $BASEFILE) records at $BASEFILE)"
  for _m in $(awk '{print $3}' $BASEFILE 2>/dev/null | sort -u); do
    _md=$(baseline_median "$_m")
    _c=$(baseline_count "$_m")
    _last=$(awk -v m="$_m" '$3==m {v=$4} END{print v}' $BASEFILE 2>/dev/null)
    note "  $(printf '%-22s' "$_m") median ${_md}  last ${_last}  n=${_c}"
  done
}
