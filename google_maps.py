import asyncio
import os
import logging
from pathlib import Path
from typing import Optional

import googlemaps
import requests
from livekit.agents import llm
from navigation import NavigationSession
from google.genai import Client
from google.genai import types

# Ensure .env.local is loaded from project root (same as agent.py), in case this
# module is imported before agent's load_dotenv or from a different cwd.
_env_path = Path(__file__).resolve().parent / ".env.local"
if _env_path.exists():
    from dotenv import load_dotenv
    load_dotenv(_env_path)

logger = logging.getLogger("google_maps")

# Topic for GPS data messages from the phone (must match Flutter publishData topic)
GPS_DATA_TOPIC = "gps"


class NavigationTool:
    def __init__(self):
        # Initialize Google Maps Client (read again after dotenv load)
        api_key = os.environ.get("GOOGLE_MAPS_API_KEY")
        if api_key:
            api_key = api_key.strip()
        self._latest_lat: Optional[float] = None
        self._latest_lng: Optional[float] = None
        if not api_key:
            logger.warning("GOOGLE_MAPS_API_KEY not found or empty in environment")
            self.client = None
        else:
            self.client = googlemaps.Client(key=api_key)
        
        # Initialize Gemini Client for route analysis
        gemini_key = os.environ.get("GOOGLE_API_KEY")
        if not gemini_key:
            logger.warning("GOOGLE_API_KEY not found (for Gemini)")
            self.genai_client = None
        else:
            self.genai_client = Client(api_key=gemini_key)
        
        self.session = NavigationSession()

    def set_latest_gps(self, lat: float, lng: float) -> None:
        """Update latest GPS from phone (called when room receives data on topic gps)."""
        self._latest_lat = lat
        self._latest_lng = lng

    @llm.function_tool(description="Get the user's current location. Use when they ask 'where am I?' or 'what's my location?'. Uses live GPS from the phone.")
    async def get_current_location(self) -> str:
        """Return current location from latest GPS sent by the phone."""
        if self._latest_lat is None or self._latest_lng is None:
            return "Location not available yet. Make sure the app is open and sending GPS."
        return f"Current location: {self._latest_lat:.6f}, {self._latest_lng:.6f} (latitude, longitude)."

    @llm.function_tool(description="Start turn-by-turn navigation from an origin to a destination. Use this when the user wants to be guided step-by-step (e.g. 'navigate me to X', 'guide me to Y').")
    async def start_navigation(self, origin: str, destination: str, mode: str = "walking") -> str:
        if not self.client:
            return "Google Maps API key not configured."
            
        try:
            # Fetch alternative routes (blocking call)
            directions_result = await asyncio.to_thread(
                self.client.directions,
                origin,
                destination,
                mode=mode,
                units="metric",
                alternatives=True
            )
            
            if not directions_result:
                return "No route found."
            
            # Use Gemini to analyze routes if available
            selected_route = directions_result[0]
            analysis_text = ""
            
            if self.genai_client and len(directions_result) > 0:
                try:
                    # Prepare prompt for Gemini
                    routes_data = []
                    for i, r in enumerate(directions_result):
                        summary = r.get("summary", "No summary")
                        legs = r.get("legs", [])
                        duration = legs[0].get("duration", {}).get("text", "N/A") if legs else "N/A"
                        distance = legs[0].get("distance", {}).get("text", "N/A") if legs else "N/A"
                        steps = legs[0].get("steps", []) if legs else []
                        step_summaries = [s.get("html_instructions", "") for s in steps]
                        routes_data.append(f"Route {i+1}: {summary}, {duration}, {distance}. Steps: {step_summaries}")
                    
                    prompt = f"""
                    You are a navigation assistant for a blind pedestrian.
                    Analyze these routes from {origin} to {destination}.
                    Select the SAFEST route with fewer complex intersections and turns.
                    Return JSON with 'selected_route_index' (1-based) and 'reasoning'.
                    Routes: {routes_data}
                    """
                    
                    response = await asyncio.to_thread(
                        self.genai_client.models.generate_content,
                        model="gemini-2.0-flash",
                        contents=prompt,
                        config=types.GenerateContentConfig(response_mime_type="application/json")
                    )
                    
                    import json
                    analysis = json.loads(response.text)
                    idx = analysis.get("selected_route_index", 1) - 1
                    if 0 <= idx < len(directions_result):
                        selected_route = directions_result[idx]
                        analysis_text = f" I selected this route because: {analysis.get('reasoning', 'it seems safer')}."
                        logger.info(f"Gemini selected route {idx+1}: {analysis.get('reasoning')}")
                        
                except Exception as g_err:
                    logger.error(f"Gemini analysis failed, falling back to default route: {g_err}")

            self.session.start_route(selected_route, destination)
            
            # Get initial instruction
            legs = selected_route.get("legs", [])
            if legs:
                steps = legs[0].get("steps", [])
                if steps:
                    first_instruction = self.session._clean_instruction(steps[0].get('html_instructions', 'Proceed to route'))
                    return f"Navigation started.{analysis_text} {first_instruction}"
            
            return f"Navigation started.{analysis_text} Proceed to the route."
            
        except Exception as e:
            logger.error(f"Error starting navigation: {e}")
            return f"Error starting navigation: {str(e)}"

    @llm.function_tool(description="Update user location (latitude, longitude) for navigation tracking. Call when you receive the user's current GPS coordinates to get the next turn instruction.")
    async def update_location(self, lat: float, lng: float) -> str:
        """
        Updates the user's location. If a turn is approaching, returns the instruction.
        Otherwise, indicates tracking works.
        """
        # This is fast enough to be sync, but wrapping for consistency if needed.
        # However, it accesses self.session state, no external IO.
        # We can leave it sync or make it async no-op waiting.
        if not self.session.active_route:
            return "Navigation not active."
            
        instruction = self.session.update_location(lat, lng)
        if instruction:
            return instruction
        
        return "Location updated. Continue on route."

    @llm.function_tool(description="Get walking directions from an origin to a destination (static list of steps)")
    async def get_walking_directions(self, origin: str, destination: str) -> str:
        if not self.client:
            return "Google Maps API key not configured."
        
        try:
            directions_result = await asyncio.to_thread(
                self.client.directions,
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
    async def search_places(self, query: str) -> str:
        api_key = os.environ.get("GOOGLE_MAPS_API_KEY")
        if not api_key:
            return "Google Maps API key not configured."

        url = "https://places.googleapis.com/v1/places:searchText"
        headers = {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": api_key,
            "X-Goog-FieldMask": "places.displayName,places.formattedAddress,places.rating",
        }
        payload = {"textQuery": query, "pageSize": 3}

        try:
            def _search():
                resp = requests.post(url, json=payload, headers=headers, timeout=10)
                resp.raise_for_status()
                return resp.json()

            data = await asyncio.to_thread(_search)
            places = data.get("places") or []
            if not places:
                return "No places found."

            response_text = f"Found {len(places)} places (showing top 3):\n"
            for place in places[:3]:
                name = "Unknown"
                if place.get("displayName") and isinstance(place["displayName"].get("text"), str):
                    name = place["displayName"]["text"]
                address = place.get("formattedAddress") or "Unknown address"
                rating = place.get("rating", "N/A")
                if isinstance(rating, (int, float)):
                    rating = str(rating)
                response_text += f"- {name}: {address} (Rating: {rating})\n"
            return response_text

        except requests.exceptions.HTTPError as e:
            logger.error(f"Error searching places: {e.response.text if e.response else e}")
            return f"Error searching places: {str(e)}"
        except Exception as e:
            logger.error(f"Error searching places: {e}")
            return f"Error searching places: {str(e)}"
