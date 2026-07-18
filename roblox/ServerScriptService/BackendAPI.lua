--[[
	BackendAPI.lua
	--------------
	Thin wrapper around HttpService for talking to the external backend
	(DigitalOcean droplet running app.py). Every call has a timeout-ish
	guard via pcall + retry, and every caller MUST handle a nil/false
	return by falling back per the failover hierarchy (spec 5.1).

	Set BACKEND_URL to your deployed backend, e.g.
	"https://creative-clash-api.yourdomain.com"
]]

local HttpService = game:GetService("HttpService")

local BackendAPI = {}

-- TODO: move to a config module / Roblox Studio "Server" secret before shipping
local BACKEND_URL = "https://YOUR-BACKEND-DOMAIN-HERE"

local MAX_RETRIES = 2
local RETRY_WAIT_SECONDS = 0.5

--- Generic POST with retry. Returns (success: bool, decodedBody: table|nil)
local function postJson(path, bodyTable)
	local url = BACKEND_URL .. path
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, bodyTable)
	if not ok then
		warn("[BackendAPI] Failed to encode request body for", path)
		return false, nil
	end

	for attempt = 1, MAX_RETRIES do
		local success, response = pcall(function()
			return HttpService:PostAsync(url, encoded, Enum.HttpContentType.ApplicationJson)
		end)

		if success then
			local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, response)
			if decodeOk then
				return true, decoded
			else
				warn("[BackendAPI] Failed to decode response from", path)
			end
		else
			warn(string.format("[BackendAPI] Request to %s failed (attempt %d/%d): %s", path, attempt, MAX_RETRIES, tostring(response)))
		end

		if attempt < MAX_RETRIES then
			task.wait(RETRY_WAIT_SECONDS)
		end
	end

	return false, nil
end

--- Fetch questions for a match.
-- blocklist: array of question IDs to avoid
-- count: how many questions to fetch (Standard mode = 3)
-- Returns (success: bool, questions: {{id=number, text=string}}|nil)
function BackendAPI.GetQuestions(blocklist, count)
	local ok, decoded = postJson("/get_questions", {
		blocklist = blocklist or {},
		count = count or 3,
	})
	if ok and decoded and decoded.questions then
		return true, decoded.questions
	end
	return false, nil
end

--- Submit answers for judging.
-- questions: array of question text strings, in round order
-- answersByPlayer: { [playerKey] = { answer1, answer2, ... }, ... }
--   playerKey is a short label like "A", "B", "C", "D" (assigned by MatchManager)
-- Returns (success: bool, scores: { ["Q1"] = { A = 8.2, B = 7.5, ... }, ... }|nil)
function BackendAPI.Judge(mode, questions, answersByPlayer, slot)
	local answersPayload = {}
	for playerKey, answers in pairs(answersByPlayer) do
		table.insert(answersPayload, { player = playerKey, answers = answers })
	end

	local ok, decoded = postJson("/judge", {
		mode = mode,
		slot = slot,
		questions = questions,
		answers = answersPayload,
	})
	if ok and decoded and decoded.scores then
		return true, decoded.scores
	end
	return false, nil
end

return BackendAPI
