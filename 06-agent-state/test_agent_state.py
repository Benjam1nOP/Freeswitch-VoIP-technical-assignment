"""Tests for the Agent Presence & Call State Service.

These are the evidence for the hard requirements in task 5. The duplicate and
out-of-order tests in particular PROVE the behaviour rather than asserting it in prose.

Run either way:
    python -m pytest test_agent_state.py -v
    python test_agent_state.py
"""

from __future__ import annotations

from agent_state import (
    AgentStateService,
    CallState,
    Device,
    Event,
    Presence,
    Rejected,
    esl_event_to_event,
)


# ───────────────────────── helpers ─────────────────────────

def fixed_clock(holder: list[float]):
    return lambda: holder[0]


def login(svc: AgentStateService, agent: str = "A1", ts: float = 1000.0) -> None:
    """Registered + Available + Idle = routable."""
    svc.apply(Event(f"{agent}-dev-1", agent, "telephony", "device", "Registered", 1, ts))
    svc.apply(Event(f"{agent}-cs-1", agent, "telephony", "call_state", "Idle", 1, ts))
    svc.apply(Event(f"{agent}-pr-1", agent, "agent_app", "presence", "Available", 1, ts))


# ───────────────────── state model ─────────────────────

def test_routable_requires_all_three_dimensions():
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))

    svc.apply(Event("e1", "A1", "telephony", "device", "Registered", 1, 1000.0))
    assert not svc.is_routable("A1"), "registered alone is not routable"

    svc.apply(Event("e2", "A1", "telephony", "call_state", "Idle", 1, 1000.0))
    assert not svc.is_routable("A1"), "still LoggedOut on the presence dimension"

    svc.apply(Event("e3", "A1", "agent_app", "presence", "Available", 1, 1000.0))
    assert svc.is_routable("A1")


def test_contradictory_states_are_representable():
    """Available-but-unregistered is a real support ticket. A single combined enum
    would hide it; two dimensions surface it."""
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    login(svc)
    svc.apply(Event("e9", "A1", "telephony", "device", "Unregistered", 2, 1001.0))

    st = svc.get("A1")
    assert st.presence == Presence.AVAILABLE      # agent thinks they are ready
    assert st.device == Device.UNREGISTERED        # but the softphone dropped
    assert not svc.is_routable("A1")               # and we correctly refuse to route


def test_source_cannot_write_a_dimension_it_does_not_own():
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    r = svc.apply(Event("e1", "A1", "agent_app", "call_state", "Talking", 1, 1000.0))
    assert r is Rejected.WRONG_SOURCE


# ───────────────── duplicates and ordering ─────────────────

def test_duplicate_event_is_applied_exactly_once():
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    login(svc)

    ev = Event("dup-1", "A1", "telephony", "call_state", "Talking", 2, 1005.0)
    assert svc.apply(ev) is None                  # applied
    assert svc.apply(ev) is Rejected.DUPLICATE    # second delivery suppressed
    assert svc.apply(ev) is Rejected.DUPLICATE

    assert svc.get("A1").call_state == CallState.TALKING
    # exactly one transition recorded for that dimension
    talking = [x for x in svc.transitions()
               if x["dimension"] == "call_state" and x["to"] == "Talking"]
    assert len(talking) == 1


def test_out_of_order_event_is_rejected():
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    login(svc)

    svc.apply(Event("e-a", "A1", "telephony", "call_state", "Talking", 5, 1005.0))
    late = svc.apply(Event("e-b", "A1", "telephony", "call_state", "Ringing", 3, 1003.0))

    assert late is Rejected.OUT_OF_ORDER
    assert svc.get("A1").call_state == CallState.TALKING, "stale event must not win"


def test_late_event_in_one_dimension_cannot_clobber_another():
    """THE test for the two-dimension model.

        t=10  telephony  call_state = Talking
        t=12  agent_app  presence   = AfterCallWork
        t=11  telephony  call_state = Idle        <- arrives last

    With one combined enum the late event discards the presence update. With
    per-dimension ordering both dimensions end up correct.
    """
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    login(svc)

    svc.apply(Event("t10", "A1", "telephony", "call_state", "Talking", 10, 1010.0))
    svc.apply(Event("a12", "A1", "agent_app", "presence", "AfterCallWork", 12, 1012.0))
    # late telephony event, but still newer than the call_state high-water mark of 10
    assert svc.apply(Event("t11", "A1", "telephony", "call_state", "Idle", 11, 1011.0)) is None

    st = svc.get("A1")
    assert st.call_state == CallState.IDLE, "newer within its own dimension -> applied"
    assert st.presence == Presence.AFTER_CALL_WORK, "presence must be untouched"
    assert not svc.is_routable("A1"), "ACW is not available"


