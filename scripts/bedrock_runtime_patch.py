"""
Bedrock Runtime Patch — survives Hermes Agent updates.

Patches normalize_model_name() in agent.anthropic_adapter to preserve
dots in Bedrock inference profile IDs (global.anthropic.claude-*).

Uses a simple sys.modules check via threading.Timer to apply the patch
after the application has fully loaded. Alternatively applied immediately
if the module is already loaded.

If upstream fix (NousResearch/hermes-agent#12577) is merged, this is a no-op.
"""

import sys
import threading


def _patch():
    """Patch normalize_model_name if agent.anthropic_adapter is loaded."""
    mod = sys.modules.get("agent.anthropic_adapter")
    if mod is None:
        return False

    orig_fn = getattr(mod, "normalize_model_name", None)
    if orig_fn is None or getattr(orig_fn, "_bedrock_patched", False):
        return True

    # Check if upstream already fixed
    try:
        import inspect
        src = inspect.getsource(orig_fn)
        if '"bedrock"' in src or "'bedrock'" in src:
            return True
    except Exception:
        pass

    def patched_normalize_model_name(model: str, preserve_dots: bool = False) -> str:
        if not preserve_dots and "." in model:
            lower = model.lower()
            for prefix in ("global.", "us.", "eu.", "ap.", "apac."):
                if lower.startswith(prefix) and "anthropic." in lower:
                    preserve_dots = True
                    break
        return orig_fn(model, preserve_dots=preserve_dots)

    patched_normalize_model_name._bedrock_patched = True
    mod.normalize_model_name = patched_normalize_model_name
    return True


def _deferred_patch():
    """Retry patching every 0.5s until the module is loaded (max 30s)."""
    for _ in range(60):
        if _patch():
            return
        import time
        time.sleep(0.5)


# Try immediate patch, otherwise start background thread
if not _patch():
    t = threading.Thread(target=_deferred_patch, daemon=True)
    t.start()
