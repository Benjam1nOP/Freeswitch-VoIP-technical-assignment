#!/bin/bash
# FreeSWITCH 1.10 installer for Debian 12 (bookworm)
#
# Written as a script on purpose: multi-line shell commands with backslash
# continuations and '=' signs get mangled when pasted into an SSH session on
# Windows. Copying one file over removes that whole class of failure.
#
# USAGE (as root on the Debian VM):
#     bash install_freeswitch.sh <SIGNALWIRE_TOKEN>
#
# It is safe to re-run: every step cleans up its own previous attempt first.

set -u

TOKEN="${1:-}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
ok()   { echo "${GRN}  [ok]${RST} $*"; }
warn() { echo "${YLW}  [!!]${RST} $*"; }
die()  { echo "${RED}  [XX]${RST} $*"; exit 1; }
step() { echo; echo "=== $* ==="; }

# ── preflight ────────────────────────────────────────────────────────────────
step "Preflight"

[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash $0 <TOKEN>"
[ -n "$TOKEN" ]      || die "No token given. Usage: bash $0 <SIGNALWIRE_TOKEN>"

CODENAME="$(lsb_release -sc 2>/dev/null || echo unknown)"
if [ "$CODENAME" != "bookworm" ]; then
  die "This is Debian '$CODENAME', not 'bookworm'.
       The SignalWire repo path is debian-release + codename, and there are no
       packages published for trixie. Reinstall with the Debian 12 netinst ISO."
fi
ok "Debian 12 bookworm confirmed"

case "$TOKEN" in
  PASTE*|your_*|"") die "That looks like the placeholder, not a real token." ;;
esac
ok "Token argument present (${#TOKEN} chars)"

# ── clean up any previous failed attempt ─────────────────────────────────────
step "Clearing previous attempts"
rm -f /usr/share/keyrings/signalwire-freeswitch-repo.gpg
rm -f /etc/apt/auth.conf.d/freeswitch.conf
rm -f /etc/apt/sources.list.d/freeswitch.list
ok "Old keyring, auth and source files removed"

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq gnupg2 wget lsb-release ca-certificates >/dev/null \
  || die "Could not install prerequisites (gnupg2 wget lsb-release)"
ok "Prerequisites present"

# ── 1. repository signing key ────────────────────────────────────────────────
step "1/5  Fetching repository signing key"

KEY=/usr/share/keyrings/signalwire-freeswitch-repo.gpg
URL=https://freeswitch.signalwire.com/repo/deb/debian-release/signalwire-freeswitch-repo.gpg

wget --quiet --http-user=signalwire --http-password="$TOKEN" -O "$KEY" "$URL" \
  || die "wget failed. Almost always the wrong KIND of token.
       You need a PERSONAL ACCESS TOKEN (prefix 'swpat_'), created from the
       user menu in the top-right of the dashboard — NOT a project API token
       (prefix 'swapi_') from the Project > API Credentials page.
       https://my.signalwire.com/?page=personal_access_tokens
       Note: a '401 Unauthorized' followed by '200 OK' in wget output is the
       normal HTTP Basic auth handshake, not an error."

if [ ! -s "$KEY" ]; then
  rm -f "$KEY"
  die "Key downloaded but is empty. The token was rejected."
fi
ok "Key saved: $(stat -c%s "$KEY") bytes"

# ── 2. apt credentials ──────────────────────────────────────────────────────
step "2/5  Storing apt credentials"

mkdir -p /etc/apt/auth.conf.d
printf 'machine freeswitch.signalwire.com login signalwire password %s\n' "$TOKEN" \
  > /etc/apt/auth.conf.d/freeswitch.conf
chmod 600 /etc/apt/auth.conf.d/freeswitch.conf

grep -q "password $TOKEN" /etc/apt/auth.conf.d/freeswitch.conf \
  || die "Credentials file did not write correctly"
ok "/etc/apt/auth.conf.d/freeswitch.conf written, mode 600"

