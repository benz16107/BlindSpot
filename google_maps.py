import asyncio
import os
import logging
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional

import googlemaps
import requests
from livekit.agents import llm
from navigation import NavigationSession, _rewrite_instruction_with_heading
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
        self._latest_heading: Optional[float] = None  # 0–360, 0=north (from phone compass)
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

    def set_latest_gps(self, lat: float, lng: float, heading: Optional[float] = None) -> None:
        """Update latest GPS and optional compass heading from phone (topic gps)."""
        self._latest_lat = lat
        self._latest_lng = lng
        if heading is not None:
            self._latest_heading = heading

    @llm.function_tool(description="Get the user's current location. Use when they ask 'where am I?' or 'what's my location?'. By default return only the address/place name from Google Maps. Set include_coordinates=True only when the user explicitly asks for coordinates or latitude/longitude.")
    async def get_current_location(self, include_coordinates: bool = False) -> str:
        """Return current location (address only by default; add coordinates only if include_coordinates is True)."""
        if self._latest_lat is None or self._latest_lng is None:
            return "Location not available yet. Make sure the app is open and sending GPS."

        lat, lng = self._latest_lat, self._latest_lng
        coords_str = f"{lat:.6f}, {lng:.6f} (latitude, longitude)"

        facing_str = ""
        if self._latest_heading is not None:
            h = self._latest_heading
            if h < 22.5 or h >= 337.5:
                facing_str = " Facing north."
            elif h < 67.5:
                facing_str = " Facing north-east."
            elif h < 112.5:
                facing_str = " Facing east."
            elif h < 157.5:
                facing_str = " Facing south-east."
            elif h < 202.5:
                facing_str = " Facing south."
            elif h < 247.5:
                facing_str = " Facing south-west."
            elif h < 292.5:
                facing_str = " Facing west."
            else:
                facing_str = " Facing north-west."

        if self.client:
            try:
                results = await asyncio.to_thread(
                    self.client.reverse_geocode,
                    (lat, lng),
                )
                if results and len(results) > 0:
                    addr = results[0].get("formatted_address")
                    if isinstance(addr, str) and addr.strip():
                        if include_coordinates:
                            return f"You are at {addr}. Coordinates: {coords_str}.{facing_str}"
                        return f"You are at {addr}.{facing_str}"
            except Exception as e:
                logger.debug("Reverse geocode failed: %s", e)

        return f"You are at coordinates {coords_str}.{facing_str}"

    @llm.function_tool(description="Get the direction the user is facing (from phone compass). Use when they ask 'which way am I facing?', 'am I pointing north?', or 'where am I walking towards?'.")
    async def get_heading(self) -> str:
        """Return current compass heading (0–360°, 0=north) or that heading is not available."""
        if self._latest_heading is None:
            return "Compass heading is not available. Make sure the app is open and has compass access."
        h = self._latest_heading
        if h < 22.5 or h >= 337.5:
            return "You are facing north."
        if h < 67.5:
            return "You are facing north-east."
        if h < 112.5:
            return "You are facing east."
        if h < 157.5:
            return "You are facing south-east."
        if h < 202.5:
            return "You are facing south."
        if h < 247.5:
            return "You are facing south-west."
        if h < 292.5:
            return "You are facing west."
        return "You are facing north-west."

    @llm.function_tool(description="Start turn-by-turn navigation from an origin to a destination. Always use origin 'current location' unless the user explicitly gives a different start address (e.g. 'navigate me to X', 'take me to Y' → origin='current location', destination=X or Y).")
    async def start_navigation(self, origin: str, destination: str, mode: str = "walking") -> str:
        if not self.client:
            return "Google Maps API key not configured."

        # Replace "current location" with live GPS from the phone (Directions API needs lat,lng or address)
        origin_lower = (origin or "").strip().lower()
        if origin_lower in ("current location", "current location.", "my location", "here"):
            if self._latest_lat is None or self._latest_lng is None:
                return "I don't have your location yet. Make sure the app is open and GPS is on, then ask again."
            origin = f"{self._latest_lat},{self._latest_lng}"
            logger.info("Using phone GPS as origin: %s", origin)

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

            # Total distance, duration, and arrival time from all legs (announce these before any directions)
            legs = selected_route.get("legs", [])
            total_meters = 0
            total_seconds = 0
            for leg in legs:
                total_meters += leg.get("distance", {}).get("value", 0) or 0
                total_seconds += leg.get("duration", {}).get("value", 0) or 0
            distance_text = legs[0].get("distance", {}).get("text", "N/A") if legs else "N/A"
            duration_text = legs[0].get("duration", {}).get("text", "N/A") if legs else "N/A"
            if len(legs) > 1:
                distance_text = f"{total_meters / 1000:.1f} km" if total_meters else "N/A"
                mins = int(total_seconds // 60)
                duration_text = f"{mins} min" if mins < 60 else f"{mins // 60} hr {mins % 60} min"
            arrival = (datetime.now() + timedelta(seconds=total_seconds)) if total_seconds else None
            try:
                arrival_str = (arrival.strftime("%I:%M %p").lstrip("0") if arrival else "N/A")
            except Exception:
                arrival_str = "N/A"
            # Confirm destination first, then total distance, time, arrival, then first direction.
            end_address = legs[0].get("end_address", destination) if legs else destination
            destination_confirm = f"Destination: {end_address}. "
            summary_announcement = (
                f"Total distance: {distance_text}. "
                f"Estimated time: {duration_text}. "
                f"Arrival around {arrival_str}."
            )
            if analysis_text:
                summary_announcement += " " + analysis_text.strip()
            if legs:
                steps = legs[0].get("steps", [])
                if steps:
                    raw_first = self.session._clean_instruction(steps[0].get('html_instructions', 'Proceed to route'))
                    # Enhance with compass: "Head left onto X, that's west"
                    if self._latest_lat is not None and self._latest_lng is not None:
                        first_instruction = _rewrite_instruction_with_heading(
                            raw_first, self._latest_heading,
                            self._latest_lat, self._latest_lng, steps[0]
                        )
                    else:
                        first_instruction = raw_first
                    return f"{destination_confirm}{summary_announcement} First direction: {first_instruction}"
            return f"{destination_confirm}{summary_announcement} Proceed to the route."
            
        except Exception as e:
            err_msg = str(e)
            logger.error(f"Error starting navigation: {e}")
            if "REQUEST_DENIED" in err_msg or "API_KEY_INVALID" in err_msg or "referer" in err_msg.lower():
                return (
                    "Google Maps error: check that Directions API is enabled and your API key is valid. "
                    "In Google Cloud Console: APIs & Services → Enable APIs → enable 'Directions API'. "
                    "Ensure billing is enabled on the project."
                )
            return f"Error starting navigation: {err_msg}"

    @llm.function_tool(description="Update user location (latitude, longitude) for navigation tracking. Call when you receive the user's current GPS coordinates to get the next turn instruction. Uses phone compass heading when available to announce 'head forward/left/right/behind' and cardinal direction (north, south, east, west).")
    async def update_location(self, lat: float, lng: float, heading: Optional[float] = None) -> str:
        """
        Updates the user's location. Returns an instruction only when approaching a turn
        (within ~45m warning or ~12m "Now"); otherwise returns empty string so the agent
        does not announce anything (no repeated "continue on route").
        heading: compass 0-360 from the same GPS packet (ensures fresh direction when user turns).
        """
        if not self.session.active_route:
            return "Navigation not active."

        h = heading if heading is not None else self._latest_heading
        instruction = self.session.update_location(lat, lng, h)
        if instruction:
            return instruction
        # No turn to announce – return empty so the agent does not speak
        return ""

    @llm.function_tool(description="Get walking directions from an origin to a destination (static list of steps). Use origin 'current location' when the user wants to start from where they are.")
    async def get_walking_directions(self, origin: str, destination: str) -> str:
        if not self.client:
            return "Google Maps API key not configured."

        origin_lower = (origin or "").strip().lower()
        if origin_lower in ("current location", "current location.", "my location", "here"):
            if self._latest_lat is None or self._latest_lng is None:
                return "I don't have your location yet. Make sure the app is open and GPS is on, then ask again."
            origin = f"{self._latest_lat},{self._latest_lng}"

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
            err_msg = str(e)
            logger.error(f"Error getting directions: {e}")
            if "REQUEST_DENIED" in err_msg or "API_KEY_INVALID" in err_msg:
                return (
                    "Google Maps error: enable Directions API and check your API key in Google Cloud Console."
                )
            return f"Error getting directions: {err_msg}"

    @llm.function_tool(
        description="Search for places matching a query (e.g. 'coffee shop', 'pharmacy'). Returns a numbered list of up to 3 nearby places with name and address. Use this FIRST when the user asks for a generic destination like 'a coffee shop' or 'a pharmacy' so they can pick which one to go to; then call start_navigation with the chosen place's address."
    )
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
        if self._latest_lat is not None and self._latest_lng is not None:
            payload["locationBias"] = {
                "circle": {
                    "center": {"latitude": self._latest_lat, "longitude": self._latest_lng},
                    "radius": 5000.0,
                }
            }
            payload["rankPreference"] = "DISTANCE"

        try:
            def _search():
                resp = requests.post(url, json=payload, headers=headers, timeout=10)
                resp.raise_for_status()
                return resp.json()

            data = await asyncio.to_thread(_search)
            places = data.get("places") or []
            if not places:
                return "No places found."

            response_text = f"Found {len(places)} places (showing top 3). Tell the user and ask which one to navigate to:\n"
            for i, place in enumerate(places[:3], 1):
                name = "Unknown"
                if place.get("displayName") and isinstance(place["displayName"].get("text"), str):
                    name = place["displayName"]["text"]
                address = place.get("formattedAddress") or "Unknown address"
                rating = place.get("rating", "N/A")
                if isinstance(rating, (int, float)):
                    rating = str(rating)
                response_text += f"{i}. {name} at {address} (Rating: {rating})\n"
            return response_text

        except requests.exceptions.HTTPError as e:
            body = (e.response.text if e.response else "") or str(e)
            logger.error(f"Error searching places: {e.response.status_code} {body}")
            if e.response and e.response.status_code == 403:
                return (
                    "Places search failed: enable 'Places API (New)' in Google Cloud Console and ensure billing is on. "
                    "APIs & Services → Enable APIs → search for 'Places API (New)'."
                )
            if "REQUEST_DENIED" in body or "API_KEY_INVALID" in body:
                return "Places error: check API key and that Places API (New) is enabled."
            return f"Error searching places: {body[:200]}"
        except Exception as e:
            logger.error(f"Error searching places: {e}")
            return f"Error searching places: {str(e)}"

    @llm.function_tool(
        description="Find a nearby place and start turn-by-turn navigation to it. Use for requests like 'navigate to a nearby McDonald's', 'take me to the nearest coffee shop', 'find a pharmacy nearby and take me there'. Pass only the place type or name (e.g. 'McDonald's', 'coffee shop', 'pharmacy')."
    )
    async def navigate_to_nearby(self, place_query: str) -> str:
        """Find the nearest place matching the query and start navigation to it."""
        if not self.client:
            return "Google Maps API key not configured."
        if self._latest_lat is None or self._latest_lng is None:
            return "I don't have your location yet. Make sure the app is open and GPS is on, then ask again."

        api_key = os.environ.get("GOOGLE_MAPS_API_KEY")
        if not api_key:
            return "Google Maps API key not configured."

        url = "https://places.googleapis.com/v1/places:searchText"
        headers = {
            "Content-Type": "application/json",
            "X-Goog-Api-Key": api_key,
            "X-Goog-FieldMask": "places.displayName,places.formattedAddress",
        }
        payload = {
            "textQuery": (place_query or "").strip() or "place",
            "pageSize": 1,
            "locationBias": {
                "circle": {
                    "center": {"latitude": self._latest_lat, "longitude": self._latest_lng},
                    "radius": 5000.0,
                }
            },
            "rankPreference": "DISTANCE",
        }
        try:
            def _search():
                resp = requests.post(url, json=payload, headers=headers, timeout=10)
                resp.raise_for_status()
                return resp.json()

            data = await asyncio.to_thread(_search)
            places = data.get("places") or []
            if not places:
                return f"No nearby place found for '{place_query}'. Try a different search or area."

            place = places[0]
            name = "Unknown"
            if place.get("displayName") and isinstance(place["displayName"].get("text"), str):
                name = place["displayName"]["text"]
            address = place.get("formattedAddress")
            if not address or not isinstance(address, str) or not address.strip():
                return f"Found {name} but could not get its address."
            return await self.start_navigation(origin="current location", destination=address, mode="walking")
        except requests.exceptions.HTTPError as e:
            body = (e.response.text if e.response else "") or str(e)
            logger.error(f"navigate_to_nearby search: {e.response.status_code} {body}")
            if e.response and e.response.status_code == 403:
                return "Places search failed: enable 'Places API (New)' in Google Cloud Console."
            return f"Search failed: {body[:150]}"
        except Exception as e:
            logger.error(f"navigate_to_nearby: {e}")
            return f"Could not find or navigate to nearby place: {str(e)}"
