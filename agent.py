import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

_env_path = Path(__file__).resolve().parent / ".env.local"
load_dotenv(_env_path)

from livekit import agents, rtc
from livekit.agents import AgentServer, AgentSession, Agent, room_io, ConversationItemAddedEvent
from livekit.plugins import (
    google,
    elevenlabs,
    noise_cancellation,
    silero,
)
from google.genai import types

from backboard_store import init_backboard
from google_maps import NavigationTool, GPS_DATA_TOPIC
from obstacle import ObstacleProcessor

import agent_config as cfg

# LiveKit data topics for obstacle detection (must match Flutter)
APP_MODE_TOPIC = "app-mode"
OBSTACLE_MODE_TOPIC = "obstacle-mode"
OBSTACLE_FRAME_TOPIC = "obstacle-frame"
OBSTACLE_DATA_TOPIC = "obstacle"

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("agent")

class Assistant(Agent):
    def __init__(self, instructions: str = None) -> None:
        default_instructions = instructions or "You are a helpful voice AI assistant."
        super().__init__(instructions=default_instructions)

server = AgentServer()

@server.rtc_session(agent_name="voice-agent")
async def my_agent(ctx: agents.JobContext):
    room_name = getattr(ctx.room, "name", None) or "unknown"
    logger.info("Agent job started for room=%s", room_name)

    # Initialize Backboard (optional memory)
    try:
        memory_manager = await init_backboard()
        if memory_manager:
            logger.info(f"✓ Backboard initialized: thread_id={memory_manager.thread_id}")
    except Exception as e:
        logger.error(f"Failed to initialize Backboard: {e}")
        memory_manager = None

    context_text = ""
    if memory_manager:
        thread_history = await memory_manager.load_thread_history(limit=cfg.MEMORY_HISTORY_LIMIT)
        context_text = memory_manager.format_context_for_llm(thread_history)
        logger.debug(f"Loaded context: {len(thread_history)} messages, {len(context_text)} chars")

    full_instructions = f"{cfg.AGENT_BASE_INSTRUCTIONS}\n\n{context_text}".strip() if context_text else cfg.AGENT_BASE_INSTRUCTIONS

    eleven_key = os.environ.get("ELEVEN_API_KEY", "").strip()
    if not eleven_key:
        logger.warning("ELEVEN_API_KEY is not set; ElevenLabs STT and TTS will fail")
    session = AgentSession(
        stt=elevenlabs.STT(model_id=cfg.STT_MODEL, language_code=cfg.STT_LANGUAGE),
        llm=google.LLM(
            model=cfg.LLM_MODEL,
            thinking_config=types.ThinkingConfig(thinking_budget=cfg.THINKING_BUDGET),
        ),
        tts=elevenlabs.TTS(
            api_key=eleven_key or None,
            voice_id=os.environ.get("ELEVEN_VOICE_ID", cfg.TTS_VOICE_ID_DEFAULT),
            model=os.environ.get("ELEVEN_MODEL", cfg.TTS_MODEL_DEFAULT),
        ),
        vad=silero.VAD.load(
            min_speech_duration=cfg.VAD_MIN_SPEECH_DURATION,
            min_silence_duration=cfg.VAD_MIN_SILENCE_DURATION,
            activation_threshold=cfg.VAD_ACTIVATION_THRESHOLD,
        ),
        turn_detection="vad",
        allow_interruptions=True,
    )

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
                pass

        session.on("conversation_item_added", on_conversation_item_added)

    agent = Assistant(instructions=full_instructions)
    if not getattr(agent, "_tools", None) or not isinstance(agent._tools, list):
        agent._tools = []

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

    room = ctx.room
    app_navigation_enabled = False
    app_obstacles_enabled = False
    greeting_said = False

    obstacle_processor: Optional[ObstacleProcessor] = None
    obstacle_frames_received = 0

    async def _publish_obstacle(detected: bool, description: str = "") -> None:
        try:
            payload = json.dumps({"detected": detected, "description": description})
            await room.local_participant.publish_data(
                payload.encode("utf-8"),
                topic=OBSTACLE_DATA_TOPIC,
                reliable=True,
            )
            logger.debug("obstacle published: detected=%s desc=%r", detected, description)
        except Exception as e:
            logger.warning("obstacle publish failed: %s", e)

    async def _on_obstacle_detected(description: str, is_new: bool) -> None:
        await _publish_obstacle(True, description)
        if is_new and not nav_tool.session.is_in_initial_nav_phase():
            try:
                phrase = cfg.OBSTACLE_PHRASE_TEMPLATE.format(description=description)
                session.interrupt()
                await session.say(phrase)
            except Exception as e:
                logger.debug("obstacle say: %s", e)

    async def _on_obstacle_clear() -> None:
        await _publish_obstacle(False, "")

    def _start_obstacle_processor() -> None:
        nonlocal obstacle_processor
        if obstacle_processor:
            return
        obstacle_processor = ObstacleProcessor(
            on_obstacle=_on_obstacle_detected,
            on_clear=_on_obstacle_clear,
        )
        obstacle_processor.start()
        logger.info("Obstacle processor started")

    def _stop_obstacle_processor() -> None:
        nonlocal obstacle_processor
        if obstacle_processor:
            obstacle_processor.stop()
            obstacle_processor = None
            logger.info("Obstacle processor stopped")

    def _on_data_received(packet):
        nonlocal app_navigation_enabled, app_obstacles_enabled
        topic = getattr(packet, "topic", None) or ""
        if topic == GPS_DATA_TOPIC:
            try:
                payload = json.loads(packet.data.decode("utf-8"))
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
                    packet_heading = heading
                    async def _process_gps():
                        try:
                            instruction = await nav_tool.update_location(lat, lng, packet_heading)
                            if instruction and session:
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
        elif topic == APP_MODE_TOPIC:
            try:
                data = packet.data.decode("utf-8")
                payload = json.loads(data)
                app_navigation_enabled = payload.get("navigation", True)
                app_obstacles_enabled = payload.get("obstacles", False)
                logger.info("app-mode received: navigation=%s obstacles=%s", app_navigation_enabled, app_obstacles_enabled)
            except Exception as e:
                logger.debug("app-mode parse error: %s", e)
        elif topic == OBSTACLE_MODE_TOPIC:
            try:
                data = packet.data.decode("utf-8")
                payload = json.loads(data)
                enabled = payload.get("enabled", False)
                nav_enabled = payload.get("navigation", app_navigation_enabled)
                app_obstacles_enabled = enabled
                app_navigation_enabled = nav_enabled
                logger.info("obstacle-mode received: enabled=%s navigation=%s", enabled, nav_enabled)
                if enabled:
                    _start_obstacle_processor()
                else:
                    _stop_obstacle_processor()
            except Exception as e:
                logger.warning("obstacle-mode parse error: %s", e)
        elif topic == OBSTACLE_FRAME_TOPIC:
            nonlocal obstacle_frames_received
            try:
                data = packet.data.decode("utf-8")
                if data.strip().startswith("{"):
                    obj = json.loads(data)
                    b64 = (obj.get("frame") or "").strip()
                else:
                    b64 = data.strip()
                if not b64:
                    return
                obstacle_frames_received += 1
                if obstacle_frames_received <= 3 or obstacle_frames_received % 20 == 0:
                    logger.info("obstacle-frame received (total=%d, payload_len=%d)", obstacle_frames_received, len(data))
                if not obstacle_processor:
                    app_obstacles_enabled = True
                    _start_obstacle_processor()
                    logger.info("obstacle processor started from first frame (obstacle-mode may have arrived before agent)")
                if obstacle_processor:
                    obstacle_processor.put_frame(b64)
            except Exception as e:
                logger.warning("obstacle-frame parse error: %s", e)

    room.on("data_received", _on_data_received)
    logger.info("Subscribed to room data (topics: gps, app-mode, obstacle-mode, obstacle-frame)")

    def _on_participant_disconnected(participant):
        _stop_obstacle_processor()
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
        nonlocal greeting_said
        delay = max(2.0, cfg.GREETING_DELAY_SECONDS or 2)
        await asyncio.sleep(delay)
        if greeting_said:
            return
        greeting_said = True
        try:
            if app_obstacles_enabled and not app_navigation_enabled:
                logger.info("Greeting: obstacles-only mode")
                await session.say("Object detection on. Point the camera ahead.")
            else:
                logger.info("Greeting: navigation mode")
                await session.say(cfg.GREETING_PHRASE)
        except Exception as e:
            logger.warning("Greeting say failed: %s", e)

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

    