# ── 3. package source ───────────────────────────────────────────────────────
step "3/5  Registering package source"

printf 'deb [signed-by=%s] https://freeswitch.signalwire.com/repo/deb/debian-release/ %s main\n' \
  "$KEY" "$CODENAME" > /etc/apt/sources.list.d/freeswitch.list

echo "  $(cat /etc/apt/sources.list.d/freeswitch.list)"
ok "/etc/apt/sources.list.d/freeswitch.list written"

# ── 4. apt update, and prove the repo actually resolved ─────────────────────
step "4/5  Refreshing package lists"

apt-get update 2>&1 | tee /tmp/fs-apt-update.log | sed 's/^/  /'

if grep -qi "freeswitch.signalwire.com" /tmp/fs-apt-update.log; then
  ok "SignalWire repo reached"
else
  die "No signalwire line in apt output — the repo did not resolve.
       Check /tmp/fs-apt-update.log. A 401 means the token is wrong."
fi

if grep -qiE "401|Unauthorized" /tmp/fs-apt-update.log; then
  die "Got 401 Unauthorized. The token is invalid or revoked. Generate a new one."
fi

if ! apt-cache policy freeswitch-meta-vanilla 2>/dev/null | grep -q Candidate; then
  die "Repo resolved but freeswitch-meta-vanilla has no candidate version.
       Run: apt-cache policy freeswitch-meta-vanilla"
fi
ok "freeswitch-meta-vanilla is available"

# ── 5. install ──────────────────────────────────────────────────────────────
step "5/5  Installing FreeSWITCH (a few minutes)"

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  freeswitch-meta-vanilla \
  freeswitch-sounds-en-us-callie \
  freeswitch-sounds-music \
  || die "Install failed. See the apt output above."
ok "Packages installed"

# vanilla config is sometimes shipped only as a sample tree
if [ ! -f /etc/freeswitch/freeswitch.xml ]; then
  if [ -d /usr/share/freeswitch/conf/vanilla ]; then
    cp -a /usr/share/freeswitch/conf/vanilla/. /etc/freeswitch/
    ok "Copied vanilla config into /etc/freeswitch"
  else
    warn "No freeswitch.xml in /etc/freeswitch and no vanilla sample found"
  fi
else
  ok "Config present at /etc/freeswitch"
fi

systemctl enable --now freeswitch >/dev/null 2>&1
sleep 4

# ── verify ──────────────────────────────────────────────────────────────────
step "Verification"

if systemctl is-active --quiet freeswitch; then
  ok "freeswitch.service is active"
else
  warn "Service is not active. Diagnose with:"
  echo "      systemctl status freeswitch --no-pager"
  echo "      journalctl -u freeswitch -n 50 --no-pager"
fi

echo
echo "  fs_cli -x 'version'"
fs_cli -x "version" 2>/dev/null | sed 's/^/    /' || warn "fs_cli could not connect yet"
echo
echo "  fs_cli -x 'sofia status'"
fs_cli -x "sofia status" 2>/dev/null | sed 's/^/    /' || true

IP="$(hostname -I | awk '{print $1}')"
echo
echo "========================================================================"
echo "  Next steps"
echo "========================================================================"
echo "  1. Change the default password (vanilla ships 1234 for users 1000-1019):"
echo "       vim /etc/freeswitch/vars.xml        # default_password=..."
echo "       fs_cli -x 'reloadxml'"
echo "       fs_cli -x 'sofia profile internal rescan'"
echo
echo "  2. Point both softphones at:   $IP   port 5060, UDP"
echo "       MicroSIP on the laptop -> 1001"
echo "       Linphone on your phone -> 1002"
echo
echo "  3. Confirm registration:"
echo "       fs_cli -x 'sofia status profile internal reg'"
echo
echo "  4. Call 1001 -> 1002, then dial 9196 (echo) and 9197 (tone)."
echo
echo "  5. THEN TAKE A VMWARE SNAPSHOT before task 4 breaks anything."
echo "========================================================================"