def test_shuffled_event_order_converges_to_the_same_state():
    """Order-insensitivity, end to end: any permutation of the same log converges."""
    import itertools

    log = [
        Event("d1", "A1", "telephony", "device", "Registered", 1, 1000.0),
        Event("c1", "A1", "telephony", "call_state", "Idle", 1, 1000.0),
        Event("p1", "A1", "agent_app", "presence", "Available", 1, 1000.0),
        Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1005.0),
        Event("p2", "A1", "agent_app", "presence", "AfterCallWork", 2, 1010.0),
    ]
    expected = None
    for permutation in itertools.permutations(log):
        t = [1000.0]
        svc = AgentStateService(clock=fixed_clock(t))
        svc.replay(permutation)
        snap = svc.get("A1").snapshot()
        if expected is None:
            expected = snap
        assert snap == expected, f"diverged on permutation: {snap} != {expected}"
    assert expected["call_state"] == "Talking"
    assert expected["presence"] == "AfterCallWork"


# ───────────────── routing: atomic reserve ─────────────────

def test_two_routers_cannot_both_reserve_one_agent():
    t = [1000.0]
    svc = AgentStateService(reservation_ttl_s=5.0, clock=fixed_clock(t))
    login(svc)

    assert svc.reserve("A1", "router-1") is True
    assert svc.reserve("A1", "router-2") is False, "double assignment must be impossible"
    assert not svc.is_routable("A1")


def test_reservation_expires_so_a_crashed_router_does_not_strand_an_agent():
    t = [1000.0]
    svc = AgentStateService(reservation_ttl_s=5.0, clock=fixed_clock(t))
    login(svc)

    assert svc.reserve("A1", "router-1") is True
    t[0] = 1004.0
    assert not svc.is_routable("A1"), "still held inside the TTL"
    t[0] = 1006.0
    assert svc.is_routable("A1"), "TTL expired -> back in the pool"


def test_real_call_supersedes_the_reservation():
    t = [1000.0]
    svc = AgentStateService(clock=fixed_clock(t))
    login(svc)
    svc.reserve("A1", "router-1")

    svc.apply(Event("ring", "A1", "telephony", "call_state", "Ringing", 2, 1001.0))
    st = svc.get("A1")
    assert st.reservation_id is None, "the real call replaces the placeholder"
    assert st.call_state == CallState.RINGING


# ───────────────── staleness: fail closed ─────────────────

def test_missing_telephony_events_make_the_agent_stale_not_wrong():
    t = [1000.0]
    svc = AgentStateService(stale_after_s=30.0, clock=fixed_clock(t))
    login(svc)
    assert svc.is_routable("A1")

    t[0] = 1031.0
    assert svc.is_stale("A1")
    assert not svc.is_routable("A1"), "fail closed: never route to state we cannot vouch for"


def test_reconcile_corrects_drift_and_refreshes_freshness():
    t = [1000.0]
    svc = AgentStateService(stale_after_s=30.0, clock=fixed_clock(t))
    login(svc)
    # a CallEnded was dropped by the queue: we believe the agent is still talking
    svc.apply(Event("stuck", "A1", "telephony", "call_state", "Talking", 2, 1005.0))
    t[0] = 1100.0
    assert not svc.is_routable("A1")

    corrections = svc.reconcile({"A1": {"device": "Registered", "call_state": "Idle"}})
    assert corrections == 1
    assert svc.get("A1").call_state == CallState.IDLE
    assert not svc.is_stale("A1"), "ground truth refreshes freshness"
    assert svc.is_routable("A1"), "agent recovered without waiting for a new event"
    assert svc.drift_corrections == 1


# ───────────────── restart recovery ─────────────────

def test_restart_recovery_is_deterministic():
    """Current state is a materialised view, so recovery is replay. Because apply()
    is idempotent, replaying a log that contains duplicates and reordering rebuilds
    exactly the same state — which is what makes at-least-once delivery safe."""
    log = [
        Event("d1", "A1", "telephony", "device", "Registered", 1, 1000.0),
        Event("c1", "A1", "telephony", "call_state", "Idle", 1, 1000.0),
        Event("p1", "A1", "agent_app", "presence", "Available", 1, 1000.0),
        Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1005.0),
        Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1005.0),   # duplicate
        Event("p2", "A1", "agent_app", "presence", "AfterCallWork", 2, 1012.0),
        Event("c1b", "A1", "telephony", "call_state", "Ringing", 1, 1001.0),  # out of order
        Event("c3", "A1", "telephony", "call_state", "Idle", 3, 1013.0),
    ]

    t1 = [1020.0]
    primary = AgentStateService(clock=fixed_clock(t1))
    primary.replay(log)

    t2 = [1020.0]
    recovered = AgentStateService(clock=fixed_clock(t2))
    recovered.replay(log)

    assert primary.get("A1").snapshot() == recovered.get("A1").snapshot()
    assert recovered.get("A1").snapshot() == {
        "agent_id": "A1",
        "device": "Registered",
        "call_state": "Idle",
        "presence": "AfterCallWork",
    }


