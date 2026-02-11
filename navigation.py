import math
import logging
import time
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger("navigation")

# Don't announce turn-by-turn from GPS for this long after route start, so the initial
# summary (distance, time, arrival, first direction) can finish without being interrupted.
ROUTE_START_GRACE_SECONDS = 18.0


def _bearing_degrees(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Bearing from point 1 to point 2 in degrees, 0=north, 90=east."""
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dlambda = math.radians(lon2 - lon1)
    y = math.sin(dlambda) * math.cos(phi2)
    x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(dlambda)
    bearing = math.degrees(math.atan2(y, x))
    return (bearing + 360) % 360


def _bearing_to_cardinal(bearing: float) -> str:
    """Convert bearing 0-360 to cardinal direction."""
    if bearing < 22.5 or bearing >= 337.5:
        return "north"
    if bearing < 67.5:
        return "north-east"
    if bearing < 112.5:
        return "east"
    if bearing < 157.5:
        return "south-east"
    if bearing < 202.5:
        return "south"
    if bearing < 247.5:
        return "south-west"
    if bearing < 292.5:
        return "west"
    return "north-west"


def _relative_direction(user_heading: float, target_bearing: float) -> str:
    """
    Relative direction from user's perspective: forward, left, right, or behind.
    user_heading: 0-360, 0=north (where phone is pointed).
    target_bearing: 0-360, direction to the target.
    """
    diff = (target_bearing - user_heading + 540) % 360 - 180  # -180 to 180
    if -45 <= diff <= 45:
        return "forward"
    if 45 < diff <= 135:
        return "right"
    if -135 <= diff < -45:
        return "left"
    return "behind"


def _rewrite_instruction_with_heading(
    raw_instruction: str, user_heading: Optional[float], lat: float, lng: float,
    next_step: Dict
) -> str:
    """
    Rewrite navigation instruction to include 'head forward/left/right/behind'
    and cardinal direction (north, south, east, west, etc.).
    """
    end_loc = next_step.get("end_location")
    if not end_loc or user_heading is None:
        return raw_instruction

    target_bearing = _bearing_degrees(lat, lng, end_loc["lat"], end_loc["lng"])
    relative = _relative_direction(user_heading, target_bearing)
    cardinal = _bearing_to_cardinal(target_bearing)

    # "Head left/right/forward/behind, that's north/south/etc."
    if relative == "forward":
        head_phrase = f"Head forward, that's {cardinal}"
    elif relative == "left":
        head_phrase = f"Head left, that's {cardinal}"
    elif relative == "right":
        head_phrase = f"Head right, that's {cardinal}"
    else:
        head_phrase = f"Head behind you, that's {cardinal}"

    # Append street/route name if present (e.g. "Head left onto Main St, that's west")
    for sep in [" onto ", " toward ", " on "]:
        if sep in raw_instruction:
            parts = raw_instruction.split(sep, 1)
            if len(parts) == 2:
                return f"{head_phrase}{sep}{parts[1].strip()}"
    return head_phrase


class NavigationSession:
    def __init__(self):
        self.active_route: Optional[Dict] = None
        self.current_step_index: int = 0
        self.destination: str = ""
        self.last_instruction_spoken_index: int = -1
        self._route_started_at: Optional[float] = None

    def start_route(self, route: Dict, destination: str):
        """Initialize a new navigation session with a route"""
        self.active_route = route
        self.current_step_index = 0
        self.destination = destination
        self.last_instruction_spoken_index = -1
        self._route_started_at = time.monotonic()
        logger.info(f"Started navigation to {destination}")

    def is_in_initial_nav_phase(self) -> bool:
        """True during grace period after route start; obstacle alerts should not interrupt."""
        if not self.active_route or self._route_started_at is None:
            return False
        elapsed = time.monotonic() - self._route_started_at
        return elapsed < ROUTE_START_GRACE_SECONDS

    def stop_navigation(self):
        """Clear navigation session"""
        self.active_route = None
        self.current_step_index = 0
        self.destination = ""
        self.last_instruction_spoken_index = -1
        self._route_started_at = None
        logger.info("Navigation stopped")

    def update_location(self, lat: float, lng: float, heading: Optional[float] = None) -> Optional[str]:
        """
        Update user location and return the next instruction if needed.
        heading: compass bearing 0-360 (0=north), from phone. Used to announce
        'head forward/left/right/behind' and cardinal (north, south, east, west).
        Returns None if no instruction needs to be spoken.
        """
        if not self.active_route:
            return None

        # Grace period: don't return any instruction right after route start, so the
        # agent can finish saying the summary (distance, time, arrival) + first direction.
        if self._route_started_at is not None:
            elapsed = time.monotonic() - self._route_started_at
            if elapsed < ROUTE_START_GRACE_SECONDS:
                return None

        legs = self.active_route.get('legs', [])
        if not legs:
            return None
        
        steps = legs[0].get('steps', [])
        if self.current_step_index >= len(steps):
            # Already finished route
            return None

        current_step = steps[self.current_step_index]
        end_location = current_step.get('end_location')
        
        if not end_location:
            return None
            
        # Check distance to end of current step (the turn point)
        dist = self._haversine_distance(lat, lng, end_location['lat'], end_location['lng'])
        
        logger.debug(f"Distance to step end: {dist:.1f}m. Step instruction: {current_step.get('html_instructions')}")

        # Like a normal nav app: early warning, then "do it now" when very close
        TURN_ANNOUNCEMENT_THRESHOLD = 45.0   # meters – early warning
        TURN_NOW_THRESHOLD = 12.0            # meters – "Turn left now"

        next_step_index = self.current_step_index + 1

        # Reached destination (last step)
        if next_step_index >= len(steps):
            if self.last_instruction_spoken_index < self.current_step_index:
                self.last_instruction_spoken_index = self.current_step_index
                return f"You have arrived at your destination: {self.destination}"
            return None

        next_step = steps[next_step_index]
        raw_instruction = self._clean_instruction(next_step.get('html_instructions', 'Proceed'))
        # Rewrite with compass: "Head left onto Main St, that's west"
        instruction_text = _rewrite_instruction_with_heading(
            raw_instruction, heading, lat, lng, next_step
        )

        # Very close – say "[instruction] Now" and advance to next segment
        if dist < TURN_NOW_THRESHOLD:
            if self.last_instruction_spoken_index <= next_step_index:
                self.last_instruction_spoken_index = next_step_index
                self.current_step_index = next_step_index
                return f"{instruction_text} Now."
        # Within range – say "In X meters, [instruction]" once; don't advance until we say "Now"
        elif dist < TURN_ANNOUNCEMENT_THRESHOLD:
            if self.last_instruction_spoken_index < next_step_index:
                self.last_instruction_spoken_index = next_step_index
                return f"In {int(dist)} meters, {instruction_text}"

        return None

    def _haversine_distance(self, lat1, lon1, lat2, lon2) -> float:
        """Calculate distance in meters between two coordinates"""
        R = 6371000  # Radius of Earth in meters
        phi1, phi2 = math.radians(lat1), math.radians(lat2)
        dphi = math.radians(lat2 - lat1)
        dlambda = math.radians(lon2 - lon1)
        
        a = math.sin(dphi / 2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2)**2
        c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
        
        return R * c

    def _clean_instruction(self, html_instruction: str) -> str:
        """Remove HTML tags from instructions"""
        instruction = html_instruction
        for tag in ['<b>', '</b>', '<div style="font-size:0.9em">', '</div>']:
            instruction = instruction.replace(tag, '')
        return instruction
