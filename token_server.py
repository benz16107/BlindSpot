"""
Simple HTTP server that issues LiveKit access tokens for the mobile app.
Run with: uv run python token_server.py
Serves GET/POST .../token?identity=optional_id -> { "token": "...", "url": "wss://..." }
"""
import os
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

from dotenv import load_dotenv

load_dotenv(".env.local")

# Optional: use LIVEKIT_URL for agent; mobile connects to same URL
LIVEKIT_URL = os.environ.get("LIVEKIT_URL", "").rstrip("/")
LIVEKIT_API_KEY = os.environ.get("LIVEKIT_API_KEY", "")
LIVEKIT_API_SECRET = os.environ.get("LIVEKIT_API_SECRET", "")
# Room name must be consistent so the agent (dispatched when participant joins) and app match
ROOM_NAME = os.environ.get("LIVEKIT_ROOM_NAME", "voice-nav")


def make_token(identity: str = "mobile-user") -> str:
    from livekit.api.access_token import AccessToken, VideoGrants

    if not LIVEKIT_API_KEY or not LIVEKIT_API_SECRET:
        raise ValueError("LIVEKIT_API_KEY and LIVEKIT_API_SECRET must be set in .env.local")
    token = AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET)
    token.with_identity(identity)
    token.with_name("Phone")
    token.with_grants(VideoGrants(room_join=True, room=ROOM_NAME, can_publish=True, can_subscribe=True, can_publish_data=True))
    return token.to_jwt()


class TokenHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path.rstrip("/") != "/token":
            self.send_response(404)
            self.end_headers()
            return
        qs = parse_qs(parsed.query)
        identity = (qs.get("identity") or ["mobile-user"])[0]

        try:
            if not LIVEKIT_URL:
                raise ValueError("LIVEKIT_URL must be set in .env.local")
            jwt_token = make_token(identity=identity)
            body = json.dumps({"token": jwt_token, "url": LIVEKIT_URL}).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode("utf-8")
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, format, *args):
        print("[token_server]", format % args)


def main():
    port = int(os.environ.get("TOKEN_SERVER_PORT", "8765"))
    server = HTTPServer(("0.0.0.0", port), TokenHandler)
    print(f"Token server at http://0.0.0.0:{port}/token (LIVEKIT_URL={LIVEKIT_URL or 'NOT SET'})")
    server.serve_forever()


if __name__ == "__main__":
    main()
