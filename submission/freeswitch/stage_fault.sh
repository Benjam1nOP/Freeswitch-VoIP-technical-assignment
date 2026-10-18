#!/bin/bash
# Task 4 — stage a fault, capture the diagnosis, then fix it.
#
# The fault: a universal catch-all extension in an INCLUDED dialplan file.
# Chosen because the root cause is real FreeSWITCH knowledge rather than a typo,
# and because the prevention is already in the submission (99_assignment_invalid.xml
# is scoped to ^(1[0-9]{3})$ precisely so it cannot do this).
#
# PRECONDITION — matters, and this script checks it.
# Two things decide which extension wins in a FreeSWITCH context:
#   1. where <X-PRE-PROCESS cmd="include" data="default/*.xml"/> sits inside
#      <context name="default">, because the pre-processor splices the included
#      files in AT THAT POINT, and
#   2. first match wins unless the extension sets continue="true".
# Stock Debian packaging puts that include at the END of the context, after the
# vanilla extensions. With it there, this catch-all cannot shadow Local_Extension,
# the echo test or the IVR demo — they are evaluated first — so the fault would
# not reproduce as described. Move the include to immediately after the
# <context name="default"> line (see README / deploy_dialplan.sh) and the
# included files, both the real ones and this fault, take precedence.
#
# USAGE (as root):
#     sudo bash stage_fault.sh break     # install the fault + capture diagnostics
#     sudo bash stage_fault.sh fix       # remove it + capture diagnostics
#     sudo bash stage_fault.sh status    # show current state
#
# Between break and fix, run:  sudo bash capture_call.sh broken

set -u

MODE="${1:-}"
FSCONF=/etc/freeswitch
DEFXML="$FSCONF/dialplan/default.xml"
FAULT="$FSCONF/dialplan/default/00_broken.xml"
OUT="$HOME/submission/05-troubleshooting"

GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RED=$'\033[31m'; RST=$'\033[0m'
ok()   { echo "${GRN}  [ok]${RST} $*"; }
warn() { echo "${YLW}  [!!]${RST} $*"; }
die()  { echo "${RED}  [XX]${RST} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0 $MODE"

include_position() {
  # Echoes "early", "late", or "missing". The catch-all fault only reproduces
  # when the include is spliced in BEFORE the vanilla extensions.
  [ -f "$DEFXML" ] || { echo "missing"; return; }
  local inc ext
  inc=$(grep -n 'X-PRE-PROCESS.*include.*default/\*\.xml' "$DEFXML" | head -1 | cut -d: -f1)
  ext=$(grep -n '<extension' "$DEFXML" | head -1 | cut -d: -f1)
  if [ -z "$inc" ]; then echo "missing"
  elif [ -z "$ext" ] || [ "$inc" -lt "$ext" ]; then echo "early"
  else echo "late"
  fi
}

snap() {   # snap <phase> — capture the diagnostic commands a reviewer wants to see
  # Two separate `local` statements on purpose. Bash expands every word on a
  # command line before the builtin runs, so `local phase="$1" d="$OUT/$phase"`
  # expands $phase while it is still unset — which aborts under `set -u`.
  local phase="$1"
  local d="$OUT/$phase"
  mkdir -p "$d"
  { echo "\$ ls -1 $FSCONF/dialplan/default/"; echo
    ls -1 "$FSCONF"/dialplan/default/; } > "$d/dialplan-files.txt"
  # default.xml itself is evidence: it shows WHERE the include sits, which is
  # what decides whether an included extension can shadow the vanilla ones.
  { echo "\$ grep -n 'context name\\|X-PRE-PROCESS\\|<extension' $DEFXML"; echo
    grep -n 'context name\|X-PRE-PROCESS\|<extension' "$DEFXML" 2>&1
    echo; echo "include position: $(include_position)"; } > "$d/default.xml-include-position.txt"
  { echo "\$ fs_cli -x \"xml_locate dialplan\""; echo
    fs_cli -x "xml_locate dialplan" 2>&1; } > "$d/xml_locate_dialplan.txt"
  { echo "\$ fs_cli -x \"show dialplan\""; echo
    fs_cli -x "show dialplan" 2>&1; } > "$d/show_dialplan.txt"
  [ -f "$FAULT" ] && cp "$FAULT" "$d/00_broken.xml"
  ok "diagnostics saved to submission/05-troubleshooting/$phase/"
}

case "$MODE" in

  break)
    [ -f "$FAULT" ] && die "Fault already staged. Run: sudo bash $0 fix"

    POS="$(include_position)"
    case "$POS" in
      missing)
        die "No 'default/*.xml' include found in $DEFXML — deploy_dialplan.sh has not run." ;;
      late)
        warn "The include sits AFTER the vanilla extensions in $DEFXML."
        echo "       With it there, this catch-all will NOT shadow 1002 / 9196 / 5000 —"
        echo "       the vanilla extensions are evaluated first, so the fault will not"
        echo "       reproduce as the README describes it. Move the include to just"
        echo "       after the <context name=\"default\"> line first, then re-run."
        echo
        echo "       Inspect:  grep -n 'context name\\|X-PRE-PROCESS' $DEFXML"
        exit 1 ;;
      early)
        ok "include is spliced in before the vanilla extensions — fault will reproduce" ;;
    esac

    # baseline first, so the README has a genuine before/after
    echo "=== Capturing healthy baseline ==="
    snap "01-before"

    echo
    echo "=== Staging the fault ==="
    cat > "$FAULT" <<'XML'
