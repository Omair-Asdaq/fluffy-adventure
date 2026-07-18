"""
content_filter.py
------------------
Server-side second layer of defense (Roblox TextService:FilterStringAsync
is the first layer, run client-side before the answer ever reaches us).

Hard guarantee (spec 3.3 #3): a flagged/profane answer is REPLACED with a
neutral placeholder, scored 0.0 automatically, and NEVER sent to the model.
This is enforced structurally below -- flagged answers are filtered out of
the payload before judge.py builds the AI prompt, not just asked-nicely-of
the model via prompt wording.
"""

import re

PLACEHOLDER_TEXT = "[content removed]"

# Prompt-injection / jailbreak patterns. Case-insensitive, checked against
# normalized (lowercased, whitespace-collapsed) text.
INJECTION_PATTERNS = [
    r"ignore (all )?(previous|prior|above) instructions",
    r"disregard (all )?(previous|prior|above)",
    r"system prompt",
    r"you are now",
    r"new instructions?:",
    r"act as (a|an) ",
    r"pretend (you|to) (are|be)",
    r"\bassign\b.{0,20}\bscore\b",
    r"\bgive\b.{0,20}\b(a\s)?10\b",
    r"\boutput\b.{0,20}\bjson\b",
    r"override",
    r"jailbreak",
    r"</?(system|assistant|player_answer)>",  # tag-spoofing attempts
]

_COMPILED_INJECTION = [re.compile(p, re.IGNORECASE) for p in INJECTION_PATTERNS]

# Minimal built-in profanity list. In production this should be swapped
# for (or combined with) a maintained third-party wordlist -- Roblox's
# own TextService filter is the primary safety net for profanity; this
# is a defense-in-depth backstop, not the sole line of defense.
_PROFANITY_STUB = {
    "fuck", "shit", "bitch", "asshole", "nigger", "faggot", "cunt",
}


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip().lower()


def contains_injection(text: str) -> bool:
    norm = _normalize(text)
    return any(p.search(norm) for p in _COMPILED_INJECTION)


def contains_profanity(text: str) -> bool:
    norm = _normalize(text)
    tokens = re.findall(r"[a-z']+", norm)
    return any(t in _PROFANITY_STUB for t in tokens)


def is_flagged(text: str) -> bool:
    if not text or not text.strip():
        return False  # empty is handled separately as non-empty=false, not "flagged"
    return contains_injection(text) or contains_profanity(text)


def sanitize_answer(text: str) -> dict:
    """
    Returns {"text": str_to_send_to_model_or_placeholder, "flagged": bool}
    Callers MUST check `flagged` and score 0.0 + skip sending to the AI
    when True -- this function does not do the scoring itself.
    """
    if is_flagged(text):
        return {"text": PLACEHOLDER_TEXT, "flagged": True}
    return {"text": text, "flagged": False}


def sanitize_batch(answers: list) -> list:
    """answers: list of raw strings -> list of sanitize_answer() results"""
    return [sanitize_answer(a) for a in answers]
