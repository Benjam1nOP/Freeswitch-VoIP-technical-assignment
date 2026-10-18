# FreeSWITCH VoIP Technical Assignment

**Lakshay** · October 2026

![Agent Presence & Call State Service](06-agent-state/agent-presence-architecture.svg)

**Platform: FreeSWITCH** (the brief allowed Asterisk or FreeSWITCH). I run FreeSWITCH in
production today, carrying a real-time AI voice agent over a carrier SIP trunk, so this
is the platform I can speak to in depth rather than the one I would be learning on a
deadline.

```
FreeSWITCH 1.11.3-release-33213556856-ef32e20529 64bit
Debian GNU/Linux 12 (bookworm), kernel 6.1.0-54-amd64
VMware Workstation Pro · 2 vCPU · 2 GB RAM · 20 GB · bridged adapter
```

| Host | Address | Role |
|---|---|---|
| `fs-lab` | 192.168.1.4 (`ens33`) | FreeSWITCH |
| Laptop, MicroSIP | 192.168.1.10 | extension **1001** |
| Phone, Linphone | 192.168.1.6 | extension **1002** |

A local bridged VM rather than a cloud instance: the brief asks for "a test environment,"
and every fault I needed to demonstrate is reachable on a LAN. No public IP was exposed,
which also means no toll-fraud surface to defend for the duration of the exercise.

### Evidence layout

```
01-installation/        version, sofia status, registrations, modules, loaded dialplan
02-dialplan-and-config/ vars.xml + freeswitch.xml (redacted), both SIP profiles,
                        all dialplan files, directory entries
03-cdr/                 Master.csv, per-accountcode CSVs, cdr_csv.conf.xml
04-call-evidence/
   success/             working 1001 -> 1002 call
   broken/              same three dials with the fault staged
   fixed/               same three dials after the fix
05-troubleshooting/
   01-before/           healthy baseline
   02-broken/           fault staged
   03-fixed/            fault removed
06-agent-state/         DESIGN.md, prototype, 18 passing tests, architecture diagram
07-screenshots/         softphone registration and mid-call
```

Each `04-call-evidence/*` folder holds `freeswitch-debug.log` (a level-7 slice bounded to
that call window), `sip-messages.txt`, `sdp-bodies.txt`, `channel-uuids.txt`,
`hangup-and-causes.txt`, `cdr-rows-annotated.csv` and a `SUMMARY.txt`.

---

## 1. Installation & Configuration

Installed from the SignalWire Debian repository, `freeswitch-meta-vanilla` plus
`freeswitch-sounds-en-us-callie`.

Two practical notes that cost real time and are not in most write-ups:

**FreeSWITCH binaries have been gated behind a SignalWire personal access token since
1.10.** An unauthenticated `apt-get install freeswitch` fails. You register, generate a
token (the prefix is `swpat_` — a project API token, `swapi_`, does *not* work), and write
it into `/etc/apt/auth.conf.d/freeswitch.conf` with the literal username `signalwire`
before the repo resolves. Building from source instead is a real option but needs libks,
sofia-sip, spandsp and signalwire-c compiled first.

**`freeswitch-sounds-music` is not a package.** Music-on-hold ships per sample rate
(`freeswitch-sounds-music-8000` and friends), so installing the meta-package by that name
fails.

**internal** on 5060 (registration required, context `default`) and **external** on 5080
(IP-authenticated, context `public`), plus the IPv6 counterparts vanilla ships:

```
$ fs_cli -x "sofia status"
                    Name   Type                                Data     State
=============================================================================
           external-ipv6   profile            sip:mod_sofia@[::1]:5080   RUNNING (0)
                external   profile   sip:mod_sofia@223.181.108.88:5080   RUNNING (0)
   external::example.com   gateway             sip:joeuser@example.com   NOREG
             192.168.1.4     alias                            internal   ALIASED
           internal-ipv6   profile            sip:mod_sofia@[::1]:5060   RUNNING (0)
                internal   profile   sip:mod_sofia@223.181.108.88:5060   RUNNING (0)
=============================================================================
4 profiles 1 alias
```

