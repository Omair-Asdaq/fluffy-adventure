--[[
	MatchmakingService.lua
	------------------------
	Phase 1 (MVP) scope: Standard mode only, 8-player queue.
	Casual / Rapid-Fire / Elimination queues are stubbed for Phase 2/3
	but the queue mechanics below are written generically so adding
	them later is just adding another entry to MODE_CONFIG.

	Matches fire immediately once a queue hits full roster (8).
	Short-handed fallback: if partially full after WAIT_THRESHOLD_SECONDS,
	start with a reduced roster (rounds/time stay fixed, roster shrinks).
	No bots are ever injected (spec 2.1 - halal-transparency requirement).
]]

local Players = game:GetService("Players")

local MatchManager = require(script.Parent.MatchManager)

local MatchmakingService = {}

local MODE_CONFIG = {
	standard = {
		fullRoster = 8,
		minRoster = 2, -- below this, short-handed start doesn't make sense
		waitThresholdSeconds = 45,
		requiresFullRoster = false,
	},
	-- casual = { ... },      -- Phase 2
	-- elimination = {        -- Phase 2 (requires full 8, no short-handed start)
	--     fullRoster = 8,
	--     minRoster = 8,
	--     waitThresholdSeconds = 90,
	--     requiresFullRoster = true,
	-- },
	-- rapidfire = { ... },   -- Phase 3 (team-based queue)
}

-- queues[mode] = { {player=Player, joinedAt=os.clock()}, ... }
local queues = {}
for mode in pairs(MODE_CONFIG) do
	queues[mode] = {}
end

local function removeFromQueue(mode, player)
	local queue = queues[mode]
	for i = #queue, 1, -1 do
		if queue[i].player == player then
			table.remove(queue, i)
		end
	end
end

local function popRoster(mode, count)
	local queue = queues[mode]
	local roster = {}
	for i = 1, math.min(count, #queue) do
		table.insert(roster, queue[i].player)
	end
	for i = 1, #roster do
		table.remove(queue, 1)
	end
	return roster
end

function MatchmakingService.JoinQueue(player, mode)
	local config = MODE_CONFIG[mode]
	if not config then
		warn("[MatchmakingService] Unknown or unimplemented mode:", mode)
		return false
	end

	removeFromQueue(mode, player) -- avoid duplicate entries
	table.insert(queues[mode], { player = player, joinedAt = os.clock() })
	return true
end

function MatchmakingService.LeaveQueue(player, mode)
	if queues[mode] then
		removeFromQueue(mode, player)
	end
end

--- Call this on a heartbeat/loop (see bottom of file) to check every
-- queue for a fireable match.
local function tickMode(mode, config)
	local queue = queues[mode]
	if #queue == 0 then
		return
	end

	if #queue >= config.fullRoster then
		local roster = popRoster(mode, config.fullRoster)
		MatchManager.StartMatch(mode, roster)
		return
	end

	if config.requiresFullRoster then
		-- Elimination-style: no short-handed start, just wait.
		-- (UI should show a "waiting for players" state client-side.)
		return
	end

	local oldestJoinTime = queue[1].joinedAt
	local waited = os.clock() - oldestJoinTime
	if waited >= config.waitThresholdSeconds and #queue >= config.minRoster then
		local roster = popRoster(mode, #queue)
		MatchManager.StartMatch(mode, roster)
	end
end

function MatchmakingService.Tick()
	for mode, config in pairs(MODE_CONFIG) do
		tickMode(mode, config)
	end
end

Players.PlayerRemoving:Connect(function(player)
	for mode in pairs(queues) do
		removeFromQueue(mode, player)
	end
end)

-- Simple heartbeat loop. In production this could be tied to a
-- lighter-weight scheduler, but a 1s tick is plenty responsive for
-- lobby-scale queue sizes.
task.spawn(function()
	while true do
		task.wait(1)
		MatchmakingService.Tick()
	end
end)

return MatchmakingService