# ───────────────── reporting ─────────────────

def test_reporting_computes_intervals_from_the_transition_log():
    t = [1000.0]
    svc = AgentStateService(stale_after_s=10_000.0, clock=fixed_clock(t))
    login(svc, ts=1000.0)

    # 1000-1020 available & idle, 1020-1080 talking, 1080-1100 ACW, 1100-1160 break
    svc.apply(Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1020.0))
    svc.apply(Event("c3", "A1", "telephony", "call_state", "Idle", 3, 1080.0))
    svc.apply(Event("p2", "A1", "agent_app", "presence", "AfterCallWork", 2, 1080.0))
    svc.apply(Event("p3", "A1", "agent_app", "presence", "OnBreak", 3, 1100.0))

    r = svc.report("A1", 1000.0, 1160.0)
    assert r["talk_time_s"] == 60.0, r
    assert r["acw_time_s"] == 20.0, r
    assert r["break_time_s"] == 60.0, r
    assert r["staffed_time_s"] == 160.0, r
    # (60 + 20) / (160 - 60) = 0.8
    assert r["occupancy"] == 0.8, r


def test_overlapping_talk_and_acw_cannot_push_occupancy_above_one():
    """Talk comes from call_state, ACW from presence — independent dimensions that
    can overlap when the agent app moves on before telephony reports CallEnded.
    Summing them double-counts; the union is correct. Occupancy > 100% is the
    symptom that catches this."""
    t = [1000.0]
    svc = AgentStateService(stale_after_s=10_000.0, clock=fixed_clock(t))
    login(svc, ts=1000.0)

    # talking 1000-1060 (telephony never sent CallEnded until the end)
    svc.apply(Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1000.0))
    # agent app moves to ACW at 1030 while telephony still says Talking -> overlap
    svc.apply(Event("p2", "A1", "agent_app", "presence", "AfterCallWork", 2, 1030.0))
    svc.apply(Event("c3", "A1", "telephony", "call_state", "Idle", 3, 1060.0))

    r = svc.report("A1", 1000.0, 1060.0)
    assert r["talk_time_s"] == 60.0
    assert r["acw_time_s"] == 30.0
    assert r["occupied_time_s"] == 60.0, "union, not 90s sum"
    assert r["occupancy"] is not None and r["occupancy"] <= 1.0, r


def test_hold_counts_as_occupied():
    t = [1000.0]
    svc = AgentStateService(stale_after_s=10_000.0, clock=fixed_clock(t))
    login(svc, ts=1000.0)
    svc.apply(Event("c2", "A1", "telephony", "call_state", "Talking", 2, 1000.0))
    svc.apply(Event("c3", "A1", "telephony", "call_state", "OnHold", 3, 1030.0))
    svc.apply(Event("c4", "A1", "telephony", "call_state", "Idle", 4, 1060.0))

    r = svc.report("A1", 1000.0, 1060.0)
    assert r["talk_time_s"] == 60.0, "hold is occupied time: the agent cannot take a call"


# ───────────────── ESL adapter ─────────────────

def test_esl_answer_event_maps_to_talking():
    ev = esl_event_to_event({
        "Event-Name": "CHANNEL_ANSWER",
        "Unique-ID": "abc-123",
        "variable_agent_id": "A1",
        "Event-Date-Timestamp": "1700000000000000",
    }, seq=7)
    assert ev is not None
    assert ev.dimension == "call_state"
    assert ev.value == CallState.TALKING.value
    assert ev.agent_id == "A1"
    assert ev.source == "telephony"


def test_esl_ignores_events_that_do_not_change_agent_state():
    assert esl_event_to_event({"Event-Name": "CHANNEL_CREATE",
                               "variable_agent_id": "A1"}, seq=1) is None
    assert esl_event_to_event({"Event-Name": "HEARTBEAT"}, seq=1) is None


# ───────────────────────── runner ─────────────────────────

if __name__ == "__main__":
    import sys, traceback

    tests = [(n, o) for n, o in sorted(globals().items())
             if n.startswith("test_") and callable(o)]
    passed = failed = 0
    for name, fn in tests:
        try:
            fn()
        except Exception:
            failed += 1
            print(f"FAIL  {name}")
            traceback.print_exc()
        else:
            passed += 1
            print(f"ok    {name}")
    print(f"\n{passed} passed, {failed} failed, {len(tests)} total")
    sys.exit(1 if failed else 0)