Two things in that output are worth reading rather than skimming.

**The profiles advertise `223.181.108.88`, the WAN address — not the VM's `192.168.1.4`.**
FreeSWITCH's NAT detection resolved `ext-sip-ip` to the externally visible address at
startup. Media, however, stayed on the LAN: every SDP in the call captures carries
`c=IN IP4 192.168.1.4`. On a LAN-only lab where both endpoints and the switch share a
subnet, that mismatch is harmless and calls connect normally. It is also precisely the
condition that produces **one-way audio** the moment the two disagree about a routable
path, which is why `ext-sip-ip` and `ext-rtp-ip` are the first two values I would check on
any NAT complaint. Worth noting as a security point too: if 5060 were port-forwarded, that
profile is already advertising itself on a public address.

**`external::example.com` is `NOREG`** — vanilla's placeholder gateway, not mine. My
outbound extension deliberately references a gateway named `assignment_gw`, which does not
exist, and that is exactly why the outbound test in §2 fails the way it does.

Both endpoints register; see `01-installation/registrations.txt`.

**Credential handling.** The default install ships users `1000`–`1019` with a shared
`default_password` in `conf/vars.xml`. I changed it before bringing the profiles up.
Worth knowing for anyone capturing diagnostics: that password is echoed **verbatim in
every level-7 log line**, because the vanilla `global` extension traces the comparison it
is making —

```
Regex (FAIL) [global] ${default_password}(<redacted>) =~ /^1234$/ break=never
```

— so every debug capture leaks it unless you scrub. `freeswitch/package_submission.sh`
reads the real value out of `vars.xml` and redacts it across the whole evidence tree, then
re-greps to confirm. Everything in `02-dialplan-and-config/` is redacted on the way out.

---

## 2. Dialplan & Call Routing

| File | Context | Covers |
|---|---|---|
| `default/01_assignment.xml` | `default` | extension routing, blind and attended transfer, outbound |
| `default/99_assignment_invalid.xml` | `default` | invalid-destination handling |
| `public/01_assignment_inbound.xml` | `public` | inbound DID routing, explicit rejection of everything else |

### The finding that mattered most: where the include sits

My dialplan was correct and **never executed**. Nothing logged an error. The symptom was
simply that the wrong extension matched.

Stock Debian packaging puts

```xml
<X-PRE-PROCESS cmd="include" data="default/*.xml"/>
```

at the **end** of `<context name="default">`, after the vanilla extensions. The XML
pre-processor splices the included files in **at that position**, and within a context the
first matching extension wins unless it sets `continue="true"`. So vanilla
`Local_Extension` — which matches `^(10[01][0-9])$`, the same range as mine — caught
`1002` first, and sent `1005` to voicemail instead of my failure branch.

The fix is to move the include to immediately after the context opens:

```
$ grep -n 'context name="default"\|X-PRE-PROCESS.*default/\|<extension' \
    /etc/freeswitch/dialplan/default.xml
14:  <context name="default">
15:    <X-PRE-PROCESS cmd="include" data="default/*.xml"/>
17:    <extension name="unloop">
```

`freeswitch/deploy_dialplan.sh` detects and performs this automatically, with a backup and
a post-edit verification, and is idempotent. Evidence of the position is captured in
`05-troubleshooting/*/default.xml-include-position.txt`.

This is the single most useful thing I learned doing the exercise, and it generalises:
*"the config is right" and "the config is reached" are different claims.*

### Demonstrated routes

