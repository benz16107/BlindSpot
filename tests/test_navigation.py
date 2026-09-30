import pytest

import navigation
from navigation import (
    NavigationSession,
    _bearing_degrees,
    _bearing_to_cardinal,
    _relative_direction,
    _rewrite_instruction_with_heading,
)

# ~0.0009 deg latitude is ~100 m.
ORIGIN = (43.6600, -79.3900)


# --- distance and bearing math ----------------------------------------------

def test_haversine_one_degree_latitude():
    d = NavigationSession()._haversine_distance(0, 0, 1, 0)
    assert d == pytest.approx(111_195, rel=1e-3)


def test_haversine_zero_and_symmetric():
    s = NavigationSession()
    assert s._haversine_distance(*ORIGIN, *ORIGIN) == 0
    a = s._haversine_distance(43.66, -79.39, 43.67, -79.38)
    b = s._haversine_distance(43.67, -79.38, 43.66, -79.39)
    assert a == pytest.approx(b)


@pytest.mark.parametrize(
    "dlat, dlon, expected",
    [(1, 0, 0), (0, 1, 90), (-1, 0, 180), (0, -1, 270)],
)
def test_bearing_cardinal_axes(dlat, dlon, expected):
    assert _bearing_degrees(0, 0, dlat, dlon) == pytest.approx(expected, abs=1e-6)


def test_bearing_is_normalised_to_0_360():
    b = _bearing_degrees(0, 0, 1, -1)  # north-west would be negative from atan2
    assert 0 <= b < 360
    assert b == pytest.approx(315, abs=0.1)


@pytest.mark.parametrize(
    "bearing, name",
    [
        (0, "north"), (22.4, "north"), (359.9, "north"), (337.5, "north"),
        (22.5, "north-east"), (90, "east"), (135, "south-east"), (180, "south"),
        (225, "south-west"), (270, "west"), (315, "north-west"),
    ],
)
def test_bearing_to_cardinal(bearing, name):
    assert _bearing_to_cardinal(bearing) == name


@pytest.mark.parametrize(
    "heading, target, expected",
    [
        (0, 0, "forward"), (0, 45, "forward"), (0, 46, "right"), (0, 90, "right"), (0, 270, "left"),
        (0, 314, "left"), (0, 315, "forward"),
        (0, 180, "behind"), (350, 10, "forward"), (10, 300, "left"), (90, 0, "left"),
    ],
)
def test_relative_direction(heading, target, expected):
    assert _relative_direction(heading, target) == expected


# --- instruction parsing ----------------------------------------------------

def test_clean_instruction_strips_google_html():
    raw = 'Turn <b>left</b> onto <b>Main St</b><div style="font-size:0.9em">Destination on right</div>'
    assert NavigationSession()._clean_instruction(raw) == "Turn left onto Main StDestination on right"


def test_rewrite_without_heading_returns_raw():
    step = {"end_location": {"lat": 1, "lng": 0}}
    assert _rewrite_instruction_with_heading("Turn left onto Main St", None, 0, 0, step) == "Turn left onto Main St"


def test_rewrite_without_end_location_returns_raw():
    assert _rewrite_instruction_with_heading("Turn left", 0, 0, 0, {}) == "Turn left"


@pytest.mark.parametrize(
    "raw, heading, expected",
    [
        ("Turn left onto Main St", 0, "Head forward, that's north onto Main St"),
        ("Turn right toward King St", 90, "Head left, that's north toward King St"),
        ("Continue on Bay St", 270, "Head right, that's north on Bay St"),
        ("Continue straight", 180, "Head behind you, that's north"),
    ],
)
def test_rewrite_with_heading(raw, heading, expected):
    step = {"end_location": {"lat": 1, "lng": 0}}  # due north of (0, 0)
    assert _rewrite_instruction_with_heading(raw, heading, 0, 0, step) == expected