<!--
  DELIBERATE FAULT for task 4 — do not ship this.
  A universal catch-all in an INCLUDED dialplan file. dialplan/default.xml
  splices default/*.xml in at the position of its X-PRE-PROCESS include, and
  the first matching extension wins unless it sets continue="true". With that
  include placed at the top of the context, this file sorts first (00_) and its
  ^.*$ condition therefore shadows every other extension: agent extensions,
  the echo test, the IVR demo, conferences and voicemail all become
  unreachable. The failure is silent — nothing errors, every call lands here.
-->
<include>
  <extension name="broken_catchall">
    <condition field="destination_number" expression="^.*$">
      <action application="log" data="ERR [FAULT] broken_catchall swallowed ${destination_number}"/>
      <action application="answer"/>
      <action application="playback" data="ivr/ivr-that_was_an_invalid_entry.wav"/>
      <action application="hangup" data="UNALLOCATED_NUMBER"/>
    </condition>
  </extension>
</include>
XML
    ok "wrote $FAULT"
    fs_cli -x "reloadxml" | sed 's/^/  /'
    snap "02-broken"

    cat <<EOF

${CYN}========================================================================
  Fault is live. Reproduce and diagnose now.
========================================================================${RST}

  ${YLW}SYMPTOM${RST} — every one of these should now hit the invalid-entry prompt:
      1002      (was working)
      9196      (echo test)
      5000      (IVR demo)

  ${YLW}CAPTURE THE BROKEN CALL${RST}
      sudo bash capture_call.sh broken

  ${YLW}DIAGNOSE${RST} — already saved for you under 05-troubleshooting/02-broken/,
  but run these live so you can narrate them in the README:
      fs_cli -x "xml_locate dialplan"
      fs_cli
        /log 7                 # then place a call and watch broken_catchall match

  ${YLW}ROOT CAUSE${RST}
      Two rules combine. (1) The XML pre-processor splices default/*.xml into
      <context name="default"> at the exact position of the X-PRE-PROCESS
      include — here, at the top of the context. (2) Within the context the
      first matching extension wins unless it sets continue="true", and the
      included files are spliced in case-sensitive ASCII filename order.
      00_broken.xml therefore sorts first and is evaluated before every real
      extension, and its ^.*\$ condition matches every destination.

      Evidence saved: 05-troubleshooting/*/default.xml-include-position.txt
      shows the include's line number relative to the vanilla extensions.

  ${YLW}THEN FIX IT${RST}
      sudo bash $0 fix
      sudo bash capture_call.sh fixed
========================================================================
EOF
    ;;

  fix)
    [ -f "$FAULT" ] || die "No fault staged — nothing to fix."
    echo "=== Removing the fault ==="
    rm -f "$FAULT"
    ok "removed $FAULT"
    fs_cli -x "reloadxml" | sed 's/^/  /'
    snap "03-fixed"

    cat <<EOF

${GRN}========================================================================
  Fixed. Verify, then capture.
========================================================================${RST}

  Re-dial 1002, 9196 and 5000 — all should work again.

      sudo bash capture_call.sh fixed

  ${YLW}PREVENTION — this is the part that scores${RST}
  Point at your own 99_assignment_invalid.xml in the README. It is scoped to
  ^(1[0-9]{3})\$ rather than ^.*\$ precisely so it cannot shadow the context,
  and the file carries a comment explaining why. Detect -> diagnose -> fix ->
  prevent, with the prevention already shipped in the deliverable.
========================================================================
EOF
    ;;

  status)
    if [ -f "$FAULT" ]; then
      echo "${YLW}  Fault IS staged${RST} — $FAULT exists"
    else
      echo "${GRN}  Clean${RST} — no fault staged"
    fi
    ls -1 "$FSCONF"/dialplan/default/*.xml | xargs -n1 basename | sed 's/^/    /'
    ;;

  *)
    echo "Usage: sudo bash $0 break | fix | status"
    exit 1
    ;;
esac
