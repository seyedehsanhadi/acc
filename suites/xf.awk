# xf.awk - print one shell function, whole.
#
#   awk -v fn=present -f xf.awk file.sh
#
# Closes on a brace at the SAME indent as the opening line. The obvious sed range
# /^funcname() {/,/^ *}/ closes on the first NESTED brace instead, which returned 11 lines of a
# 93-line idle_discharging() and made every assertion about the rest of that function read as
# "absent" - a silent truncation that looks exactly like a missing feature.
#
# Handles all three definition styles this codebase mixes: `sdp() {`, `_cache_usable(){`, and
# two-space-indented `temp_now() {` inside accd.sh.

!f {
  if ($0 ~ "^[ \t]*" fn "\\(\\)[ \t]*\\{") {
    f = 1
    ind = ""
    s = $0
    while (substr(s, 1, 1) == " " || substr(s, 1, 1) == "\t") {
      ind = ind substr(s, 1, 1)
      s = substr(s, 2)
    }
    closer = ind "}"
    print
  }
  next
}
{
  print
  if ($0 == closer) exit
}
