-- FuldStonks: Guild betting addon for World of Warcraft
-- Version: 0.1.0
-- Author: EraxterCodes

-- Create addon namespace
local ADDON_NAME, FuldStonks = ...

-- Initialize saved variables
FuldStonksDB = FuldStonksDB or {
    activeBets = {},      -- Active bets in the system
    myBets = {},          -- Bets I've placed
    betHistory = {}       -- Historical bets
}

-- Constants
local COLOR_GREEN = "|cFF00FF00"
local COLOR_RESET = "|r"
local COLOR_YELLOW = "|cFFFFFF00"
local COLOR_RED = "|cFFFF0000"

-- Addon state
FuldStonks.version = "0.1.0"
FuldStonks.frame = nil
FuldStonks.peers = {}           -- Track connected peers: [fullName] = { lastSeen = time, betCount = 0 }
FuldStonks.lastBroadcast = 0    -- Rate limiting for broadcasts
FuldStonks.syncRequested = false

-- Event frame for initialization
local eventFrame = CreateFrame("Frame")

-- Get player's full name (Name-Realm)
local playerName, playerRealm = UnitFullName("player")
local playerFullName = (playerRealm and playerRealm ~= "" and (playerName .. "-" .. playerRealm)) or playerName

-- Helper function for debug output
local function DebugPrint(msg)
    if FuldStonksDB.debug then
        print(COLOR_GREEN .. "FuldStonks [DEBUG]" .. COLOR_RESET .. " " .. tostring(msg))
    end
end

-- Addon initialization
local function Initialize()
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " addon loaded! Type /FuldStonks or /fs to open the UI.")
end

-- Create the main UI frame (placeholder)
local function CreateMainFrame()
    if FuldStonks.frame then
        return FuldStonks.frame
    end
    
    -- Create main frame
    local frame = CreateFrame("Frame", "FuldStonksMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(500, 400)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    
    -- Set title
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.title:SetPoint("TOP", frame.TitleBg, "TOP", 0, -3)
    frame.title:SetText("FuldStonks - Guild Betting")
    
    -- Create placeholder content
    local content = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    content:SetPoint("CENTER", frame, "CENTER", 0, 50)
    content:SetText("Welcome to FuldStonks!\n\n" ..
                   "This addon will allow you to create and participate\n" ..
                   "in guild betting pools for raids and events.\n\n" ..
                   "Betting logic coming soon!")
    content:SetJustifyH("CENTER")
    
    -- Create connected peers display
    frame.peersText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.peersText:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -35)
    frame.peersText:SetJustifyH("LEFT")
    frame.peersText:SetTextColor(0.8, 0.8, 0.8)
    
    -- Update function for peers display
    frame.UpdatePeers = function(self)
        local peerCount = 0
        for _ in pairs(FuldStonks.peers) do
            peerCount = peerCount + 1
        end
        
        if peerCount == 0 then
            self.peersText:SetText("Connected peers: None\n(Use /fs sync to request connection)")
        else
            local text = "Connected peers: " .. peerCount .. "\n"
            local count = 0
            for name, data in pairs(FuldStonks.peers) do
                if count < 5 then  -- Show max 5 peers
                    local timeSince = math.floor(GetTime() - data.lastSeen)
                    local baseName = name:gsub("%-.*", "")
                    text = text .. "  • " .. baseName .. " (" .. timeSince .. "s ago)\n"
                    count = count + 1
                end
            end
            if peerCount > 5 then
                text = text .. "  ... and " .. (peerCount - 5) .. " more"
            end
            self.peersText:SetText(text)
        end
    end
    
    -- Create version text
    local versionText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 10)
    versionText:SetText("Version " .. FuldStonks.version .. " • Synchronization Active")
    versionText:SetTextColor(0.7, 0.7, 0.7)
    
    -- Create close button handler
    frame.CloseButton:SetScript("OnClick", function()
        frame:Hide()
    end)
    
    -- Update peers display every 2 seconds when visible
    frame.updateTicker = C_Timer.NewTicker(2, function()
        if frame:IsShown() then
            frame:UpdatePeers()
        end
    end)
    
    -- Initial update
    frame:UpdatePeers()
    
    FuldStonks.frame = frame
    return frame
