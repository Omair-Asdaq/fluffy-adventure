"""
app.py
------
Creative Clash backend -- Phase 1 (MVP) scope.

Endpoints (spec 3.2):
  GET  /get_questions   -> {"questions": [{"id": 1, "text": "..."}]}
  POST /judge            -> {"scores": {"Q1": {"A": 8.2, ...}, ...}}
  GET  /bank_status       -> admin only, requires ADMIN_TOKEN

Run locally:
  uvicorn app:app --host 0.0.0.0 --port 8000

Deploy: see README.md for the DigitalOcean droplet steps.
"""

import os
from typing import List, Optional

from fastapi import FastAPI, HTTPException, Header
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from question_bank import QuestionBank
from content_filter import sanitize_answer
import judge as judge_module

app = FastAPI(title="Creative Clash Backend", version="0.1.0-mvp")

# Roblox's HTTPService doesn't send browser-style CORS preflight, but this
# keeps local testing (curl/Postman/a web dashboard) painless.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)

bank = QuestionBank()

ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")


# ---------- schemas ----------

class GetQuestionsRequest(BaseModel):
    blocklist: List[int] = Field(default_factory=list)
    count: int = 3  # Standard mode = 3 rounds (MVP default); Rapid-Fire will pass 7 in Phase 3


class PlayerAnswers(BaseModel):
    player: str
    answers: List[str]


class JudgeRequest(BaseModel):
    mode: str = "standard"
    slot: Optional[str] = None
    questions: List[str]
    answers: List[PlayerAnswers]


# ---------- endpoints ----------

@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/get_questions")
def get_questions(req: GetQuestionsRequest):
    if req.count < 1 or req.count > 20:
        raise HTTPException(400, "count must be between 1 and 20")
    questions = bank.select_questions(req.blocklist, count=req.count)
    if not questions:
        raise HTTPException(503, "question bank unavailable")
    return {"questions": questions}


@app.post("/judge")
def judge(req: JudgeRequest):
    if not req.questions:
        raise HTTPException(400, "questions list is empty")
    if not req.answers:
        raise HTTPException(400, "answers list is empty")

    num_questions = len(req.questions)
    for pa in req.answers:
        if len(pa.answers) != num_questions:
            raise HTTPException(
                400,
                f"player {pa.player} submitted {len(pa.answers)} answers, "
                f"expected {num_questions}",
            )

    scores = {}

    for q_idx, question_text in enumerate(req.questions):
        q_key = f"Q{q_idx + 1}"

        # Sanitize every player's answer to this question first.
        # Flagged/profane answers are scored 0.0 and NEVER sent to the model
        # (hard guarantee -- spec 3.3 #3).
        clean_players = {}
        forced_zero = {}
        for pa in req.answers:
            raw_answer = pa.answers[q_idx]
            sanitized = sanitize_answer(raw_answer)
            if sanitized["flagged"] or not raw_answer or not raw_answer.strip():
                forced_zero[pa.player] = 0.0
            else:
                clean_players[pa.player] = sanitized["text"]

        question_scores = {}
        if clean_players:
            question_scores = judge_module.score_question(question_text, clean_players)

        question_scores.update(forced_zero)
        scores[q_key] = question_scores

    return {"scores": scores}


@app.get("/bank_status")
def bank_status(x_admin_token: str = Header(default="")):
    if not ADMIN_TOKEN or x_admin_token != ADMIN_TOKEN:
        raise HTTPException(403, "forbidden")
    status = bank.status()
    status["health"] = bank.bank_size_healthcheck()
    return status
