"""Agent Presence & Call State Service — working prototype.

Task 5 of the CC33 technical assignment. Standard library only, so it runs anywhere
with `python agent_state.py` or under pytest. See DESIGN.md for the reasoning.

WHAT THIS DEMONSTRATES
----------------------
1. Two ORTHOGONAL state dimensions (telephony vs agent application) rather than one
   combined enum, with routability as a DERIVED predicate.
2. Idempotent, order-insensitive event application:
     * duplicates rejected by event_id
     * out-of-order rejected by a per-(agent, dimension) high-water mark
     * a late event in one dimension cannot clobber a newer event in another
3. Atomic reserve-with-TTL, so two routers cannot both claim one agent.
4. TTL-based staleness, so a missed event degrades to "not routable" rather than
   to a wrong answer. Fail closed.
5. Deterministic restart recovery: replaying the log rebuilds identical state.
6. Interval-based reporting (talk / break / ACW / occupancy) computed from the
   transition log, so figures can always be recomputed rather than drifting.

MAPPING TO PRODUCTION
---------------------
    this prototype              production
    ------------------          ------------------------------------------
    in-process dict             Redis hash per agent (hot read path)
    _applied_seq high-water     Redis field compare, or Lua CAS
    reserve()                   single Lua script (atomic, one round trip)
    _transitions list           append-only log (Kafka, partitioned by agent_id)
    _subscribers callbacks      Redis pub/sub -> WebSocket fanout
    replay()                    consumer resuming from its committed offset
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Iterable


# ─────────────────────────── dimensions ───────────────────────────
# Three independent dimensions. Collapsing these into one enum is the most common
# mistake in this problem: it makes the state space ambiguous and, more importantly,
# makes correct ordering impossible (see apply()).

class Device(str, Enum):
    """Telephony: is the agent's endpoint registered?"""
    UNREGISTERED = "Unregistered"
    REGISTERED = "Registered"


class CallState(str, Enum):
    """Telephony: what is the agent's channel doing?"""
    IDLE = "Idle"
    RINGING = "Ringing"
    TALKING = "Talking"
    ON_HOLD = "OnHold"


class Presence(str, Enum):
    """Agent application: what has the agent told us they are doing?"""
    LOGGED_OUT = "LoggedOut"
    AVAILABLE = "Available"
    ON_BREAK = "OnBreak"
    AFTER_CALL_WORK = "AfterCallWork"


DIMENSION_TYPES = {"device": Device, "call_state": CallState, "presence": Presence}
TELEPHONY_DIMENSIONS = ("device", "call_state")

# Which source is allowed to write which dimension. An event from the wrong source
# is rejected rather than trusted — cheap defence against a misconfigured producer.
SOURCE_DIMENSIONS = {
    "telephony": {"device", "call_state"},
    "agent_app": {"presence"},
}


@dataclass(frozen=True)
class Event:
    """One normalised state event from either source.

    seq is monotonic per (agent_id, source). If the upstream cannot provide it, the
    adapter assigns one at ingest — see DESIGN.md §3 for why timestamps alone are
    not sufficient.
    """
    event_id: str
    agent_id: str
    source: str       # "telephony" | "agent_app"
    dimension: str    # "device" | "call_state" | "presence"
    value: str
    seq: int
    ts: float         # source clock, epoch seconds — for reporting, not for ordering


class Rejected(str, Enum):
    """Why an event was not applied. Exposed so the caller can meter it."""
    DUPLICATE = "duplicate"          # same event_id seen already
    OUT_OF_ORDER = "out_of_order"    # seq <= high-water mark for that dimension
    NO_CHANGE = "no_change"          # newer, but the value is unchanged
    WRONG_SOURCE = "wrong_source"    # source not authoritative for that dimension
    BAD_VALUE = "bad_value"          # value not in the dimension's enum


@dataclass
class AgentState:
    agent_id: str
    device: Device = Device.UNREGISTERED
    call_state: CallState = CallState.IDLE
    presence: Presence = Presence.LOGGED_OUT

    # Per-dimension high-water marks. THIS is what makes ordering correct per
    # dimension rather than globally.
    applied_seq: dict[str, int] = field(default_factory=dict)
    # Local receipt time per dimension, used for staleness. Deliberately NOT the
    # source timestamp: we are asking "when did we last hear anything", which is a
    # question about our own clock.
    last_seen: dict[str, float] = field(default_factory=dict)

    reserved_until: float = 0.0
    reservation_id: str | None = None

    def snapshot(self) -> dict:
        return {
            "agent_id": self.agent_id,
            "device": self.device.value,
            "call_state": self.call_state.value,
            "presence": self.presence.value,
        }