end

-- Toggle main frame visibility
local function ToggleMainFrame()
    local frame = CreateMainFrame()
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Slash command handler
local function SlashCommandHandler(msg)
    local command = strtrim(msg:lower())
    
    if command == "help" then
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Commands:")
        print("  /FuldStonks or /fs - Toggle main UI")
        print("  /FuldStonks help - Show this help message")
        print("  /FuldStonks version - Show addon version")
        print("  /FuldStonks sync - Request sync from guild/group")
        print("  /FuldStonks peers - Show connected peers")
        print("  /FuldStonks debug - Toggle debug mode")
    elseif command == "version" then
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " version " .. FuldStonks.version)
    elseif command == "sync" then
        FuldStonks:RequestSync()
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Requesting sync from guild/group...")
    elseif command == "peers" then
        local count = 0
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Connected peers:")
        for name, data in pairs(FuldStonks.peers) do
            local timeSince = math.floor(GetTime() - data.lastSeen)
            print("  " .. name .. " (seen " .. timeSince .. "s ago)")
            count = count + 1
        end
        if count == 0 then
            print("  No peers connected yet.")
        end
    elseif command == "debug" then
        FuldStonksDB.debug = not FuldStonksDB.debug
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Debug mode: " .. (FuldStonksDB.debug and "ON" or "OFF"))
    else
        -- Default: toggle UI
        ToggleMainFrame()
    end
end

-- Register slash commands
SLASH_FULDSTONKS1 = "/FuldStonks"
SLASH_FULDSTONKS2 = "/fs"
SlashCmdList["FULDSTONKS"] = SlashCommandHandler

-- ============================================
-- ADDON MESSAGE COMMUNICATION
-- ============================================

-- Addon message prefix for communication between players
local MESSAGE_PREFIX = "FuldStonks"

-- Message types
local MSG_HEARTBEAT = "HB"      -- Periodic heartbeat to announce presence
local MSG_SYNC_REQUEST = "SYNCREQ"  -- Request full state sync
local MSG_SYNC_RESPONSE = "SYNCRSP" -- Response with full state
local MSG_BET_CREATED = "BETCRT"    -- New bet created
local MSG_BET_PLACED = "BETPLC"     -- Bet placement
local MSG_BET_RESOLVED = "BETRSV"   -- Bet resolved

-- Determine the best channel to send messages
local function GetBroadcastChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    else
        return "GUILD"
    end
end

-- Serialize data for transmission (simple pipe-separated format)
local function SerializeMessage(msgType, ...)
    local parts = {msgType}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        table.insert(parts, tostring(v))
    end
    return table.concat(parts, "|")
end

-- Deserialize received message
local function DeserializeMessage(message)
    local parts = {strsplit("|", message)}
    local msgType = parts[1]
    table.remove(parts, 1)
    return msgType, unpack(parts)
end

-- Send addon message with rate limiting
function FuldStonks:BroadcastMessage(msgType, ...)
    local now = GetTime()
    
    -- Rate limit: max 1 message per second (except sync responses)
    if msgType ~= MSG_SYNC_RESPONSE and (now - self.lastBroadcast) < 1.0 then
        DebugPrint("Rate limited: " .. msgType)
        return false
    end
    
    local channel = GetBroadcastChannel()
    local message = SerializeMessage(msgType, ...)
    
    -- Check message length (WoW limit is 255 chars)
    if #message > 255 then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Message too long (" .. #message .. " chars)")
        return false
    end
    
    C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, message, channel)
    self.lastBroadcast = now
    DebugPrint("Sent " .. msgType .. " to " .. channel .. ": " .. message)
    return true
end

-- Initialize addon communication
local function InitializeAddonComms()
    -- Register addon message prefix
    C_ChatInfo.RegisterAddonMessagePrefix(MESSAGE_PREFIX)
    DebugPrint("Addon message prefix registered: " .. MESSAGE_PREFIX)
end

-- Send heartbeat to announce presence
function FuldStonks:SendHeartbeat()
    local activeBetCount = 0
    if FuldStonksDB.activeBets then
        for _ in pairs(FuldStonksDB.activeBets) do
            activeBetCount = activeBetCount + 1
        end
    end
    self:BroadcastMessage(MSG_HEARTBEAT, self.version, activeBetCount)
