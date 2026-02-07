import asyncio
from contextlib import AbstractAsyncContextManager, AsyncExitStack
from typing import Any, Dict, List, Optional, Tuple
import logging
import traceback

import httpx

# Import from the installed mcp package
from anyio.streams.memory import MemoryObjectReceiveStream, MemoryObjectSendStream
import mcp.types
from mcp.types import CallToolResult, JSONRPCMessage, Tool as MCPTool
from mcp.client.sse import sse_client
from mcp.client.streamable_http import streamable_http_client
from mcp.client.session import ClientSession

# Base class for MCP servers
class MCPServer:
    async def connect(self):
        """Connect to the server."""
        raise NotImplementedError

    @property
    def name(self) -> str:
        """A readable name for the server."""
        raise NotImplementedError

    async def list_tools(self) -> List[MCPTool]:
        """List the tools available on the server."""
        raise NotImplementedError

    async def call_tool(self, tool_name: str, arguments: Optional[Dict[str, Any]] = None) -> CallToolResult:
        """Invoke a tool on the server."""
        raise NotImplementedError

    async def cleanup(self):
        """Cleanup the server."""
        raise NotImplementedError

# Base class for MCP servers that use a ClientSession
class _MCPServerWithClientSession(MCPServer):
    """Base class for MCP servers that use a ClientSession to communicate with the server."""

    def __init__(self, cache_tools_list: bool):
        """
        Args:
            cache_tools_list: Whether to cache the tools list. If True, the tools list will be
            cached and only fetched from the server once. If False, the tools list will be
            fetched from the server on each call to list_tools(). You should set this to True
            if you know the server will not change its tools list, because it can drastically
            improve latency.
        """
        self.session: Optional[ClientSession] = None
        self.exit_stack: AsyncExitStack = AsyncExitStack()
        self._cleanup_lock: asyncio.Lock = asyncio.Lock()
        self.cache_tools_list = cache_tools_list

        # The cache is always dirty at startup, so that we fetch tools at least once
        self._cache_dirty = True
        self._tools_list: Optional[List[MCPTool]] = None
        self.logger = logging.getLogger(__name__)

    def create_streams(
        self,
    ) -> AbstractAsyncContextManager[
        Tuple[
            MemoryObjectReceiveStream[JSONRPCMessage | Exception],
            MemoryObjectSendStream[JSONRPCMessage],
        ]
    ]:
        """Create the streams for the server."""
        raise NotImplementedError

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc_value, traceback):
        await self.cleanup()

    def invalidate_tools_cache(self):
        """Invalidate the tools cache."""
        self._cache_dirty = True

    async def connect(self):
        """Connect to the server."""
        try:
            transport = await self.exit_stack.enter_async_context(self.create_streams())
            # streamable_http_client returns (read, write, get_session_id_callback)
            # sse_client returns (read, write)
            # Handle both cases with safe unpacking
            try:
                read, write, _ = transport
            except ValueError:
                read, write = transport
            session = await self.exit_stack.enter_async_context(ClientSession(read, write))
            await session.initialize()
            self.session = session
            self.logger.info(f"Connected to MCP server: {self.name}")
        except Exception as e:
            self.logger.error(f"Error initializing MCP server: {e}")
            await self.cleanup()
            raise

    async def list_tools(self) -> List[MCPTool]:
        """List the tools available on the server."""
        if not self.session:
            raise RuntimeError("Server not initialized. Make sure you call connect() first.")

        # Return from cache if caching is enabled, we have tools, and the cache is not dirty
        if self.cache_tools_list and not self._cache_dirty and self._tools_list:
            return self._tools_list

        # Reset the cache dirty to False
        self._cache_dirty = False

        try:
            # Fetch the tools from the server
            result = await self.session.list_tools()
            self._tools_list = result.tools
            return self._tools_list
        except Exception as e:
            self.logger.error(f"Error listing tools: {e}")
            raise

    async def call_tool(self, tool_name: str, arguments: Optional[Dict[str, Any]] = None) -> CallToolResult:
        """Invoke a tool on the server."""
        if not self.session:
            raise RuntimeError("Server not initialized. Make sure you call connect() first.")

        arguments = arguments or {}
        try:
            return await self.session.call_tool(tool_name, arguments)
        except Exception as e:
            # Log full exception details including traceback
            self.logger.error(f"Error calling tool {tool_name}: {repr(e)}\n{traceback.format_exc()}")
            
            # Log HTTP-specific details if available
            if isinstance(e, httpx.HTTPError) and hasattr(e, 'response'):
                try:
                    status = e.response.status_code if hasattr(e.response, 'status_code') else 'unknown'
                    url = e.request.url if hasattr(e, 'request') else 'unknown'
                    self.logger.error(f"HTTP Error: {status} on {url}")
                except:
                    pass
            
            raise

    async def cleanup(self):
        """Cleanup the server."""
        async with self._cleanup_lock:
            try:
                await self.exit_stack.aclose()
                self.session = None
                self.logger.info(f"Cleaned up MCP server: {self.name}")
            except Exception as e:
                self.logger.error(f"Error cleaning up server: {e}")

    async def reset(self):
        """Reset the server by cleaning up and reconnecting. Call this when session is poisoned."""
        self.logger.info(f"Resetting MCP server: {self.name}")
        await self.cleanup()
        # Mark tools cache as dirty so they'll be refetched
        self.invalidate_tools_cache()
        try:
            await self.connect()
            self.logger.info(f"Successfully reset MCP server: {self.name}")
        except Exception as e:
            self.logger.error(f"Error resetting MCP server {self.name}: {e}")
            raise

