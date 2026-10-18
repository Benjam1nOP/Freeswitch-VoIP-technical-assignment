# Agent Presence & Call State Service — design

Task 5 of the CC33 technical assignment. Draft in your voice — read it, change what you disagree with, and be ready to defend every claim.

**Scale given:** ~2,000 logged-in agents, up to 3,000 concurrent calls, ~8,000 events/sec. Two independent event sources arriving over a message queue, possibly duplicated and possibly out of order.

---

## 0. Assumptions, stated up front

1. **8,000 events/sec is a burst figure, not a sustained one.** With 2,000 agents that is four events per agent per second, which no real contact centre sustains — a call generates perhaps six to ten telephony events over several minutes. I am sizing the ingest path for the burst and the storage path for the sustained average, with backpressure between them.
2. 3,000 concurrent calls against 2,000 agents implies calls that are not agent-bound (queued, IVR, outbound dialler pacing), so **channel count and agent count are tracked separately**.
3. Events carry an agent identifier, a source, a source timestamp, and a unique event id. If the upstream can also supply a **monotonic per-source sequence number**, ordering becomes exact rather than heuristic — I would ask for this, because it is cheap to produce and removes a whole class of bugs. The design works either way.
4. Clocks between the telephony platform and the agent application are not assumed to be in sync beyond NTP accuracy.
5. "Occupancy" is defined differently by different contact centres, so I state my formula in §6 rather than assume one.

---

## 1. State model — two orthogonal dimensions, not one enum

The most common mistake here is collapsing both event sources into a single agent-status enum. That produces an ambiguous state space (is `OnBreak` while `Talking` legal?) and makes every new status a combinatorial change.

The two sources describe **independent dimensions**, so model them independently:

```
device      ∈ { Unregistered, Registered }                        ← telephony
call_state  ∈ { Idle, Ringing, Talking, OnHold }                  ← telephony
presence    ∈ { LoggedOut, Available, OnBreak, AfterCallWork }    ← agent application
```

Then **routability is a derived predicate, never a stored field**:

```
routable = device == Registered
        && presence == Available
        && call_state == Idle
        && not reserved
        && telephony_state_is_fresh
```

Three consequences worth stating:

- Every combination is representable, including the diagnostically useful contradictions — `presence=Available` with `device=Unregistered` means an agent who thinks they are ready but whose softphone has dropped. That is a real and common support ticket, and a single-enum model hides it.
- New statuses from either source extend one dimension instead of multiplying the state space.
- Because routability is computed, the rule can change without migrating stored state.

**This is also what makes correct ordering possible** — see §3.

---

## 2. Architecture

```
  FreeSWITCH nodes                      Agent application
         │                                      │
    ESL (inbound)                          app events
         │                                      │
         ▼                                      ▼
  ┌──────────────┐                     ┌──────────────┐
  │ ESL adapter  │                     │ app adapter  │
  │ normalises   │                     │ normalises   │
  └──────┬───────┘                     └──────┬───────┘
         │                                    │
         └──────────────┬─────────────────────┘
                        ▼
            event log  (Kafka, partitioned by agent_id)
                        │
                        ▼
            ┌─────────────────────────┐
            │  state service          │   stateful consumer
            │  per-dimension LWW      │   N instances,
            │  dedupe + staleness     │   one consumer group
            └───────┬─────────┬───────┘
                    │         │
       ┌────────────┘         └────────────┐
       ▼                                   ▼
  Redis: current state              pub/sub change stream
  (hot read + atomic reserve)        (dashboard fanout)
       │                                   │
       ▼                                   ▼
  routing engine                    supervisor dashboard
                        │
                        ▼
            event log → warehouse (reporting)
```

**Why an append-only log in the middle.** It gives three things at once that are otherwise three separate problems: replay for restart recovery, a durable source for reporting independent of the live state, and per-key ordering for free.

**Partition the log by `agent_id`.** This is the single most important infrastructure choice. It gives per-agent ordering from the broker, so events for one agent are never processed concurrently by two instances, and it scales horizontally — 2,000 agents across, say, 24 partitions is comfortably balanced. Partitioning by event time or round-robin would throw ordering away and force application-level locking.

**Current state in Redis, not only in process memory.** Service instances stay effectively stateless so they can be replaced during a rolling deploy, and the routing engine gets a sub-millisecond read path that does not depend on which instance consumed the event.

---

## 3. Duplicate and out-of-order handling

Two mechanisms, and they solve different problems.