| Dial | Result | Matched |
|---|---|---|
| `1002` from `1001` | connects, two-way audio, PCMA both directions | `assignment_internal_extension` |
| `1005` (not registered) | failure branch, prompt, `NO_USER_RESPONSE` | `assignment_internal_extension` |
| `1050` | invalid-extension branch, `UNALLOCATED_NUMBER` | `assignment_invalid_extension` |
| `90123456789` | outbound; no carrier, so the failure branch fires | `assignment_outbound` |
| `9196` / `5000` | vanilla echo and IVR demo, untouched | `echo` / `ivr_demo` |
| transfer | A-leg moved to `5000`, B-leg released | `uuid_transfer` → `ivr_demo` |

### Error handling

The pattern that matters is `continue_on_fail=true` with actions **after** the `bridge`.
Without it a failed bridge ends the extension immediately and the caller gets silence then
a drop — the most common dialplan bug I see, and the difference between a call you can
investigate later and one that vanishes.

Dialling `1005`, which is in the directory but not registered:

```
[NOTICE] switch_ivr_originate.c:3059 Cannot create outgoing channel of type [user]
         cause: [USER_NOT_REGISTERED]
[INFO]   mod_dptools.c:3637 Originate Failed.  Cause: USER_NOT_REGISTERED
[WARNING] [assignment] bridge to 1005 failed: originate_disposition=USER_NOT_REGISTERED
EXECUTE  playback(ivr/ivr-call_cannot_be_completed_as_dialed.wav)
[NOTICE] mod_dptools.c:1374 Hangup ... [NO_USER_RESPONSE]
```

Note `cause=` and `sip=` came back empty in that warning. That is correct, not a bug:
`originate_disposition` is set, but `hangup_cause` and
`last_bridge_proto_specific_hangup_cause` are not, because the user was never registered
so **no INVITE was ever sent** — there was no SIP transaction to produce a cause code. On
this path the originate disposition is the only meaningful field.

### Call transfer

`*1<ext>` dialled as a fresh call is not a transfer — it is just a destination number.
Vanilla `Local_Extension` binds `*1`–`*4` mid-call via `bind_meta_app`; my extension
deliberately does not, so there is no DTMF feature code. A real transfer is a SIP `REFER`
from the softphone, or from the CLI:

```
$ fs_cli -x "show channels like 1001"
$ fs_cli -x "uuid_transfer c68f188b-bf43-4421-8403-a1b86a42263a 5000 XML default"
+OK
```

```
[NOTICE] switch_ivr.c:2303 Transfer sofia/internal/1001@192.168.1.4 to XML[5000@default]
[DEBUG]  switch_ivr_bridge.c:819 ending bridge by request from write function
[NOTICE] switch_ivr_bridge.c:1027 Hangup sofia/internal/1002@192.168.1.6:41307
         [CS_EXCHANGE_MEDIA] [NORMAL_CLEARING]
[INFO]   mod_dialplan_xml.c:648 Processing 1001 <1001>->5000 in context default
         Regex (PASS) [ivr_demo] destination_number(5000) =~ /^5000$/
```

The A-leg re-entered the dialplan at `5000`, the B-leg was released cleanly, and the CDR
corroborates it independently — see §3.

### Outbound, honestly

No carrier trunk was available, so `assignment_outbound` exercises its **failure** branch:

```
Invalid Gateway 'assignment_gw'
originate_disposition=INVALID_GATEWAY
playback(ivr/ivr-call_rejected.wav)
hangup(NORMAL_TEMPORARY_FAILURE)
```

The routing logic, caller-ID handling and error path are all demonstrated; the carrier leg
is not. I have not faked a completed PSTN call.

The pattern is `^(?:0|9)(\d{10})$` — eleven digits total, deliberately, so it cannot
collide with the four-digit service codes the default dialplan owns. The log proves the
isolation held even after the context was reordered:

```
Regex (FAIL) [assignment_outbound] destination_number(9196) =~ /^(?:0|9)(\d{10})$/
...
Regex (PASS) [echo] destination_number(9196) =~ /^9196$/
```

### Public context as a security boundary

Calls arriving on the external profile are unauthenticated, so `public` matches the DID
explicitly and rejects everything else. An open public context that can reach an outbound
extension is the standard toll-fraud path, so the rejection is deliberate rather than
tidiness. No DID was available to dial in on, so inbound routing is provided and explained
but not demonstrated end-to-end.

