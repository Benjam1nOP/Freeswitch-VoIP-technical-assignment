#!/bin/bash
# Deploy the assignment dialplan and verify it loaded in the right order.
#
# USAGE (as root, from inside the unzipped pack):
#     cd ~/assignment/freeswitch
#     sudo bash deploy_dialplan.sh

set -u

FSCONF=/etc/freeswitch
DEFXML="$FSCONF/dialplan/default.xml"
SRC="$(cd "$(dirname "$0")" && pwd)/dialplan"
STAMP="$(date +%Y%m%d-%H%M%S)"

GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; RST=$'\033[0m'
ok()   { echo "${GRN}  [ok]${RST} $*"; }
warn() { echo "${YLW}  [--]${RST} $*"; }
die()  { echo "${RED}  [XX]${RST} $*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash $0"
[ -d "$SRC" ]        || die "No dialplan/ next to this script. Run it from inside the unzipped pack."
[ -d "$FSCONF" ]     || die "No $FSCONF — is FreeSWITCH installed?"
[ -f "$DEFXML" ]     || die "No $DEFXML — unexpected FreeSWITCH layout."

include_position() {
  # "early" | "late" | "missing" — is default/*.xml spliced in before the
  # vanilla extensions, or after them?
  local inc ext
  inc=$(grep -n 'X-PRE-PROCESS.*include.*default/\*\.xml' "$DEFXML" | head -1 | cut -d: -f1)
  ext=$(grep -n '<extension' "$DEFXML" | head -1 | cut -d: -f1)
  if   [ -z "$inc" ];                       then echo "missing"
  elif [ -z "$ext" ] || [ "$inc" -lt "$ext" ]; then echo "early"
  else echo "late"
  fi
}

echo "=== Deploying dialplan ==="

install -m 644 "$SRC/default/01_assignment.xml"        "$FSCONF/dialplan/default/" && ok "default/01_assignment.xml"
install -m 644 "$SRC/default/99_assignment_invalid.xml" "$FSCONF/dialplan/default/" && ok "default/99_assignment_invalid.xml"
install -m 644 "$SRC/public/01_assignment_inbound.xml"  "$FSCONF/dialplan/public/"  && ok "public/01_assignment_inbound.xml"

# ── make the include actually take effect ─────────────────────────────────
# The XML pre-processor splices default/*.xml into <context name="default"> at
# the position of the X-PRE-PROCESS line, and within a context the first
# matching extension wins unless it sets continue="true". Stock Debian
# packaging puts that include at the END of the context, so the vanilla
# extensions are evaluated first: vanilla Local_Extension matches ^(10[01][0-9])$
# and therefore swallows 1002 and sends 1005 to voicemail, and the assignment's
# own extensions never run. Moving the include to the top of the context is the
# difference between this dialplan working and silently never being reached.
# Idempotent: re-running leaves an already-correct file untouched.
echo
echo "=== Include position in default.xml ==="
case "$(include_position)" in
  missing)
    die "No 'default/*.xml' include in $DEFXML. Expected stock packaging; inspect it by hand." ;;
  early)
    ok "already spliced in ahead of the vanilla extensions — nothing to change" ;;
  late)
    warn "include sits AFTER the vanilla extensions — assignment extensions would be shadowed"
    cp -a "$DEFXML" "$DEFXML.bak-$STAMP" && ok "backup: $DEFXML.bak-$STAMP"
    TMP="$(mktemp)"
    awk '
      /X-PRE-PROCESS[^>]*include[^>]*default\/\*\.xml/ { saved=$0; next }
      { buf[++n]=$0 }
      END {
        if (saved == "") saved="    <X-PRE-PROCESS cmd=\"include\" data=\"default/*.xml\"/>"
        for (i=1; i<=n; i++) {
          print buf[i]
          if (buf[i] ~ /<context[ \t]+name="default"/) print saved
        }
      }
    ' "$DEFXML" > "$TMP"
    # sanity-check before overwriting: the rewrite must still contain the
    # include exactly once, and must now place it early.
    if [ "$(grep -c 'X-PRE-PROCESS.*include.*default/\*\.xml' "$TMP")" -ne 1 ]; then
      rm -f "$TMP"; die "rewrite produced the wrong number of include lines — left $DEFXML untouched"
    fi
    cat "$TMP" > "$DEFXML"     # preserve inode, owner and mode
    rm -f "$TMP"
    if [ "$(include_position)" = "early" ]; then
      ok "moved the include to the top of <context name=\"default\">"
    else
      cp -a "$DEFXML.bak-$STAMP" "$DEFXML"
      die "reposition failed verification — restored the backup"
    fi ;;
esac
grep -n 'context name="default"\|X-PRE-PROCESS.*default/\|<extension' "$DEFXML" | head -5 | sed 's/^/    /'

echo
echo "=== Reloading ==="
fs_cli -x "reloadxml" | sed 's/^/  /'

echo
echo "=== Load order in the default context ==="
echo "  (included files splice in at the X-PRE-PROCESS position, in case-sensitive"
echo "   filename order; first match wins unless the extension sets continue=\"true\")"
ls -1 "$FSCONF"/dialplan/default/*.xml | xargs -n1 basename | sed 's/^/    /'

echo
echo "=== Extensions FreeSWITCH now knows ==="
fs_cli -x "show dialplan" 2>/dev/null | grep -iE 'assignment|XML' | head -20 | sed 's/^/  /' \
  || warn "show dialplan returned nothing unexpected — check 'fs_cli -x \"xml_locate dialplan\"'"

cat <<'EOF'

========================================================================
  Now test each branch by hand from extension 1001
========================================================================
  1002      -> extension routing, two-way audio          (task 2)
  1005      -> registered? no. Hits the FAILURE branch,
               plays "cannot be completed", hangup NO_USER_RESPONSE   (task 2 error handling)
  1050      -> invalid extension branch, "invalid entry",
               hangup UNALLOCATED_NUMBER                 (task 2 error handling)
  90123456789 -> outbound via gateway. NO CARRIER in the lab, so this
               exercises the failure branch and logs originate_disposition.
               That IS the error-handling evidence — say so in the README,
               do not pretend a PSTN call completed.

  TRANSFER — use a real transfer, not a feature code.
  Vanilla Local_Extension binds *1-*4 mid-call via bind_meta_app; the
  assignment extension above deliberately does not, so there is no DTMF
  feature code to press. Connect 1001 -> 1002, then either press Transfer
  in the softphone (sends SIP REFER), or from the CLI:
      fs_cli -x "show channels"
      fs_cli -x "uuid_transfer <uuid> 5000 XML default"

  Watch it happen live in another window:
      fs_cli
      /log 7

  Then capture the good call:
      sudo bash capture_call.sh success
========================================================================
EOF
