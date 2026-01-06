-- FuldStonks: Guild betting addon for World of Warcraft
-- Version: 0.1.0
-- Author: EraxterCodes

-- Create addon namespace
local ADDON_NAME, FuldStonks = ...

-- Initialize saved variables
FuldStonksDB = FuldStonksDB or {}

-- Addon state
FuldStonks.version = "0.1.0"
FuldStonks.frame = nil

-- Event frame for initialization
local eventFrame = CreateFrame("Frame")

-- Addon initialization
local function Initialize()
    print("|cFF00FF00FuldStonks|r addon loaded! Type /FuldStonks or /fs to open the UI.")
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
    
    -- Create version text
    local versionText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    versionText:SetPoint("BOTTOM", frame, "BOTTOM", 0, 10)
    versionText:SetText("Version " .. FuldStonks.version)
    versionText:SetTextColor(0.7, 0.7, 0.7)
    
    -- Create close button handler
    frame.CloseButton:SetScript("OnClick", function()
        frame:Hide()
    end)
    
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
    local command = msg:lower():trim()
    
    if command == "help" then
        print("|cFF00FF00FuldStonks|r Commands:")
        print("  /FuldStonks or /fs - Toggle main UI")
        print("  /FuldStonks help - Show this help message")
        print("  /FuldStonks version - Show addon version")
    elseif command == "version" then
        print("|cFF00FF00FuldStonks|r version " .. FuldStonks.version)
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
-- ADDON MESSAGE COMMUNICATION HOOKS (FUTURE)
-- ============================================

-- Addon message prefix for communication between players
local MESSAGE_PREFIX = "FuldStonks"

-- Initialize addon communication
local function InitializeAddonComms()
    -- Register addon message prefix
    C_ChatInfo.RegisterAddonMessagePrefix(MESSAGE_PREFIX)
    
    -- TODO: Implement message handlers for:
    -- - Broadcasting bet creation
    -- - Syncing bet states
    -- - Processing bet participations
    -- - Resolving bet outcomes
end

-- Hook for sending addon messages
function FuldStonks:SendAddonMessage(messageType, data, channel)
    -- TODO: Implement message serialization and sending
    -- channel can be "GUILD", "RAID", "PARTY", or "WHISPER"
    -- Example: C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, serializedData, channel, target)
end

-- Hook for receiving addon messages
local function OnAddonMessageReceived(prefix, message, channel, sender)
    if prefix ~= MESSAGE_PREFIX then
        return
    end
    
    -- TODO: Implement message deserialization and handling
    -- Parse messageType and data
    -- Update local state based on received information
end

-- Event handler
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            Initialize()
            InitializeAddonComms()
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessageReceived(...)
    end
end)

-- Register events
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

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

-- Export namespace for debugging
_G.FuldStonks = FuldStonks
