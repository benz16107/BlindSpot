      
from dotenv import load_dotenv

from livekit import agents, rtc
from livekit.agents import AgentServer, AgentSession, Agent, room_io
from livekit.plugins import (
    google,
    # openai,  # Commented out - using Google Gemini instead
    noise_cancellation,
)

# from mcp_client import MCPServerSse
from mcp_client import MCPServerHttp, MCPToolsIntegration   # or MCPServerStreamableHttp
from backboard_store import init_backboard
from google_maps import NavigationTool
import os
import logging

load_dotenv(".env.local")

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
    base_instructions = "You are a helpful voice AI assistant soley for the purpose of navigation for blind people.. You can use the tools provided to you to help the user (Zapier MCP Server)"
    
    if context_text:
        full_instructions = f"{base_instructions}\n\n{context_text}"
    else:
        full_instructions = base_instructions
    
    # Google Gemini Realtime Model
    session = AgentSession(
        llm=google.realtime.RealtimeModel(
            voice="Aoede", # Other options Puck (default), Kore (Femme), Charon, Fenrir, Aoede,
        ),
        # PTT Configuration: Helper can be interrupted (mutes when user speaks/presses button)
        allow_interruptions=True,
    )
    
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
    if hasattr(agent, "_tools") and isinstance(agent._tools, list):
        agent._tools.extend([
            nav_tool.start_navigation,
            nav_tool.update_location,
            nav_tool.get_walking_directions,
            nav_tool.search_places,
        ])
        logger.info("Registered Google Maps navigation tools with agent")

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

    