
import math
import logging
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger("navigation")

class NavigationSession:
    def __init__(self):
        self.active_route: Optional[Dict] = None
        self.current_step_index: int = 0
        self.destination: str = ""
        self.last_instruction_spoken_index: int = -1
        
    def start_route(self, route: Dict, destination: str):
        """Initialize a new navigation session with a route"""
        self.active_route = route
        self.current_step_index = 0
        self.destination = destination
        self.last_instruction_spoken_index = -1
        logger.info(f"Started navigation to {destination}")

    def stop_navigation(self):
        """Clear navigation session"""
        self.active_route = None
        self.current_step_index = 0
        self.destination = ""
        self.last_instruction_spoken_index = -1
        logger.info("Navigation stopped")

    def update_location(self, lat: float, lng: float) -> Optional[str]:
        """
        Update user location and return the next instruction if needed.
        Returns None if no instruction needs to be spoken.
        """
        if not self.active_route:
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
        instruction_text = self._clean_instruction(next_step.get('html_instructions', 'Proceed'))

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