def test_rewrite_toward_separator():
    step = {"end_location": {"lat": 1, "lng": 0}}
    out = _rewrite_instruction_with_heading("Head north toward King St", 0, 0, 0, step)
    assert out == "Head forward, that's north toward King St"


# --- NavigationSession step progression -------------------------------------

def _route():
    lat, lng = ORIGIN
    return {
        "legs": [{
            "steps": [
                {"html_instructions": "Head <b>north</b>", "end_location": {"lat": lat + 0.0009, "lng": lng}},
                {"html_instructions": "Turn <b>right</b> onto <b>Bloor St</b>",
                 "end_location": {"lat": lat + 0.0009, "lng": lng + 0.0012}},
            ]
        }]
    }


@pytest.fixture
def session():
    s = NavigationSession()
    s.start_route(_route(), "Robarts Library")
    s._route_started_at -= navigation.ROUTE_START_GRACE_SECONDS + 1  # skip grace period
    return s


def test_no_route_returns_none():
    assert NavigationSession().update_location(*ORIGIN) is None


def test_grace_period_suppresses_instructions():
    s = NavigationSession()
    s.start_route(_route(), "X")
    assert s.is_in_initial_nav_phase()
    turn = _route()["legs"][0]["steps"][0]["end_location"]
    assert s.update_location(turn["lat"], turn["lng"]) is None


def test_far_from_turn_is_silent(session):
    assert session.update_location(*ORIGIN) is None
    assert not session.is_in_initial_nav_phase()


def test_step_progression_to_arrival(session):
    lat, lng = ORIGIN
    # ~33 m before the turn: early warning, once.
    msg = session.update_location(lat + 0.0006, lng)
    assert msg.startswith("In 3") and msg.endswith("meters, Turn right onto Bloor St")
    assert session.update_location(lat + 0.0006, lng) is None
    # At the turn: "Now", advance.
    assert session.update_location(lat + 0.0009, lng) == "Turn right onto Bloor St Now."
    assert session.current_step_index == 1


@pytest.mark.xfail(
    strict=True,
    reason="Known bug: 'Now' sets last_instruction_spoken_index to the final step, "
    "so the arrival check (last_spoken < current_step_index) never passes.",
)
def test_arrival_announced_after_final_turn(session):
    lat, lng = ORIGIN
    session.update_location(lat + 0.0009, lng)  # final turn "Now"
    assert session.update_location(lat + 0.0009, lng + 0.0012) == "You have arrived at your destination: Robarts Library"


def test_heading_rewrites_turn_now(session):
    lat, lng = ORIGIN
    # Standing at the turn facing north; next step ends due east.
    assert session.update_location(lat + 0.0009, lng, heading=0) == "Head right, that's east onto Bloor St Now."


def test_stop_navigation_resets(session):
    session.stop_navigation()
    assert session.active_route is None and session.destination == ""
    assert session.update_location(*ORIGIN) is None


def test_empty_legs_returns_none(session):
    session.active_route = {"legs": []}
    assert session.update_location(*ORIGIN) is None


def _single_step_session():
    lat, lng = ORIGIN
    s = NavigationSession()
    s.start_route({"legs": [{"steps": [
        {"html_instructions": "Head <b>north</b>", "end_location": {"lat": lat + 0.001, "lng": lng}},
    ]}]}, "Cafe")
    s._route_started_at -= navigation.ROUTE_START_GRACE_SECONDS + 1
    return s


def test_single_step_arrival_announced_once():
    s = _single_step_session()
    lat, lng = ORIGIN
    assert s.update_location(lat + 0.001, lng) == "You have arrived at your destination: Cafe"
    assert s.update_location(lat + 0.001, lng) is None


@pytest.mark.xfail(
    strict=True,
    reason="Known bug: the last-step branch in update_location has no distance check, "
    "so arrival is announced ~111 m from the destination as soon as the route starts.",
)
def test_single_step_no_arrival_when_far_away():
    assert _single_step_session().update_location(*ORIGIN) is None
