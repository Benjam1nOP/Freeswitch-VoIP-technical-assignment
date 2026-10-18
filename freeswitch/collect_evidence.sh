#!/bin/bash
# Gather deliverables 1 and 3 (config + dialplan, CDR + CLI output) into a tidy tree.
#
# Safe to re-run — it overwrites its own output and never modifies FreeSWITCH.
# Passwords are redacted on the way out.
#
# USAGE (as root on the Debian VM):
#     bash collect_evidence.sh
#
# Then from your laptop:
#     scp -r lakshay@192.168.1.4:~/submission ./

set -u

OUT="$HOME/submission"
FSCONF=/etc/freeswitch
CDRDIR=/var/log/freeswitch/cdr-csv

GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { echo "${GRN}  [ok]${RST} $*"; }
warn() { echo "${YLW}  [--]${RST} $*"; }
step() { echo; echo "=== $* ==="; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v fs_cli >/dev/null || { echo "fs_cli not found — is FreeSWITCH installed?"; exit 1; }

# Redact secrets from any XML we copy out.
redact() {
  sed -e 's/\(default_password=\)[^"]*/\1REDACTED/g' \
      -e 's/\(name="password" value="\)[^"]*/\1REDACTED/g' \
      -e 's/\(login signalwire password \).*/\1REDACTED/g' "$1"
}

mkdir -p "$OUT"/{01-installation,02-dialplan-and-config/sip_profiles,02-dialplan-and-config/dialplan/default,02-dialplan-and-config/dialplan/public,02-dialplan-and-config/directory,03-cdr}

# ── 1. installation evidence ────────────────────────────────────────────────
step "Deliverable 1 — installation and runtime state"

D="$OUT/01-installation"

dump() {  # dump "<fs_cli command>" <filename>
  local cmd="$1" file="$2"
  { echo "\$ fs_cli -x \"$cmd\""; echo; fs_cli -x "$cmd" 2>&1; } > "$D/$file"
  ok "$file"
}

dump "version"                            version.txt
dump "status"                             status.txt
dump "sofia status"                       sofia-status.txt
dump "sofia status profile internal"      sofia-profile-internal.txt
dump "sofia status profile external"      sofia-profile-external.txt
dump "sofia status profile internal reg"  registrations.txt
dump "show registrations"                 show-registrations.txt
dump "show modules"                       modules.txt
dump "show dialplan"                      dialplan-loaded.txt
dump "xml_locate dialplan"                dialplan-load-order.txt

{
  echo "=== OS ==="
  . /etc/os-release && echo "$PRETTY_NAME  (codename: $(lsb_release -sc))"
  uname -a
  echo
  echo "=== FreeSWITCH packages ==="
  dpkg -l | awk '/freeswitch/ {print $2, $3}'
  echo
  echo "=== network ==="
  ip -4 addr show | sed -n 's/^\s*inet \([0-9.]*\/[0-9]*\).*/\1/p'
  echo
  echo "=== listening sockets (SIP) ==="
  ss -lunp 2>/dev/null | grep -E '5060|5080' || echo "(none shown)"
} > "$D/os-and-packages.txt"
ok "os-and-packages.txt"

# ── 2. config + dialplan ────────────────────────────────────────────────────
step "Deliverable 1 — configuration files and dialplan"

C="$OUT/02-dialplan-and-config"

for f in vars.xml freeswitch.xml; do
  [ -f "$FSCONF/$f" ] && { redact "$FSCONF/$f" > "$C/$f"; ok "$f (redacted)"; }
done

for f in internal.xml external.xml; do
  [ -f "$FSCONF/sip_profiles/$f" ] && { redact "$FSCONF/sip_profiles/$f" > "$C/sip_profiles/$f"; ok "sip_profiles/$f"; }
done

[ -f "$FSCONF/dialplan/default.xml" ] && { redact "$FSCONF/dialplan/default.xml" > "$C/dialplan/default.xml"; ok "dialplan/default.xml"; }
[ -f "$FSCONF/dialplan/public.xml" ]  && { redact "$FSCONF/dialplan/public.xml"  > "$C/dialplan/public.xml";  ok "dialplan/public.xml"; }

n=0
for f in "$FSCONF"/dialplan/default/*.xml; do
  [ -f "$f" ] || continue
  redact "$f" > "$C/dialplan/default/$(basename "$f")"; n=$((n+1))
done
ok "dialplan/default/ — $n file(s)"

n=0
for f in "$FSCONF"/dialplan/public/*.xml; do
  [ -f "$f" ] || continue
  redact "$f" > "$C/dialplan/public/$(basename "$f")"; n=$((n+1))
done
ok "dialplan/public/ — $n file(s)"

for ext in 1001 1002; do
  f="$FSCONF/directory/default/$ext.xml"
  [ -f "$f" ] && { redact "$f" > "$C/directory/$ext.xml"; ok "directory/$ext.xml (redacted)"; }
done

# Which of my assignment files actually loaded?
{
  echo "Assignment dialplan files present in $FSCONF/dialplan:"
  ls -1 "$FSCONF"/dialplan/default/ "$FSCONF"/dialplan/public/ 2>/dev/null
} > "$C/files-present.txt"
ok "files-present.txt"

# ── 3. CDR ──────────────────────────────────────────────────────────────────
step "Deliverable 3 — CDR and configuration"

R="$OUT/03-cdr"

if [ -f "$FSCONF/autoload_configs/cdr_csv.conf.xml" ]; then
  cp "$FSCONF/autoload_configs/cdr_csv.conf.xml" "$R/"
  LEGS=$(grep -oP 'name="legs"\s+value="\K[^"]+' "$FSCONF/autoload_configs/cdr_csv.conf.xml" 2>/dev/null || echo "?")
  ok "cdr_csv.conf.xml  (legs=\"$LEGS\")"
  # legs="a" is NOT a gap. It writes one row per call, from the A leg's point of
  # view, and the default template already carries ${bleg_uuid} — so A/B
  # correlation is present without changing anything. legs="ab" adds a SECOND
  # row written from the B leg, with its own duration, billsec and hangup_cause,
  # which can legitimately differ from the A leg's. Useful, not required.
  [ "$LEGS" = "a" ] && echo "       note: one row per call, A-leg view; bleg_uuid in that row gives
       the correlation. \"ab\" would add a separate B-leg row."
fi

if [ -d "$CDRDIR" ]; then
  cp -r "$CDRDIR"/. "$R/cdr-csv/" 2>/dev/null || mkdir -p "$R/cdr-csv"
  ROWS=$(wc -l < "$CDRDIR/Master.csv" 2>/dev/null || echo 0)
  ok "cdr-csv/ copied — $ROWS row(s) in Master.csv"
  [ "$ROWS" -eq 0 ] && warn "No CDR rows yet. Place a call, then re-run this script."
  # a readable version of the most recent rows
  if [ -s "$CDRDIR/Master.csv" ]; then
    tail -5 "$CDRDIR/Master.csv" > "$R/last-5-rows.csv"
    ok "last-5-rows.csv  (paste these into the README and annotate the fields)"
  fi
else
  warn "No $CDRDIR — is mod_cdr_csv loaded?  fs_cli -x 'show modules' | grep cdr"
fi

# ── summary ─────────────────────────────────────────────────────────────────
step "Done"
echo
find "$OUT" -type f | sed "s|$HOME/|  |" | sort
echo
SIZE=$(du -sh "$OUT" | cut -f1)
echo "  Collected: $SIZE in $OUT"
echo
echo "========================================================================"
echo "  Still needs doing by hand"
echo "========================================================================"
echo "  D2  call evidence   ->  bash capture_call.sh success"
echo "  D4  agent state     ->  python3 test_agent_state.py  (on your laptop)"
echo "  D5  README          ->  SUBMISSION_README.md in the pack"
echo "      screenshots     ->  MicroSIP registered + mid-call, Linphone connected"
echo
echo "  Pull it down from your laptop:"
echo "      scp -r $(whoami)@$(hostname -I | awk '{print $1}'):~/submission ./"
echo "========================================================================"
