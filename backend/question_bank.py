"""
question_bank.py
-----------------
Phase 1 (MVP) scope: load a static seed bank, serve filtered selections.
Hourly rotation / generation via Groq is NOT implemented yet (Phase 2).
The selection + blocklist logic below is written to match the final
spec exactly so Phase 2 only has to add the rotation cron job on top.
"""

import json
import os
import random
import shutil
import threading

BANK_PATH = os.path.join(os.path.dirname(__file__), "bank.json")
BACKUP_PATH = os.path.join(os.path.dirname(__file__), "bank_backup.json")

# Hardcoded emergency bank used only if the real bank is corrupt/missing
# and no backup exists either. Keeps the game playable no matter what.
HARDCODED_FALLBACK_BANK = [
    {"id": 9001, "text": "What would you name a new planet?", "uses": 0},
    {"id": 9002, "text": "Invent a new holiday and describe how it's celebrated.", "uses": 0},
    {"id": 9003, "text": "If you could have any superpower for one day, what would it be?", "uses": 0},
    {"id": 9004, "text": "Write a haiku about your favorite food.", "uses": 0},
    {"id": 9005, "text": "What would you put in a time capsule for aliens to find?", "uses": 0},
    {"id": 9006, "text": "Invent a new color and describe what it looks like.", "uses": 0},
    {"id": 9007, "text": "What's the worst advice you've ever heard?", "uses": 0},
    {"id": 9008, "text": "If animals could talk, which would be the most interesting?", "uses": 0},
    {"id": 9009, "text": "Design a new emoji and explain what it means.", "uses": 0},
    {"id": 9010, "text": "What would you do with a million dollars?", "uses": 0},
]

MIN_FILTERED_POOL = 20  # below this, blocklist is ignored (spec 2.5)


class QuestionBank:
    """
    Thread-safe in-memory question bank. Loaded once on startup,
    persisted to disk whenever `uses` counters change.
    """

    def __init__(self, path: str = BANK_PATH):
        self._path = path
        self._lock = threading.Lock()
        self._bank = self._load()

    # ---------- persistence ----------

    def _load(self):
        try:
            with open(self._path, "r") as f:
                data = json.load(f)
                if isinstance(data, list) and len(data) > 0:
                    return data
                raise ValueError("bank.json is empty or malformed")
        except (FileNotFoundError, json.JSONDecodeError, ValueError):
            # Try the backup before giving up
            try:
                with open(BACKUP_PATH, "r") as f:
                    data = json.load(f)
                    if isinstance(data, list) and len(data) > 0:
                        return data
            except (FileNotFoundError, json.JSONDecodeError, ValueError):
                pass
            # Last resort: hardcoded bank (spec 5.2, "Bank size < 500")
            return list(HARDCODED_FALLBACK_BANK)

    def save(self):
        with self._lock:
            # Write backup of the previous good state before overwriting
            if os.path.exists(self._path):
                try:
                    shutil.copyfile(self._path, BACKUP_PATH)
                except OSError:
                    pass
            with open(self._path, "w") as f:
                json.dump(self._bank, f, indent=2)

    # ---------- read ----------

    def size(self) -> int:
        with self._lock:
            return len(self._bank)

    def status(self) -> dict:
        with self._lock:
            if not self._bank:
                return {"size": 0, "avg_uses": 0, "top_10": []}
            avg_uses = sum(q["uses"] for q in self._bank) / len(self._bank)
            top_10 = sorted(self._bank, key=lambda q: q["uses"], reverse=True)[:10]
            return {"size": len(self._bank), "avg_uses": round(avg_uses, 2), "top_10": top_10}

    # ---------- selection (spec 2.5) ----------

    def select_questions(self, blocklist: list, count: int = 7) -> list:
        """
        1. Filter bank, removing any id in blocklist.
        2. If filtered pool >= MIN_FILTERED_POOL: pick `count` randomly.
        3. Else: ignore blocklist, pick from full bank (fallback).
        Increments `uses` at selection time (handed-out, not match-finish),
        so a crashed match still ages the question out of rotation.
        Returns full question objects: [{id, text}, ...]
        """
        with self._lock:
            blockset = set(blocklist or [])
            filtered = [q for q in self._bank if q["id"] not in blockset]

            pool = filtered if len(filtered) >= MIN_FILTERED_POOL else self._bank

            if len(pool) == 0:
                # Absolute edge case: bank itself is empty
                pool = list(HARDCODED_FALLBACK_BANK)
                self._bank = pool

            k = min(count, len(pool))
            chosen = random.sample(pool, k)

            # increment uses immediately (at hand-out time)
            chosen_ids = {q["id"] for q in chosen}
            for q in self._bank:
                if q["id"] in chosen_ids:
                    q["uses"] += 1

            result = [{"id": q["id"], "text": q["text"]} for q in chosen]

        self.save()
        return result

    # ---------- Phase 2 hook (not active in MVP) ----------

    def bank_size_healthcheck(self):
        """
        Spec 5.2 Question Bank Failover:
          size < 900  -> generate 200 new (Phase 2, needs Groq)
          size < 500  -> fallback to hardcoded backup bank
        MVP only implements the < 500 hard fallback since generation
        isn't wired up yet; this is called by /bank_status for visibility.
        """
        size = self.size()
        if size < 500:
            return "critical: below 500, hardcoded fallback bank in use or recommended"
        if size < 900:
            return "warning: below 900, would trigger generation in Phase 2"
        return "healthy"
