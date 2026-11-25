"""
OpenAI-compatible provider.

Covers: LM Studio, Ollama, llama.cpp server, vLLM, OpenAI, and any other
endpoint that implements the OpenAI chat completions API.

LM Studio exposes http://localhost:1234/v1 by default.
The api_key is required by the SDK but ignored by local servers — use any string.
"""

import logging
import uuid
from . import ProviderConfig

log = logging.getLogger(__name__)

# One conversation ID per bridge run. Every turn is a fresh [system, user]
# request, so session-routing proxies (e.g. OpenCode Go) cannot infer that the
# turns belong together; a stable x-opencode-session keeps them on one backend
# and lets the unchanging system prompt hit the prompt cache.
SESSION_ID = f"ai-player-{uuid.uuid4().hex}"


def complete(messages: list[dict], config: ProviderConfig) -> str | None:
    """
    Send a chat completion request to an OpenAI-compatible endpoint.

    messages: standard OpenAI format — [{"role": "system"|"user"|"assistant", "content": str}]
    Returns the assistant content string, or None on failure.
    """
    try:
        from openai import OpenAI, APIError, APITimeoutError, APIConnectionError
    except ImportError:
        log.error("openai package not installed — run: pip install openai")
        return None

    if config.provider == "opencode" and not config.api_key:
        log.error("AI_PROVIDER=opencode but OPENCODE_API_KEY is not set in bridge/.env")
        return None

    client = OpenAI(
        base_url=config.url,
        api_key=config.api_key,
        timeout=config.timeout,
        # No retries: the SDK retries timeouts twice by default, and each retry
        # re-submits the full prompt and restarts the local model's generation —
        # so a slow model never finishes and one "turn" silently costs
        # 3 × timeout seconds. One clean attempt; the mod re-requests next tick.
        max_retries=0,
        # OpenCode Go rejects generic client User-Agents.
        default_headers={"x-opencode-session": SESSION_ID, "User-Agent": "ai-player-v3-bridge"},
    )

    extra = {"reasoning_effort": config.reasoning_effort} if config.reasoning_effort else {}
    try:
        response = client.chat.completions.create(
            model=config.model,
            messages=messages,
            max_tokens=config.max_tokens,
            temperature=config.temperature,
            **extra,
        )
        if not response.choices:
            log.error(
                "LM Studio returned no choices (model=%s). "
                "Is the model loaded and the server running?",
                config.model,
            )
            return None
        content = response.choices[0].message.content
        if content is None:
            log.error("response.choices[0].message.content is None (model=%s)", config.model)
            return None
        log.debug("provider=openai_compat tokens_used=%s", response.usage)
        return content

    except APITimeoutError:
        log.error("Request timed out after %.0fs (model=%s)", config.timeout, config.model)
    except APIConnectionError as e:
        log.error("Cannot reach %s: %s", config.url, e)
    except APIError as e:
        log.error("API error %s: %s", e.status_code, e.message)

    return None