### A trade-off I introduced, stated plainly

Moving the include to the top means `assignment_internal_extension` matches before
vanilla's `global` extension (`continue="true"`), which populates the `spymap` and
`last_dial` hashes behind `*69` redial, eavesdrop and call-return. Those features no
longer work for calls to 1000–1019. Nothing the brief asks for, but it is a real
consequence of first-match-wins. In production I would either carry those `hash` inserts
into my own extension or put a `continue="true"` logging extension ahead of it.

---

## 3. Call Flow & CDR

`mod_cdr_csv`, writing `/var/log/freeswitch/cdr-csv/Master.csv` plus one file per
accountcode (`1001.csv`, `1002.csv`) — which is how per-agent extracts get built without
parsing the master.

The config is `<param name="legs" value="a"/>`. That is **one row per call from the A-leg's
point of view**, and the default template already carries `${bleg_uuid}`, so A/B
correlation is present without change. `legs="ab"` would add a second row written from the
B-leg with its own duration, billsec and hangup_cause, which can legitimately differ.
Useful; not required here.

Fields, in template order:

```
caller_id_name, caller_id_number, destination_number, context,
start_stamp, answer_stamp, end_stamp, duration, billsec, hangup_cause,
uuid, bleg_uuid, accountcode, read_codec, write_codec
```

**A successful call** (`04-call-evidence/success/cdr-rows-annotated.csv`):

```
"1001","1001","1002","default","2026-10-18 22:33:10","2026-10-18 22:33:13",
"2026-10-18 22:33:45","35","32","NORMAL_UNSPECIFIED",
"d83b6eb5-d3b9-469c-b3da-177e9cd6ab67","9da4b68c-484d-46fa-bd77-51375495a4b2",
"1001","PCMA","PCMA"
```

**The transfer**, same CDR, and it is the strongest single row in the submission:

```
"1001","1001","5000","default",...,"34","32","NORMAL_UNSPECIFIED",
"c68f188b-bf43-4421-8403-a1b86a42263a","","1001","PCMA","PCMA"
```

`destination_number` is **5000**, not 1002 — on the same channel UUID I passed to
`uuid_transfer` — and `bleg_uuid` is **empty**, because at hangup the A-leg was in the IVR
rather than bridged to anyone. The CDR proves the transfer happened without reference to
the log: one channel, destination rewritten mid-call, B-leg gone.

### How CDRs are generated

The record is written on **`CHANNEL_HANGUP_COMPLETE`**, not `CHANNEL_HANGUP`. Hangup fires
when teardown begins; complete fires when the channel is destroyed and the record is final.
Anything hooking events for billing or state tracking must use the later one or it races
the teardown.

I hit this concretely: my capture script originally read the CDR row count the instant the
call ended and reported "no new row," because the write landed a moment later. It now polls.
That is the same race a naive billing integration makes.

### How they are used to investigate

| Field | Why it is the one you read |
|---|---|
| `uuid` | correlates the row with every log line for that channel |
| `bleg_uuid` | links A-leg to B-leg; its **absence** means no bridge was attempted |
| `duration` vs `billsec` | duration is the whole channel lifetime including ringing, billsec is answer→hangup. The delta *is* the ring time. `billsec = 0` with a healthy duration is the no-answer signature |
| `hangup_cause` | who ended it and why |
| `read_codec` / `write_codec` | a mismatch or an unexpected codec points at transcoding or a negotiation problem |

In the success row above, `35` versus `32` is exactly the three seconds the phone rang.

**The before/after from the staged fault makes the point better than prose.** With the
fault in place, all three dials produced:

```
"1001","1001","1002","default",...,"1","1","UNALLOCATED_NUMBER","b9ab7d6f-...","",...
"1001","1001","9196","default",...,"2","2","UNALLOCATED_NUMBER","1cefadbd-...","",...
"1001","1001","5000","default",...,"2","2","UNALLOCATED_NUMBER","65cdc080-...","",...
```