class AgentStateService:
    """Materialised view over the event log, plus the routing reserve primitive."""

    def __init__(
        self,
        stale_after_s: float = 30.0,
        reservation_ttl_s: float = 5.0,
        dedupe_window_s: float = 300.0,
        clock: Callable[[], float] | None = None,
    ) -> None:
        self._stale_after_s = stale_after_s
        self._reservation_ttl_s = reservation_ttl_s
        self._dedupe_window_s = dedupe_window_s
        self._now = clock or time.time

        self._agents: dict[str, AgentState] = {}
        self._seen_event_ids: dict[str, float] = {}       # event_id -> receipt time
        self._transitions: list[dict] = []                 # the append-only log
        self._subscribers: list[Callable[[dict], None]] = []
        self.rejections: dict[str, int] = {}               # Rejected.value -> count
        self.drift_corrections = 0

    # ───────────────────────── ingest ─────────────────────────

    def apply(self, ev: Event) -> Rejected | None:
        """Apply one event. Returns None if applied, else why it was rejected.

        Idempotent and order-insensitive: calling this repeatedly with the same or
        shuffled events converges on the same state.
        """
        now = self._now()
        self._evict_dedupe(now)

        # 1. authority check — only the owning source may write a dimension
        if ev.dimension not in SOURCE_DIMENSIONS.get(ev.source, ()):
            return self._reject(Rejected.WRONG_SOURCE)

        # 2. value must be legal for the dimension
        enum_type = DIMENSION_TYPES[ev.dimension]
        try:
            value = enum_type(ev.value)
        except ValueError:
            return self._reject(Rejected.BAD_VALUE)

        # 3. duplicate suppression — at-least-once redelivery of the same event
        if ev.event_id in self._seen_event_ids:
            return self._reject(Rejected.DUPLICATE)

        agent = self._agents.setdefault(ev.agent_id, AgentState(agent_id=ev.agent_id))

        # 4. ordering — PER DIMENSION, not globally.
        #    A telephony event arriving late must not discard a newer presence event,
        #    because the two describe independent facts. This is the whole reason the
        #    state model is split the way it is.
        high_water = agent.applied_seq.get(ev.dimension)
        if high_water is not None and ev.seq <= high_water:
            self._seen_event_ids[ev.event_id] = now
            return self._reject(Rejected.OUT_OF_ORDER)

        # From here the event wins. Record it even if the value is unchanged, so the
        # high-water mark and freshness both advance.
        self._seen_event_ids[ev.event_id] = now
        agent.applied_seq[ev.dimension] = ev.seq
        agent.last_seen[ev.dimension] = now

        previous = getattr(agent, ev.dimension)
        if previous == value:
            return self._reject(Rejected.NO_CHANGE)

        setattr(agent, ev.dimension, value)

        # A real call starting supersedes any reservation the router was holding.
        if ev.dimension == "call_state" and value in (CallState.RINGING, CallState.TALKING):
            agent.reserved_until = 0.0
            agent.reservation_id = None

        self._transitions.append({
            "agent_id": ev.agent_id,
            "dimension": ev.dimension,
            "from": previous.value,
            "to": value.value,
            "effective_at": ev.ts,
            "seq": ev.seq,
        })
        self._publish({
            "type": "state_change",
            "agent_id": ev.agent_id,
            "dimension": ev.dimension,
            "from": previous.value,
            "to": value.value,
            "routable": self.is_routable(ev.agent_id),
        })
        return None

    def replay(self, events: Iterable[Event]) -> None:
        """Rebuild state from the log. Used for restart recovery."""
        for ev in events:
            self.apply(ev)

    # ───────────────────────── read ─────────────────────────

    def get(self, agent_id: str) -> AgentState | None:
        return self._agents.get(agent_id)

    def is_stale(self, agent_id: str) -> bool:
        """True if we have not heard from telephony recently enough to trust state.

        Fail closed: an agent we cannot vouch for is not routable. This bounds the
        damage of ANY missed event to stale_after_s — see DESIGN.md §8.
        """
        agent = self._agents.get(agent_id)
        if agent is None:
            return True
        now = self._now()
        for dim in TELEPHONY_DIMENSIONS:
            seen = agent.last_seen.get(dim)
            if seen is None or now - seen > self._stale_after_s:
                return True
        return False

    def is_routable(self, agent_id: str) -> bool:
        """DERIVED, never stored. Changing this rule needs no data migration."""
        agent = self._agents.get(agent_id)
        if agent is None:
            return False
        return (
            agent.device == Device.REGISTERED
            and agent.presence == Presence.AVAILABLE
            and agent.call_state == CallState.IDLE
            and agent.reserved_until <= self._now()
            and not self.is_stale(agent_id)
        )

    def routable_agents(self) -> list[str]:
        return sorted(a for a in self._agents if self.is_routable(a))

    # ───────────────────── routing primitive ─────────────────────

    def reserve(self, agent_id: str, reservation_id: str) -> bool:
        """Atomically claim an agent. False if they were not claimable.

        Knowing an agent is free is NOT the same as being allowed to assign them:
        two routers reading the same state would both assign, and the customer hears
        a call land on someone already talking. In production this is one Lua script
        in Redis so the check and the write cannot be interleaved.

        The TTL means a router that crashes after reserving does not strand the agent.
        """
        if not self.is_routable(agent_id):
            return False
        agent = self._agents[agent_id]
        agent.reserved_until = self._now() + self._reservation_ttl_s
        agent.reservation_id = reservation_id
        self._publish({"type": "reserved", "agent_id": agent_id,
                       "reservation_id": reservation_id})
        return True

    def release(self, agent_id: str, reservation_id: str | None = None) -> bool:
        agent = self._agents.get(agent_id)
        if agent is None:
            return False
        if reservation_id is not None and agent.reservation_id != reservation_id:
            return False
        agent.reserved_until = 0.0
        agent.reservation_id = None
        self._publish({"type": "released", "agent_id": agent_id})
        return True

    # ───────────────────── reconciliation ─────────────────────

    def reconcile(self, truth: dict[str, dict[str, str]]) -> int:
        """Correct drift against ground truth polled from FreeSWITCH.

        `truth` maps agent_id -> {"device": ..., "call_state": ...}, built from
        `sofia status profile internal reg` and `show channels`.

        Event streams ALWAYS drift — a dropped queue message, an ESL reconnect, a
        node restarting mid-call. Without this pass an agent stuck in Talking never
        takes another call for the rest of the shift and nobody notices.

        Every correction is counted; the rate is a health metric worth alarming on.
        """
        corrections = 0
        now = self._now()
        for agent_id, dims in truth.items():
            agent = self._agents.setdefault(agent_id, AgentState(agent_id=agent_id))
            for dim, raw in dims.items():
                if dim not in DIMENSION_TYPES:
                    continue
                value = DIMENSION_TYPES[dim](raw)
                agent.last_seen[dim] = now          # ground truth refreshes freshness
                if getattr(agent, dim) != value:
                    previous = getattr(agent, dim)
                    setattr(agent, dim, value)
                    corrections += 1
                    self._transitions.append({
                        "agent_id": agent_id, "dimension": dim,
                        "from": previous.value, "to": value.value,
                        "effective_at": now, "seq": -1, "source": "reconcile",
                    })
                    self._publish({"type": "drift_corrected", "agent_id": agent_id,
                                   "dimension": dim, "from": previous.value,
                                   "to": value.value})
        self.drift_corrections += corrections
        return corrections

    # ───────────────────────── reporting ─────────────────────────

    def report(self, agent_id: str, window_start: float, window_end: float) -> dict:
        """Talk / break / ACW / occupancy from transition intervals.

        Computed from the log rather than from runtime counters, so figures can always
        be recomputed and never drift. Definitions are stated because every contact
        centre defines occupancy differently — see DESIGN.md §6.
        """
        spans = {"call_state": [], "presence": []}
        for dim in spans:
            events = [t for t in self._transitions
                      if t["agent_id"] == agent_id and t["dimension"] == dim]
            events.sort(key=lambda t: t["effective_at"])
            # state as at window_start = the value the last pre-window transition moved to
            current = None
            for t in events:
                if t["effective_at"] <= window_start:
                    current = t["to"]
            cursor = window_start
            for t in events:
                if t["effective_at"] <= window_start or t["effective_at"] > window_end:
                    continue
                if current is not None:
                    spans[dim].append((current, cursor, t["effective_at"]))
                current = t["to"]
                cursor = t["effective_at"]
            if current is not None and cursor < window_end:
                spans[dim].append((current, cursor, window_end))

        def intervals(dim: str, values: set[str]) -> list[tuple[float, float]]:
            return [(start, end) for v, start, end in spans[dim] if v in values]

        def duration(ivs: list[tuple[float, float]]) -> float:
            return sum(end - start for start, end in ivs)

        def union(ivs: list[tuple[float, float]]) -> list[tuple[float, float]]:
            """Merge overlapping intervals.

            Required because talk time comes from the call_state dimension and ACW
            from the presence dimension, and the two CAN legitimately overlap —
            telephony may still report Talking while the agent application has
            already moved to AfterCallWork. Summing them double-counts and pushes
            occupancy above 100%, which is exactly how you notice the bug.
            """
            if not ivs:
                return []
            merged = [[s, e] for s, e in sorted(ivs)]
            out = [merged[0]]
            for s, e in merged[1:]:
                if s <= out[-1][1]:
                    out[-1][1] = max(out[-1][1], e)
                else:
                    out.append([s, e])
            return [(s, e) for s, e in out]

        # Hold counts as occupied: the agent cannot take another call. Configurable
        # in production rather than hard-coded.
        talk_iv = intervals("call_state", {CallState.TALKING.value, CallState.ON_HOLD.value})
        acw_iv = intervals("presence", {Presence.AFTER_CALL_WORK.value})
        break_iv = intervals("presence", {Presence.ON_BREAK.value})
        staffed_iv = intervals("presence", {Presence.AVAILABLE.value,
                                            Presence.ON_BREAK.value,
                                            Presence.AFTER_CALL_WORK.value})

        talk, acw = duration(talk_iv), duration(acw_iv)
        break_t, staffed = duration(break_iv), duration(staffed_iv)
        occupied = duration(union(talk_iv + acw_iv))
        denominator = staffed - break_t
        return {
            "agent_id": agent_id,
            "talk_time_s": round(talk, 3),
            "break_time_s": round(break_t, 3),
            "acw_time_s": round(acw, 3),
            "staffed_time_s": round(staffed, 3),
            "occupied_time_s": round(occupied, 3),
            "occupancy": round(occupied / denominator, 4) if denominator > 0 else None,
            "occupancy_formula": ("union(talk|hold, acw) / (staffed - break); "
                                  "hold counts as occupied; union not sum, because "
                                  "talk and acw are independent dimensions"),
        }

    # ───────────────────────── plumbing ─────────────────────────

    def subscribe(self, callback: Callable[[dict], None]) -> None:
        """Dashboard fanout. In production this is Redis pub/sub -> WebSocket,
        with deltas coalesced into a ~500 ms tick so an event storm does not
        become a frame storm."""
        self._subscribers.append(callback)

    def transitions(self) -> list[dict]:
        return list(self._transitions)

    def _publish(self, message: dict) -> None:
        for cb in self._subscribers:
            cb(message)

    def _reject(self, reason: Rejected) -> Rejected:
        self.rejections[reason.value] = self.rejections.get(reason.value, 0) + 1
        return reason

    def _evict_dedupe(self, now: float) -> None:
        if len(self._seen_event_ids) < 10_000:
            return
        cutoff = now - self._dedupe_window_s
        self._seen_event_ids = {k: v for k, v in self._seen_event_ids.items() if v > cutoff}


