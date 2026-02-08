import asyncio
import os
import logging
from pathlib import Path

from dotenv import load_dotenv

# Load .env.local from project root (where this file lives). Required when the agent
# runs in a worker process whose current working directory is not the project root.
_env_path = Path(__file__).resolve().parent / ".env.local"
load_dotenv(_env_path)

from livekit import agents, rtc
from livekit.agents import AgentServer, AgentSession, Agent, room_io, ConversationItemAddedEvent
from livekit.plugins import (
    deepgram,
    google,
    elevenlabs,
    noise_cancellation,
    silero,
)
from google.genai import types

# from mcp_client import MCPServerSse
from mcp_client import MCPServerHttp, MCPToolsIntegration   # or MCPServerStreamableHttp
from backboard_store import init_backboard
from google_maps import NavigationTool, GPS_DATA_TOPIC

OBSTACLE_DATA_TOPIC = "obstacle"

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("agent")

class Assistant(Agent):
    def __init__(self, instructions: str = None) -> None:
        default_instructions = instructions or "You are a helpful voice AI assistant. You can use the tools provided to you to help the user (Zapier MCP Server)"
        super().__init__(instructions=default_instructions)

server = AgentServer()

@server.rtc_session()
async def my_agent(ctx: agents.JobContext):
    room_name = getattr(ctx.room, "name", None) or "unknown"
    logger.info("Agent job started for room=%s", room_name)
    # 1. Initialize Backboard memory FIRST
    try:
        memory_manager = await init_backboard()
        logger.info(f"✓ Backboard initialized: thread_id={memory_manager.thread_id}")
    except Exception as e:
        logger.error(f"Failed to initialize Backboard: {e}")
        # Continue without memory - voice still works
        memory_manager = None
    
    # 2. Load thread history (keep small for low latency)
    context_text = ""
    if memory_manager:
        thread_history = await memory_manager.load_thread_history(limit=20)
        context_text = memory_manager.format_context_for_llm(thread_history)
        logger.debug(f"Loaded context: {len(thread_history)} messages, {len(context_text)} chars")

    # 3. Short instructions = faster first token; thinking off = much lower latency
    base_instructions = (
        "You are a concise voice walking navigation assistant for blind users. Multilingual. "
        "Phone sends live GPS. Use get_current_location for 'where am I?'. "
        "For 'navigate to X' or 'take me to Y' (with a specific address or place name) use start_navigation(origin='current location', destination=X or Y). Never ask for start address. "
        "For 'navigate to a nearby X', 'nearest Y', 'find a Z and take me there' use navigate_to_nearby(place_query) with just the place type (e.g. 'McDonald's', 'coffee shop', 'pharmacy') — do NOT use start_navigation with a vague destination like 'nearby McDonald's'. "
        "Turn-by-turn is automatic from GPS. Use Zapier tools when relevant. Keep replies brief."
    )
    full_instructions = f"{base_instructions}\n\n{context_text}".strip() if context_text else base_instructions

    # Voice pipeline: Deepgram STT + Gemini (no thinking for speed) + ElevenLabs TTS
    # Set ELEVEN_API_KEY in .env.local (required). Optional: ELEVEN_VOICE_ID, ELEVEN_MODEL
    eleven_key = os.environ.get("ELEVEN_API_KEY", "").strip()
    if not eleven_key:
        logger.warning("ELEVEN_API_KEY is not set; ElevenLabs TTS will fail (no audio frames)")
    session = AgentSession(
        stt=deepgram.STT(model="nova-2", language="en"),
        llm=google.LLM(
            model="gemini-2.5-flash",
            thinking_config=types.ThinkingConfig(thinking_budget=0),  # 0 = no thinking, faster replies
        ),
        tts=elevenlabs.TTS(
            api_key=eleven_key or None,
            voice_id=os.environ.get("ELEVEN_VOICE_ID", "EXAVITQu4vr4xnSDxMaL"),
            model=os.environ.get("ELEVEN_MODEL", "eleven_multilingual_v2"),
        ),
        vad=silero.VAD.load(
            min_speech_duration=0.4,    # require ~400ms speech before treating as user (reduces cutoffs)
            min_silence_duration=1.0,   # wait 1s before end-of-turn (let agent finish)
            activation_threshold=0.65,  # need clearer speech to interrupt (less noise triggers)
        ),
        turn_detection="vad",
        allow_interruptions=True,
    )

    # Persist each user/assistant turn to Backboard so memory survives restarts
    if memory_manager:

        def on_conversation_item_added(event: ConversationItemAddedEvent):
            text = (event.item.text_content or "").strip()
            if not text:
                return
            role = (event.item.role or "").lower()
            try:
                loop = asyncio.get_running_loop()
                if role == "user":
                    loop.create_task(memory_manager.add_user_message(text))
                elif role == "assistant":
                    loop.create_task(memory_manager.add_assistant_message(text))
            except RuntimeError:
                pass  # No running loop (e.g. during shutdown)

        session.on("conversation_item_added", on_conversation_item_added)
    
    # # Commented out: OpenAI Realtime Model (replaced with Google Gemini)
    # session = AgentSession(
    #     llm=openai.realtime.RealtimeModel(
    #         voice="coral"
    #     )
    # )

    # mcp_server = MCPServerSse(
    #     params={"url": os.environ.get("ZAPIER_MCP_URL")},
    #     cache_tools_list=True,
    #     name="SSE MCP Server"
    # )

    try:
        mcp_server = MCPServerHttp(
            params={
                "url": os.environ.get("ZAPIER_MCP_URL"),
                "headers": {
                    "Authorization": f"Bearer {os.environ.get('ZAPIER_MCP_TOKEN')}"
                }
            },
            cache_tools_list=True,
            name="Zapier MCP Server"
        )
        agent = await MCPToolsIntegration.create_agent_with_tools(
            agent_class=Assistant,
            mcp_servers=[mcp_server],
            agent_kwargs={"instructions": full_instructions},
            memory_manager=memory_manager
        )
        logger.info("Agent created with MCP (Zapier) tools")
    except Exception as e:
        logger.warning("MCP failed, using navigation-only agent: %s", e)
        agent = Assistant(instructions=full_instructions)
        if not getattr(agent, "_tools", None) or not isinstance(agent._tools, list):
            agent._tools = []

    # Register Google Maps navigation tools
    nav_tool = NavigationTool()
    if nav_tool.client:
        logger.info("Google Maps API key loaded; navigation tools enabled")
    else:
        logger.warning("GOOGLE_MAPS_API_KEY missing or invalid; navigation will report 'not configured'")
    if hasattr(agent, "_tools") and isinstance(agent._tools, list):
        agent._tools.extend([
            nav_tool.start_navigation,
            nav_tool.navigate_to_nearby,
            nav_tool.update_location,
            nav_tool.get_current_location,
            nav_tool.get_heading,
            nav_tool.get_walking_directions,
            nav_tool.search_places,
        ])
        logger.info("Registered Google Maps navigation tools with agent")

    # Use constantly updating GPS from the phone. Client should publish JSON { "lat": <float>, "lng": <float> } with topic "gps".
    room = ctx.room
    import json as _json

    def _on_data_received(packet):
        topic = getattr(packet, "topic", None) or ""

        # Obstacle: single voice — agent announces when app sends (only when obstacle button is on)
        if topic == OBSTACLE_DATA_TOPIC:
            try:
                payload = _json.loads(packet.data.decode("utf-8"))
                desc = payload.get("obstacle") or "object"
                phrase = f"Watch out. Obstacle detected. {desc} in front."
                session.interrupt()
                session.say(phrase)
            except Exception as e:
                logger.debug("Obstacle data_received: %s", e)
            return

        if topic != GPS_DATA_TOPIC:
            return
        try:
            payload = _json.loads(packet.data.decode("utf-8"))
            lat = payload.get("lat")
            lng = payload.get("lng")
            if lat is None or lng is None:
                return
            lat, lng = float(lat), float(lng)
            heading = payload.get("heading")
            if heading is not None:
                try:
                    heading = float(heading)
                except (TypeError, ValueError):
                    heading = None
            nav_tool.set_latest_gps(lat, lng, heading)
            if nav_tool.session.active_route:
                async def _process_gps():
                    try:
                        instruction = await nav_tool.update_location(lat, lng)
                        if instruction and session:
                            # Interrupt any current speech so the nav instruction is heard immediately (like a nav app)
                            session.interrupt()
                            session.say(instruction)
                    except Exception as e:
                        logger.debug(f"GPS update_location/say: {e}")
                try:
                    asyncio.get_running_loop().create_task(_process_gps())
                except RuntimeError:
                    pass
        except Exception as e:
            logger.debug(f"GPS data_received parse: {e}")

    room.on("data_received", _on_data_received)
    logger.info("Subscribed to room data (topic=%s, %s)", GPS_DATA_TOPIC, OBSTACLE_DATA_TOPIC)

    def _on_participant_disconnected(participant):
        """When the phone disconnects, leave the room so next connect gets a fresh agent."""
        logger.info("Participant %s left; agent leaving room so next connect gets a new session", participant.identity)

        async def _leave():
            try:
                await room.disconnect()
            except Exception as e:
                logger.debug("Agent room.disconnect: %s", e)

        try:
            asyncio.get_running_loop().create_task(_leave())
        except RuntimeError:
            pass

    room.on("participant_disconnected", _on_participant_disconnected)

    async def say_greeting():
        """Ask where to go as soon as the session is ready (mic enabled)."""
        await asyncio.sleep(2.0)
        try:
            await session.say("Where would you like to go?")
        except Exception as e:
            logger.debug("Greeting say: %s", e)

    asyncio.create_task(say_greeting())
    await session.start(
        room=ctx.room,
        agent=agent,
        room_options=room_io.RoomOptions(
            audio_input=room_io.AudioInputOptions(
                noise_cancellation=lambda params: noise_cancellation.BVCTelephony() if params.participant.kind == rtc.ParticipantKind.PARTICIPANT_KIND_SIP else noise_cancellation.BVC(),
            ),
        ),
    )


if __name__ == "__main__":
    agents.cli.run_app(server)

    