A wall of one-to-two-second calls, all `UNALLOCATED_NUMBER`, all with no B-leg. That is the
CDR-level fingerprint of a routing fault, and it is spottable from a CSV dump without
reading a single log line. Those UUIDs are also the pivot: `b9ab7d6f-1f06-4f1a-a2ff-753f48de7402`
appears both in that row and in the dialplan trace matching `broken_catchall`.

---

## 4. Troubleshooting — root cause and fix

**Fault chosen: incorrect dialplan routing** — one of the four the brief names. A universal
`^.*$` catch-all in an *included* dialplan file. Chosen because the root cause is real
FreeSWITCH behaviour rather than a typo, and because the prevention is already shipped in
the deliverable.

Staged, diagnosed and removed by `freeswitch/stage_fault.sh`, which captures a healthy
baseline first so the before/after is genuine.

### Symptom

Every one of these landed on the invalid-entry prompt and hung up:

- `1002` — an agent extension that had been working
- `9196` — the vanilla echo test
- `5000` — the vanilla IVR demo

Nothing errored. No module failed. Calls just stopped arriving where they should.

### Diagnosis, by CLI

```
$ ls -1 /etc/freeswitch/dialplan/default/
00_broken.xml                 <- the staged fault
00_pizza_demo.xml
01_assignment.xml
01_example.com.xml
01_Talking_Clock.xml
99_assignment_invalid.xml
ideasip.com.noload
pulver.com.noload
sipbroker.com.noload
sipphone.com.noload
tollfreegateway.com.noload
```

Two details in that listing matter. The include glob is `default/*.xml`, so the `.noload`
files are present on disk and never parsed — that is how vanilla ships disabled gateway
examples. And `00_broken.xml` sorts ahead of every real file, which is the whole mechanism
of the fault.

```
$ fs_cli -x "xml_locate dialplan"
$ fs_cli -x "show dialplan"
$ grep -n 'context name="default"\|X-PRE-PROCESS.*default/' \
    /etc/freeswitch/dialplan/default.xml
```

Captured for all three phases in `05-troubleshooting/{01-before,02-broken,03-fixed}/`.

### Diagnosis, by log

With `/log 7`, the matching extension is named on every call:

```
Regex (PASS) [broken_catchall] destination_number(1002) =~ /^.*$/ break=on-false
Regex (PASS) [broken_catchall] destination_number(9196) =~ /^.*$/ break=on-false
Regex (PASS) [broken_catchall] destination_number(5000) =~ /^.*$/ break=on-false
```

Three different destinations, one extension. That is what distinguishes a *context*
failure from a broken extension: `9196` and `5000` are vanilla service codes I never
touched, and they died too.

### Root cause

Two rules combine.

1. The XML pre-processor splices `default/*.xml` into `<context name="default">` **at the
   position of the `X-PRE-PROCESS` line** — which §2 moved to the top of the context.
2. Within a context the **first matching extension wins** unless it sets `continue="true"`,
   and included files are spliced in case-sensitive ASCII filename order.

`00_broken.xml` therefore sorts first, is evaluated before every real extension, and its
`^.*$` condition matches every destination. The failure is silent and total.

### Fix, and verification

```
$ rm /etc/freeswitch/dialplan/default/00_broken.xml
$ fs_cli -x "reloadxml"
+OK [Success]
```

`1002`, `9196` and `5000` all recovered — captured in `04-call-evidence/fixed/`, with CDR
rows back to `NORMAL_*` causes and a populated `bleg_uuid` on the `1002` row.

### Prevention, which is the part that counts

My own `99_assignment_invalid.xml` does the job a catch-all is usually reached for, and it
is scoped to `^(1[0-9]{3})$` rather than `^.*$` **precisely so it cannot shadow the
context**. It matches only extension-shaped dials that cannot be routed — `1020`–`1999`,
since `01_assignment.xml` consumes `1000`–`1019` first — and the file carries a comment
explaining why. Service codes, conferences, voicemail and the IVR stay reachable.

