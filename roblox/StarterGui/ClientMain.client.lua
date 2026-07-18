--[[
	ClientMain.client.lua
	-----------------------
	Minimal functional UI for Phase 1 (MVP): a "Play Standard" button,
	a round screen (question + countdown + text input with live char
	count), and a results screen. This is intentionally plain -- visual
	polish is Phase 4 scope. Every screen is built fresh here so the
	game is playable end-to-end without any pre-built GUI in Studio.

	Place as a LocalScript in StarterGui (or under StarterPlayerScripts).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local RemoteEvents = require(ReplicatedStorage:WaitForChild("RemoteEvents"))

-- ===== GUI scaffolding =====

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CreativeClashUI"
screenGui.ResetOnSpawn = false
screenGui.Parent = player:WaitForChild("PlayerGui")

-- ---- Lobby frame ----
local lobbyFrame = Instance.new("Frame")
lobbyFrame.Name = "Lobby"
lobbyFrame.Size = UDim2.new(0, 260, 0, 120)
lobbyFrame.Position = UDim2.new(0.5, -130, 0.5, -60)
lobbyFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
lobbyFrame.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundTransparency = 1
title.Text = "Creative Clash"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextScaled = true
title.Parent = lobbyFrame

local playButton = Instance.new("TextButton")
playButton.Size = UDim2.new(0.8, 0, 0, 40)
playButton.Position = UDim2.new(0.1, 0, 0, 40)
playButton.Text = "Play Standard (8p)"
playButton.BackgroundColor3 = Color3.fromRGB(70, 140, 220)
playButton.TextColor3 = Color3.fromRGB(255, 255, 255)
playButton.Parent = lobbyFrame

local queueStatusLabel = Instance.new("TextLabel")
queueStatusLabel.Size = UDim2.new(1, 0, 0, 20)
queueStatusLabel.Position = UDim2.new(0, 0, 0, 85)
queueStatusLabel.BackgroundTransparency = 1
queueStatusLabel.Text = ""
queueStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
queueStatusLabel.TextScaled = true
queueStatusLabel.Parent = lobbyFrame

local inQueue = false
playButton.MouseButton1Click:Connect(function()
	inQueue = not inQueue
	if inQueue then
		RemoteEvents.JoinQueue:FireServer("standard")
		playButton.Text = "Leave Queue"
		queueStatusLabel.Text = "Searching for players..."
	else
		RemoteEvents.LeaveQueue:FireServer("standard")
		playButton.Text = "Play Standard (8p)"
		queueStatusLabel.Text = ""
	end
end)

-- ---- Round frame ----
local roundFrame = Instance.new("Frame")
roundFrame.Name = "Round"
roundFrame.Size = UDim2.new(0, 480, 0, 220)
roundFrame.Position = UDim2.new(0.5, -240, 0.5, -110)
roundFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
roundFrame.Visible = false
roundFrame.Parent = screenGui

local roundLabel = Instance.new("TextLabel")
roundLabel.Size = UDim2.new(1, 0, 0, 24)
roundLabel.BackgroundTransparency = 1
roundLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
roundLabel.TextScaled = true
roundLabel.Parent = roundFrame

local timerLabel = Instance.new("TextLabel")
timerLabel.Size = UDim2.new(1, 0, 0, 24)
timerLabel.Position = UDim2.new(0, 0, 0, 24)
timerLabel.BackgroundTransparency = 1
timerLabel.TextColor3 = Color3.fromRGB(255, 210, 90)
timerLabel.TextScaled = true
timerLabel.Parent = roundFrame

local questionLabel = Instance.new("TextLabel")
questionLabel.Size = UDim2.new(1, -20, 0, 60)
questionLabel.Position = UDim2.new(0, 10, 0, 52)
questionLabel.BackgroundTransparency = 1
questionLabel.TextWrapped = true
questionLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
questionLabel.TextScaled = true
questionLabel.Parent = roundFrame

local answerBox = Instance.new("TextBox")
answerBox.Size = UDim2.new(1, -20, 0, 60)
answerBox.Position = UDim2.new(0, 10, 0, 120)
answerBox.ClearTextOnFocus = false
answerBox.TextWrapped = true
answerBox.PlaceholderText = "Type your answer..."
answerBox.Parent = roundFrame

local charCountLabel = Instance.new("TextLabel")
charCountLabel.Size = UDim2.new(1, 0, 0, 18)
charCountLabel.Position = UDim2.new(0, 0, 0, 182)
charCountLabel.BackgroundTransparency = 1
charCountLabel.TextColor3 = Color3.fromRGB(160, 160, 160)
charCountLabel.TextScaled = true
charCountLabel.Parent = roundFrame

local submitButton = Instance.new("TextButton")
submitButton.Size = UDim2.new(0.5, 0, 0, 24)
submitButton.Position = UDim2.new(0.25, 0, 0, 194)
submitButton.Text = "Submit"
submitButton.BackgroundColor3 = Color3.fromRGB(70, 180, 120)
submitButton.TextColor3 = Color3.fromRGB(255, 255, 255)
submitButton.Parent = roundFrame

local currentCharLimit = 120
local hasSubmittedThisRound = false

local function submitAnswer()
	if hasSubmittedThisRound then
		return
	end
	hasSubmittedThisRound = true
	RemoteEvents.SubmitAnswer:FireServer(string.sub(answerBox.Text, 1, currentCharLimit))
	submitButton.Text = "Submitted!"
	submitButton.BackgroundColor3 = Color3.fromRGB(90, 90, 90)
end

submitButton.MouseButton1Click:Connect(submitAnswer)

answerBox:GetPropertyChangedSignal("Text"):Connect(function()
	if #answerBox.Text > currentCharLimit then
		answerBox.Text = string.sub(answerBox.Text, 1, currentCharLimit)
	end
	charCountLabel.Text = string.format("%d / %d", #answerBox.Text, currentCharLimit)
end)

-- ---- Results frame ----
local resultsFrame = Instance.new("Frame")
resultsFrame.Name = "Results"
resultsFrame.Size = UDim2.new(0, 320, 0, 300)
resultsFrame.Position = UDim2.new(0.5, -160, 0.5, -150)
resultsFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
resultsFrame.Visible = false
resultsFrame.Parent = screenGui

local resultsList = Instance.new("UIListLayout")
resultsList.Parent = resultsFrame

local resultsTitle = Instance.new("TextLabel")
resultsTitle.Size = UDim2.new(1, 0, 0, 30)
resultsTitle.BackgroundTransparency = 1
resultsTitle.Text = "Results"
resultsTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
resultsTitle.TextScaled = true
resultsTitle.LayoutOrder = 0
resultsTitle.Parent = resultsFrame

local closeResultsButton = Instance.new("TextButton")
closeResultsButton.Size = UDim2.new(1, 0, 0, 30)
closeResultsButton.Text = "Back to Lobby"
closeResultsButton.LayoutOrder = 99
closeResultsButton.Parent = resultsFrame
closeResultsButton.MouseButton1Click:Connect(function()
	resultsFrame.Visible = false
	lobbyFrame.Visible = true
	inQueue = false
	playButton.Text = "Play Standard (8p)"
	queueStatusLabel.Text = ""
end)

-- ===== Remote handlers =====

RemoteEvents.RoundStart.OnClientEvent:Connect(function(data)
	lobbyFrame.Visible = false
	resultsFrame.Visible = false
	roundFrame.Visible = true

	hasSubmittedThisRound = false
	answerBox.Text = ""
	submitButton.Text = "Submit"
	submitButton.BackgroundColor3 = Color3.fromRGB(70, 180, 120)

	currentCharLimit = data.charLimit
	roundLabel.Text = string.format("Round %d / %d", data.roundIndex, data.totalRounds)
	questionLabel.Text = data.questionText
	charCountLabel.Text = string.format("0 / %d", currentCharLimit)

	-- Simple countdown; server is the source of truth for the actual deadline.
	task.spawn(function()
		local remaining = data.timeSeconds
		while remaining > 0 and roundFrame.Visible do
			timerLabel.Text = tostring(remaining) .. "s"
			task.wait(1)
			remaining -= 1
		end
		if roundFrame.Visible and not hasSubmittedThisRound then
			submitAnswer() -- auto-submit whatever's typed when time runs out
		end
	end)
end)

RemoteEvents.BackupScoringActive.OnClientEvent:Connect(function()
	local banner = roundFrame:FindFirstChild("BackupBanner")
	if not banner then
		banner = Instance.new("TextLabel")
		banner.Name = "BackupBanner"
		banner.Size = UDim2.new(1, 0, 0, 16)
		banner.Position = UDim2.new(0, 0, 1, -16)
		banner.BackgroundColor3 = Color3.fromRGB(120, 90, 20)
		banner.TextColor3 = Color3.fromRGB(255, 255, 255)
		banner.Text = "Backup Scoring Active"
		banner.TextScaled = true
		banner.Parent = roundFrame
	end
end)

RemoteEvents.MatchResults.OnClientEvent:Connect(function(data)
	roundFrame.Visible = false
	resultsFrame.Visible = true

	for _, child in ipairs(resultsFrame:GetChildren()) do
		if child:IsA("TextLabel") and child.Name:match("^PlacementRow") then
			child:Destroy()
		end
	end

	for _, entry in ipairs(data.placements) do
		local row = Instance.new("TextLabel")
		row.Name = "PlacementRow" .. entry.placement
		row.Size = UDim2.new(1, 0, 0, 26)
		row.BackgroundTransparency = 1
		row.LayoutOrder = entry.placement
		row.TextColor3 = Color3.fromRGB(230, 230, 230)
		row.TextScaled = true
		local youTag = (entry.userId == player.UserId) and "  <- you" or ""
		row.Text = string.format("#%d %s - %.1f pts (+%d Wins)%s", entry.placement, entry.name, entry.points, entry.wins, youTag)
		row.Parent = resultsFrame
	end
end)
