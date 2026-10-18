#!/bin/bash
# Final packaging — audit what has been collected, then produce one archive to send.
#
# USAGE (as root on the VM):
#     sudo bash package_submission.sh
#
# Produces ~/lakshay-cc33-freeswitch-assignment.zip (or .tar.gz if zip is absent).

set -u

OUT="$HOME/submission"
NAME="lakshay-cc33-freeswitch-assignment"

GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
have() { [ -e "$1" ] && [ -s "$1" ] 2>/dev/null; }

echo
echo "========================================================================"
echo "  Deliverable audit"
echo "========================================================================"

MISSING=0
check() {  # check "<label>" <path>
  local label="$1" path="$2"
  if [ -e "$path" ] && [ -n "$(find "$path" -type f 2>/dev/null | head -1)" ]; then
    echo "${GRN}  [x]${RST} $label"
  else
    echo "${RED}  [ ]${RST} $label      ${YLW}<- missing${RST}"
    MISSING=$((MISSING+1))
  fi
}

check "D1  config files + dialplan"        "$OUT/02-dialplan-and-config"
check "D1  installation / CLI state"       "$OUT/01-installation"
check "D2  successful call evidence"       "$OUT/04-call-evidence/success"
check "D3  CDR sample"                     "$OUT/03-cdr"
check "D4  agent state service"            "$OUT/06-agent-state"
check "D5  README"                         "$OUT/README.md"
echo
check "T4  troubleshooting - before"       "$OUT/05-troubleshooting/01-before"
check "T4  troubleshooting - broken"       "$OUT/05-troubleshooting/02-broken"
check "T4  troubleshooting - fixed"        "$OUT/05-troubleshooting/03-fixed"
check "T4  broken call capture"            "$OUT/04-call-evidence/broken"
check "T4  fixed call capture"             "$OUT/04-call-evidence/fixed"
echo
# Screenshots are NOT a deliverable — the brief asks for config, call evidence,
# CDR/CLI output, the agent-state service and a README. Softphone screenshots are
# corroboration at best; the SIP trace and the CDR row are stronger evidence of a
# completed call than a picture of a dialler. Reported, never counted as missing.
if [ -d "$OUT/07-screenshots" ] && [ -n "$(find "$OUT/07-screenshots" -type f 2>/dev/null | head -1)" ]; then
  echo "${GRN}  [x]${RST}     screenshots            (optional, present)"
else
  echo "      [ ]     screenshots            ${YLW}(optional, not a deliverable)${RST}"
fi
check "    reproduction scripts"          "$OUT/freeswitch"

if [ "$MISSING" -gt 0 ]; then
  echo
  echo "${YLW}  $MISSING item(s) missing. Reminders:${RST}"
  echo "    config/CLI/CDR      sudo bash collect_evidence.sh"
  echo "    call evidence       sudo bash capture_call.sh success"
  echo "    fault before/after  sudo bash stage_fault.sh break   (then capture_call.sh broken)"
  echo "                        sudo bash stage_fault.sh fix     (then capture_call.sh fixed)"
  echo "    agent state         copy DESIGN.md + agent_state.py + test_agent_state.py"
  echo "                        + the passing test output into 06-agent-state/"
  echo "    repro scripts       cp -r <pack>/freeswitch \$OUT/freeswitch"
  echo "                        (the README's \"Reproducing this\" section cites them)"
  echo "    README              README.md at the root of \$OUT"
  echo
  printf "  Package anyway? [y/N] "
  read -r a
  case "$a" in y|Y) ;; *) echo "  Stopped."; exit 1 ;; esac
fi

# ── safety sweep: nothing secret should leave the box ──────────────────────
echo
echo "========================================================================"
echo "  Secret sweep"
echo "========================================================================"
HITS=$(grep -rilE 'swpat_|swapi_|auth\.conf' "$OUT" 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "${RED}  Possible token or credential references found:${RST}"
  echo "$HITS" | sed 's|^|    |'
  echo "${YLW}  Review these before sending.${RST}"
else
  echo "${GRN}  [ok]${RST} no SignalWire tokens or apt auth files in the tree"
fi

# The SIP password leaks into evidence two ways: verbatim in vars.xml, and in
# EVERY level-7 log line, because the user_exists lookup traces the comparison —
#     ${default_password}(REDACTED) =~ /^1234$/
# So scrub it automatically rather than trusting a reminder. The real value is
# read from vars.xml so nothing is hardcoded here.
VARS=/etc/freeswitch/vars.xml
if [ -f "$VARS" ]; then
  PWVAL=$(sed -n 's/.*default_password=\([^"]*\)".*/\1/p' "$VARS" | head -1)
  if [ -n "$PWVAL" ]; then
    mapfile -t PWFILES < <(grep -rl -F "$PWVAL" "$OUT" 2>/dev/null || true)
    if [ "${#PWFILES[@]}" -gt 0 ]; then
      ESC=$(printf '%s' "$PWVAL" | sed 's/[&|\\]/\\&/g')
      for f in "${PWFILES[@]}"; do sed -i "s|$ESC|REDACTED|g" "$f"; done
      echo "${GRN}  [ok]${RST} scrubbed the SIP password from ${#PWFILES[@]} file(s)"
      if grep -rq -F "$PWVAL" "$OUT" 2>/dev/null; then
        echo "${RED}  [XX]${RST} password STILL present after scrub — check manually before sending"
      fi
    else
      echo "${GRN}  [ok]${RST} SIP password not present in the evidence tree"
    fi
  else
    echo "${YLW}  [--]${RST} could not read default_password from vars.xml — check logs by hand"
  fi
fi

# Screenshots are images: sed cannot reach into them. The SignalWire token and
# the password were both on screen at points during setup.
if [ -d "$OUT/07-screenshots" ] && [ -n "$(find "$OUT/07-screenshots" -type f 2>/dev/null | head -1)" ]; then
  echo "${YLW}  [--]${RST} eyeball 07-screenshots/ yourself — no token, no password, no apt auth file"
fi

# ── build the archive ──────────────────────────────────────────────────────
echo
echo "========================================================================"
echo "  Packaging"
echo "========================================================================"

cd "$(dirname "$OUT")" || exit 1
rm -f "$HOME/$NAME.zip" "$HOME/$NAME.tar.gz"

if command -v zip >/dev/null 2>&1; then
  zip -qr "$HOME/$NAME.zip" "$(basename "$OUT")" -x '*__pycache__*' -x '*.pyc'
  ARCHIVE="$HOME/$NAME.zip"
else
  tar --exclude='__pycache__' --exclude='*.pyc' \
      -czf "$HOME/$NAME.tar.gz" "$(basename "$OUT")"
  ARCHIVE="$HOME/$NAME.tar.gz"
  echo "${YLW}  zip not installed (apt-get install zip) — produced a tar.gz instead${RST}"
fi

SIZE=$(du -h "$ARCHIVE" | cut -f1)
FILES=$(find "$OUT" -type f | wc -l)

echo "${GRN}  [ok]${RST} $ARCHIVE  ($SIZE, $FILES files)"
echo
echo "  Pull it to your laptop:"
echo "      scp $(whoami)@$(hostname -I | awk '{print $1}'):$ARCHIVE ./"
echo
