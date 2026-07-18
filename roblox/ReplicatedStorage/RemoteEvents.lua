--[[
	RemoteEvents.lua
	-----------------
	Place this ModuleScript directly in ReplicatedStorage (so both server
	and client can `require(ReplicatedStorage.RemoteEvents)`). It creates
	(or fetches) all RemoteEvents used by Creative Clash under a child
	folder, so Explorer stays tidy, while the require path stays simple.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER_NAME = "CreativeClashRemotes"

local function getOrCreateFolder()
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
	end
	return folder
end

local function getOrCreateRemoteEvent(folder, name)
	local remote = folder:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	return remote
end

local folder = getOrCreateFolder()

local RemoteEvents = {
	-- Client -> Server
	JoinQueue = getOrCreateRemoteEvent(folder, "JoinQueue"),         -- (mode: string)
	LeaveQueue = getOrCreateRemoteEvent(folder, "LeaveQueue"),       -- (mode: string)
	SubmitAnswer = getOrCreateRemoteEvent(folder, "SubmitAnswer"),   -- (roundIndex: number, text: string)

	-- Server -> Client
	QueueUpdate = getOrCreateRemoteEvent(folder, "QueueUpdate"),                     -- ({mode, queueSize, fullRoster})
	RoundStart = getOrCreateRemoteEvent(folder, "RoundStart"),                       -- ({roundIndex, totalRounds, questionText, timeSeconds, charLimit})
	RoundEnd = getOrCreateRemoteEvent(folder, "RoundEnd"),                           -- ({roundIndex})
	BackupScoringActive = getOrCreateRemoteEvent(folder, "BackupScoringActive"),     -- ()
	MatchResults = getOrCreateRemoteEvent(folder, "MatchResults"),                   -- ({placements = {{name, points, rawScore, wins}, ...}})
}

return RemoteEvents
