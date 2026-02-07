
import os
import googlemaps
from livekit.agents import llm
import logging
from navigation import NavigationSession

logger = logging.getLogger("google_maps")

class NavigationTool:
    def __init__(self):
        api_key = os.environ.get("GOOGLE_MAPS_API_KEY")
        if not api_key:
            logger.warning("GOOGLE_MAPS_API_KEY not found in environment variables")
            self.client = None
        else:
            self.client = googlemaps.Client(key=api_key)
        
        self.session = NavigationSession()

    @llm.function_tool(description="Start turn-by-turn navigation to a destination")
    def start_navigation(self, origin: str, destination: str, mode: str = "walking") -> str:
        if not self.client:
            return "Google Maps API key not configured."
            
        try:
            directions_result = self.client.directions(
                origin,
                destination,
                mode=mode,
                units="metric"
            )
            
            if not directions_result:
                return "No route found."
            
            route = directions_result[0]
            self.session.start_route(route, destination)
            
            # Get initial instruction
            legs = route.get("legs", [])
            if legs:
                steps = legs[0].get("steps", [])
                if steps:
                    first_instruction = self.session._clean_instruction(steps[0].get('html_instructions', 'Proceed to route'))
                    return f"Navigation started. {first_instruction}"
            
            return "Navigation started. Proceed to the route."
            
        except Exception as e:
            logger.error(f"Error starting navigation: {e}")
            return f"Error starting navigation: {str(e)}"

    @llm.function_tool(description="Update user location (latitude, longitude) for navigation tracking")
    def update_location(self, lat: float, lng: float) -> str:
        """
        Updates the user's location. If a turn is approaching, returns the instruction.
        Otherwise, indicates tracking works.
        """
        if not self.session.active_route:
            return "Navigation not active."
            
        instruction = self.session.update_location(lat, lng)
        if instruction:
            return instruction
        
        return "Location updated. Continue on route."

    @llm.function_tool(description="Get walking directions from an origin to a destination (static list of steps)")
    def get_walking_directions(self, origin: str, destination: str) -> str:
        if not self.client:
            return "Google Maps API key not configured."
        
        try:
            directions_result = self.client.directions(
                origin,
                destination,
                mode="walking",
                units="metric"
            )
            
            if not directions_result:
                return "No directions found."
            
            route = directions_result[0]
            legs = route.get("legs", [])
            if not legs:
                return "No route legs found."
            
            leg = legs[0]
            steps = leg.get("steps", [])
            
            direction_text = f"Walking directions from {leg['start_address']} to {leg['end_address']} ({leg['duration']['text']}, {leg['distance']['text']}):\n"
            
            for i, step in enumerate(steps, 1):
                # Clean html instructions
                instruction = step['html_instructions']
                # Basic HTML tag removal
                for tag in ['<b>', '</b>', '<div style="font-size:0.9em">', '</div>']:
                    instruction = instruction.replace(tag, '')
                
                direction_text += f"{i}. {instruction} ({step['distance']['text']})\n"
                
            return direction_text
            
        except Exception as e:
            logger.error(f"Error getting directions: {e}")
            return f"Error getting directions: {str(e)}"

    @llm.function_tool(description="Search for a place or point of interest")
    def search_places(self, query: str) -> str:
        if not self.client:
            return "Google Maps API key not configured."
            
        try:
            places_result = self.client.places(query)
            
            if not places_result or 'results' not in places_result:
                return "No places found."
            
            results = places_result['results']
            if not results:
                return "No places found."
            
            # Return top 3 results
            response_text = f"Found {len(results)} places (showing top 3):\n"
            for place in results[:3]:
                name = place.get('name', 'Unknown')
                address = place.get('formatted_address', 'Unknown address')
                rating = place.get('rating', 'N/A')
                response_text += f"- {name}: {address} (Rating: {rating})\n"
                
            return response_text
            
        except Exception as e:
            logger.error(f"Error searching places: {e}")
            return f"Error searching places: {str(e)}"