`stage_fault.sh` also refuses to stage the fault if the include is still at the end of the
context, because the catch-all would not shadow anything from there and the demonstration
would be a lie.

Detect → diagnose → fix → prevent, with the prevention already in the shipped dialplan.

---

## 5. Agent Presence & Call State Service

Full design in `06-agent-state/DESIGN.md`; architecture diagram in
`06-agent-state/agent-presence-architecture.html` (interactive) and `.svg`. Working
prototype in `agent_state.py` with 18 passing tests, standard library only:

```
$ python test_agent_state.py
(see 06-agent-state/test-output.txt)
```

The brief asks for a prototype **or** an architecture. Both are here.

### Assumptions, stated before the design

**8,000 events/sec is a burst figure, not a sustained one.** With 2,000 agents that is four
events per agent per second, and no contact centre sustains that — a call produces perhaps
six to ten telephony events over several minutes. I sized the ingest path for the burst and
the storage path for the sustained average, with backpressure between them.

3,000 concurrent calls against 2,000 agents also implies calls that are not agent-bound
(queued, IVR, dialler pacing), so channel count and agent count are tracked separately.

### The four decisions that carry the design

**1 · Two orthogonal dimensions, not one enum; routability is derived.** Telephony owns
`device` and `call_state`, the agent application owns `presence`:

```
routable = Registered AND Available AND Idle AND not reserved AND not stale
```

A single merged status is the common approach and it is wrong: the state space becomes
ambiguous, it multiplies on every new status, and it hides useful contradictions.
`presence=Available` with `device=Unregistered` means an agent who believes they are ready
but whose softphone dropped — a real and frequent ticket a merged enum cannot express.

**2 · Ordering is enforced per dimension, which is only possible because of (1).**
Duplicates are suppressed by `event_id`; reordering by a high-water mark per
`(agent, dimension)`. The case that proves it necessary:

```
t=10  telephony  call_state = Talking
t=12  agent_app  presence   = AfterCallWork
t=11  telephony  call_state = Idle       <- arrives last
```

A global ordering rule lets the late event discard the presence update. Per-dimension
ordering applies it to `call_state` only and leaves `presence` intact, so both end correct.

**3 · Routing needs an atomic reserve, not a read.** Knowing an agent is free is not the
same as being allowed to claim them — two routers reading the same state both assign, and
the customer hears a call land on someone already talking. So the API is
`POST /agents/{id}/reserve`, a compare-and-set (one Lua script in Redis), carrying a short
TTL so a router that crashes mid-assignment does not strand the agent.

**4 · Event streams always drift, so reconciliation is mandatory.** An agent stuck in
`Talking` takes no further calls for the rest of the shift and nobody notices until they
complain. Three mitigations, all needed: **TTL staleness** so an agent we cannot vouch for
is not routable (fail closed); **periodic reconciliation** against
`sofia status profile internal reg` and `show channels`, with every correction logged so
the drift rate becomes a health metric; and an **agent-application heartbeat**.

I have hit this in production. My own platform tracks live sessions across nodes in a Redis
registry, and I had to build ghost-session detection because sessions died without cleaning
up while the registry kept reporting them live. A design that trusts the event stream alone
is correct on paper and wrong in operation.

### Restart recovery and 24/7 availability

Current state is a materialised view over an append-only log partitioned by `agent_id`, so
recovery is replay from the last committed offset — there is no bespoke recovery path to
get wrong. Because `apply()` is idempotent, replaying a log containing duplicates and
reordering rebuilds identical state, which is what makes at-least-once delivery safe.

Rolling deploys work because instances are members of one consumer group: a new instance
joins, partitions rebalance, the old one drains. No call is affected, because calls live in
FreeSWITCH rather than here. Schema changes are additive only with a versioned envelope,
and new status values are deployed read-side before producers emit them.