**Deduplication — by `event_id`.** A short-TTL set (a few minutes, comfortably wider than the queue's redelivery window). Catches at-least-once redelivery of the *same* event cheaply.

**Reordering — per-dimension high-water mark.** For each `(agent_id, dimension)` the service stores the sequence number, or timestamp, of the last applied event. An arriving event is applied only if it is **newer than the high-water mark for its own dimension**. Last-writer-wins, scoped to the dimension.

This is where §1 pays off. Consider:

```
t=10  telephony   call_state = Talking
t=12  agent_app   presence   = AfterCallWork
t=11  telephony   call_state = Idle        ← arrives last, out of order
```

With one combined enum, the late event at t=11 overwrites everything and you lose the presence update. With per-dimension ordering, the t=11 event is compared only against the `call_state` high-water mark (t=10), is newer, and is applied — while `presence` keeps its t=12 value. **Both dimensions end correct.** A global ordering rule gets this wrong in a way that is extremely hard to debug from a dashboard.

**Without upstream sequence numbers**, use the source timestamp plus a small tolerance, and keep the dedupe window generous. State the limitation: two events from the same source within clock resolution cannot be strictly ordered, so the adapter should attach its own monotonic counter at ingest — which is why I would ask for a sequence number upstream.

**Terminal-state guard.** `LoggedOut` and `Unregistered` are absorbing within their dimension until a newer event explicitly moves them. This prevents a late `Ringing` from resurrecting an agent who has gone home.

---

## 4. The routing engine needs more than a read

Knowing that an agent is routable is not the same as being allowed to assign them. Between a router's read and its assign, a second router can read the same state and assign the same agent — a double-assignment, which in a contact centre means a customer hearing a call connect to someone already talking.

So the routing API is not `GET /routable`. It is an **atomic reserve**:

```
POST /agents/{id}/reserve   → 200 {reservation_id, expires_at} | 409 Conflict
```

Implemented as a compare-and-set: flip to reserved **only if** the agent is currently routable, in one atomic operation. In Redis that is a short Lua script or a `WATCH`/`MULTI` transaction; the Lua script is preferable because it is a single round trip and cannot be interleaved.

**The reservation carries a TTL** (a few seconds). If the router crashes between reserving and originating the call, the reservation expires and the agent returns to the pool rather than being stranded. The telephony `Ringing` event then supersedes the reservation naturally.

This is the detail that separates a design from an implementation plan, and it is worth volunteering before being asked.

---

## 4b. API surface

Three readers with three different needs (§5), so three different shapes rather than one
generic endpoint. Prototype equivalents are in `agent_state.py`.

### Ingest — not an HTTP API

Events arrive on the message queue, not over HTTP. There is deliberately no
`POST /events`: an HTTP ingest endpoint would mean the producers depend on this service
being up, and a restart here would lose telephony state. The log is the contract.

```
topic: agent-events          partitioned by agent_id
{
  "event_id":  "uuid",              // dedupe key
  "agent_id":  "A1042",
  "source":    "telephony" | "agent_app",
  "dimension": "device" | "call_state" | "presence",
  "value":     "Talking",
  "seq":       8814,                // monotonic per (agent_id, source)
  "ts":        1761045123.482       // source clock — reporting only, never ordering
}
```

### Routing engine — correctness first

```
POST   /agents/{id}/reserve          → 200 {reservation_id, expires_at} | 409 Conflict
DELETE /agents/{id}/reserve/{rid}    → 204 | 404
GET    /agents/routable?skill=...&limit=n  → [{agent_id, idle_since}]
```

`reserve` is the important one and it is a compare-and-set, not a read (§4). `GET
/routable` is advisory only — a router must still `reserve` before originating, because
anything it read may be stale by the time it acts.

### Supervisor dashboard — freshness over precision

```
GET /agents                          → full snapshot, on connect and reconnect only
WS  /agents/stream                   → deltas, coalesced into a ~500 ms tick
    { "agent_id", "dimension", "from", "to", "routable", "stale" }
```

Deltas rather than snapshots, because 2,000 agents polling becomes a thundering herd
while the actual change rate is a few events per agent per minute. A full snapshot is
served only on connect so a reconnecting browser cannot drift.

### Reporting — completeness over latency

```
GET /agents/{id}/report?from=&to=    → talk/break/acw/staffed/occupied + occupancy
GET /reports/occupancy?from=&to=     → per-agent rollup for the window
```

Computed from transition intervals on the log (§6), not from runtime counters, so any
window can be recomputed and figures never drift. These may lag the live state by
minutes and that is the correct trade.

### Operational

```
GET /healthz                         → liveness
GET /readyz                          → consumer lag, last-event age, drift rate
POST /admin/reconcile                → force a reconciliation pass (§8)
```

`readyz` is the one that matters in production: it fails when consumer lag or the age of
the newest event crosses a threshold, so a lagging instance is pulled from the load
balancer rather than quietly serving stale routing decisions.

---

## 5. The three consumers need different guarantees

| Consumer | Consistency need | Freshness | Served from |
|---|---|---|---|
| **Routing engine** | Strongest — must never double-assign | Immediate | Redis current state + atomic reserve |
| **Supervisor dashboard** | Eventual is fine | ~1 s | Pub/sub change stream pushed over WebSocket |
| **Reporting** | Durable and complete, may lag | Minutes | The event log, aggregated into a warehouse |

Designing one API to serve all three is the second common mistake. The dashboard wants high fanout and tolerates staleness; routing wants correctness and tolerates low fanout; reporting wants completeness and tolerates latency. They get three different paths off the same log.

**Dashboard fanout.** 2,000 agents changing state a few times a minute, fanned out to tens of supervisors, is small — but push deltas, not snapshots, and coalesce bursts into a tick (say 500 ms) so a storm of events does not become a storm of frames. Send a full snapshot only on connect and on reconnect.

**Backpressure order, when the system is behind.** Shed dashboard updates first — they are the least valuable and self-correct on the next tick. Never shed the durable log write, and never shed routing. Making the shedding order explicit is the kind of thing that only comes from having operated something.

---

## 6. Reporting — talk time, break time, occupancy

Compute these from **state-transition intervals**, not from counters incremented at runtime. Counters drift and cannot be recomputed; intervals can be replayed.

Every applied transition appends `(agent_id, dimension, from, to, effective_at)` to the log. Durations in a reporting window are then the sum of intervals, with the interval clipped at the window boundaries.

```
talk_time   = Σ time in call_state ∈ {Talking, OnHold}
break_time  = Σ time in presence   == OnBreak
acw_time    = Σ time in presence   == AfterCallWork
staffed     = Σ time in presence   != LoggedOut

occupancy   = (talk_time + acw_time) / (staffed - break_time)
```

**State the ambiguities rather than quietly resolving them** — this is the part that shows contact-centre literacy:

- Does hold time count as talk time? I include it, because the agent is occupied and cannot take another call. Some operations report it separately; it should be a configuration flag, not a hard-coded choice.
- Is ACW occupied or available? I count it as occupied. Again, configurable.
- Occupancy denominators vary by operation — some use staffed time, some use staffed minus break. I have used staffed minus break and labelled it, so a supervisor comparing against another system can see why the numbers differ.

Open intervals at the window edge are clipped, and the agent's state at the start of the window is reconstructed from the last transition before it — which is why the log matters rather than just current state.

---

## 7. FreeSWITCH ESL — the role of the interface

ESL has two modes and the distinction is the heart of what the task is asking:

- **Inbound ESL** — my process connects *to* FreeSWITCH on 8021, authenticates, and subscribes to the event stream. One long-lived connection per FreeSWITCH node. This is what a presence service uses: it is a firehose of what is happening, not a controller of any one call.
- **Outbound ESL** — the dialplan hands a specific channel to my process (`<action application="socket" .../>`), which then drives that one call. Useful for per-call application logic, wrong for this service.

So: **inbound ESL, one connection per node, filtered to the events that change agent state.**

| FreeSWITCH event | Dimension | Value |
|---|---|---|
| `CUSTOM sofia::register` | device | Registered |
| `CUSTOM sofia::unregister` / `sofia::expire` | device | Unregistered |
| `CHANNEL_CALLSTATE` (→ RINGING) / `CHANNEL_PROGRESS` | call_state | Ringing |
| `CHANNEL_ANSWER` | call_state | Talking |
| `CHANNEL_HOLD` | call_state | OnHold |
| `CHANNEL_UNHOLD` | call_state | Talking |
| `CHANNEL_HANGUP_COMPLETE` | call_state | Idle |

Four implementation notes that matter:

1. **Subscribe selectively.** `event plain CHANNEL_ANSWER CHANNEL_HANGUP_COMPLETE ...` rather than `event plain ALL`. At 8,000 events/sec, parsing the full firehose — including per-packet media events — is wasted CPU and a real source of lag.
2. **Use `CHANNEL_HANGUP_COMPLETE`, not `CHANNEL_HANGUP`.** Hangup fires when teardown begins; complete fires when the channel is destroyed and the CDR is final. Acting on the earlier event races the teardown.
3. **Map channel to agent via a channel variable**, set in the dialplan (`<action application="set" data="agent_id=..."/>`) and exported onto the B leg. Do not infer the agent from the SIP user, because the same user can have several channels and bridged legs confuse the mapping.
4. **The ESL connection itself is a failure domain.** If it drops, you stop receiving telephony events while the agent application keeps sending — so the state silently goes stale in one dimension only. On reconnect, resynchronise before trusting the stream again (§8).

---

## 8. The failure mode that actually bites — state drift

Event streams drift. Something is always missed: an ESL reconnect, a dropped queue message, a FreeSWITCH node restarting mid-call, an agent's browser closing without a `LoggedOut`.

The symptom in a contact centre is specific and expensive. An agent stuck in `Talking` after the call ended never receives another call for the rest of their shift and nobody notices until they complain. An agent stuck in `Available` after their device died receives calls that ring into nothing, and the customer hears silence then a drop.

**I have hit exactly this in production.** My own platform tracks live sessions across multiple nodes in a Redis registry, and I had to build ghost-session detection because sessions died without cleaning up and the registry kept claiming they were live. Event streams alone were not enough. Three mitigations, and all three are needed:

**1 · TTL-based staleness.** Every dimension carries a last-seen timestamp. If no telephony event has arrived for an agent within a threshold, the telephony dimension is marked **stale** and `routable` becomes false. Fail closed: a stale agent is not routed to. This bounds the damage of any missed event to the threshold.

**2 · Periodic reconciliation against the source of truth.** On a timer, and always after an ESL reconnect, poll FreeSWITCH for ground truth and correct drift:

```
sofia status profile internal reg     → who is actually registered
show channels                         → who is actually on a call
```

Then diff against stored state, correct the differences, and **log every correction as a drift event**. The drift rate is a health metric: if it climbs, something upstream is broken and you want to know before the supervisors do.

**3 · Agent-application heartbeat.** Presence requires a periodic keepalive. No heartbeat within the window means the agent is demoted out of `Available` rather than left there forever.

Say plainly that reconciliation is not a nice-to-have. A design that relies purely on the event stream is correct on paper and wrong in production, and that is the most useful thing experience teaches here.

---

## 9. Restart recovery

Because current state is a materialised view over an append-only log, recovery is replay — there is no bespoke recovery path to get wrong.

1. The consumer commits its log offset alongside the state it produced.
2. On restart it resumes from the last committed offset.
3. Replay is **idempotent** — the per-dimension high-water marks and the dedupe set mean re-processing already-applied events changes nothing. This is the property that makes at-least-once delivery safe, and it is the reason to build idempotency in from the start rather than bolt on exactly-once semantics.
4. For a cold start with no Redis state, replay a bounded window (long enough to cover the longest plausible shift) rather than all history, then run a reconciliation pass against FreeSWITCH to close any gap.

The prototype's `test_restart_recovery_is_deterministic` demonstrates this directly: the same event log replayed into a fresh service produces an identical state, including when the log contains duplicates and reordering.

---

## 10. 24/7 availability with no maintenance window

**Rolling deploys.** Instances are members of one consumer group. A new instance joins, partitions rebalance, the old instance drains and exits. In-flight events are reprocessed from the last committed offset, which is safe because processing is idempotent. No call is affected because calls live in FreeSWITCH, not here.

**Schema evolution without coordinated releases.** Additive event fields only, with a version on the envelope, and consumers must ignore unknown fields. A new status value in either dimension is deployed read-side first — consumers learn to understand it before producers start emitting it. Never rename or repurpose a field in place.

**Redundancy.** Log replication factor ≥3 with acknowledgement from a majority. Redis with a replica and automatic failover; the loss window is bounded by the staleness threshold and closed by a reconciliation pass, so a Redis failover degrades routing briefly rather than corrupting state.

**Capacity and backpressure.** Size ingest for the burst figure. When the consumer lags, shed in the order from §5. Alarm on consumer lag, drift-correction rate, and reservation-expiry rate — the last one is a good early signal that the routing engine is unhealthy.

**Multi-node FreeSWITCH.** One ESL connection per node, each adapter tagging its source. Because ordering is per `agent_id` and an agent is registered to one node at a time, cross-node ordering is not a problem in practice — but the reconciliation pass must union across all nodes so a channel on node B is not read as a drift on node A.

---

## 11. What I would do differently with more time

Honest list, worth including because it shows judgement about scope rather than gold-plating:

- Replace timestamp-based ordering with upstream sequence numbers, and make the adapters assign them if the sources cannot.
- Make the occupancy definitions configuration rather than code, since every contact centre defines them differently.
- Add a conformance harness that replays recorded production event streams against the service and asserts invariants — no agent routable while on a call, no negative interval, drift rate under a threshold.
- Push reporting aggregation into a columnar store rather than computing intervals on read.
- Model per-tenant isolation properly if this is multi-tenant: partition keys prefixed by tenant, and per-tenant rate limits so one tenant's dialler burst cannot starve another's routing.
