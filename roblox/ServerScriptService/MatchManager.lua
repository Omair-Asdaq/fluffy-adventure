--[[
	MatchManager.lua
	------------------
	Phase 1 (MVP) scope: runs a full Standard-mode match end to end.
	8 players, 3 rounds, 60s/round, 120 char limit, per-round timer.

	Flow (spec 3.4):
	  1. Fetch histories for all players -> merge into Blocklist
	  2. Call BackendAPI.GetQuestions(Blocklist)
	     - on failure: fall back to LOCAL_BACKUP_QUESTIONS (spec 5.1 step 5)
	  3. Questions are locked into local match state immediately -- an
	     hourly rotation mid-match can never change a question out from
	     under a live match (nothing here re-queries the bank per round).
	  4. Run each round: display question, timer, collect answers
	     (length-capped to WORD_LIMIT, filtered via TextService)
	  5. Call BackendAPI.Judge with the full batch of questions/answers
	     - on failure: local heuristic fallback (mirrors judge.py exactly)
	  6. Compute points per question, tie-breaker hierarchy, award Wins
	  7. Save each player's new question IDs to their history
]]

local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BackendAPI = require(script.Parent.BackendAPI)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))

local MatchManager = {}

-- ===== Standard mode config (spec 2.1) =====
local ROUNDS = 3
local ROUND_TIME_SECONDS = 60
local CHAR_LIMIT = 120

-- Wins payout (spec 2.8, Standard row)
local WINS_BY_PLACEMENT = { [1] = 3, [2] = 1, [3] = 1, [4] = 0 }
-- Placements 5-8 (only relevant for short-handed matches < 8) get 0.
local function winsForPlacement(placement)
	return WINS_BY_PLACEMENT[placement] or 0
end

-- Used only if the backend is completely unreachable (spec 5.1 step 5)
local LOCAL_BACKUP_QUESTIONS = {
	{ id = 9001, text = "What would you name a new planet?" },
	{ id = 9002, text = "Invent a new holiday and describe how it's celebrated." },
	{ id = 9003, text = "If you could have any superpower for one day, what would it be?" },
	{ id = 9004, text = "Write a haiku about your favorite food." },
	{ id = 9005, text = "What would you put in a time capsule for aliens to find?" },
}

-- ===================================================================
-- Local heuristic fallback -- mirrors backend/judge.py:heuristic_fallback_score
-- exactly (length, lexical uniqueness, non-emptiness). Used only when
-- BackendAPI.Judge() itself fails to reach the server at all.
-- ===================================================================

local function wordSet(text)
	local set = {}
	for word in string.gmatch(string.lower(text or ""), "[%a']+") do
		set[word] = true
	end
	return set
end

local function setSize(set)
	local n = 0
	for _ in pairs(set) do
		n += 1
	end
	return n
end

local function heuristicFallbackScore(playersAnswers)
	-- playersAnswers: { [playerKey] = answerText }
	local wordSets = {}
	for key, text in pairs(playersAnswers) do
		wordSets[key] = wordSet(text)
	end

	local scores = {}
	for key, text in pairs(playersAnswers) do
		local trimmed = text and text:gsub("^%s+", ""):gsub("%s+$", "") or ""
		if trimmed == "" then
			scores[key] = 0.0
		else
			local lengthScore = math.min(#trimmed / 80.0, 1.0) * 4.0

			local othersWords = {}
			for otherKey, ws in pairs(wordSets) do
				if otherKey ~= key then
					for w in pairs(ws) do
						othersWords[w] = true
					end
				end
			end

			local myWords = wordSets[key]
			local uniqueCount = 0
			local myCount = 0
			for w in pairs(myWords) do
				myCount += 1
				if not othersWords[w] then
					uniqueCount += 1
				end
			end
			local uniquenessRatio = (myCount > 0) and (uniqueCount / myCount) or 0
			local uniquenessScore = uniquenessRatio * 4.0

			local nonEmptyScore = 2.0

			local total = lengthScore + uniquenessScore + nonEmptyScore
			scores[key] = math.min(math.floor(total * 10 + 0.5) / 10, 10.0)
		end
	end
	return scores
end

-- ===================================================================
-- Scoring: per-question points + tie-breaker hierarchy (spec 2.2)
-- ===================================================================

local function computeQuestionPoints(scoresForQuestion)
	-- scoresForQuestion: { [playerKey] = numericScore }
	local sorted = {}
	for key, score in pairs(scoresForQuestion) do
		table.insert(sorted, { key = key, score = score })
	end
	table.sort(sorted, function(a, b) return a.score > b.score end)

	local points = {}
	for _, entry in ipairs(sorted) do
		points[entry.key] = 0
	end

	if #sorted == 0 then
		return points
	end

	if #sorted >= 2 and (sorted[1].score - sorted[2].score) <= 0.3 then
		points[sorted[1].key] = 0.5
		points[sorted[2].key] = 0.5
	else
		points[sorted[1].key] = 1
	end

	return points
end

--- Ranks players using the full tie-breaker hierarchy (spec 2.2):
-- 1) total points desc, 2) total raw score desc, 3) total time ms asc, 4) coin flip
local function rankPlayers(totals)
	-- totals: { [playerKey] = { points=n, rawScore=n, timeMs=n } }
	local ranked = {}
	for key, t in pairs(totals) do
		table.insert(ranked, { key = key, points = t.points, rawScore = t.rawScore, timeMs = t.timeMs })
	end

	table.sort(ranked, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		if a.rawScore ~= b.rawScore then
			return a.rawScore > b.rawScore
		end
		if a.timeMs ~= b.timeMs then
			return a.timeMs < b.timeMs
		end
		-- Edge case: fully tied. Deterministic-but-unpredictable coin flip.
		return math.random() < 0.5
	end)

	return ranked
