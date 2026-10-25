# tests/lib/legs.sh — a test LEG that did not run is reported NOT RUN, and the suite FAILS.
#
# A suite that printed "SKIPPED" for a leg and still exited 0 let CI go green on a result nobody
# checked: the leg that would have failed was the leg the runner could not run. A skipped leg is a
# gap in the evidence, not a pass, so it fails the suite until the runner can run it.
#
#   leg_not_run <leg> <why>    print the NOT RUN line, record it
#   legs_verdict <fail-count>  exit status for the suite: 1 if any leg was NOT RUN or anything failed
LEGS_NOT_RUN=0
leg_not_run() {
  echo " ── $1 — NOT RUN: $2"
  LEGS_NOT_RUN=$((LEGS_NOT_RUN + 1))
}
legs_verdict() {
  if [ "$LEGS_NOT_RUN" -gt 0 ]; then
    echo "  ❌ NOT RUN: $LEGS_NOT_RUN leg(s) did not run, so this suite is INCOMPLETE, not passed"
    return 1
  fi
  [ "$1" -eq 0 ]
}