end

-- Request full sync from other players
function FuldStonks:RequestSync()
    self:BroadcastMessage(MSG_SYNC_REQUEST)
    self.syncRequested = true
end

-- Send sync response with current state
function FuldStonks:SendSyncResponse(target)
    -- For now, just send basic info
    -- In future, this will include active bets
    local activeBetCount = 0
    if FuldStonksDB.activeBets then
        for _ in pairs(FuldStonksDB.activeBets) do
            activeBetCount = activeBetCount + 1
        end
    end
    self:BroadcastMessage(MSG_SYNC_RESPONSE, activeBetCount)
end

-- Handle received addon messages
local function OnAddonMessageReceived(prefix, message, channel, sender)
    if prefix ~= MESSAGE_PREFIX then
        return
    end
    
    -- Ignore messages from self
    if sender == playerFullName then
        return
    end
    
    DebugPrint("Received from " .. sender .. " [" .. channel .. "]: " .. message)
    
    local msgType, arg1, arg2, arg3 = DeserializeMessage(message)
    local now = GetTime()
    
    -- Update peer tracking
    if not FuldStonks.peers[sender] then
        FuldStonks.peers[sender] = {}
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. sender .. " connected!")
    end
    FuldStonks.peers[sender].lastSeen = now
    
    -- Handle different message types
    if msgType == MSG_HEARTBEAT then
        local peerVersion = arg1 or "unknown"
        local peerBetCount = tonumber(arg2) or 0
        FuldStonks.peers[sender].version = peerVersion
        FuldStonks.peers[sender].betCount = peerBetCount
        DebugPrint(sender .. " heartbeat: v" .. peerVersion .. ", " .. peerBetCount .. " bets")
        
    elseif msgType == MSG_SYNC_REQUEST then
        DebugPrint(sender .. " requested sync")
        -- Send our current state
        FuldStonks:SendSyncResponse(sender)
        
    elseif msgType == MSG_SYNC_RESPONSE then
        local betCount = tonumber(arg1) or 0
        DebugPrint(sender .. " sync response: " .. betCount .. " bets")
        FuldStonks.peers[sender].betCount = betCount
        
    elseif msgType == MSG_BET_CREATED then
        -- TODO: Handle bet creation from peer
        DebugPrint(sender .. " created a bet")
        
    elseif msgType == MSG_BET_PLACED then
        -- TODO: Handle bet placement from peer
        DebugPrint(sender .. " placed a bet")
        
    elseif msgType == MSG_BET_RESOLVED then
        -- TODO: Handle bet resolution from peer
        DebugPrint(sender .. " resolved a bet")
        
    else
        DebugPrint("Unknown message type: " .. tostring(msgType))
    end
end

-- Event handler
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            Initialize()
            InitializeAddonComms()
            
            -- Initialize debug mode if not set
            if FuldStonksDB.debug == nil then
                FuldStonksDB.debug = false
            end
            
            -- Start heartbeat timer (every 30 seconds)
            C_Timer.NewTicker(30, function()
                FuldStonks:SendHeartbeat()
            end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessageReceived(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Group composition changed, send heartbeat
        C_Timer.After(1.0, function()
            FuldStonks:SendHeartbeat()
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Entering world/instance, request sync
        C_Timer.After(2.0, function()
            FuldStonks:SendHeartbeat()
            FuldStonks:RequestSync()
        end)
    end
end)

-- Register events
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

-- ============================================
-- FUTURE EXPANSION HOOKS
-- ============================================

-- Hook for bet management
function FuldStonks:CreateBet(betData)
    -- TODO: Implement bet creation logic
    -- betData should contain: title, description, options, entryFee, endTime, etc.
end

function FuldStonks:PlaceBet(betId, option, amount)
    -- TODO: Implement bet placement logic
end

function FuldStonks:ResolveBet(betId, winningOption)
    -- TODO: Implement bet resolution and gold distribution logic
end

-- Hook for data persistence
function FuldStonks:SaveData()
    -- TODO: Implement saving active bets and user data to SavedVariables
end

function FuldStonks:LoadData()
    -- TODO: Implement loading saved data from SavedVariables
end
