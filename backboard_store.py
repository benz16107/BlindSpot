"""
Backboard Memory Manager - Handles persistent memory across sessions

This module manages:
- Single assistant creation (reused across all sessions)
- Thread reuse (same thread_id = continuous memory)
- Message history (stored on Backboard, accessed on session start)
- Tool execution tracking (as messages in thread)
- Local metadata (only thread_id and assistant_id cached)
"""

import json
import os
import logging
from datetime import datetime
from typing import Optional, Dict, List, Any
from backboard import BackboardClient

logger = logging.getLogger("backboard")


class BackboardMemoryManager:
    """Manages persistent memory via Backboard API"""

    def __init__(self, api_key: str, memory_file: Optional[str] = None):
        """
        Initialize memory manager

        Args:
            api_key: Backboard API key
            memory_file: Path to local metadata file (default: .backboard.json next to this module)
        """
        self.client = BackboardClient(api_key=api_key)
        self.memory_file = memory_file or os.path.join(
            os.path.dirname(os.path.abspath(__file__)), ".backboard.json"
        )
        self.assistant_id: Optional[str] = None
        self.thread_id: Optional[str] = None
        self.conversation_history = self._load_memory()

    def _load_memory(self) -> Dict[str, Any]:
        """Load local metadata from .backboard.json"""
        if os.path.exists(self.memory_file):
            try:
                with open(self.memory_file, "r") as f:
                    data = json.load(f)
                    logger.info(f"Loaded existing memory: {data}")
                    return data
            except Exception as e:
                logger.warning(f"Could not load memory file: {e}")
        
        return {
            "assistant_id": None,
            "thread_id": None,
            "created": None,
            "last_used": None,
        }

    def _save_memory(self):
        """Save local metadata to .backboard.json"""
        try:
            self.conversation_history["last_used"] = datetime.now().isoformat()
            with open(self.memory_file, "w") as f:
                json.dump(self.conversation_history, f, indent=2)
            logger.debug(f"Saved memory to {self.memory_file}")
        except Exception as e:
            logger.error(f"Could not save memory: {e}")

    async def initialize(self):
        """
        Initialize Backboard assistant and thread
        
        Flow:
        1. Create/get assistant (idempotent, reused across sessions)
        2. Load or create thread (same thread_id = persistent memory)
        3. Save metadata locally
        """
        try:
            # Step 1: Get or create assistant
            assistant = await self.client.create_assistant(
                name="LiveKit Voice Agent",
                system_prompt="""You are a helpful voice AI assistant. 
Remember context from previous messages in this conversation and use it to provide consistent, 
context-aware responses. Be concise since this is voice interaction."""
            )
            self.assistant_id = str(assistant.assistant_id)
            logger.info(f"Assistant ready: {self.assistant_id}")
            
            # Step 2: Get or create thread
            last_thread_id = self.conversation_history.get("thread_id")
            
            if last_thread_id:
                # REUSE THREAD = PERSISTENT MEMORY
                self.thread_id = last_thread_id
                logger.info(f"✓ Thread reused (persistent memory): {self.thread_id}")
            else:
                # FIRST TIME = CREATE NEW THREAD
                thread = await self.client.create_thread(self.assistant_id)
                self.thread_id = str(thread.thread_id)
                logger.info(f"✓ Thread created (new): {self.thread_id}")
                
                # Save for next session
                self.conversation_history["thread_id"] = self.thread_id
                self.conversation_history["assistant_id"] = self.assistant_id
                self.conversation_history["created"] = datetime.now().isoformat()
            
            self.conversation_history["assistant_id"] = self.assistant_id
            self._save_memory()
            
        except Exception as e:
            logger.error(f"Failed to initialize Backboard: {e}")
            raise

    async def load_thread_history(self, limit: int = 50) -> List[Dict[str, Any]]:
        """
        Load full conversation history from Backboard thread
        
        Args:
            limit: Maximum number of recent messages to load (increased to 50 for better recall)
            
        Returns:
            List of messages with role, content, created_at
        """
        if not self.thread_id:
            logger.warning("No thread_id set, returning empty history")
            return []
        
        try:
            thread = await self.client.get_thread(self.thread_id)
            logger.debug(f"Loaded thread with {len(thread.messages)} messages")
            
            # Convert to dicts, keep only recent messages
            message_list = []
            for msg in thread.messages[-limit:]:
                message_list.append({
                    "role": getattr(msg, "role", "user"),
                    "content": getattr(msg, "content", ""),
                    "created_at": getattr(msg, "created_at", None),
                })
            
            return message_list
            
        except Exception as e:
            logger.error(f"Failed to load thread history: {e}")
            return []

    def format_context_for_llm(self, messages: List[Dict[str, Any]], max_chars: int = 8000) -> str:
        """
        Format message history as context for LLM injection
        
        Converts thread messages into a concise context string that can be injected
        into Realtime model instructions.
        
        Args:
            messages: List of messages from load_thread_history()
            max_chars: Maximum characters to include (8000 for rich memory recall)
            
        Returns:
            Formatted context string ready for injection
        """
        if not messages:
            return ""
        
        lines = ["[Previous Session Context]"]
        char_count = len(lines[0])
        
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            
            # Format based on message type
            if isinstance(content, str):
                # Regular message
                line = f"{role.title()}: {content[:150]}"
            elif isinstance(content, dict) and content.get("type") == "tool_execution":
                # Tool execution
                tool_name = content.get("tool_name", "unknown")
                status = content.get("status", "?")
                result = content.get("result", "")[:100]
                line = f"Tool({tool_name}): {status} - {result}"
            else:
                continue
            
            if char_count + len(line) < max_chars:
                lines.append(line)
                char_count += len(line) + 1
            else:
                break
        
        # If we have history, format it nicely
        if len(lines) > 1:
            return "\n".join(lines) + "\n"
        return ""

    async def add_user_message(self, content: str):
        """
        Save user message to Backboard thread
        
        Args:
            content: User message text
        """
        if not self.thread_id:
            logger.warning("No thread_id set, cannot save user message")
            return
        
        try:
            await self.client.add_message(
                thread_id=self.thread_id,
                content=content,
                llm_provider=None  # Critical: don't trigger LLM inference, just store
            )
            logger.debug(f"Saved user message to Backboard")
        except Exception as e:
            logger.error(f"Failed to save user message: {e}")

    async def add_assistant_message(self, content: str):
        """
        Save assistant response to Backboard thread
        
        Args:
            content: Assistant response text
        """
        if not self.thread_id:
            logger.warning("No thread_id set, cannot save assistant message")
            return
        
        try:
            await self.client.add_message(
                thread_id=self.thread_id,
                content=content,
                llm_provider=None
            )
            logger.debug(f"Saved assistant message to Backboard")
        except Exception as e:
            logger.error(f"Failed to save assistant message: {e}")

    async def add_tool_message(self, tool_execution: Dict[str, Any]):
        """
        Save tool execution result to Backboard thread as a message
        
        Tool executions are stored as structured messages in the thread,
        making them part of the conversation history that the LLM can see.
        
        Args:
            tool_execution: Dict with:
                - tool_name: str
                - status: "SUCCESS" | "ERROR" | "TIMEOUT" | "CANCELLED"
                - args: sanitized tool arguments
                - result: tool output or error message
                - timestamp: ISO timestamp
        """
        if not self.thread_id:
            logger.warning("No thread_id set, cannot save tool message")
            return
        
        try:
            # Format as message content
            message_content = json.dumps({
                "type": "tool_execution",
                "tool_name": tool_execution.get("tool_name"),
                "status": tool_execution.get("status"),
                "args": tool_execution.get("args"),
                "result": tool_execution.get("result", ""),
                "timestamp": tool_execution.get("timestamp")
            })
            
            await self.client.add_message(
                thread_id=self.thread_id,
                content=message_content,
                llm_provider=None
            )
            logger.info(
                f"Tool execution saved: {tool_execution.get('tool_name')} "
                f"status={tool_execution.get('status')}"
            )
        except Exception as e:
            logger.error(f"Failed to save tool message: {e}")

    async def get_thread_summary(self) -> str:
        """
        Get a summary of the current thread
        
        Useful for displaying to user: "You have 15 messages in this conversation"
        """
        if not self.thread_id:
            return "No active thread"
        
        try:
            messages = await self.client.get_thread(self.thread_id)
            return f"Thread has {len(messages)} messages"
        except Exception as e:
            logger.error(f"Failed to get thread summary: {e}")
            return "Unable to retrieve summary"


async def init_backboard() -> BackboardMemoryManager:
    """
    Initialize and return Backboard memory manager
    
    This is the entry point for agent.py
    
    Returns:
        Initialized BackboardMemoryManager ready to use
    """
    from dotenv import load_dotenv
    
    load_dotenv(".env.local")
    api_key = os.getenv("BACKBOARD_API_KEY")
    
    if not api_key:
        raise ValueError("BACKBOARD_API_KEY not set in .env.local")
    
    manager = BackboardMemoryManager(api_key=api_key)
    await manager.initialize()
    return manager