# ───────────────────────── ESL adapter sketch ─────────────────────────

ESL_EVENT_MAP = {
    "sofia::register":          ("device", Device.REGISTERED.value),
    "sofia::unregister":        ("device", Device.UNREGISTERED.value),
    "sofia::expire":            ("device", Device.UNREGISTERED.value),
    "CHANNEL_PROGRESS":         ("call_state", CallState.RINGING.value),
    "CHANNEL_ANSWER":           ("call_state", CallState.TALKING.value),
    "CHANNEL_HOLD":             ("call_state", CallState.ON_HOLD.value),
    "CHANNEL_UNHOLD":           ("call_state", CallState.TALKING.value),
    "CHANNEL_HANGUP_COMPLETE":  ("call_state", CallState.IDLE.value),
}


def esl_event_to_event(headers: dict[str, str], seq: int) -> Event | None:
    """Translate one inbound-ESL event into a normalised Event.

    Notes that matter in production:
      * subscribe selectively (`event plain CHANNEL_ANSWER CHANNEL_HANGUP_COMPLETE ...`),
        never `ALL` — at 8k events/sec the firehose is wasted CPU and a source of lag
      * use CHANNEL_HANGUP_COMPLETE, not CHANNEL_HANGUP: the former is final
      * resolve the agent from a channel variable set in the dialplan, not from the
        SIP user, because one user can own several channels and bridged legs confuse it
    """
    name = headers.get("Event-Subclass") or headers.get("Event-Name", "")
    mapped = ESL_EVENT_MAP.get(name)
    if mapped is None:
        return None
    agent_id = headers.get("variable_agent_id") or headers.get("from-user")
    if not agent_id:
        return None
    dimension, value = mapped
    return Event(
        event_id=headers.get("Unique-ID", f"{name}:{agent_id}:{seq}"),
        agent_id=agent_id,
        source="telephony",
        dimension=dimension,
        value=value,
        seq=seq,
        ts=float(headers.get("Event-Date-Timestamp", 0)) / 1_000_000 or time.time(),
    )


