"""
Obstacle server: only loads GOOGLE_API_KEY and runs obstacle detection (Gemini).
Run with: uv run python obstacle_server.py
POST /obstacle-frame (body = JPEG) -> { "obstacle_detected", "distance", "description" }
"""
import os
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse

from dotenv import load_dotenv

load_dotenv(".env.local")

logger = logging.getLogger("obstacle_server")

# API key only
GOOGLE_API_KEY = os.environ.get("GOOGLE_API_KEY", "").strip()
OBSTACLE_FRAME_MAX_BYTES = 500_000


def _analyze_obstacle(image_bytes: bytes) -> dict:
    if not GOOGLE_API_KEY:
        return {"obstacle_detected": False, "distance": "none", "description": "", "error": "GOOGLE_API_KEY not set"}
    try:
        from google.genai import Client
        from google.genai import types

        client = Client(api_key=GOOGLE_API_KEY)
        prompt = """You are analyzing a single frame from a phone camera held by a blind pedestrian. Alert ONLY when something is (1) directly in front and centered, AND (2) very close — within about 2 meters (arm's reach, could bump into it soon).

STRICT RULES:
- "obstacle_detected" must be true ONLY if the object is in the CENTER of the frame (middle third of the image, especially the lower center). If it is to the left or right side, say false.
- "distance" must be "near" ONLY if the object appears within ~2 meters (large in frame, immediate proximity). If it is farther away (smaller in frame, more than 2 meters), use "none" or "far" and set obstacle_detected to false so we do NOT alert.
- Do NOT report: the road, pavement, sidewalk, or ground. Do NOT report things that are far away or off to the side. When in doubt, say no obstacle (prefer fewer false alarms).
- ONLY set obstacle_detected true + distance "near" when something (pole, person, object, door) is directly in front, centered, and very close — within 2 meters.

Reply with JSON only, no other text, with these exact keys:
- "obstacle_detected": true or false
- "distance": one of "none", "far", "medium", "near" (use "near" only when within ~2 m and centered)
- "description": short phrase (e.g. "pole", "person") or empty if none"""

        response = client.models.generate_content(
            model="gemini-2.0-flash",
            contents=[
                types.Content(
                    role="user",
                    parts=[
                        types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
                        types.Part.from_text(text=prompt),
                    ],
                )
            ],
            config=types.GenerateContentConfig(
                response_mime_type="application/json",
                temperature=0.2,
            ),
        )
        text = (response.text or "").strip()
        if not text:
            return {"obstacle_detected": False, "distance": "none", "description": ""}
        if "```" in text:
            start = text.find("{")
            end = text.rfind("}") + 1
            if start >= 0 and end > start:
                text = text[start:end]
        out = json.loads(text)
        if not isinstance(out, dict):
            return {"obstacle_detected": False, "distance": "none", "description": ""}
        detected = out.get("obstacle_detected")
        if isinstance(detected, str):
            detected = detected.strip().lower() in ("true", "1", "yes")
        else:
            detected = bool(detected)
        dist = out.get("distance")
        if isinstance(dist, str):
            dist = dist.strip().lower()
        distance = dist if dist in ("far", "medium", "near") else ("none" if not detected else "medium")
        return {
            "obstacle_detected": detected,
            "distance": distance,
            "description": str(out.get("description") or ""),
        }
    except json.JSONDecodeError as e:
        logger.warning("Obstacle JSON parse error: %s", e)
        return {"obstacle_detected": False, "distance": "none", "description": ""}
    except Exception as e:
        logger.warning("Obstacle analysis error: %s", e)
        return {"obstacle_detected": False, "distance": "none", "description": "", "error": str(e)}


class ObstacleHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if urlparse(self.path).path.rstrip("/") != "/obstacle-frame":
            self.send_response(404)
            self.end_headers()
            return
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length <= 0 or content_length > OBSTACLE_FRAME_MAX_BYTES:
            self.send_response(400)
            body = json.dumps({"error": "Invalid Content-Length (JPEG body, max %s bytes)" % OBSTACLE_FRAME_MAX_BYTES}).encode("utf-8")
            self._send_json(400, body)
            return
        try:
            image_bytes = self.rfile.read(content_length)
        except Exception as e:
            self._send_json(200, json.dumps({"obstacle_detected": False, "distance": "none", "description": "", "error": str(e)}).encode("utf-8"))
            return
        result = _analyze_obstacle(image_bytes)
        self._send_json(200, json.dumps(result).encode("utf-8"))

    def _send_json(self, status: int, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        print("[obstacle_server]", format % args)


def main():
    port = int(os.environ.get("OBSTACLE_SERVER_PORT", "8766"))
    server = HTTPServer(("0.0.0.0", port), ObstacleHandler)
    print(f"Obstacle server http://0.0.0.0:{port}/obstacle-frame (API key: GOOGLE_API_KEY)")
    server.serve_forever()


if __name__ == "__main__":
    main()
