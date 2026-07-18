--[[
	Init.server.lua
	-----------------
	Entry point. Wires the client-facing RemoteEvents to MatchmakingService.
	Place directly in ServerScriptService alongside the other modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))
local MatchmakingService = require(script.Parent.MatchmakingService)

local VALID_MODES = { standard = true } -- Phase 1 scope; add casual/elimination/rapidfire later

RemoteEvents.JoinQueue.OnServerEvent:Connect(function(player, mode)
	if type(mode) ~= "string" or not VALID_MODES[mode] then
		warn("[Init] Rejected JoinQueue with invalid mode from", player.Name, mode)
		return
	end
	MatchmakingService.JoinQueue(player, mode)
end)

RemoteEvents.LeaveQueue.OnServerEvent:Connect(function(player, mode)
	if type(mode) ~= "string" then
		return
	end
	MatchmakingService.LeaveQueue(player, mode)
end)

print("[Init] Creative Clash server systems online (Phase 1 - Standard mode)")
