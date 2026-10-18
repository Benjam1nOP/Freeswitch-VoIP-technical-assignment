#!/bin/bash
# Wrap a single call in full SIP + debug tracing and save a self-contained artifact.
#
# Deliverable 2 ("evidence of a successful test call") and the before/after pair for
# deliverable 3's troubleshooting section.
#
# USAGE (as root on the Debian VM):
#     bash capture_call.sh success        # the working 1001 -> 1002 call
#     bash capture_call.sh broken         # after you stage the task-4 fault
#     bash capture_call.sh fixed          # after you fix it
#
# Non-destructive: it records the log's byte offset before the call and slices from
# there afterwards, so nothing is truncated and nothing is lost.

set -u

LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "Usage: bash $0 <label>   e.g. success | broken | fixed"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0 $LABEL"; exit 1; }

LOG=/var/log/freeswitch/freeswitch.log
CDR=/var/log/freeswitch/cdr-csv/Master.csv
OUT="$HOME/submission/04-call-evidence/$LABEL"

GRN=$'\033[32m'; YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'

[ -f "$LOG" ] || { echo "No $LOG — check 'systemctl status freeswitch'"; exit 1; }

mkdir -p "$OUT"

LOG_START=$(wc -c < "$LOG")
CDR_START=$(wc -l < "$CDR" 2>/dev/null || echo 0)

fs_cli -x "sofia global siptrace on" >/dev/null 2>&1
fs_cli -x "console loglevel debug"   >/dev/null 2>&1

cat <<EOF

${CYN}========================================================================
  Tracing is ON — label: $LABEL
========================================================================${RST}

  Place the call now from your softphone, let it connect, speak for a few
  seconds so there is real RTP, then hang up.

  Suggested for "$LABEL":
      success  ->  1001 dials 1002, both answer, ~10 seconds of audio
      broken   ->  the same call, with the fault staged
      fixed    ->  the same call again after the fix

  ${YLW}Press ENTER once the call has ended.${RST}
EOF
read -r

fs_cli -x "sofia global siptrace off" >/dev/null 2>&1
fs_cli -x "console loglevel info"     >/dev/null 2>&1

echo
echo "=== Extracting ==="

# ── full debug slice for this call window ───────────────────────────────────
tail -c "+$((LOG_START + 1))" "$LOG" > "$OUT/freeswitch-debug.log"
LINES=$(wc -l < "$OUT/freeswitch-debug.log")
echo "${GRN}  [ok]${RST} freeswitch-debug.log  ($LINES lines)"

if [ "$LINES" -eq 0 ]; then
  echo "${YLW}  [--]${RST} Nothing was logged. Did the call actually go through this box?"
fi

# ── SIP messages only, which is what a reviewer wants to read ───────────────
grep -nE '(send|recv) [0-9]+ bytes|^[[:space:]]*(INVITE|ACK|BYE|CANCEL|REGISTER|OPTIONS|SIP/2\.0)' \
  "$OUT/freeswitch-debug.log" > "$OUT/sip-messages.txt" 2>/dev/null || true
echo "${GRN}  [ok]${RST} sip-messages.txt     ($(wc -l < "$OUT/sip-messages.txt") lines)"

# ── SDP bodies: where one-way audio is diagnosed ────────────────────────────
grep -nE '^[[:space:]]*(v=0|o=|c=IN IP4|m=audio|a=rtpmap)' \
  "$OUT/freeswitch-debug.log" > "$OUT/sdp-bodies.txt" 2>/dev/null || true
echo "${GRN}  [ok]${RST} sdp-bodies.txt       (check the c=IN IP4 lines for the media address)"

# ── channel UUIDs seen in this window ──────────────────────────────────────
grep -ohE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
  "$OUT/freeswitch-debug.log" 2>/dev/null | sort -u > "$OUT/channel-uuids.txt" || true
echo "${GRN}  [ok]${RST} channel-uuids.txt    ($(wc -l < "$OUT/channel-uuids.txt") uuid(s))"

# ── hangup causes, the quickest read on what happened ──────────────────────
grep -nE 'Hangup|hangup_cause|originate_disposition|NORMAL_CLEARING|USER_BUSY|NO_ANSWER|UNALLOCATED' \
  "$OUT/freeswitch-debug.log" > "$OUT/hangup-and-causes.txt" 2>/dev/null || true
echo "${GRN}  [ok]${RST} hangup-and-causes.txt"

# ── the CDR rows this call produced ────────────────────────────────────────
# mod_cdr_csv writes on CHANNEL_HANGUP_COMPLETE, which fires when the channel is
# destroyed — a moment AFTER the media stops and the user presses ENTER here.
# Reading the row count immediately races that write and reports a false "none",
# so poll for a few seconds instead.
if [ -f "$CDR" ]; then
  CDR_END=$CDR_START
  for _ in $(seq 1 10); do
    CDR_END=$(wc -l < "$CDR")
    [ "$CDR_END" -gt "$CDR_START" ] && break
    sleep 1
  done
  NEW=$((CDR_END - CDR_START))
  if [ "$NEW" -gt 0 ]; then
    tail -n "$NEW" "$CDR" > "$OUT/cdr-rows.csv"
    # A header makes the row readable without the reviewer hunting for the
    # template in cdr_csv.conf.xml.
    { echo "caller_id_name,caller_id_number,destination_number,context,start_stamp,answer_stamp,end_stamp,duration,billsec,hangup_cause,uuid,bleg_uuid,accountcode,read_codec,write_codec"
      cat "$OUT/cdr-rows.csv"; } > "$OUT/cdr-rows-annotated.csv"
    echo "${GRN}  [ok]${RST} cdr-rows.csv         ($NEW new row(s) from this call)"
    echo "${GRN}  [ok]${RST} cdr-rows-annotated.csv  (same rows, with a header)"
  else
    echo "${YLW}  [--]${RST} No new CDR row after 10s. Check that the call answered, and"
    echo "       that mod_cdr_csv is loaded:  fs_cli -x \"show modules\" | grep cdr"
  fi
fi

# ── a short human-readable summary to drop into the README ────────────────
{
  echo "Call capture: $LABEL"
  echo "Captured at:  $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "FreeSWITCH:   $(fs_cli -x 'version' 2>/dev/null | head -1)"
  echo
  echo "Channel UUIDs:"
  sed 's/^/  /' "$OUT/channel-uuids.txt" 2>/dev/null
  echo
  echo "Media addresses advertised in SDP (c=IN IP4):"
  grep -oE 'c=IN IP4 [0-9.]+' "$OUT/freeswitch-debug.log" 2>/dev/null | sort -u | sed 's/^/  /'
  echo
  echo "CDR rows produced:"
  sed 's/^/  /' "$OUT/cdr-rows.csv" 2>/dev/null || echo "  (none)"
} > "$OUT/SUMMARY.txt"
echo "${GRN}  [ok]${RST} SUMMARY.txt"

echo
echo "  Saved to: $OUT"
echo
echo "  Read first:   $OUT/SUMMARY.txt"
echo "  For the README, the useful excerpts are:"
echo "    - INVITE / 200 OK / ACK / BYE from sip-messages.txt"
echo "    - the c=IN IP4 line from sdp-bodies.txt"
echo "    - the CDR row, with duration / billsec / hangup_cause annotated"
echo
