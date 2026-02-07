import asyncio
import logging
import json
import inspect
import keyword
import typing
from typing import Any, List, Dict, Callable, Optional, Awaitable, Sequence, Tuple, Type, Union, cast
from uuid import uuid4
from datetime import datetime

# Import from the MCP module
from .util import MCPUtil, FunctionTool
from .server import MCPServer, MCPServerSse
from livekit.agents import ChatContext, AgentSession, JobContext, FunctionTool as Tool
from mcp import CallToolRequest

logger = logging.getLogger("mcp-agent-tools")

class MCPToolsIntegration:
    """
    Helper class for integrating MCP tools with LiveKit agents.
    Provides utilities for registering dynamic tools from MCP servers.
    """

    @staticmethod
    def _sanitize_kwargs(kwargs: Dict[str, Any]) -> Dict[str, Any]:
        """
        Sanitize sensitive data from tool arguments (emails, tokens, passwords, etc).
        """
        sensitive_keys = {'password', 'token', 'secret', 'key', 'api_key', 'auth', 'email'}
        sanitized = {}
        
        for k, v in kwargs.items():
            if any(sensitive in k.lower() for sensitive in sensitive_keys):
                # Redact sensitive values
                if isinstance(v, str) and len(v) > 4:
                    sanitized[k] = v[:2] + "***" + v[-2:]
                else:
                    sanitized[k] = "***REDACTED***"
            else:
                sanitized[k] = v
        
        return sanitized

    @staticmethod
    async def prepare_dynamic_tools(mcp_servers: List[MCPServer],
                                   convert_schemas_to_strict: bool = True,
                                   auto_connect: bool = True,
                                   memory_manager = None) -> List[Callable]:
        """
        Fetches tools from multiple MCP servers and prepares them for use with LiveKit agents.

        Args:
            mcp_servers: List of MCPServer instances
            convert_schemas_to_strict: Whether to convert JSON schemas to strict format
            auto_connect: Whether to automatically connect to servers if they're not connected
            memory_manager: Optional BackboardMemoryManager for saving tool results

        Returns:
            List of decorated tool functions ready to be added to a LiveKit agent
        """
        prepared_tools = []

        # Ensure all servers are connected if auto_connect is True
        if auto_connect:
            for server in mcp_servers:
                if not getattr(server, 'connected', False):
                    try:
                        logger.debug(f"Auto-connecting to MCP server: {server.name}")
                        await server.connect()
                    except Exception as e:
                        logger.error(f"Failed to connect to MCP server {server.name}: {e}")

        # Process each server
        for server in mcp_servers:
            logger.info(f"Fetching tools from MCP server: {server.name}")
            try:
                mcp_tools = await MCPUtil.get_function_tools(
                    server, convert_schemas_to_strict=convert_schemas_to_strict
                )
                logger.info(f"Received {len(mcp_tools)} tools from {server.name}")
            except Exception as e:
                logger.error(f"Failed to fetch tools from {server.name}: {e}")
                continue

            # Process each tool from this server
            for tool_instance in mcp_tools:
                try:
                    decorated_tool = MCPToolsIntegration._create_decorated_tool(
                        tool_instance, server, memory_manager
                    )
                    prepared_tools.append(decorated_tool)
                    logger.debug(f"Successfully prepared tool: {tool_instance.name}")
                except Exception as e:
                    logger.error(f"Failed to prepare tool '{tool_instance.name}': {e}")

        return prepared_tools

    @staticmethod
    def _create_decorated_tool(tool: FunctionTool, mcp_server: MCPServer, memory_manager = None) -> Callable:
        """
        Creates a decorated function for a single MCP tool that can be used with LiveKit agents.

        Args:
            tool: The FunctionTool instance to convert
            mcp_server: The MCPServer instance that owns this tool (for reset capability)
            memory_manager: Optional BackboardMemoryManager for saving tool results

        Returns:
            A decorated async function that can be added to a LiveKit agent's tools
        """
        # Get function_tool decorator from LiveKit
        # Import locally to avoid circular imports
        from livekit.agents.llm import function_tool

        # Create parameters list from JSON schema
        params = []
        annotations = {}
        schema_props = tool.params_json_schema.get("properties", {})
        schema_required = set(tool.params_json_schema.get("required", []))
        type_map = {
            "string": str, "integer": int, "number": float,
            "boolean": bool, "array": list, "object": dict,
        }

        # Build keyword remapping dict for generalized keyword handling
        import keyword as keyword_module
        schema_to_python_name = {}  # Maps schema param names to Python param names
        
        # Build parameters from the schema properties
        for p_name, p_details in schema_props.items():
            # Handle Python reserved keywords by appending underscore
            param_name = p_name
            if keyword_module.iskeyword(p_name):
                param_name = p_name + '_'  # Map reserved keywords to name_
                logger.warning(f"Remapping parameter '{p_name}' to '{param_name}' in tool '{tool.name}' as it's a Python reserved keyword")
            
            schema_to_python_name[p_name] = param_name

            json_type = p_details.get("type", "string")
            py_type = type_map.get(json_type, typing.Any)
            annotations[param_name] = py_type

            # Make all parameters optional in the function signature with None as default
            # This allows LiveKit to accept the function call even if required fields are missing
            # We'll handle validation inside the function before MCP call
            default = None
            params.append(inspect.Parameter(
                name=param_name,
                kind=inspect.Parameter.KEYWORD_ONLY,
                annotation=py_type,
                default=default
            ))

        # Define the actual function that will be called by the agent
        async def tool_impl(**kwargs):
            # Timeout for tool execution (longer than LiveKit interruption timeout)
            # This prevents a slow tool call from poisoning the session
            TOOL_TIMEOUT_SECONDS = 60
            
            # Remap Python names back to schema names (e.g., from_ -> from) and filter None values
            remapped_kwargs = {}
            for python_name, v in kwargs.items():
                # Skip None values to avoid validation errors from the MCP server
                if v is None:
                    continue
                
                # Reverse lookup: python_name back to schema_name
                schema_name = next((sn for sn, pn in schema_to_python_name.items() if pn == python_name), python_name)
                remapped_kwargs[schema_name] = v
            
            # Auto-fill instructions if it's in the schema but not provided
            # (don't validate as strictly required - let server handle validation)
            if 'instructions' in schema_props and 'instructions' not in remapped_kwargs:
                remapped_kwargs['instructions'] = "Execute using the provided parameters."
            
            input_json = json.dumps(remapped_kwargs)
            sanitized_kwargs = MCPToolsIntegration._sanitize_kwargs(remapped_kwargs)
            logger.info(f"Invoking tool '{tool.name}' with args: {sanitized_kwargs}")
            
            try:
                # Wrap tool call with timeout to keep voice loop responsive
                # If it times out or is cancelled, reset the MCP connection
                async def make_tool_call():
                    return await tool.on_invoke_tool(None, input_json)
                
                result_str = await asyncio.wait_for(make_tool_call(), timeout=TOOL_TIMEOUT_SECONDS)
                logger.info(f"Tool '{tool.name}' result: {result_str}")
                
                # Save tool execution to Backboard
                if memory_manager:
                    await memory_manager.add_tool_message({
                        "tool_name": tool.name,
                        "status": "SUCCESS",
                        "args": sanitized_kwargs,
                        "result": result_str,  # Store full result for better memory recall
                        "timestamp": datetime.utcnow().isoformat()
                    })
                
                return result_str
                
            except asyncio.CancelledError:
                # Handle speech cancellation gracefully
                logger.warning(f"Tool '{tool.name}' was cancelled (speech interrupted)")
                
                # Save cancellation to Backboard
                if memory_manager:
                    await memory_manager.add_tool_message({
                        "tool_name": tool.name,
                        "status": "CANCELLED",
                        "args": sanitized_kwargs,
                        "result": "User interrupted",
                        "timestamp": datetime.utcnow().isoformat()
                    })
                
                # Reset the MCP connection to prevent poisoning
                try:
                    if hasattr(tool, 'mcp_server'):
                        await tool.mcp_server.reset()
                except Exception as e:
                    logger.error(f"Error resetting MCP server after cancellation: {e}")
                
                # Return a user-friendly message
                return "I was interrupted. Please ask me to try again."
                
            except asyncio.TimeoutError:
                logger.error(f"Tool '{tool.name}' timed out after {TOOL_TIMEOUT_SECONDS}s")
                
                # Save timeout to Backboard
                if memory_manager:
                    await memory_manager.add_tool_message({
                        "tool_name": tool.name,
                        "status": "TIMEOUT",
                        "args": sanitized_kwargs,
                        "result": f"Tool took longer than {TOOL_TIMEOUT_SECONDS}s",
                        "timestamp": datetime.utcnow().isoformat()
                    })
                
                # Reset the MCP connection to prevent poisoning
                try:
                    if hasattr(tool, 'mcp_server'):
                        await tool.mcp_server.reset()
                except Exception as e:
                    logger.error(f"Error resetting MCP server after timeout: {e}")
                
                # Return a user-friendly message
                return "That tool is taking longer than expected—please try again."
                
            except Exception as e:
                logger.error(f"Error calling tool '{tool.name}': {repr(e)}")
                
                # Save error to Backboard
                if memory_manager:
                    await memory_manager.add_tool_message({
                        "tool_name": tool.name,
                        "status": "ERROR",
                        "args": sanitized_kwargs,
                        "result": str(e),  # Store full error message
                        "timestamp": datetime.utcnow().isoformat()
                    })
                
                # Check if this is a connection error that should trigger reset
                error_str = str(e).lower()
                if any(x in error_str for x in ['closed', 'connection', 'disconnected', 'reset']):
                    try:
                        if hasattr(tool, 'mcp_server'):
                            await tool.mcp_server.reset()
                    except Exception as reset_e:
                        logger.error(f"Error resetting MCP server after connection error: {reset_e}")
                
                # Return a user-friendly message
                return "I lost connection to the tool service. Please try again in a moment."

        # Set function metadata
        tool_impl.__signature__ = inspect.Signature(parameters=params)
        tool_impl.__name__ = tool.name
        tool_impl.__doc__ = tool.description
        tool_impl.__annotations__ = {'return': str, **annotations}
        # Attach mcp_server for reset capability
        tool_impl.mcp_server = mcp_server

        # Apply the decorator and return
        return function_tool()(tool_impl)

    @staticmethod
    async def register_with_agent(agent, mcp_servers: List[MCPServer],
                                 convert_schemas_to_strict: bool = True,
                                 auto_connect: bool = True,
                                 memory_manager = None) -> List[Callable]:
        """
        Helper method to prepare and register MCP tools with a LiveKit agent.

        Args:
            agent: The LiveKit agent instance
            mcp_servers: List of MCPServer instances
            convert_schemas_to_strict: Whether to convert schemas to strict format
            auto_connect: Whether to auto-connect to servers
            memory_manager: Optional BackboardMemoryManager for saving tool results

        Returns:
            List of tool functions that were registered
        """
        # Prepare the dynamic tools
        tools = await MCPToolsIntegration.prepare_dynamic_tools(
            mcp_servers,
            convert_schemas_to_strict=convert_schemas_to_strict,
            auto_connect=auto_connect,
            memory_manager=memory_manager
        )

        # Register with the agent
        if hasattr(agent, '_tools') and isinstance(agent._tools, list):
            agent._tools.extend(tools)
            logger.info(f"Registered {len(tools)} MCP tools with agent")

            # Log the names of registered tools
            if tools:
                tool_names = [getattr(t, '__name__', 'unknown') for t in tools]
                logger.info(f"Registered tool names: {tool_names}")
        else:
            logger.warning("Agent does not have a '_tools' attribute, tools were not registered")

        return tools

    @staticmethod
    async def create_agent_with_tools(agent_class, mcp_servers: List[MCPServer], agent_kwargs: Dict = None,
                                    convert_schemas_to_strict: bool = True, memory_manager = None) -> Any:
        """
        Factory method to create and initialize an agent with MCP tools already loaded.

        Args:
            agent_class: Agent class to instantiate
            mcp_servers: List of MCP servers to register with the agent
            agent_kwargs: Additional keyword arguments to pass to the agent constructor
            convert_schemas_to_strict: Whether to convert JSON schemas to strict format
            memory_manager: Optional BackboardMemoryManager for saving tool results

        Returns:
            An initialized agent instance with MCP tools registered
        """
        # Connect to MCP servers
        for server in mcp_servers:
            if not getattr(server, 'connected', False):
                try:
                    logger.debug(f"Connecting to MCP server: {server.name}")
                    await server.connect()
                except Exception as e:
                    logger.error(f"Failed to connect to MCP server {server.name}: {e}")

        # Create agent instance
        agent_kwargs = agent_kwargs or {}
        agent = agent_class(**agent_kwargs)

        # Prepare tools
        tools = await MCPToolsIntegration.prepare_dynamic_tools(
            mcp_servers,
            convert_schemas_to_strict=convert_schemas_to_strict,
            auto_connect=False,  # Already connected above
            memory_manager=memory_manager,
        )

        # Register tools with agent
        if tools and hasattr(agent, '_tools') and isinstance(agent._tools, list):
            agent._tools.extend(tools)
            logger.info(f"Registered {len(tools)} MCP tools with agent")

            # Log the names of registered tools
            tool_names = [getattr(t, '__name__', 'unknown') for t in tools]
            logger.info(f"Registered tool names: {tool_names}")
        else:
            if not tools:
                logger.warning("No tools were found to register with the agent")
            else:
                logger.warning("Agent does not have a '_tools' attribute, tools were not registered")

        return agent
