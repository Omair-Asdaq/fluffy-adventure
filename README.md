# Creative Clash — Phase 1 (MVP)

Scope, per the roadmap: **Standard mode only** (8 players, 3 rounds, 60s/round,
120 char limit). Backend with a static question bank (no hourly rotation yet —
that's Phase 2). Gemini Flash judge + heuristic fallback. Basic Roblox UI
(lobby, round, results). DataStore for player history.

## Repo layout

```
backend/
  app.py             FastAPI server: /get_questions, /judge, /bank_status
  question_bank.py   Bank loading, blocklist filtering, question selection
  judge.py           Gemini -> Groq 70B -> Groq 8B -> heuristic fallback
  content_filter.py  Prompt-injection / profanity pre-filter (hard 0.0 score)
  bank.json           50-question seed bank
  requirements.txt
  .env.example

roblox/
  ReplicatedStorage/
    RemoteEvents.lua        Shared RemoteEvent definitions
  ServerScriptService/
    Init.server.lua         Bootstraps everything, wires remotes
    MatchmakingService.lua  Standard-mode 8p queue, short-handed fallback
    MatchManager.lua        Full match flow: questions -> rounds -> judging -> wins
    PlayerDataService.lua   DataStore history + Wins, budget check + retries
    BackendAPI.lua          HTTP client for the external backend
  StarterGui/
    ClientMain.client.lua   Lobby button, round screen, results screen
```

## 1. Run the backend locally

```bash
cd backend
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # fill in GEMINI_API_KEY / GROQ_API_KEY / ADMIN_TOKEN
uvicorn app:app --reload --port 8000
```

Test it:

```bash
curl -X POST localhost:8000/get_questions -H "Content-Type: application/json" \
  -d '{"blocklist": [], "count": 3}'

curl -X POST localhost:8000/judge -H "Content-Type: application/json" -d '{
  "mode": "standard",
  "questions": ["What would you name a new planet?"],
  "answers": [
    {"player": "A", "answers": ["Zorblax, a planet of glowing purple oceans"]},
    {"player": "B", "answers": ["idk"]}
  ]
}'
```

**No API keys configured?** That's fine for local dev — every judge call
automatically falls through Gemini → Groq 70B → Groq 8B → the heuristic
scorer, so `/judge` still returns real scores without any provider set up.

## 2. Deploy the backend (DigitalOcean, per spec 4.2)

1. Spin up the smallest droplet (2GB/1vCPU covers Phase 1 load easily).
2. `git clone` this repo onto it, `pip install -r requirements.txt`.
3. Set `GEMINI_API_KEY`, `GROQ_API_KEY`, `ADMIN_TOKEN` as environment
   variables (systemd unit or a `.env` + `python-dotenv`, your call).
4. Run behind `uvicorn app:app --host 0.0.0.0 --port 8000` + a process
   manager (systemd/pm2/supervisor) so it restarts on crash.
5. Put nginx (or Caddy, for free auto-HTTPS) in front of it — Roblox's
   `HttpService` requires **https**, plain `http://` will not work.

## 3. Wire up Roblox

1. In Studio: `ReplicatedStorage/RemoteEvents.lua` → ModuleScript named
   `RemoteEvents`, parented directly under `ReplicatedStorage`.
2. `ServerScriptService/*.lua` → four ModuleScripts (`BackendAPI`,
   `PlayerDataService`, `MatchmakingService`, `MatchManager`) plus one
   `Script` (`Init.server.lua`), all siblings under `ServerScriptService`.
3. `StarterGui/ClientMain.client.lua` → a `LocalScript` under `StarterGui`.
4. In `BackendAPI.lua`, set `BACKEND_URL` to your deployed backend's HTTPS
   URL.
5. In Studio settings, enable **Allow HTTP Requests** (Game Settings →
   Security) or `HttpService:SetAsync` calls will silently no-op.
6. Playtest with **8 simulated players** (Studio's built-in multi-client
   test, or publish to a private server and use alts) — the queue only
   fires a Standard match once it hits 8, or after the 45s short-handed
   timeout with 2+ players.

## What's stubbed vs. real in this pass

- **Real**: matchmaking queue + short-handed fallback, full match flow,
  question blocklist/history, AI judge with full failover chain including
  a local (client-side, no-backend-needed) heuristic scorer, scoring +
  tie-breaker hierarchy exactly per spec, Wins payout, DataStore writes
  with budget checks + retries, content filtering (prompt injection +
  profanity) before anything reaches the model.
- **Stubbed for later phases**: hourly bank rotation / Groq question
  generation (Phase 2), Casual/Elimination/Rapid-Fire modes and their
  queues (Phase 2/3), achievements, cosmetics/lootbox UI (Phase 3/4),
  visual polish and the mobile glide-typing tutorial pop-up (Phase 4).

## Known gaps to close before this is genuinely shippable

- `MatchmakingService`'s 1-second polling loop is fine at Phase 1 scale;
  revisit if queue sizes grow.
- `BackendAPI.lua` has no request signing/auth — add an API key header
  once this is public, so randoms can't hit your `/judge` endpoint
  directly and burn your AI quota.
- The Lua heuristic fallback and the Python one are hand-kept in sync;
  if you change the scoring formula, update both `judge.py` and
  `MatchManager.lua`.