# ───────────────────────── demo ─────────────────────────

def _demo() -> None:
    print("=" * 72)
    print("  Agent Presence & Call State Service — prototype demo")
    print("=" * 72)

    t = [1000.0]
    svc = AgentStateService(stale_after_s=30.0, reservation_ttl_s=5.0,
                            clock=lambda: t[0])
    svc.subscribe(lambda m: print(f"   [pub] {m}"))

    print("\n1. agent logs in and registers")
    svc.apply(Event("e1", "A1", "telephony", "device", "Registered", 1, 1000.0))
    svc.apply(Event("e2", "A1", "agent_app", "presence", "Available", 1, 1000.0))
    svc.apply(Event("e3", "A1", "telephony", "call_state", "Idle", 2, 1000.0))
    print(f"   routable = {svc.is_routable('A1')}   (expected True)")

    print("\n2. two routers race for the same agent — only one may win")
    print(f"   router-1 reserve -> {svc.reserve('A1', 'r1')}  (expected True)")
    print(f"   router-2 reserve -> {svc.reserve('A1', 'r2')}  (expected False)")

    print("\n3. the call connects, then the duplicate arrives, then a LATE Idle")
    svc.apply(Event("e4", "A1", "telephony", "call_state", "Talking", 3, 1005.0))
    dup = svc.apply(Event("e4", "A1", "telephony", "call_state", "Talking", 3, 1005.0))
    print(f"   duplicate rejected as -> {dup}")
    svc.apply(Event("e5", "A1", "agent_app", "presence", "AfterCallWork", 2, 1012.0))
    late = svc.apply(Event("e6", "A1", "telephony", "call_state", "Idle", 2, 1011.0))
    print(f"   late/out-of-order rejected as -> {late}")
    st = svc.get("A1")
    print(f"   state = {st.snapshot()}")
    print("   ^ presence survived the late telephony event: ordering is PER DIMENSION")

    print("\n4. nothing heard from telephony for 40s -> stale, fail closed")
    t[0] = 1060.0
    print(f"   stale = {svc.is_stale('A1')}   routable = {svc.is_routable('A1')}")

    print("\n5. reconcile against FreeSWITCH ground truth")
    n = svc.reconcile({"A1": {"device": "Registered", "call_state": "Idle"}})
    print(f"   corrections = {n}   (telephony said Idle; we had a stuck Talking)")

    print("\n6. reporting over the shift window")
    import json
    print("   " + json.dumps(svc.report("A1", 1000.0, 1060.0), indent=2).replace("\n", "\n   "))

    print(f"\n   rejection counters: {svc.rejections}")
    print("=" * 72)


if __name__ == "__main__":
    _demo()
