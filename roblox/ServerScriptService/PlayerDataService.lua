--[[
	PlayerDataService.lua
	----------------------
	Stores each player's answered-question history (last 500 IDs) and their
	Wins currency in Roblox DataStore. Implements the request-budget check
	and retry logic from spec 2.6 / 3.4, plus the failover table in 5.3:
		- read fails            -> treat as empty history (no blocklist)
		- write fails (3x)      -> log error, continue (match still counted)
		- budget exceeded       -> skip write for that cycle
]]

local DataStoreService = game:GetService("DataStoreService")

local playerHistoryStore = DataStoreService:GetDataStore("PlayerHistory")
local playerWinsStore = DataStoreService:GetDataStore("PlayerWins")

local HISTORY_LIMIT = 500
local MAX_RETRIES = 3
local RETRY_WAIT_SECONDS = 0.5

local PlayerDataService = {}

local function hasWriteBudget()
	local budget = DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementAsync)
	return budget ~= Enum.DataStoreRequestBudgetStatus.Exceeded
end

local function hasWriteBudgetFor(requestType)
	local budget = DataStoreService:GetRequestBudgetForRequestType(requestType)
	return budget ~= Enum.DataStoreRequestBudgetStatus.Exceeded
end

--- Returns the player's answered-question history, or {} if unavailable.
-- Read failures are treated as an empty history (spec 5.3): worst case is
-- a player sees a repeat question, never a hard failure of matchmaking.
function PlayerDataService.GetHistory(userId)
	local key = "Answered_" .. tostring(userId)
	local ok, history = pcall(function()
		return playerHistoryStore:GetAsync(key)
	end)
	if ok and type(history) == "table" then
		return history
	end
	if not ok then
		warn("[PlayerDataService] GetHistory failed for", userId, "- treating as empty")
	end
	return {}
end

--- Appends newQuestionIds to the player's history and trims to HISTORY_LIMIT.
-- Retries up to 3 times; on total failure, logs and returns false but the
-- caller should NOT block match results on this (spec 5.3).
function PlayerDataService.SaveHistory(userId, newQuestionIds)
	if not hasWriteBudgetFor(Enum.DataStoreRequestType.SetIncrementAsync) then
		warn("[PlayerDataService] DataStore budget exceeded, skipping history write for", userId)
		return false
	end

	local key = "Answered_" .. tostring(userId)

	local readOk, history = pcall(function()
		return playerHistoryStore:GetAsync(key)
	end)
	if not readOk or type(history) ~= "table" then
		history = {}
	end

	for _, id in ipairs(newQuestionIds) do
		table.insert(history, id)
	end
	while #history > HISTORY_LIMIT do
		table.remove(history, 1)
	end

	for attempt = 1, MAX_RETRIES do
		local writeOk = pcall(function()
			playerHistoryStore:SetAsync(key, history)
		end)
		if writeOk then
			return true
		end
		warn(string.format("[PlayerDataService] SaveHistory attempt %d/%d failed for %s", attempt, MAX_RETRIES, tostring(userId)))
		if attempt < MAX_RETRIES then
			task.wait(RETRY_WAIT_SECONDS)
		end
	end

	warn("[PlayerDataService] SaveHistory permanently failed for", userId, "- match result still counted")
	return false
end

--- Awards Wins to a player. Same budget/retry pattern as SaveHistory.
function PlayerDataService.AddWins(userId, amount)
	if amount == 0 then
		return true
	end
	if not hasWriteBudgetFor(Enum.DataStoreRequestType.UpdateAsync) then
		warn("[PlayerDataService] DataStore budget exceeded, skipping Wins write for", userId)
		return false
	end

	local key = "Wins_" .. tostring(userId)

	for attempt = 1, MAX_RETRIES do
		local writeOk, newValue = pcall(function()
			return playerWinsStore:UpdateAsync(key, function(oldValue)
				return (oldValue or 0) + amount
			end)
		end)
		if writeOk then
			return true, newValue
		end
		warn(string.format("[PlayerDataService] AddWins attempt %d/%d failed for %s", attempt, MAX_RETRIES, tostring(userId)))
		if attempt < MAX_RETRIES then
			task.wait(RETRY_WAIT_SECONDS)
		end
	end

	warn("[PlayerDataService] AddWins permanently failed for", userId)
	return false
end

function PlayerDataService.GetWins(userId)
	local key = "Wins_" .. tostring(userId)
	local ok, value = pcall(function()
		return playerWinsStore:GetAsync(key)
	end)
	if ok and type(value) == "number" then
		return value
	end
	return 0
end

return PlayerDataService
