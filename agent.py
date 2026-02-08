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
    # 1. Initialize Backboard memory FIRST
    try:
        memory_manager = await init_backboard()
        logger.info(f"✓ Backboard initialized: thread_id={memory_manager.thread_id}")
    except Exception as e:
        logger.error(f"Failed to initialize Backboard: {e}")
        # Continue without memory - voice still works
        memory_manager = None
    
    # 2. Load thread history and format as context
    context_text = ""
    if memory_manager:
        thread_history = await memory_manager.load_thread_history(limit=50)
        context_text = memory_manager.format_context_for_llm(thread_history)
        logger.debug(f"Loaded context: {len(thread_history)} messages, {len(context_text)} chars")
    
    # 3. Create session with injected context
    base_instructions = (
        "You are a helpful multi-lingual voice AI assistant solely for navigation for blind people, you can communicate in multiple languages. "
        "The user's phone sends live GPS to you. Use get_current_location when they ask 'where am I?' or 'what's my location?'. "
        "For navigation, use start_navigation with origin 'current location' when they want to start from where they are. "
        "During turn-by-turn navigation, you will get GPS updates automatically and speak the next instruction when they approach a turn. "
        "You can also use the tools provided to you (Zapier MCP Server) when relevant."
    )
    
    if context_text:
        full_instructions = f"{base_instructions}\n\n{context_text}"
    else:
        full_instructions = base_instructions
    
    # Voice pipeline: Deepgram STT + Gemini (with thinking) + ElevenLabs TTS
    # Set DEEPGRAM_API_KEY, ELEVEN_API_KEY; optionally ELEVEN_VOICE_ID in .env.local
    session = AgentSession(
        stt=deepgram.STT(model="nova-2", language="en"),
        llm=google.LLM(
            model="gemini-2.5-flash",
            thinking_config=types.ThinkingConfig(thinking_budget=-1),  # -1 = dynamic thinking
        ),
        tts=elevenlabs.TTS(
            voice_id=os.environ.get("ELEVEN_VOICE_ID", "EXAVITQu4vr4xnSDxMaL"),
            model=os.environ.get("ELEVEN_MODEL", "eleven_multilingual_v2"),
        ),
        vad=silero.VAD.load(),
        turn_detection="vad",  # VAD-only; no turn-detector model download needed
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

    mcp_server = MCPServerHttp(
        params={
            "url": os.environ.get("ZAPIER_MCP_URL"),
            # headers optional but commonly needed now
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
        memory_manager=memory_manager  # Pass memory manager to tools
    )

    # Register Google Maps navigation tools so the agent can provide directions
    nav_tool = NavigationTool()
    if nav_tool.client:
        logger.info("Google Maps API key loaded; navigation tools enabled")
    else:
        logger.warning("GOOGLE_MAPS_API_KEY missing or invalid; navigation will report 'not configured'")
    if hasattr(agent, "_tools") and isinstance(agent._tools, list):
        agent._tools.extend([
            nav_tool.start_navigation,
            nav_tool.update_location,
            nav_tool.get_current_location,
            nav_tool.get_walking_directions,
            nav_tool.search_places,
        ])
        logger.info("Registered Google Maps navigation tools with agent")

    # Use constantly updating GPS from the phone. Client should publish JSON { "lat": <float>, "lng": <float> } with topic "gps".
    room = ctx.room
    import json as _json

    def _on_data_received(packet):
        if (getattr(packet, "topic", None) or "") != GPS_DATA_TOPIC:
            return
        try:
            payload = _json.loads(packet.data.decode("utf-8"))
            lat = payload.get("lat")
            lng = payload.get("lng")
            if lat is None or lng is None:
                return
            lat, lng = float(lat), float(lng)
            nav_tool.set_latest_gps(lat, lng)
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
    logger.info("Subscribed to room GPS data (topic=%s)", GPS_DATA_TOPIC)

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

    