# Cleanup old definition removed - see below

# Define parameter types for clarity
MCPServerSseParams = Dict[str, Any]
MCPServerStdioParams = Dict[str, Any]
MCPServerHttpParams = Dict[str, Any]

# SSE server implementation
class MCPServerSse(_MCPServerWithClientSession):
    """MCP server implementation that uses the HTTP with SSE transport."""

    def __init__(
        self,
        params: MCPServerSseParams,
        cache_tools_list: bool = False,
        name: Optional[str] = None,
    ):
        """Create a new MCP server based on the HTTP with SSE transport.

        Args:
            params: The params that configure the server including the URL, headers,
                   timeout, and SSE read timeout.
            cache_tools_list: Whether to cache the tools list.
            name: A readable name for the server.
        """
        super().__init__(cache_tools_list)
        self.params = params
        self._name = name or f"SSE Server at {self.params.get('url', 'unknown')}"

    def create_streams(
        self,
    ) -> AbstractAsyncContextManager[
        Tuple[
            MemoryObjectReceiveStream[JSONRPCMessage | Exception],
            MemoryObjectSendStream[JSONRPCMessage],
        ]
    ]:
        """Create the streams for the server."""
        return sse_client(
            url=self.params["url"],
            headers=self.params.get("headers"),
            timeout=self.params.get("timeout", 5),
            sse_read_timeout=self.params.get("sse_read_timeout", 60 * 5),
        )

    @property
    def name(self) -> str:
        """A readable name for the server."""
        return self._name

# HTTP Streamable server implementation
class MCPServerHttp(_MCPServerWithClientSession):
    """MCP server implementation that uses the Streamable HTTP transport (new default)."""

    def __init__(
        self,
        params: MCPServerHttpParams,
        cache_tools_list: bool = False,
        name: Optional[str] = None,
    ):
        """Create a new MCP server based on the HTTP Streamable transport.

        Args:
            params: The params that configure the server including the URL and optional headers.
            cache_tools_list: Whether to cache the tools list.
            name: A readable name for the server.
        """
        super().__init__(cache_tools_list)
        self.params = params
        self._name = name or f"HTTP Streamable Server at {self.params.get('url', 'unknown')}"
        self._http_client: Optional[httpx.AsyncClient] = None
        self._owns_http_client = False

    def create_streams(
        self,
    ) -> AbstractAsyncContextManager[
        Tuple[
            MemoryObjectReceiveStream[JSONRPCMessage | Exception],
            MemoryObjectSendStream[JSONRPCMessage],
        ]
    ]:
        """Create the streams for the server."""
        # Create an httpx.AsyncClient with headers and explicit timeouts
        # Track ownership to ensure proper cleanup (prevents socket leaks)
        http_client = None
        if self.params.get("headers"):
            # Set explicit timeouts to prevent hanging requests
            # These prevent a single hung request from cascading into all subsequent failures
            timeout = httpx.Timeout(30.0, connect=10.0, read=30.0, write=10.0, pool=5.0)
            http_client = httpx.AsyncClient(headers=self.params.get("headers"), timeout=timeout)
            self._http_client = http_client
            self._owns_http_client = True
        
        return streamable_http_client(
            url=self.params["url"],
            http_client=http_client,
        )

    @property
    def name(self) -> str:
        """A readable name for the server."""
        return self._name

    async def cleanup(self):
        """Cleanup the server and close httpx client to prevent socket leaks."""
        # Close httpx client if we own it
        if self._owns_http_client and self._http_client is not None:
            try:
                await self._http_client.aclose()
                self._http_client = None
            except Exception as e:
                self.logger.error(f"Error closing httpx client for {self.name}: {e}")
        
        # Call parent cleanup
        await super().cleanup()

# Stdio server implementation
class MCPServerStdio(MCPServer):
    """An example (minimal) Stdio server implementation."""

    def __init__(self, params: MCPServerStdioParams, cache_tools_list: bool = False, name: Optional[str] = None):
        self.params = params
        self.cache_tools_list = cache_tools_list
        self._tools_cache: Optional[List[MCPTool]] = None
        self._name = name or f"Stdio Server: {self.params.get('command', 'unknown')}"
        self.connected = False
        self.logger = logging.getLogger(__name__)

    @property
    def name(self) -> str:
        return self._name

    async def connect(self):
        await asyncio.sleep(0.5)
        self.connected = True
        self.logger.info(f"Connected to MCP Stdio server: {self.name}")

    async def list_tools(self) -> List[MCPTool]:
        if self.cache_tools_list and self._tools_cache is not None:
            return self._tools_cache
        # For demonstration, return an empty list or similar static tools.
        tools: List[MCPTool] = []
        if self.cache_tools_list:
            self._tools_cache = tools
        return tools

    async def call_tool(self, tool_name: str, arguments: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        return {"content": [f"Called {tool_name} with args {arguments} via Stdio"]}

    async def cleanup(self):
        self.connected = False
        self.logger.info(f"Cleaned up MCP Stdio server: {self.name}")
