#!/system/bin/sh
# consumption-4arm-report.sh - turn the 4-arm TSV into a table fit to publish.
#
#   sh consumption-4arm-report.sh [/data/local/tmp/consumption-4arm.tsv]
#
# THE STATISTIC
#   Each round measures all four arms minutes apart, so every build window has an `off` window
#   close to it in time. The figure reported per build is the MEDIAN OF THE PAIRED DIFFERENCES
#   against its own round's floor. Temperature falls and the pack drains across a run this long;
#   that moves both members of a pair together and cancels out of a paired difference. It does not
#   cancel out of two unpaired medians taken an hour apart.
#
# THE RESOLUTION RULE
#   The `off` arm is measured as often as the builds. The spread of those floor windows is what this
#   rig can resolve on this phone today. Any difference smaller than that is reported as
#   indistinguishable rather than ranked, because ranking noise is how a benchmark lies.
#
# WHAT IS EXACT
#   Daemon CPU time and fork counts are counters read from /proc, not samples. They are reported
#   without error bars because they do not have any. Where the current means cannot separate two
#   builds, these still can.

TSV=${1:-/data/local/tmp/consumption-4arm.tsv}
[ -f "$TSV" ] || { echo "no TSV at $TSV"; exit 1; }

awk -F'\t' '
function med(c,   i,j,t){ for(i=1;i<c;i++)for(j=i+1;j<=c;j++)if(S[j]<S[i]){t=S[i];S[i]=S[j];S[j]=t}
  return (c%2)?S[int(c/2)+1]:int((S[c/2]+S[c/2+1])/2) }
function medof(a,k,c,  i){ for(i=1;i<=c;i++)S[i]=V[a,k,i]; return med(c) }
function spanof(a,k,c,  i,lo,hi){ lo=V[a,k,1];hi=lo
  for(i=2;i<=c;i++){ if(V[a,k,i]<lo)lo=V[a,k,i]; if(V[a,k,i]>hi)hi=V[a,k,i] } return hi-lo }
NR==1{next}
$3!="yes"{ inval[$2]++; next }
{ a=$2; n[a]++
  V[a,"ma",n[a]]=$4+0; V[a,"sp",n[a]]=$5+0; V[a,"cpu",n[a]]=$7+0; V[a,"fk",n[a]]=$8+0
  seen[a]=1
  if(a=="off") floor_of[$1]=$4+0
  rnd[a,n[a]]=$1; rma[a,n[a]]=$4+0 }
END{
  o[1]="off"; o[2]="vr25"; o[3]="rc23"; o[4]="rc24"
  MINN=2
  for(k=1;k<=4;k++){ a=o[k]; if(!seen[a])continue
    pc=0
    if(a!="off") for(i=1;i<=n[a];i++){ r=rnd[a,i]; if(r in floor_of){ pc++; V[a,"pd",pc]=rma[a,i]-floor_of[r] } }
    pm[a]=(pc>0)?medof(a,"pd",pc):0; pn[a]=pc
    mma[a]=medof(a,"ma",n[a]); mcpu[a]=medof(a,"cpu",n[a]); mfk[a]=medof(a,"fk",n[a]) }

  res=spanof("off","ma",n["off"])
  usable=(n["off"]>=MINN)

  print ""
  printf "%-6s %3s %11s %15s %13s %12s\n","arm","n","mean mA","vs off (paired)","daemon ms/min","forks/min"
  printf "%-6s %3s %11s %15s %13s %12s\n","------","---","-----------","---------------","-------------","------------"
  for(k=1;k<=4;k++){ a=o[k]; if(!seen[a])continue
    pcol=(a=="off")?"-":((pn[a]>0)?sprintf("%+d mA (n=%d)",pm[a],pn[a]):"n/a")
    printf "%-6s %3d %11d %15s %13d %12d",a,n[a],mma[a],pcol,mcpu[a],mfk[a]
    if(inval[a]) printf "   %d discarded",inval[a]
    print "" }

  print ""
  if(!usable){ print "Too few valid floor windows to form a resolution. No drain verdict." }
  else {
    printf "resolution: the %d floor windows spanned %d mA end to end.\n",n["off"],res
    print  "            Nothing smaller than that has been resolved on this phone today."
  }

  print ""
  print "verdict, measured drain:"
  for(k=2;k<=4;k++){ a=o[k]; if(!seen[a]||pn[a]<1)continue
    d=pm[a]; ad=(d<0)?-d:d
    printf "  %-5s %+d mA against no ACC at all",a,d
    if(ad<=res) print "   - inside the resolution, indistinguishable from zero"
    else printf "   = %.0f mAh/day\n",d*24.0 }

  print ""
  print "verdict, exact counters (these have no error bars - they are counters, not samples):"
  for(k=2;k<=4;k++){ a=o[k]; if(!seen[a])continue
    printf "  %-5s daemon %5d ms/min   %+5d forks/min over the floor\n",a,mcpu[a]-mcpu["off"],mfk[a]-mfk["off"] }
  if(seen["rc23"]&&seen["rc24"]&&mcpu["rc23"]-mcpu["off"]>0){
    x=mcpu["rc24"]-mcpu["off"]; y=mcpu["rc23"]-mcpu["off"]
    printf "\n  rc24 uses %.1f%% of rc23 daemon CPU (%d vs %d ms/min over the floor).\n",x*100.0/y,x,y }
  if(seen["vr25"]&&seen["rc24"]&&mcpu["rc24"]-mcpu["off"]>0){
    x=mcpu["rc24"]-mcpu["off"]; v=mcpu["vr25"]-mcpu["off"]
    printf "  VR25 original uses %.1fx rc24 daemon CPU (%d vs %d ms/min over the floor).\n",v*1.0/x,v,x }

  print ""
  print "A daemon at C ms/min occupies C/600 percent of one core. Converting that to battery needs a"
  print "per-core power figure this rig does not measure, so it is deliberately not converted here -"
  print "an earlier attempt derived one from a pegged core and produced a figure that contradicted"
  print "its own direct measurement, because a pegged core sits at the top of the DVFS range and a"
  print "daemon that wakes for milliseconds does not."
}
' "$TSV"
