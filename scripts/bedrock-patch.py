#!/usr/bin/env python3
"""
Bedrock Auxiliary Client Patch for Hermes Agent
================================================
Patches agent/auxiliary_client.py to add AWS Bedrock Converse API support.

Usage (run inside hermes-agent venv):
    cd ~/.hermes/hermes-agent
    python3 /tmp/bedrock-patch.py

The patch adds:
  1. BedrockAuxiliaryClient / AsyncBedrockAuxiliaryClient classes
  2. Bedrock branch in _to_async_client()
  3. aws_sdk auth_type handler in resolve_provider_client()
"""

import os
import sys

FILEPATH = "agent/auxiliary_client.py"

def main():
    if not os.path.isfile(FILEPATH):
        print(f"ERROR: {FILEPATH} not found. Run this from the hermes-agent root.", file=sys.stderr)
        sys.exit(1)

    with open(FILEPATH, "r") as f:
        content = f.read()

    # Guard: skip if already patched
    if "BedrockAuxiliaryClient" in content:
        print("Bedrock auxiliary patch already applied — skipping")
        return

    # -------------------------------------------------------------------------
    # 1. Add BedrockAuxiliaryClient classes after AsyncCodexAuxiliaryClient
    # -------------------------------------------------------------------------
    bedrock_classes = """


# ---------------------------------------------------------------------------
# AWS Bedrock Converse API -> OpenAI-compatible wrapper for auxiliary tasks
# ---------------------------------------------------------------------------


class _BedrockCompletionsAdapter:
    \"\"\"Translate chat.completions.create() kwargs to Bedrock Converse API.\"\"\"

    def __init__(self, region: str, default_model: str):
        self._region = region
        self._default_model = default_model

    def create(self, **kwargs) -> Any:
        from agent.bedrock_adapter import call_converse
        model = kwargs.get("model") or self._default_model
        messages = kwargs.get("messages", [])
        max_tokens = kwargs.get("max_tokens") or kwargs.get("max_completion_tokens") or 4096
        temperature = kwargs.get("temperature")
        return call_converse(region=self._region, model=model, messages=messages,
                             max_tokens=max_tokens, temperature=temperature)

class _BedrockChatShim:
    def __init__(self, adapter): self.completions = adapter

class BedrockAuxiliaryClient:
    \"\"\"OpenAI-client-compatible wrapper for Bedrock Converse API.\"\"\"
    def __init__(self, region: str, default_model: str):
        self.chat = _BedrockChatShim(_BedrockCompletionsAdapter(region, default_model))
        self.api_key = "aws-sdk"
        self.base_url = f"https://bedrock-runtime.{region}.amazonaws.com"
    def close(self): pass

class _AsyncBedrockCompletionsAdapter:
    def __init__(self, sync_adapter): self._sync = sync_adapter
    async def create(self, **kwargs):
        import asyncio
        return await asyncio.to_thread(self._sync.create, **kwargs)

class _AsyncBedrockChatShim:
    def __init__(self, adapter): self.completions = adapter

class AsyncBedrockAuxiliaryClient:
    def __init__(self, sync_wrapper):
        self.chat = _AsyncBedrockChatShim(_AsyncBedrockCompletionsAdapter(sync_wrapper.chat.completions))
        self.api_key = sync_wrapper.api_key
        self.base_url = sync_wrapper.base_url
"""

    marker = "class AsyncCodexAuxiliaryClient:"
    idx = content.find(marker)
    if idx == -1:
        print("ERROR: Could not find AsyncCodexAuxiliaryClient class — hermes-agent version may be incompatible", file=sys.stderr)
        sys.exit(1)

    next_blank = content.find("\n\n", idx + len(marker))
    if next_blank != -1:
        content = content[:next_blank] + bedrock_classes + content[next_blank:]

    # -------------------------------------------------------------------------
    # 2. Add Bedrock to _to_async_client
    # -------------------------------------------------------------------------
    old_async = (
        "    if isinstance(sync_client, AnthropicAuxiliaryClient):\n"
        "        return AsyncAnthropicAuxiliaryClient(sync_client), model"
    )
    new_async = (
        old_async + "\n"
        "    if isinstance(sync_client, BedrockAuxiliaryClient):\n"
        "        return AsyncBedrockAuxiliaryClient(sync_client), model"
    )
    if old_async not in content:
        print("WARNING: Could not find _to_async_client Anthropic branch — skipping step 2", file=sys.stderr)
    else:
        content = content.replace(old_async, new_async, 1)

    # -------------------------------------------------------------------------
    # 3. Add aws_sdk auth_type handler in resolve_provider_client
    # -------------------------------------------------------------------------
    old_block = (
        '    logger.warning("resolve_provider_client: unhandled auth_type %s for %s",\n'
        '                   pconfig.auth_type, provider)\n'
        '    return None, None'
    )
    new_block = (
        '    if pconfig.auth_type == "aws_sdk":\n'
        '        try:\n'
        '            from agent.bedrock_adapter import has_aws_credentials\n'
        '            if not has_aws_credentials():\n'
        '                return None, None\n'
        '            _region = os.getenv("AWS_DEFAULT_REGION") or os.getenv("AWS_REGION") or "us-east-1"\n'
        '            import re as _re\n'
        '            _base = str(explicit_base_url or "")\n'
        '            _match = _re.search(r"bedrock-runtime\\.([a-z0-9-]+)\\.", _base)\n'
        '            if _match: _region = _match.group(1)\n'
        '            _default_model = model or "apac.anthropic.claude-sonnet-4-20250514-v1:0"\n'
        '            _client = BedrockAuxiliaryClient(_region, _default_model)\n'
        '            if async_mode: return AsyncBedrockAuxiliaryClient(_client), _default_model\n'
        '            return _client, _default_model\n'
        '        except Exception:\n'
        '            logger.warning("resolve_provider_client: bedrock aws_sdk init failed", exc_info=True)\n'
        '            return None, None\n'
        '\n'
        '    logger.warning("resolve_provider_client: unhandled auth_type %s for %s",\n'
        '                   pconfig.auth_type, provider)\n'
        '    return None, None'
    )
    if old_block not in content:
        print("WARNING: Could not find resolve_provider_client fallback — skipping step 3", file=sys.stderr)
    else:
        content = content.replace(old_block, new_block, 1)

    with open(FILEPATH, "w") as f:
        f.write(content)

    print("Bedrock auxiliary patch applied successfully")


if __name__ == "__main__":
    main()
