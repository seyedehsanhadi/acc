#!/system/bin/sh
# sample.sh - N samples of the charge-direction question, from every observable at once.
B=/sys/class/power_supply/battery
U=/sys/class/power_supply/usb
G=$B
[ -f /sys/class/power_supply/maxfg/capacity ] && G=/sys/class/power_supply/maxfg
echo "context=$(id -Z 2>/dev/null) uid=$(id -u)"
echo "readable: online=$([ -r $U/online ] && echo y || echo n) status=$([ -r $B/status ] && echo y || echo n) cur=$([ -r $B/current_now ] && echo y || echo n)"
n=${1:-5}
i=0
while [ $i -lt $n ]; do
  on=$(cat $U/online 2>/dev/null)
  ks=$(cat $B/status 2>/dev/null)
  cu=$(cat $B/current_now 2>/dev/null)
  cc=$(cat $G/charge_counter 2>/dev/null)
  as=$(acc -i 2>/dev/null | sed -n 's/^status //p' | head -1)
  echo "online=$on kernel=$ks acc=$as cur=$cu cc=$cc"
  i=$((i + 1))
  [ $i -lt $n ] && sleep 6
done
echo "dpol=$(sed -n 's/^_DPOL=//p' /dev/.vr25/acc/.batt-interface.sh 2>/dev/null) flips=$(cat /dev/.vr25/acc/.dpol_flips 2>/dev/null) unstable=$([ -f /dev/.vr25/acc/.dpol_unstable ] && echo yes || echo no)"