end

-- ===================================================================
-- Match flow
-- ===================================================================

function MatchManager.StartMatch(mode, roster)
	if mode ~= "standard" then
		warn("[MatchManager] Phase 1 only implements 'standard' mode, got:", mode)
		return
	end

	task.spawn(function()
		MatchManager._runStandardMatch(roster)
	end)
end

function MatchManager._runStandardMatch(roster)
	-- Assign short player keys (A, B, C, ...) for the judge payload
	local playerKeys = {}
	local keyToPlayer = {}
	local letters = "ABCDEFGH"
	for i, player in ipairs(roster) do
		local key = letters:sub(i, i)
		playerKeys[player] = key
		keyToPlayer[key] = player
	end

	-- 1. Fetch histories -> merge blocklist
	local blocklistSet = {}
	for _, player in ipairs(roster) do
		local history = PlayerDataService.GetHistory(player.UserId)
		for _, qid in ipairs(history) do
			blocklistSet[qid] = true
		end
	end
	local blocklist = {}
	for qid in pairs(blocklistSet) do
		table.insert(blocklist, qid)
	end

	-- 2 & 3. Fetch and lock questions for the whole match
	local ok, questions = BackendAPI.GetQuestions(blocklist, ROUNDS)
	if not ok or not questions or #questions < ROUNDS then
		warn("[MatchManager] Backend unreachable or insufficient questions, using local backup bank")
		questions = {}
		for i = 1, ROUNDS do
			table.insert(questions, LOCAL_BACKUP_QUESTIONS[((i - 1) % #LOCAL_BACKUP_QUESTIONS) + 1])
		end
	end

	-- 4. Run rounds, collect answers + completion time per player
	-- answersByPlayer[key] = { round1Text, round2Text, round3Text }
	-- timeMsByPlayer[key] = total ms across all rounds (ascending = faster = better)
	local answersByPlayer = {}
	local timeMsByPlayer = {}
	for _, key in pairs(playerKeys) do
		answersByPlayer[key] = {}
		timeMsByPlayer[key] = 0
	end

	for roundIndex = 1, ROUNDS do
		local question = questions[roundIndex]
		MatchManager._broadcastRoundStart(roster, roundIndex, ROUNDS, question.text, ROUND_TIME_SECONDS, CHAR_LIMIT)

		local roundStart = os.clock()
		local roundAnswers, roundTimes = MatchManager._collectRoundAnswers(roster, ROUND_TIME_SECONDS, CHAR_LIMIT)
		local _ = roundStart

		for _, player in ipairs(roster) do
			local key = playerKeys[player]
			local rawText = roundAnswers[player] or ""

			-- Client-side filter is expected to have already run
			-- (TextService:FilterStringAsync per spec 3.3 #1); this is a
			-- defensive second pass in case a client is modified/exploited.
			local filtered = rawText
			local filterOk, result = pcall(function()
				local filterResult = TextService:FilterStringAsync(rawText, player.UserId)
				return filterResult:GetNonChatStringForBroadcastAsync()
			end)
			if filterOk and result then
				filtered = result
			end

			table.insert(answersByPlayer[key], string.sub(filtered, 1, CHAR_LIMIT))
			timeMsByPlayer[key] += (roundTimes[player] or (ROUND_TIME_SECONDS * 1000))
		end
	end

	-- 5. Judge the full batch
	local questionTexts = {}
	for _, q in ipairs(questions) do
		table.insert(questionTexts, q.text)
	end

	local judgeOk, scoresByQuestion = BackendAPI.Judge("standard", questionTexts, answersByPlayer, nil)

	if not judgeOk or not scoresByQuestion then
		warn("[MatchManager] Backend judging unreachable, using LOCAL heuristic fallback")
		scoresByQuestion = {}
		for roundIndex = 1, ROUNDS do
			local qKey = "Q" .. roundIndex
			local playersAnswers = {}
			for key, answers in pairs(answersByPlayer) do
				playersAnswers[key] = answers[roundIndex]
			end
			scoresByQuestion[qKey] = heuristicFallbackScore(playersAnswers)
		end
		MatchManager._broadcastBackupScoringActive(roster)
	end

	-- 6. Compute points + totals, rank, award Wins
	local totals = {}
	for _, key in pairs(playerKeys) do
		totals[key] = { points = 0, rawScore = 0, timeMs = timeMsByPlayer[key] }
	end

	for roundIndex = 1, ROUNDS do
		local qKey = "Q" .. roundIndex
		local scoresForQuestion = scoresByQuestion[qKey] or {}
		local pointsForQuestion = computeQuestionPoints(scoresForQuestion)

		for key, score in pairs(scoresForQuestion) do
			if totals[key] then
				totals[key].rawScore += score
				totals[key].points += (pointsForQuestion[key] or 0)
			end
		end
	end

	local ranked = rankPlayers(totals)

	for placement, entry in ipairs(ranked) do
		local player = keyToPlayer[entry.key]
		local wins = winsForPlacement(placement)
		if player then
			PlayerDataService.AddWins(player.UserId, wins)
		end
	end

	-- 7. Save history (all participants, regardless of placement)
	local questionIds = {}
	for _, q in ipairs(questions) do
		table.insert(questionIds, q.id)
	end
	for _, player in ipairs(roster) do
		PlayerDataService.SaveHistory(player.UserId, questionIds)
	end

	MatchManager._broadcastResults(roster, ranked, keyToPlayer, playerKeys)
end

-- ===================================================================
-- Client comms stubs -- wire these to your actual RemoteEvents / GUI.
-- Kept separate so UI iteration doesn't touch match logic above.
-- ===================================================================

function MatchManager._broadcastRoundStart(roster, roundIndex, totalRounds, questionText, timeSeconds, charLimit)
	for _, player in ipairs(roster) do
		RemoteEvents.RoundStart:FireClient(player, {
			roundIndex = roundIndex,
			totalRounds = totalRounds,
			questionText = questionText,
			timeSeconds = timeSeconds,
			charLimit = charLimit,
		})
	end
end

function MatchManager._broadcastBackupScoringActive(roster)
	for _, player in ipairs(roster) do
		RemoteEvents.BackupScoringActive:FireClient(player)
	end
end

function MatchManager._broadcastResults(roster, ranked, keyToPlayer, playerKeys)
	local placements = {}
	for placement, entry in ipairs(ranked) do
		local player = keyToPlayer[entry.key]
		table.insert(placements, {
			name = player and player.Name or "?",
			userId = player and player.UserId or 0,
			placement = placement,
			points = entry.points,
			rawScore = entry.rawScore,
			wins = winsForPlacement(placement),
		})
	end
	for _, player in ipairs(roster) do
		RemoteEvents.MatchResults:FireClient(player, { placements = placements })
	end
end

--- Collects answers from all players for one round via the SubmitAnswer
-- RemoteEvent. Ends early only once every roster player has submitted;
-- otherwise runs the full timer. Late/non-submitters get "".
-- Returns (answersByPlayerInstance, timeMsByPlayerInstance)
function MatchManager._collectRoundAnswers(roster, timeSeconds, charLimit)
	local answers, times = {}, {}
	local submitted = {}
	local rosterSet = {}
	for _, player in ipairs(roster) do
		rosterSet[player] = true
	end

	local roundStartClock = os.clock()

	local connection
	connection = RemoteEvents.SubmitAnswer.OnServerEvent:Connect(function(player, text)
		if not rosterSet[player] or submitted[player] then
			return -- not in this match, or already submitted this round
		end
		if type(text) ~= "string" then
			return
		end
		submitted[player] = true
		answers[player] = string.sub(text, 1, charLimit)
		times[player] = math.floor((os.clock() - roundStartClock) * 1000)
	end)

	local deadline = roundStartClock + timeSeconds
	while os.clock() < deadline do
		local allSubmitted = true
		for _, player in ipairs(roster) do
			if not submitted[player] then
				allSubmitted = false
				break
			end
		end
		if allSubmitted then
			break
		end
		task.wait(0.1)
	end

	connection:Disconnect()

	for _, player in ipairs(roster) do
		if not submitted[player] then
			answers[player] = ""
			times[player] = timeSeconds * 1000 -- didn't finish in time
		end
	end

	return answers, times
end

return MatchManager