### Role of ESL

**Inbound ESL, one long-lived connection per node.** Inbound is the mode where my process
connects to FreeSWITCH and subscribes to the event stream. Outbound ESL, where the dialplan
hands a specific channel to an external process, is right for per-call application logic
and wrong here.

| FreeSWITCH event | Dimension | Value |
|---|---|---|
| `sofia::register` | device | Registered |
| `sofia::unregister` / `sofia::expire` | device | Unregistered |
| `CHANNEL_PROGRESS` | call_state | Ringing |
| `CHANNEL_ANSWER` | call_state | Talking |
| `CHANNEL_HOLD` / `CHANNEL_UNHOLD` | call_state | OnHold / Talking |
| `CHANNEL_HANGUP_COMPLETE` | call_state | Idle |

Three implementation points. Subscribe **selectively** rather than to `ALL`, because at
burst rates parsing the full firehose is wasted CPU and a source of lag. Use
`CHANNEL_HANGUP_COMPLETE`, for the reason in §3. And resolve the agent from a **channel
variable set in the dialplan**, not from the SIP user, because one user can own several
channels and bridged legs confuse the mapping — which is why `01_assignment.xml` carries:

```xml
<action application="export" data="agent_id=$1"/>
```

visible firing in the call logs as `EXPORT (export_vars) [agent_id]=[1002]`. The dialplan
in §2 and the service in §5 are deliberately connected at that one line.

The ESL connection is also its own failure domain: if it drops, telephony state goes stale
while the agent application keeps reporting, so a reconnect must trigger reconciliation
before the stream is trusted again.

---

## 6. Assumptions and limitations

- **Single-node lab.** Multi-node FreeSWITCH, media/signalling separation and an edge SIP
  proxy are discussed as production improvements, not demonstrated.
- **No carrier trunk**, so the outbound path shows its failure branch (§2).
- **No DID**, so inbound routing is provided and explained but not dialled end-to-end.
- **No TLS or SRTP** — plain UDP on a LAN. Production needs both.
- The agent-state service is a **prototype with an in-process store**; the mapping to
  Redis, Kafka and pub/sub is in `DESIGN.md`.
- Reporting definitions (hold as occupied, ACW as occupied, the occupancy denominator)
  vary by contact centre, so my formula is stated explicitly rather than assumed. In
  production it would be configuration, not code.
- The `1050` and `90123456789` captures are timestamped before the include was
  repositioned. The matched extension and hangup cause are identical either way, because
  `01_assignment.xml` is evaluated ahead of `01_example.com.xml` in both orderings.

## 7. What I would do differently in production

- Records in a database via `mod_odbc_cdr` or `mod_json_cdr` with a **monitored spool**,
  not CSV on disk. A silently growing spool is lost revenue data.
- TLS for SIP, SRTP for media, source-IP ACLs rather than an open 5060.
- Kamailio or OpenSIPS at the edge with media separated from signalling, so signalling and
  media capacity scale independently.
- Upstream **sequence numbers** on state events so ordering is exact rather than
  timestamp-heuristic. Cheap to produce, removes a whole class of bugs.
- A conformance harness replaying recorded event streams against the state service and
  asserting invariants: no agent routable while on a call, no negative interval, drift rate
  under threshold.
- Prometheus plus Homer/sipcapture, with alarms on registration churn, RTP loss and
  consumer lag.

---

## Reproducing this

Scripts in `freeswitch/`, all idempotent, all run as root on a Debian 12 box:

```
install_freeswitch.sh     repo + token auth + packages
deploy_dialplan.sh        install dialplan, reposition the include, verify
capture_call.sh <label>   wrap one call in siptrace + level-7, slice the log
collect_evidence.sh       config, CLI state and CDR, with passwords redacted
stage_fault.sh break|fix  the task-4 fault, with before/after diagnostics
package_submission.sh     audit deliverables, scrub secrets, archive
```
