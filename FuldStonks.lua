-- FuldStonks: Guild betting addon for World of Warcraft
-- Version: 0.1.0
-- Author: EraxterCodes

-- Create addon namespace
local ADDON_NAME, FuldStonks = ...

-- Initialize saved variables
FuldStonksDB = FuldStonksDB or {
    activeBets = {},      -- Active bets in the system
    myBets = {},          -- Bets I've placed
    betHistory = {},      -- Historical bets
    ignoredBets = {},     -- Bets hidden from view
    stateVersion = 0,     -- Lamport clock for state versioning
    syncNonce = 0         -- Nonce to track sync sessions
}

-- Constants
local COLOR_GREEN = "|cFF00FF00"
local COLOR_RESET = "|r"
local COLOR_YELLOW = "|cFFFFFF00"
local COLOR_RED = "|cFFFF0000"
local COLOR_ORANGE = "|cFFFF8800"
local COLOR_GRAY = "|cFF808080"

-- Addon state
FuldStonks.version = "0.2.0"
FuldStonks.frame = nil
FuldStonks.peers = {}           -- Track connected peers: [fullName] = { lastSeen = time, stateVersion = 0, nonce = 0 }
FuldStonks.lastBroadcast = 0    -- Rate limiting for broadcasts
FuldStonks.syncRequested = false
FuldStonks.syncTicker = nil     -- Store state sync ticker for cleanup (replaces heartbeat)
FuldStonks.rosterUpdateTimer = nil  -- Debounce timer for roster updates
FuldStonks.betIdCounter = 0      -- Counter for generating unique bet IDs
FuldStonks.pendingBets = {}      -- Track pending bets awaiting gold trade: {betId, option, amount}
FuldStonks.pendingStateUpdates = {}  -- Queue for state updates to be applied

-- Event frame for initialization
local eventFrame = CreateFrame("Frame")

-- Get player's full name (Name-Realm)
local playerName, playerRealm = UnitFullName("player")
local playerFullName = (playerRealm and playerRealm ~= "" and (playerName .. "-" .. playerRealm)) or playerName

-- Helper function for debug output
local function DebugPrint(msg)
    if FuldStonksDB.debug == true then
        print(COLOR_GREEN .. "FuldStonks [DEBUG]" .. COLOR_RESET .. " " .. tostring(msg))
    end
end

-- Static popup for confirming bet cancellation
StaticPopupDialogs["FULDSTONKS_CONFIRM_CANCEL"] = {
    text = "Cancel this bet and return all gold to participants?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function(self, betId)
        FuldStonks:CancelBet(betId)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Helper function to extract base name (remove realm suffix)
-- Handles hyphenated names correctly: "Mary-Jane-Stormrage" -> "Mary-Jane"
local function GetPlayerBaseName(fullName)
    if not fullName or fullName == "" then
        return fullName
    end
    return fullName:gsub("%-[^%-]*$", "")
end

-- Generate unique bet ID
local function GenerateBetId()
    FuldStonks.betIdCounter = FuldStonks.betIdCounter + 1
    local timestamp = math.floor(GetTime())
    return playerName .. "-" .. timestamp .. "-" .. FuldStonks.betIdCounter
end

-- Serialize bet data for transmission
local function SerializeBet(bet)
    -- Format: betId|title|betType|option1,option2,...|createdBy|timestamp
    local options = table.concat(bet.options, ",")
    return bet.id .. "|" .. bet.title .. "|" .. bet.betType .. "|" .. options .. "|" .. bet.createdBy .. "|" .. bet.timestamp
end

-- Deserialize bet data from message
local function DeserializeBet(betString)
    local parts = {strsplit("|", betString)}
    if #parts < 6 then return nil end
    
    local bet = {
        id = parts[1],
        title = parts[2],
        betType = parts[3],
        options = {strsplit(",", parts[4])},
        createdBy = parts[5],
        timestamp = tonumber(parts[6]) or 0,
        participants = {},  -- {playerName = {option = "Yes", amount = 100}}
        totalPot = 0,
        status = "active",   -- active, locked, resolved
        pendingTrades = {}   -- Only used by bet holder
    }
    return bet
end

-- Addon initialization
local function Initialize()
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " addon loaded! Type /FuldStonks or /fs to open the UI.")
end

-- Create the main UI frame
local function CreateMainFrame()
    if FuldStonks.frame then
        return FuldStonks.frame
    end
    
    -- Create main frame
    local frame = CreateFrame("Frame", "FuldStonksMainFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(600, 450)
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
    
    -- Create "Create Bet" button
    frame.createBetButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.createBetButton:SetSize(120, 25)
    frame.createBetButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -30)
    frame.createBetButton:SetText("Create Bet")
    frame.createBetButton:SetScript("OnClick", function()
        FuldStonks:ShowBetCreationDialog()
    end)
    
    -- Active bets title
    frame.activeBetsTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.activeBetsTitle:SetPoint("TOPLEFT", frame.createBetButton, "BOTTOMLEFT", 0, -10)
    frame.activeBetsTitle:SetText("Active Bets:")
    
    -- Scrollable bet list
    frame.betList = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    frame.betList:SetPoint("TOPLEFT", frame.activeBetsTitle, "BOTTOMLEFT", 0, -5)
    frame.betList:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 40)
    
    frame.betListContent = CreateFrame("Frame", nil, frame.betList)
    frame.betListContent:SetSize(540, 1)
    frame.betList:SetScrollChild(frame.betListContent)
    
    -- Function to update bet list display
    frame.UpdateBetList = function(self)
        -- Clear existing children
        for _, child in pairs({self.betListContent:GetChildren()}) do
            child:Hide()
            child:SetParent(nil)
        end
        
        local yOffset = 0
        local betCount = 0
        
        -- Display active bets
        for betId, bet in pairs(FuldStonksDB.activeBets) do
            if bet.status == "active" and not FuldStonksDB.ignoredBets[betId] then
                local betFrame = CreateFrame("Frame", nil, self.betListContent, "BackdropTemplate")
                betFrame:SetSize(520, 80)
                betFrame:SetPoint("TOPLEFT", self.betListContent, "TOPLEFT", 0, -yOffset)
                betFrame:SetBackdrop({
                    bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                    edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 16,
                    insets = { left = 4, right = 4, top = 4, bottom = 4 }
                })
                betFrame:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
                betFrame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
                
                -- Bet title
                local title = betFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                title:SetPoint("TOPLEFT", betFrame, "TOPLEFT", 10, -8)
                title:SetText(bet.title)
                title:SetJustifyH("LEFT")
                title:SetWidth(450)
                
                -- Hide button on the right
                local hideButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                hideButton:SetSize(50, 20)
                hideButton:SetPoint("TOPRIGHT", betFrame, "TOPRIGHT", -8, -8)
                hideButton:SetText("Hide")
                hideButton:SetScript("OnClick", function()
                    FuldStonks:HideBet(betId)
                    self:UpdateBetList()
                end)
                
                -- Bet info
                local creatorName = GetPlayerBaseName(bet.createdBy)
                local info = betFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                info:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
                info:SetText("By: " .. creatorName .. " • Type: " .. bet.betType .. " • Pot: " .. bet.totalPot .. "g")
                info:SetTextColor(0.7, 0.7, 0.7)
                
                -- Check if player has a pending bet on this
                local hasPending = FuldStonks.pendingBets[playerFullName] and FuldStonks.pendingBets[playerFullName].betId == betId
                
                if hasPending then
                    -- Show pending status
                    local pendingText = betFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                    pendingText:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -3)
                    local pendingBet = FuldStonks.pendingBets[playerFullName]
                    pendingText:SetText(COLOR_ORANGE .. "⏳ PENDING: " .. pendingBet.option .. " (" .. pendingBet.amount .. "g) - Awaiting trade" .. COLOR_RESET)
                    pendingText:SetTextColor(1, 0.5, 0)
                    
                    -- Add cancel button
                    local cancelButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                    cancelButton:SetSize(80, 22)
                    cancelButton:SetPoint("TOPLEFT", pendingText, "BOTTOMLEFT", 0, -5)
                    cancelButton:SetText("Cancel")
                    cancelButton:SetScript("OnClick", function()
                        FuldStonks:CancelPendingBet()
                        self:UpdateBetList()
                    end)
                else
                    -- Bet buttons for each option
                    local buttonOffset = 0
                    for _, option in ipairs(bet.options) do
                        local optionButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                        optionButton:SetSize(80, 22)
                        optionButton:SetPoint("TOPLEFT", info, "BOTTOMLEFT", buttonOffset, -5)
                        optionButton:SetText(option)
                        optionButton:SetScript("OnClick", function()
                            FuldStonks:ShowPlaceBetDialog(betId, option)
                        end)
                        buttonOffset = buttonOffset + 85
                    end
                    
                    -- Add Inspect button for all bets (shows confirmed and pending bets)
                    local inspectButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                    inspectButton:SetSize(80, 22)
                    inspectButton:SetPoint("TOPLEFT", info, "BOTTOMLEFT", buttonOffset, -5)
                    inspectButton:SetText("Inspect")
                    inspectButton:SetScript("OnClick", function()
                        FuldStonks:ShowBetInspectDialog(betId)
                    end)
                end
                
                yOffset = yOffset + 85
                betCount = betCount + 1
            end
        end
        
        -- Show message if no bets
        if betCount == 0 then
            local noBetsText = self.betListContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            noBetsText:SetPoint("TOP", self.betListContent, "TOP", 0, -20)
            noBetsText:SetText("No active bets.\nUse " .. COLOR_YELLOW .. "/fs create" .. COLOR_RESET .. " to create one!")
            noBetsText:SetJustifyH("CENTER")
        end
        
        self.betListContent:SetHeight(math.max(yOffset, 300))
    end
    
    -- Create connected peers display
    frame.peersText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.peersText:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 15, 10)
    frame.peersText:SetJustifyH("LEFT")
    frame.peersText:SetTextColor(0.6, 0.6, 0.6)
    
    -- Update function for peers display
    frame.UpdatePeers = function(self)
        local peerCount = 0
        for _ in pairs(FuldStonks.peers) do
            peerCount = peerCount + 1
        end
        self.peersText:SetText("Connected: " .. peerCount .. " peers • v" .. FuldStonks.version)
    end
    
    -- Create close button handler
    frame.CloseButton:SetScript("OnClick", function()
        frame:Hide()
    end)
    
    -- Update displays every 2 seconds when visible
    frame:SetScript("OnShow", function(self)
        self:UpdatePeers()
        self:UpdateBetList()
        self.updateTicker = C_Timer.NewTicker(2, function()
            if self:IsShown() then
                self:UpdatePeers()
                self:UpdateBetList()
            end
        end)
    end)
    
    frame:SetScript("OnHide", function(self)
        if self.updateTicker then
            self.updateTicker:Cancel()
            self.updateTicker = nil
        end
    end)
    
    -- Initial update
    frame:UpdatePeers()
    frame:UpdateBetList()
    
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

-- Show bet creation dialog
function FuldStonks:ShowBetCreationDialog()
    -- Create dialog if it doesn't exist
    if not self.betCreationDialog then
        local dialog = CreateFrame("Frame", "FuldStonksBetCreationDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(400, 300)
        dialog:SetPoint("CENTER")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:SetFrameStrata("DIALOG")
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", dialog.TitleBg, "TOP", 0, -3)
        dialog.title:SetText("Create New Bet")
        
        -- Bet title input
        dialog.titleLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.titleLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", 20, -35)
        dialog.titleLabel:SetText("Bet Question:")
        
        dialog.titleInput = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.titleInput:SetSize(360, 20)
        dialog.titleInput:SetPoint("TOPLEFT", dialog.titleLabel, "BOTTOMLEFT", 10, -5)
        dialog.titleInput:SetAutoFocus(false)
        dialog.titleInput:SetMaxLetters(100)
        
        -- Bet type selector
        dialog.typeLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.typeLabel:SetPoint("TOPLEFT", dialog.titleInput, "BOTTOMLEFT", -10, -15)
        dialog.typeLabel:SetText("Bet Type:")
        
        -- Yes/No radio button
        dialog.yesNoRadio = CreateFrame("CheckButton", nil, dialog, "UIRadioButtonTemplate")
        dialog.yesNoRadio:SetPoint("TOPLEFT", dialog.typeLabel, "BOTTOMLEFT", 0, -5)
        dialog.yesNoRadio.text:SetText("Yes/No")
        dialog.yesNoRadio:SetChecked(true)
        
        -- Multiple choice radio (for future expansion)
        dialog.multiRadio = CreateFrame("CheckButton", nil, dialog, "UIRadioButtonTemplate")
        dialog.multiRadio:SetPoint("TOPLEFT", dialog.yesNoRadio, "BOTTOMLEFT", 0, -5)
        dialog.multiRadio.text:SetText("Multiple Choice (Coming Soon)")
        dialog.multiRadio:Disable()
        
        -- Radio button behavior
        dialog.yesNoRadio:SetScript("OnClick", function(self)
            self:SetChecked(true)
            dialog.multiRadio:SetChecked(false)
        end)
        
        -- Create button
        dialog.createButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.createButton:SetSize(100, 25)
        dialog.createButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, 15)
        dialog.createButton:SetText("Create")
        dialog.createButton:SetScript("OnClick", function()
            local title = dialog.titleInput:GetText()
            if title and title ~= "" then
                local betType = "YesNo"  -- Default for now
                local options = {"Yes", "No"}
                
                FuldStonks:CreateBet({
                    title = title,
                    betType = betType,
                    options = options
                })
                
                dialog.titleInput:SetText("")
                dialog:Hide()
            else
                print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Please enter a bet question!")
            end
        end)
        
        -- Cancel button
        dialog.cancelButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.cancelButton:SetSize(100, 25)
        dialog.cancelButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, 15)
        dialog.cancelButton:SetText("Cancel")
        dialog.cancelButton:SetScript("OnClick", function()
            dialog.titleInput:SetText("")
            dialog:Hide()
        end)
        
        dialog.CloseButton:SetScript("OnClick", function()
            dialog.titleInput:SetText("")
            dialog:Hide()
        end)
        
        self.betCreationDialog = dialog
    end
    
    self.betCreationDialog:Show()
end

-- Show place bet dialog
function FuldStonks:ShowPlaceBetDialog(betId, option)
    -- Create dialog if it doesn't exist
    if not self.placeBetDialog then
        local dialog = CreateFrame("Frame", "FuldStonksPlaceBetDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(350, 200)
        dialog:SetPoint("CENTER")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:SetFrameStrata("DIALOG")
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", dialog.TitleBg, "TOP", 0, -3)
        dialog.title:SetText("Place Bet")
        
        dialog.betInfo = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.betInfo:SetPoint("TOP", dialog, "TOP", 0, -40)
        dialog.betInfo:SetWidth(310)
        dialog.betInfo:SetJustifyH("CENTER")
        
        dialog.amountLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.amountLabel:SetPoint("TOP", dialog.betInfo, "BOTTOM", 0, -20)
        dialog.amountLabel:SetText("Amount (gold):")
        
        dialog.amountInput = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.amountInput:SetSize(100, 20)
        dialog.amountInput:SetPoint("TOP", dialog.amountLabel, "BOTTOM", 0, -5)
        dialog.amountInput:SetAutoFocus(false)
        dialog.amountInput:SetNumeric(true)
        dialog.amountInput:SetMaxLetters(10)
        
        dialog.placeButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.placeButton:SetSize(100, 25)
        dialog.placeButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, 15)
        dialog.placeButton:SetText("Place Bet")
        
        dialog.cancelButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.cancelButton:SetSize(100, 25)
        dialog.cancelButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, 15)
        dialog.cancelButton:SetText("Cancel")
        dialog.cancelButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        dialog.CloseButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        self.placeBetDialog = dialog
    end
    
    -- Set current bet info
    local bet = FuldStonksDB.activeBets[betId]
    if bet then
        self.placeBetDialog.betInfo:SetText("Betting " .. COLOR_YELLOW .. option .. COLOR_RESET .. " on:\n" .. bet.title)
        self.placeBetDialog.currentBetId = betId
        self.placeBetDialog.currentOption = option
        
        self.placeBetDialog.placeButton:SetScript("OnClick", function()
            local amount = tonumber(self.placeBetDialog.amountInput:GetText())
            if amount and amount > 0 then
                FuldStonks:PlaceBet(betId, option, amount)
                self.placeBetDialog.amountInput:SetText("")
                self.placeBetDialog:Hide()
            else
                print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Please enter a valid amount!")
            end
        end)
        
        self.placeBetDialog:Show()
    end
end

-- Show bet resolution dialog
function FuldStonks:ShowBetResolutionDialog(betId)
    betId = betId or self.selectedBetForResolution
    
    if not betId then
        -- If no betId provided, show selection dialog
        self:ShowBetSelectionDialog()
        return
    end
    
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Bet not found!")
        return
    end
    
    -- Only bet creator can resolve
    if bet.createdBy ~= playerFullName then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Only the bet creator can resolve this bet!")
        return
    end
    
    -- Create dialog if it doesn't exist
    if not self.resolutionDialog then
        local dialog = CreateFrame("Frame", "FuldStonksResolutionDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(450, 400)
        dialog:SetPoint("CENTER")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:SetFrameStrata("DIALOG")
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", dialog.TitleBg, "TOP", 0, -3)
        dialog.title:SetText("Resolve Bet")
        
        dialog.betTitle = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.betTitle:SetPoint("TOP", dialog, "TOP", 0, -35)
        dialog.betTitle:SetWidth(420)
        dialog.betTitle:SetJustifyH("CENTER")
        
        dialog.infoLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.infoLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", 20, -70)
        dialog.infoLabel:SetText("Select winning option:")
        
        -- Scrollable payout info
        dialog.scrollFrame = CreateFrame("ScrollFrame", nil, dialog, "UIPanelScrollFrameTemplate")
        dialog.scrollFrame:SetPoint("TOPLEFT", dialog.infoLabel, "BOTTOMLEFT", 0, -10)
        dialog.scrollFrame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -30, 80)
        
        dialog.scrollContent = CreateFrame("Frame", nil, dialog.scrollFrame)
        dialog.scrollContent:SetSize(390, 1)
        dialog.scrollFrame:SetScrollChild(dialog.scrollContent)
        
        dialog.payoutText = dialog.scrollContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dialog.payoutText:SetPoint("TOPLEFT", dialog.scrollContent, "TOPLEFT", 0, 0)
        dialog.payoutText:SetWidth(390)
        dialog.payoutText:SetJustifyH("LEFT")
        
        dialog.CloseButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        self.resolutionDialog = dialog
    end
    
    -- Set bet info
    self.resolutionDialog.betTitle:SetText(COLOR_YELLOW .. bet.title .. COLOR_RESET)
    self.resolutionDialog.currentBetId = betId
    
    -- Calculate and show payout information
    local payoutInfo = "Total Pot: " .. COLOR_GREEN .. bet.totalPot .. "g" .. COLOR_RESET .. "\n\n"
    
    -- Group participants by option
    local optionGroups = {}
    for playerName, participation in pairs(bet.participants) do
        if not optionGroups[participation.option] then
            optionGroups[participation.option] = {}
        end
        table.insert(optionGroups[participation.option], {name = playerName, amount = participation.amount})
    end
    
    -- Show breakdown for each option
    for _, option in ipairs(bet.options) do
        local group = optionGroups[option] or {}
        local totalBets = 0
        for _, p in ipairs(group) do
            totalBets = totalBets + p.amount
        end
        
        payoutInfo = payoutInfo .. COLOR_YELLOW .. option .. ":" .. COLOR_RESET .. " " .. #group .. " bets, " .. totalBets .. "g total\n"
        
        if #group > 0 then
            for _, p in ipairs(group) do
                local baseName = GetPlayerBaseName(p.name)
                local payout = math.floor((p.amount / totalBets) * bet.totalPot)
                local profit = payout - p.amount
                payoutInfo = payoutInfo .. "  " .. baseName .. ": " .. p.amount .. "g bet → " .. payout .. "g payout ("
                if profit > 0 then
                    payoutInfo = payoutInfo .. COLOR_GREEN .. "+" .. profit .. "g" .. COLOR_RESET
                elseif profit < 0 then
                    payoutInfo = payoutInfo .. COLOR_RED .. profit .. "g" .. COLOR_RESET
                else
                    payoutInfo = payoutInfo .. "0g"
                end
                payoutInfo = payoutInfo .. ")\n"
            end
        else
            payoutInfo = payoutInfo .. "  No bets\n"
        end
        payoutInfo = payoutInfo .. "\n"
    end
    
    self.resolutionDialog.payoutText:SetText(payoutInfo)
    
    -- Update scroll content height
    local textHeight = self.resolutionDialog.payoutText:GetStringHeight()
    self.resolutionDialog.scrollContent:SetHeight(math.max(textHeight + 20, 200))
    
    -- Clear old option buttons
    if self.resolutionDialog.optionButtons then
        for _, btn in ipairs(self.resolutionDialog.optionButtons) do
            btn:Hide()
            btn:SetParent(nil)
        end
    end
    self.resolutionDialog.optionButtons = {}
    
    -- Create option buttons
    local buttonOffset = 0
    for _, option in ipairs(bet.options) do
        local optionButton = CreateFrame("Button", nil, self.resolutionDialog, "UIPanelButtonTemplate")
        optionButton:SetSize(100, 25)
        optionButton:SetPoint("BOTTOMLEFT", self.resolutionDialog, "BOTTOMLEFT", 20 + buttonOffset, 15)
        optionButton:SetText(option .. " Wins")
        optionButton:SetScript("OnClick", function()
            FuldStonks:ResolveBet(betId, option)
            self.resolutionDialog:Hide()
        end)
        table.insert(self.resolutionDialog.optionButtons, optionButton)
        buttonOffset = buttonOffset + 110
    end
    
    -- Cancel button
    local cancelButton = CreateFrame("Button", nil, self.resolutionDialog, "UIPanelButtonTemplate")
    cancelButton:SetSize(100, 25)
    cancelButton:SetPoint("BOTTOMRIGHT", self.resolutionDialog, "BOTTOMRIGHT", -20, 15)
    cancelButton:SetText("Cancel")
    cancelButton:SetScript("OnClick", function()
        self.resolutionDialog:Hide()
    end)
    table.insert(self.resolutionDialog.optionButtons, cancelButton)
    
    self.resolutionDialog:Show()
end

-- Show bet selection dialog for resolution
function FuldStonks:ShowBetSelectionDialog()
    -- Find bets created by this player
    local myBets = {}
    for betId, bet in pairs(FuldStonksDB.activeBets) do
        if bet.createdBy == playerFullName and bet.status == "active" then
            table.insert(myBets, {id = betId, title = bet.title})
        end
    end
    
    if #myBets == 0 then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " You have no active bets to resolve.")
        return
    end
    
    if #myBets == 1 then
        -- Only one bet, show resolution dialog directly
        self:ShowBetResolutionDialog(myBets[1].id)
        return
    end
    
    -- Multiple bets, let user choose
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Select a bet to resolve:")
    for i, bet in ipairs(myBets) do
        print("  " .. i .. ". " .. bet.title)
    end
    print("Use: /fs resolve (from UI click Resolve button on the specific bet)")
end

-- Show payout dialog
function FuldStonks:ShowPayoutDialog(betId, winningOption)
    local bet = FuldStonksDB.betHistory[betId] or FuldStonksDB.activeBets[betId]
    if not bet then
        return
    end
    
    -- Create dialog if it doesn't exist
    if not self.payoutDialog then
        local dialog = CreateFrame("Frame", "FuldStonksPayoutDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(500, 450)
        dialog:SetPoint("CENTER")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:SetFrameStrata("DIALOG")
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", dialog.TitleBg, "TOP", 0, -3)
        dialog.title:SetText("Payout Summary")
        
        dialog.betTitle = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dialog.betTitle:SetPoint("TOP", dialog, "TOP", 0, -35)
        dialog.betTitle:SetWidth(460)
        dialog.betTitle:SetJustifyH("CENTER")
        
        dialog.resultText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.resultText:SetPoint("TOP", dialog.betTitle, "BOTTOM", 0, -10)
        dialog.resultText:SetWidth(460)
        dialog.resultText:SetJustifyH("CENTER")
        
        -- Scrollable payout list
        dialog.scrollFrame = CreateFrame("ScrollFrame", nil, dialog, "UIPanelScrollFrameTemplate")
        dialog.scrollFrame:SetPoint("TOPLEFT", dialog.resultText, "BOTTOMLEFT", 0, -15)
        dialog.scrollFrame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -30, 50)
        
        dialog.scrollContent = CreateFrame("Frame", nil, dialog.scrollFrame)
        dialog.scrollContent:SetSize(440, 1)
        dialog.scrollFrame:SetScrollChild(dialog.scrollContent)
        
        dialog.payoutText = dialog.scrollContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.payoutText:SetPoint("TOPLEFT", dialog.scrollContent, "TOPLEFT", 0, 0)
        dialog.payoutText:SetWidth(440)
        dialog.payoutText:SetJustifyH("LEFT")
        
        -- Close button
        dialog.closeButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.closeButton:SetSize(100, 25)
        dialog.closeButton:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 15)
        dialog.closeButton:SetText("Close")
        dialog.closeButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        dialog.CloseButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        self.payoutDialog = dialog
    end
    
    -- Set bet info
    self.payoutDialog.betTitle:SetText(COLOR_YELLOW .. bet.title .. COLOR_RESET)
    
    local payoutInfo = ""
    
    if bet.status == "cancelled" then
        -- Cancelled bet - return all money
        self.payoutDialog.resultText:SetText(COLOR_YELLOW .. "BET CANCELLED - Return All Gold" .. COLOR_RESET)
        
        payoutInfo = COLOR_ORANGE .. "Return the following amounts to each participant:\n\n" .. COLOR_RESET
        
        if next(bet.participants) then
            local sortedParticipants = {}
            for playerName, participation in pairs(bet.participants) do
                table.insert(sortedParticipants, {name = playerName, amount = participation.amount, option = participation.option})
            end
            table.sort(sortedParticipants, function(a, b) return a.amount > b.amount end)
            
            for _, p in ipairs(sortedParticipants) do
                local baseName = GetPlayerBaseName(p.name)
                payoutInfo = payoutInfo .. COLOR_GREEN .. baseName .. COLOR_RESET .. "\n"
                payoutInfo = payoutInfo .. "  Return: " .. COLOR_YELLOW .. p.amount .. "g" .. COLOR_RESET .. " (originally bet on " .. p.option .. ")\n\n"
            end
        else
            payoutInfo = COLOR_GRAY .. "No participants to refund." .. COLOR_RESET
        end
        
    elseif bet.status == "resolved" and winningOption then
        -- Resolved bet - calculate payouts
        self.payoutDialog.resultText:SetText(COLOR_GREEN .. winningOption .. " WINS!" .. COLOR_RESET)
        
        -- Calculate winners
        local totalWinningBets = 0
        local winners = {}
        local losers = {}
        
        for playerName, participation in pairs(bet.participants) do
            if participation.option == winningOption then
                totalWinningBets = totalWinningBets + participation.amount
                table.insert(winners, {name = playerName, amount = participation.amount})
            else
                table.insert(losers, {name = playerName, amount = participation.amount, option = participation.option})
            end
        end
        
        if totalWinningBets == 0 then
            -- No winners - return all bets
            payoutInfo = COLOR_ORANGE .. "No winners! Return all gold:\n\n" .. COLOR_RESET
            
            for _, p in ipairs(losers) do
                local baseName = GetPlayerBaseName(p.name)
                payoutInfo = payoutInfo .. COLOR_GREEN .. baseName .. COLOR_RESET .. "\n"
                payoutInfo = payoutInfo .. "  Return: " .. COLOR_YELLOW .. p.amount .. "g" .. COLOR_RESET .. "\n\n"
            end
        else
            -- Winners get payouts
            table.sort(winners, function(a, b) return a.amount > b.amount end)
            
            payoutInfo = COLOR_GREEN .. "WINNERS - Pay Out:\n\n" .. COLOR_RESET
            
            for _, winner in ipairs(winners) do
                local share = math.floor((winner.amount / totalWinningBets) * bet.totalPot)
                local profit = share - winner.amount
                local baseName = GetPlayerBaseName(winner.name)
                
                payoutInfo = payoutInfo .. COLOR_GREEN .. baseName .. COLOR_RESET .. "\n"
                payoutInfo = payoutInfo .. "  Bet: " .. winner.amount .. "g\n"
                payoutInfo = payoutInfo .. "  Payout: " .. COLOR_YELLOW .. share .. "g" .. COLOR_RESET
                
                if profit > 0 then
                    payoutInfo = payoutInfo .. " (" .. COLOR_GREEN .. "+" .. profit .. "g profit" .. COLOR_RESET .. ")"
                elseif profit < 0 then
                    payoutInfo = payoutInfo .. " (" .. COLOR_RED .. profit .. "g loss" .. COLOR_RESET .. ")"
                end
                
                payoutInfo = payoutInfo .. "\n\n"
            end
            
            -- Show losers (no payout)
            if #losers > 0 then
                table.sort(losers, function(a, b) return a.amount > b.amount end)
                payoutInfo = payoutInfo .. "\n" .. COLOR_RED .. "LOSERS - No Payout:\n\n" .. COLOR_RESET
                
                for _, loser in ipairs(losers) do
                    local baseName = GetPlayerBaseName(loser.name)
                    payoutInfo = payoutInfo .. COLOR_GRAY .. baseName .. COLOR_RESET .. " (lost " .. loser.amount .. "g on " .. loser.option .. ")\n"
                end
            end
        end
    end
    
    self.payoutDialog.payoutText:SetText(payoutInfo)
    
    -- Update scroll content height
    local textHeight = self.payoutDialog.payoutText:GetStringHeight()
    self.payoutDialog.scrollContent:SetHeight(math.max(textHeight + 20, 300))
    
    self.payoutDialog:Show()
end

-- Show bet inspect dialog
function FuldStonks:ShowBetInspectDialog(betId)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Bet not found!")
        return
    end
    
    -- Create dialog if it doesn't exist
    if not self.inspectDialog then
        local dialog = CreateFrame("Frame", "FuldStonksInspectDialog", UIParent, "BasicFrameTemplateWithInset")
        dialog:SetSize(600, 500)
        dialog:SetPoint("CENTER")
        dialog:SetMovable(true)
        dialog:EnableMouse(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", dialog.StartMoving)
        dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
        dialog:SetFrameStrata("DIALOG")
        dialog:Hide()
        
        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        dialog.title:SetPoint("TOP", dialog.TitleBg, "TOP", 0, -3)
        dialog.title:SetText("Inspect Bet")
        
        dialog.betTitle = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dialog.betTitle:SetPoint("TOP", dialog, "TOP", 0, -35)
        dialog.betTitle:SetWidth(560)
        dialog.betTitle:SetJustifyH("CENTER")
        
        -- Info section
        dialog.infoText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.infoText:SetPoint("TOP", dialog.betTitle, "BOTTOM", 0, -10)
        dialog.infoText:SetWidth(560)
        dialog.infoText:SetJustifyH("CENTER")
        
        -- Top row: 2 columns (Yes and No)
        -- Left column (Yes - Green)
        dialog.yesFrame = CreateFrame("Frame", nil, dialog, "InsetFrameTemplate")
        dialog.yesFrame:SetPoint("TOPLEFT", dialog.infoText, "BOTTOMLEFT", 10, -10)
        dialog.yesFrame:SetSize(270, 180)
        
        dialog.yesTitle = dialog.yesFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dialog.yesTitle:SetPoint("TOP", dialog.yesFrame, "TOP", 0, -8)
        dialog.yesTitle:SetText(COLOR_GREEN .. "YES" .. COLOR_RESET)
        
        dialog.yesScroll = CreateFrame("ScrollFrame", nil, dialog.yesFrame, "UIPanelScrollFrameTemplate")
        dialog.yesScroll:SetPoint("TOPLEFT", dialog.yesFrame, "TOPLEFT", 8, -30)
        dialog.yesScroll:SetPoint("BOTTOMRIGHT", dialog.yesFrame, "BOTTOMRIGHT", -28, 8)
        
        dialog.yesContent = CreateFrame("Frame", nil, dialog.yesScroll)
        dialog.yesContent:SetSize(230, 1)
        dialog.yesScroll:SetScrollChild(dialog.yesContent)
        
        dialog.yesText = dialog.yesContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.yesText:SetPoint("TOPLEFT", dialog.yesContent, "TOPLEFT", 0, 0)
        dialog.yesText:SetWidth(230)
        dialog.yesText:SetJustifyH("LEFT")
        
        -- Right column (No - Red)
        dialog.noFrame = CreateFrame("Frame", nil, dialog, "InsetFrameTemplate")
        dialog.noFrame:SetPoint("TOPRIGHT", dialog.infoText, "BOTTOMRIGHT", -10, -10)
        dialog.noFrame:SetSize(270, 180)
        
        dialog.noTitle = dialog.noFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dialog.noTitle:SetPoint("TOP", dialog.noFrame, "TOP", 0, -8)
        dialog.noTitle:SetText(COLOR_RED .. "NO" .. COLOR_RESET)
        
        dialog.noScroll = CreateFrame("ScrollFrame", nil, dialog.noFrame, "UIPanelScrollFrameTemplate")
        dialog.noScroll:SetPoint("TOPLEFT", dialog.noFrame, "TOPLEFT", 8, -30)
        dialog.noScroll:SetPoint("BOTTOMRIGHT", dialog.noFrame, "BOTTOMRIGHT", -28, 8)
        
        dialog.noContent = CreateFrame("Frame", nil, dialog.noScroll)
        dialog.noContent:SetSize(230, 1)
        dialog.noScroll:SetScrollChild(dialog.noContent)
        
        dialog.noText = dialog.noContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.noText:SetPoint("TOPLEFT", dialog.noContent, "TOPLEFT", 0, 0)
        dialog.noText:SetWidth(230)
        dialog.noText:SetJustifyH("LEFT")
        
        -- Bottom row: Full width (Pending Bets)
        dialog.pendingFrame = CreateFrame("Frame", nil, dialog, "InsetFrameTemplate")
        dialog.pendingFrame:SetPoint("TOPLEFT", dialog.yesFrame, "BOTTOMLEFT", 0, -10)
        dialog.pendingFrame:SetPoint("TOPRIGHT", dialog.noFrame, "BOTTOMRIGHT", 0, -10)
        dialog.pendingFrame:SetHeight(80)
        
        dialog.pendingTitle = dialog.pendingFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dialog.pendingTitle:SetPoint("TOP", dialog.pendingFrame, "TOP", 0, -8)
        dialog.pendingTitle:SetText(COLOR_ORANGE .. "PENDING BETS" .. COLOR_RESET)
        
        dialog.pendingScroll = CreateFrame("ScrollFrame", nil, dialog.pendingFrame, "UIPanelScrollFrameTemplate")
        dialog.pendingScroll:SetPoint("TOPLEFT", dialog.pendingFrame, "TOPLEFT", 8, -30)
        dialog.pendingScroll:SetPoint("BOTTOMRIGHT", dialog.pendingFrame, "BOTTOMRIGHT", -28, 8)
        
        dialog.pendingContent = CreateFrame("Frame", nil, dialog.pendingScroll)
        dialog.pendingContent:SetSize(540, 1)
        dialog.pendingScroll:SetScrollChild(dialog.pendingContent)
        
        dialog.pendingText = dialog.pendingContent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.pendingText:SetPoint("TOPLEFT", dialog.pendingContent, "TOPLEFT", 0, 0)
        dialog.pendingText:SetWidth(540)
        dialog.pendingText:SetJustifyH("LEFT")
        
        -- Resolution buttons (shown only if bet creator)
        dialog.yesWinsButton = CreateFrame("Button", nil, dialog.yesFrame, "UIPanelButtonTemplate")
        dialog.yesWinsButton:SetSize(80, 22)
        dialog.yesWinsButton:SetPoint("BOTTOM", dialog.yesFrame, "BOTTOM", 0, 8)
        dialog.yesWinsButton:SetText("YES Wins")
        dialog.yesWinsButton:SetScript("OnClick", function()
            if dialog.currentBetId then
                FuldStonks:ResolveBet(dialog.currentBetId, "Yes")
                dialog:Hide()
            end
        end)
        
        dialog.noWinsButton = CreateFrame("Button", nil, dialog.noFrame, "UIPanelButtonTemplate")
        dialog.noWinsButton:SetSize(80, 22)
        dialog.noWinsButton:SetPoint("BOTTOM", dialog.noFrame, "BOTTOM", 0, 8)
        dialog.noWinsButton:SetText("NO Wins")
        dialog.noWinsButton:SetScript("OnClick", function()
            if dialog.currentBetId then
                FuldStonks:ResolveBet(dialog.currentBetId, "No")
                dialog:Hide()
            end
        end)
        
        -- Cancel bet button (shown only if bet creator)
        dialog.cancelBetButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.cancelBetButton:SetSize(100, 25)
        dialog.cancelBetButton:SetPoint("BOTTOM", dialog, "BOTTOM", -55, 15)
        dialog.cancelBetButton:SetText("Cancel Bet")
        dialog.cancelBetButton:SetScript("OnClick", function()
            if dialog.currentBetId then
                StaticPopup_Show("FULDSTONKS_CONFIRM_CANCEL", nil, nil, dialog.currentBetId)
            end
        end)
        
        -- Close button
        dialog.closeButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.closeButton:SetSize(100, 25)
        dialog.closeButton:SetPoint("BOTTOM", dialog, "BOTTOM", 55, 15)
        dialog.closeButton:SetText("Close")
        dialog.closeButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        dialog.CloseButton:SetScript("OnClick", function()
            dialog:Hide()
        end)
        
        self.inspectDialog = dialog
    end
    
    -- Set bet info
    self.inspectDialog.betTitle:SetText(COLOR_YELLOW .. bet.title .. COLOR_RESET)
    self.inspectDialog.currentBetId = betId
    
    local infoText = "Total Pot: " .. COLOR_GREEN .. bet.totalPot .. "g" .. COLOR_RESET .. " (confirmed only) • Created by: " .. GetPlayerBaseName(bet.createdBy)
    self.inspectDialog.infoText:SetText(infoText)
    
    -- Show/hide resolution buttons based on whether player is bet creator
    local isCreator = (bet.createdBy == playerFullName)
    self.inspectDialog.yesWinsButton:SetShown(isCreator)
    self.inspectDialog.noWinsButton:SetShown(isCreator)
    self.inspectDialog.cancelBetButton:SetShown(isCreator)
    
    -- Group participants by option
    local optionGroups = {}
    for playerName, participation in pairs(bet.participants) do
        if not optionGroups[participation.option] then
            optionGroups[participation.option] = {}
        end
        table.insert(optionGroups[participation.option], {name = playerName, amount = participation.amount})
    end
    
    -- Sort participants within each group by amount (highest first)
    for option, group in pairs(optionGroups) do
        table.sort(group, function(a, b) return a.amount > b.amount end)
    end
    
    -- Build Yes section
    local yesGroup = optionGroups["Yes"] or {}
    local yesTotalBets = 0
    for _, p in ipairs(yesGroup) do
        yesTotalBets = yesTotalBets + p.amount
    end
    
    local yesInfo = #yesGroup .. " bets • " .. COLOR_GREEN .. yesTotalBets .. "g" .. COLOR_RESET
    if yesTotalBets > 0 and bet.totalPot > 0 then
        local percentage = math.floor((yesTotalBets / bet.totalPot) * 100)
        yesInfo = yesInfo .. " (" .. percentage .. "%)"
    end
    yesInfo = yesInfo .. "\n\n"
    
    if #yesGroup > 0 then
        for _, p in ipairs(yesGroup) do
            local baseName = GetPlayerBaseName(p.name)
            if bet.totalPot > 0 then
                local percentage = math.floor((p.amount / bet.totalPot) * 100)
                yesInfo = yesInfo .. baseName .. "\n" .. COLOR_GREEN .. p.amount .. "g" .. COLOR_RESET .. " (" .. percentage .. "%)\n\n"
            else
                yesInfo = yesInfo .. baseName .. "\n" .. COLOR_GREEN .. p.amount .. "g" .. COLOR_RESET .. "\n\n"
            end
        end
    else
        yesInfo = yesInfo .. COLOR_GRAY .. "No bets placed" .. COLOR_RESET .. "\n"
    end
    
    self.inspectDialog.yesText:SetText(yesInfo)
    local yesHeight = self.inspectDialog.yesText:GetStringHeight()
    self.inspectDialog.yesContent:SetHeight(math.max(yesHeight + 20, 100))
    
    -- Build No section
    local noGroup = optionGroups["No"] or {}
    local noTotalBets = 0
    for _, p in ipairs(noGroup) do
        noTotalBets = noTotalBets + p.amount
    end
    
    local noInfo = #noGroup .. " bets • " .. COLOR_RED .. noTotalBets .. "g" .. COLOR_RESET
    if noTotalBets > 0 and bet.totalPot > 0 then
        local percentage = math.floor((noTotalBets / bet.totalPot) * 100)
        noInfo = noInfo .. " (" .. percentage .. "%)"
    end
    noInfo = noInfo .. "\n\n"
    
    if #noGroup > 0 then
        for _, p in ipairs(noGroup) do
            local baseName = GetPlayerBaseName(p.name)
            if bet.totalPot > 0 then
                local percentage = math.floor((p.amount / bet.totalPot) * 100)
                noInfo = noInfo .. baseName .. "\n" .. COLOR_RED .. p.amount .. "g" .. COLOR_RESET .. " (" .. percentage .. "%)\n\n"
            else
                noInfo = noInfo .. baseName .. "\n" .. COLOR_RED .. p.amount .. "g" .. COLOR_RESET .. "\n\n"
            end
        end
    else
        noInfo = noInfo .. COLOR_GRAY .. "No bets placed" .. COLOR_RESET .. "\n"
    end
    
    self.inspectDialog.noText:SetText(noInfo)
    local noHeight = self.inspectDialog.noText:GetStringHeight()
    self.inspectDialog.noContent:SetHeight(math.max(noHeight + 20, 100))
    
    -- Build pending bets section
    local pendingInfo = ""
    local hasPendingBets = false
    
    for playerName, pendingBet in pairs(self.pendingBets) do
        if pendingBet.betId == betId then
            hasPendingBets = true
            local baseName = GetPlayerBaseName(playerName)
            local optionColor = pendingBet.option == "Yes" and COLOR_GREEN or COLOR_RED
            pendingInfo = pendingInfo .. COLOR_ORANGE .. "⏳" .. COLOR_RESET .. " " .. baseName .. " • " .. optionColor .. pendingBet.option .. COLOR_RESET .. " • " .. pendingBet.amount .. "g • " .. COLOR_ORANGE .. "Awaiting trade" .. COLOR_RESET .. "\n\n"
        end
    end
    
    if not hasPendingBets then
        if bet.totalPot == 0 then
            pendingInfo = COLOR_GRAY .. "No bets or pending bets yet" .. COLOR_RESET
        else
            pendingInfo = COLOR_GRAY .. "No pending bets" .. COLOR_RESET
        end
    end
    
    self.inspectDialog.pendingText:SetText(pendingInfo)
    local pendingHeight = self.inspectDialog.pendingText:GetStringHeight()
    self.inspectDialog.pendingContent:SetHeight(math.max(pendingHeight + 20, 80))
    
    self.inspectDialog:Show()
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
        print("  /FuldStonks create - Create a new bet")
        print("  /FuldStonks pending - Show pending bets (bet creator only)")
        print("  /FuldStonks cancel - Cancel your pending bet")
        print("  /FuldStonks resolve - Resolve a bet you created")
        print("  /FuldStonks showhidden - Show list of hidden bets")
        print("  /FuldStonks unhideall - Unhide all hidden bets")
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
            local baseName = GetPlayerBaseName(name)
            print("  " .. baseName .. " (seen " .. timeSince .. "s ago)")
            count = count + 1
        end
        if count == 0 then
            print("  No peers connected yet.")
        end
    elseif command == "debug" then
        FuldStonksDB.debug = not FuldStonksDB.debug
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Debug mode: " .. (FuldStonksDB.debug and "ON" or "OFF"))
    elseif command == "create" then
        -- Show bet creation dialog
        FuldStonks:ShowBetCreationDialog()
    elseif command == "cancel" then
        -- Cancel pending bet
        FuldStonks:CancelPendingBet()
    elseif command == "resolve" then
        -- Show bet resolution dialog
        FuldStonks:ShowBetResolutionDialog()
    elseif command == "pending" then
        -- Show pending bets (bet creator only)
        local count = 0
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Pending bets awaiting trade:")
        for playerName, pendingBet in pairs(FuldStonks.pendingBets) do
            local bet = FuldStonksDB.activeBets[pendingBet.betId]
            if bet then
                local baseName = GetPlayerBaseName(playerName)
                local timeAgo = math.floor(GetTime() - pendingBet.timestamp)
                print("  " .. baseName .. ": " .. pendingBet.amount .. "g on " .. COLOR_YELLOW .. pendingBet.option .. COLOR_RESET .. " (" .. timeAgo .. "s ago)")
                print("    Bet: " .. bet.title)
                count = count + 1
            end
        end
        if count == 0 then
            print("  No pending bets.")
        end
    elseif command == "showhidden" then
        FuldStonks:ShowHiddenBets()
    elseif command == "unhideall" then
        FuldStonks:UnhideAllBets()
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

-- Message types (State-based sync model)
local MSG_STATE_SYNC = "STATESYNC"  -- Full state broadcast (sent every 5s)
local MSG_SYNC_REQUEST = "SYNCREQ"  -- Request full state sync on demand
local MSG_BET_PENDING = "BETPND"    -- Pending bet notification (sent to bet creator immediately)

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

-- Serialize data for transmission (use ASCII control character as delimiter)
local DELIMITER = "\001"  -- ASCII SOH (Start of Heading) - safe delimiter

local function SerializeMessage(msgType, ...)
    local parts = {msgType}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        table.insert(parts, tostring(v))
    end
    return table.concat(parts, DELIMITER)
end

-- Deserialize received message
local function DeserializeMessage(message)
    local parts = {strsplit(DELIMITER, message)}
    local msgType = parts[1]
    -- Use unpack starting from index 2 to avoid expensive table.remove
    return msgType, unpack(parts, 2)
end

-- ============================================
-- STATE SYNCHRONIZATION SYSTEM
-- ============================================

-- Increment Lamport clock for state versioning
local function IncrementStateVersion()
    FuldStonksDB.stateVersion = (FuldStonksDB.stateVersion or 0) + 1
    DebugPrint("State version incremented to: " .. FuldStonksDB.stateVersion)
    return FuldStonksDB.stateVersion
end

-- Update Lamport clock when receiving a message
local function UpdateStateVersion(receivedVersion)
    local currentVersion = FuldStonksDB.stateVersion or 0
    FuldStonksDB.stateVersion = math.max(currentVersion, receivedVersion) + 1
    DebugPrint("State version updated to: " .. FuldStonksDB.stateVersion .. " (received: " .. receivedVersion .. ")")
end

-- Serialize a single bet for transmission
local function SerializeBetForSync(bet)
    -- Format: id^title^betType^options^createdBy^timestamp^status^totalPot^stateVersion
    local options = table.concat(bet.options, ",")
    local parts = {
        bet.id,
        bet.title,
        bet.betType,
        options,
        bet.createdBy,
        tostring(bet.timestamp),
        bet.status or "active",
        tostring(bet.totalPot or 0),
        tostring(bet.stateVersion or 0)
    }
    return table.concat(parts, "^")
end

-- Deserialize a bet from sync message
local function DeserializeBetFromSync(betString)
    local parts = {strsplit("^", betString)}
    if #parts < 9 then 
        DebugPrint("Invalid bet string, not enough parts: " .. #parts)
        return nil 
    end
    
    local bet = {
        id = parts[1],
        title = parts[2],
        betType = parts[3],
        options = {strsplit(",", parts[4])},
        createdBy = parts[5],
        timestamp = tonumber(parts[6]) or 0,
        status = parts[7],
        totalPot = tonumber(parts[8]) or 0,
        stateVersion = tonumber(parts[9]) or 0,
        participants = {},
        pendingTrades = {}
    }
    return bet
end

-- Serialize a participant entry
local function SerializeParticipant(playerName, participation)
    -- Format: playerName~option~amount~confirmed~timestamp
    return playerName .. "~" .. participation.option .. "~" .. tostring(participation.amount) .. "~" .. 
           tostring(participation.confirmed or true) .. "~" .. tostring(participation.timestamp or GetTime())
end

-- Deserialize a participant entry
local function DeserializeParticipant(participantString)
    local parts = {strsplit("~", participantString)}
    if #parts < 5 then return nil end
    
    return parts[1], {
        option = parts[2],
        amount = tonumber(parts[3]) or 0,
        confirmed = (parts[4] == "true"),
        timestamp = tonumber(parts[5]) or 0
    }
end

-- Create a snapshot of current addon state
function FuldStonks:CreateStateSnapshot()
    local snapshot = {
        version = FuldStonksDB.stateVersion or 0,
        nonce = (FuldStonksDB.syncNonce or 0) + 1,
        timestamp = GetTime(),
        bets = {},
        participants = {}  -- Separate participant data
    }
    
    FuldStonksDB.syncNonce = snapshot.nonce
    
    -- Collect all active bets
    for betId, bet in pairs(FuldStonksDB.activeBets) do
        if bet.status == "active" then
            table.insert(snapshot.bets, {
                id = betId,
                data = SerializeBetForSync(bet)
            })
            
            -- Collect participants for this bet
            for playerName, participation in pairs(bet.participants or {}) do
                table.insert(snapshot.participants, {
                    betId = betId,
                    data = SerializeParticipant(playerName, participation)
                })
            end
        end
    end
    
    return snapshot
end

-- Broadcast full state sync
function FuldStonks:BroadcastStateSync()
    local snapshot = self:CreateStateSnapshot()
    
    -- Send bet data in chunks (WoW has 255 char limit per message)
    -- Format: STATESYNC|version|nonce|betCount|participantCount
    local header = SerializeMessage(MSG_STATE_SYNC, "HEADER", snapshot.version, snapshot.nonce, #snapshot.bets, #snapshot.participants)
    
    if #header <= 255 then
        C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, header, GetBroadcastChannel())
        DebugPrint("Sent state sync header: v" .. snapshot.version .. " nonce:" .. snapshot.nonce .. " bets:" .. #snapshot.bets .. " participants:" .. #snapshot.participants)
    end
    
    -- Send each bet
    for i, betData in ipairs(snapshot.bets) do
        local betMsg = SerializeMessage(MSG_STATE_SYNC, "BET", snapshot.nonce, i, betData.id, betData.data)
        if #betMsg <= 255 then
            C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, betMsg, GetBroadcastChannel())
        else
            DebugPrint("Bet message too long (" .. #betMsg .. " chars), skipping: " .. betData.id)
        end
    end
    
    -- Send participant data
    for i, participantData in ipairs(snapshot.participants) do
        local partMsg = SerializeMessage(MSG_STATE_SYNC, "PARTICIPANT", snapshot.nonce, i, participantData.betId, participantData.data)
        if #partMsg <= 255 then
            C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, partMsg, GetBroadcastChannel())
        else
            DebugPrint("Participant message too long, skipping")
        end
    end
    
    self.lastBroadcast = GetTime()
end

-- Merge received state with local state
function FuldStonks:MergeState(receivedBets, receivedParticipants, senderVersion, sender)
    local changesMade = false
    local conflicts = 0
    
    -- Update our Lamport clock
    UpdateStateVersion(senderVersion)
    
    DebugPrint("Merging state from " .. sender .. " (v" .. senderVersion .. ")")
    
    -- Process each received bet
    for betId, receivedBet in pairs(receivedBets) do
        local localBet = FuldStonksDB.activeBets[betId]
        
        if not localBet then
            -- New bet we don't have - accept it
            FuldStonksDB.activeBets[betId] = receivedBet
            changesMade = true
            DebugPrint("  Added new bet: " .. betId)
            
            local creatorName = GetPlayerBaseName(receivedBet.createdBy)
            print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. creatorName .. " created bet: " .. receivedBet.title)
            
        elseif receivedBet.stateVersion > (localBet.stateVersion or 0) then
            -- Received bet is newer - update it
            -- Preserve local participants if they're newer
            local localParticipants = localBet.participants
            FuldStonksDB.activeBets[betId] = receivedBet
            
            -- Merge participants (will be handled separately)
            receivedBet.participants = localParticipants or {}
            
            changesMade = true
            DebugPrint("  Updated bet: " .. betId .. " (v" .. receivedBet.stateVersion .. " > v" .. (localBet.stateVersion or 0) .. ")")
            
        elseif receivedBet.stateVersion == (localBet.stateVersion or 0) then
            -- Same version - use tie-breaker (creator name lexicographically)
            if receivedBet.createdBy < localBet.createdBy then
                FuldStonksDB.activeBets[betId] = receivedBet
                conflicts = conflicts + 1
                changesMade = true
                DebugPrint("  Conflict resolved for bet: " .. betId .. " (chose " .. receivedBet.createdBy .. "'s version)")
            end
        end
        -- else: local bet is newer, keep it
    end
    
    -- Process participants
    for betId, participants in pairs(receivedParticipants) do
        local bet = FuldStonksDB.activeBets[betId]
        if bet then
            for playerName, participation in pairs(participants) do
                local localParticipation = bet.participants[playerName]
                
                if not localParticipation then
                    -- New participant
                    bet.participants[playerName] = participation
                    bet.totalPot = (bet.totalPot or 0) + participation.amount
                    changesMade = true
                    
                    local baseName = GetPlayerBaseName(playerName)
                    if not FuldStonksDB.ignoredBets[betId] then
                        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. baseName .. " bet " .. participation.amount .. "g on " .. COLOR_YELLOW .. participation.option .. COLOR_RESET .. " | Pot now: " .. bet.totalPot .. "g")
                    end
                    
                elseif (participation.timestamp or 0) > (localParticipation.timestamp or 0) then
                    -- Received participant data is newer
                    local oldAmount = localParticipation.amount
                    bet.participants[playerName] = participation
                    bet.totalPot = (bet.totalPot or 0) - oldAmount + participation.amount
                    changesMade = true
                    DebugPrint("  Updated participant: " .. playerName .. " in bet " .. betId)
                end
            end
        end
    end
    
    if conflicts > 0 then
        DebugPrint("Resolved " .. conflicts .. " conflicts during merge")
    end
    
    -- Update UI if changes were made
    if changesMade and self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
    
    return changesMade
end

-- Send addon message (simplified for state-based sync)
function FuldStonks:BroadcastMessage(msgType, ...)
    local channel = GetBroadcastChannel()
    local message = SerializeMessage(msgType, ...)
    
    -- Check message length (WoW limit is 255 chars)
    if #message > 255 then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Message too long (" .. #message .. " chars)")
        return false
    end
    
    C_ChatInfo.SendAddonMessage(MESSAGE_PREFIX, message, channel)
    DebugPrint("Sent " .. msgType .. " to " .. channel)
    return true
end

-- Initialize addon communication
local function InitializeAddonComms()
    -- Register addon message prefix
    C_ChatInfo.RegisterAddonMessagePrefix(MESSAGE_PREFIX)
    DebugPrint("Addon message prefix registered: " .. MESSAGE_PREFIX)
end

-- Request full sync from other players (on-demand)
function FuldStonks:RequestSync()
    self:BroadcastMessage(MSG_SYNC_REQUEST)
    self.syncRequested = true
    DebugPrint("Sync requested from peers")
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
    
    local msgType, arg1, arg2, arg3, arg4, arg5 = DeserializeMessage(message)
    local now = GetTime()
    
    DebugPrint("Received " .. msgType .. " from " .. sender .. " [" .. channel .. "]")
    
    -- Update peer tracking
    if not FuldStonks.peers[sender] then
        FuldStonks.peers[sender] = {
            lastSeen = now,
            stateVersion = 0,
            nonce = 0
        }
        local baseName = GetPlayerBaseName(sender)
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. baseName .. " connected!")
    end
    FuldStonks.peers[sender].lastSeen = now
    
    -- Handle different message types
    if msgType == MSG_STATE_SYNC then
        local syncType = arg1  -- HEADER, BET, or PARTICIPANT
        
        if syncType == "HEADER" then
            -- State sync header: version, nonce, betCount, participantCount
            local version = tonumber(arg2) or 0
            local nonce = tonumber(arg3) or 0
            local betCount = tonumber(arg4) or 0
            local participantCount = tonumber(arg5) or 0
            
            FuldStonks.peers[sender].stateVersion = version
            FuldStonks.peers[sender].nonce = nonce
            
            -- Initialize pending state update for this nonce
            if not FuldStonks.pendingStateUpdates[sender] then
                FuldStonks.pendingStateUpdates[sender] = {}
            end
            
            FuldStonks.pendingStateUpdates[sender][nonce] = {
                version = version,
                expectedBets = betCount,
                expectedParticipants = participantCount,
                receivedBets = {},
                receivedParticipants = {},
                timestamp = now
            }
            
            DebugPrint("State sync started from " .. sender .. ": v" .. version .. " nonce:" .. nonce .. " expecting " .. betCount .. " bets, " .. participantCount .. " participants")
            
        elseif syncType == "BET" then
            -- Bet data: nonce, index, betId, serializedBet
            local nonce = tonumber(arg2) or 0
            local index = tonumber(arg3) or 0
            local betId = arg4
            local betData = arg5
            
            if FuldStonks.pendingStateUpdates[sender] and FuldStonks.pendingStateUpdates[sender][nonce] then
                local bet = DeserializeBetFromSync(betData)
                if bet then
                    FuldStonks.pendingStateUpdates[sender][nonce].receivedBets[betId] = bet
                    DebugPrint("  Received bet " .. index .. "/" .. FuldStonks.pendingStateUpdates[sender][nonce].expectedBets .. ": " .. betId)
                    
                    -- Check if we've received all expected data
                    FuldStonks:CheckAndApplyStateUpdate(sender, nonce)
                end
            end
            
        elseif syncType == "PARTICIPANT" then
            -- Participant data: nonce, index, betId, serializedParticipant
            local nonce = tonumber(arg2) or 0
            local index = tonumber(arg3) or 0
            local betId = arg4
            local participantData = arg5
            
            if FuldStonks.pendingStateUpdates[sender] and FuldStonks.pendingStateUpdates[sender][nonce] then
                local playerName, participation = DeserializeParticipant(participantData)
                if playerName and participation then
                    if not FuldStonks.pendingStateUpdates[sender][nonce].receivedParticipants[betId] then
                        FuldStonks.pendingStateUpdates[sender][nonce].receivedParticipants[betId] = {}
                    end
                    FuldStonks.pendingStateUpdates[sender][nonce].receivedParticipants[betId][playerName] = participation
                    DebugPrint("  Received participant " .. index .. "/" .. FuldStonks.pendingStateUpdates[sender][nonce].expectedParticipants .. " for bet " .. betId)
                    
                    -- Check if we've received all expected data
                    FuldStonks:CheckAndApplyStateUpdate(sender, nonce)
                end
            end
        end
        
    elseif msgType == MSG_SYNC_REQUEST then
        DebugPrint(sender .. " requested sync")
        -- Send our current state immediately
        FuldStonks:BroadcastStateSync()
        
    elseif msgType == MSG_BET_PENDING then
        -- Handle pending bet notification (received by bet creator)
        -- This still sends immediately for better UX
        local betId = arg1
        local option = arg2
        local amount = tonumber(arg3) or 0
        
        DebugPrint("Received pending bet notification from " .. sender .. ": " .. betId .. " | " .. option .. " | " .. amount .. "g")
        
        local bet = FuldStonksDB.activeBets[betId]
        if bet and bet.createdBy == playerFullName then
            -- Store pending bet info from this player
            FuldStonks.pendingBets[sender] = {
                betId = betId,
                option = option,
                amount = amount,
                timestamp = GetTime()
            }
            
            local baseName = GetPlayerBaseName(sender)
            print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. baseName .. " wants to bet " .. amount .. "g on " .. COLOR_YELLOW .. option .. COLOR_RESET)
            print("  Bet: " .. bet.title)
            print("  " .. COLOR_YELLOW .. "Accept their trade to confirm the bet" .. COLOR_RESET)
            
            DebugPrint("Stored pending bet for " .. sender)
        else
            DebugPrint("Bet not found or I'm not the creator, ignoring pending bet notification")
        end
        
    else
        DebugPrint("Unknown message type: " .. tostring(msgType))
    end
end

-- Check if we've received complete state update and apply it
function FuldStonks:CheckAndApplyStateUpdate(sender, nonce)
    local update = self.pendingStateUpdates[sender] and self.pendingStateUpdates[sender][nonce]
    if not update then return end
    
    local receivedBetCount = 0
    for _ in pairs(update.receivedBets) do
        receivedBetCount = receivedBetCount + 1
    end
    
    local receivedParticipantCount = 0
    for _, participants in pairs(update.receivedParticipants) do
        for _ in pairs(participants) do
            receivedParticipantCount = receivedParticipantCount + 1
        end
    end
    
    -- Check if we have all the data
    if receivedBetCount >= update.expectedBets and receivedParticipantCount >= update.expectedParticipants then
        DebugPrint("Complete state received from " .. sender .. " (nonce:" .. nonce .. "), applying...")
        
        -- Apply the state update
        self:MergeState(update.receivedBets, update.receivedParticipants, update.version, sender)
        
        -- Clean up
        self.pendingStateUpdates[sender][nonce] = nil
        
        -- Clean up old pending updates (older than 30 seconds)
        local now = GetTime()
        for peerName, nonces in pairs(self.pendingStateUpdates) do
            for n, upd in pairs(nonces) do
                if now - upd.timestamp > 30 then
                    DebugPrint("Cleaned up stale state update from " .. peerName .. " nonce:" .. n)
                    self.pendingStateUpdates[peerName][n] = nil
                end
            end
        end
    end
end

-- ============================================
-- TRADE HANDLING FOR BET HOLDER
-- ============================================

-- Track trade information
FuldStonks.currentTrade = {
    player = nil,
    amount = 0,
    betInfo = nil,
    traderName = nil,
    goldBefore = 0
}

-- Handle trade window opening
local function OnTradeShow()
    local tradeName = UnitName("NPC")
    if not tradeName then return end
    
    -- Get full name with realm
    local _, tradeRealm = UnitFullName("NPC")
    local tradeFullName = (tradeRealm and tradeRealm ~= "" and (tradeName .. "-" .. tradeRealm)) or tradeName
    
    FuldStonks.currentTrade.player = tradeFullName
    FuldStonks.currentTrade.amount = 0
    FuldStonks.currentTrade.betInfo = nil
    FuldStonks.currentTrade.goldBefore = math.floor(GetMoney() / 10000)  -- Store current gold
    
    DebugPrint("Trade window opened with: " .. tradeFullName)
    DebugPrint("Current gold: " .. FuldStonks.currentTrade.goldBefore .. "g")
    
    -- SCENARIO 1: Check if YOU have a pending bet and are trading TO the bet creator
    DebugPrint("Checking if I have a pending bet to trade with: " .. tradeFullName)
    local myPendingBet = FuldStonks.pendingBets[playerFullName]
    if myPendingBet then
        DebugPrint("  I have a pending bet for betId: " .. myPendingBet.betId)
        local bet = FuldStonksDB.activeBets[myPendingBet.betId]
        if bet then
            DebugPrint("  Bet found. Creator: " .. bet.createdBy)
            local betCreatorBaseName = GetPlayerBaseName(bet.createdBy)
            local tradeBaseName = GetPlayerBaseName(tradeFullName)
            
            -- Check if the person we're trading with is the bet creator
            if bet.createdBy == tradeFullName or betCreatorBaseName == tradeBaseName then
                DebugPrint("  Trading with bet creator! Setting up trade confirmation.")
                FuldStonks.currentTrade.betInfo = myPendingBet
                FuldStonks.currentTrade.traderName = playerFullName  -- I am the trader
                print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Trading gold for your bet:")
                print("  Bet: " .. bet.title)
                print("  Amount: " .. myPendingBet.amount .. "g")
                print("  Option: " .. myPendingBet.option)
                return
            else
                DebugPrint("  Creator doesn't match trader: '" .. bet.createdBy .. "' vs '" .. tradeFullName .. "'")
            end
        else
            DebugPrint("  Bet not found in activeBets")
        end
    else
        DebugPrint("  I don't have a pending bet")
    end
    
    -- SCENARIO 2: Check if someone is trading TO YOU for a bet you created
    DebugPrint("Checking if trader has pending bet with me (bet creator)")
    local foundMatch = false
    for playerName, pendingBet in pairs(FuldStonks.pendingBets) do
        DebugPrint("  Pending bet from: " .. playerName .. " for betId: " .. pendingBet.betId)
        local playerBaseName = GetPlayerBaseName(playerName)
        local tradeBaseName = GetPlayerBaseName(tradeFullName)
        
        -- Match by full name OR base name (for same-realm players)
        if playerName == tradeFullName or playerBaseName == tradeBaseName then
            DebugPrint("    Name matches! Checking bet...")
            local bet = FuldStonksDB.activeBets[pendingBet.betId]
            if bet then
                DebugPrint("    Bet found. Creator: " .. bet.createdBy .. ", Me: " .. playerFullName)
                -- Only accept trades if we are the bet creator
                if bet.createdBy == playerFullName then
                    FuldStonks.currentTrade.betInfo = pendingBet
                    FuldStonks.currentTrade.traderName = playerName  -- Store the actual key used in pendingBets
                    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Receiving gold for bet:")
                    print("  Bet: " .. bet.title)
                    print("  Expected: " .. pendingBet.amount .. "g")
                    DebugPrint("Trade opened with " .. tradeBaseName .. " who has pending bet for " .. pendingBet.amount .. "g")
                    foundMatch = true
                    break
                else
                    DebugPrint("    Not the bet creator, skipping")
                end
            else
                DebugPrint("    Bet not found in activeBets")
            end
        else
            DebugPrint("    Name doesn't match: '" .. playerName .. "' vs '" .. tradeFullName .. "' (base: '" .. playerBaseName .. "' vs '" .. tradeBaseName .. "')")
        end
    end
    if not foundMatch then
        DebugPrint("No matching pending bet found for this trade")
    end
end

-- Handle gold being added to trade
local function OnTradeMoneyChanged()
    local targetGold = GetTargetTradeMoney()
    
    -- Track the amount being received (convert copper to gold)
    FuldStonks.currentTrade.amount = math.floor(targetGold / 10000)
    
    DebugPrint("Trade money changed: receiving " .. FuldStonks.currentTrade.amount .. "g")
    
    if FuldStonks.currentTrade.betInfo then
        local bet = FuldStonksDB.activeBets[FuldStonks.currentTrade.betInfo.betId]
        if bet and bet.createdBy == playerFullName then
            local expected = FuldStonks.currentTrade.betInfo.amount
            if FuldStonks.currentTrade.amount == expected then
                local traderName = GetPlayerBaseName(FuldStonks.currentTrade.player)
                print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. traderName .. " is trading the correct amount: " .. expected .. "g")
            elseif FuldStonks.currentTrade.amount > 0 then
                print(COLOR_YELLOW .. "FuldStonks" .. COLOR_RESET .. " Warning: Expected " .. expected .. "g but receiving " .. FuldStonks.currentTrade.amount .. "g")
            end
        end
    end
end

-- Handle trade accept button updates
local function OnTradeAcceptUpdate(player, target)
    DebugPrint("Trade accept update: player=" .. player .. ", target=" .. target)
    if player == 1 and target == 1 then
        DebugPrint("Both players have accepted the trade")
    end
end

-- Handle trade window closing (check if money increased)
local function OnTradeClosed()
    DebugPrint("Trade window closed")
    
    if FuldStonks.currentTrade.betInfo and FuldStonks.currentTrade.amount > 0 then
        -- Store trade info locally before clearing (C_Timer callback needs it)
        local tradeInfo = {
            betInfo = FuldStonks.currentTrade.betInfo,
            goldBefore = FuldStonks.currentTrade.goldBefore,
            traderName = FuldStonks.currentTrade.traderName or FuldStonks.currentTrade.player
        }
        
        -- Delay gold check slightly because TRADE_CLOSED fires before gold is added
        C_Timer.After(0.5, function()
            -- Check if our money increased by the expected amount
            local currentGold = math.floor(GetMoney() / 10000)
            local goldIncrease = currentGold - tradeInfo.goldBefore
            
            DebugPrint("Gold before trade: " .. tradeInfo.goldBefore .. "g, after: " .. currentGold .. "g, increase: " .. goldIncrease .. "g")
            
            local pendingBet = tradeInfo.betInfo
            local traderName = tradeInfo.traderName
            local bet = FuldStonksDB.activeBets[pendingBet.betId]
            
            -- Only confirm if we are the bet creator and received the correct amount
            if bet and bet.createdBy == playerFullName then
                if goldIncrease == pendingBet.amount then
                    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Trade completed successfully! Confirming bet...")
                    DebugPrint("Received " .. goldIncrease .. "g, matches expected " .. pendingBet.amount .. "g")
                    
                    -- Confirm the bet
                    FuldStonks:ConfirmBetTrade(traderName, pendingBet.betId, pendingBet.option, pendingBet.amount)
                    
                    -- Remove from pending
                    FuldStonks.pendingBets[traderName] = nil
                    
                    DebugPrint("Removed pending bet for " .. traderName)
                elseif goldIncrease > 0 then
                    print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Trade amount mismatch! Expected " .. pendingBet.amount .. "g but received " .. goldIncrease .. "g")
                else
                    DebugPrint("Trade was cancelled or failed - no gold received")
                end
            end
        end)
    end
    
    -- Clear trade info
    FuldStonks.currentTrade = {
        player = nil,
        amount = 0,
        betInfo = nil,
        traderName = nil,
        goldBefore = 0
    }
end

-- Event handler
eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            Initialize()
            InitializeAddonComms()
            FuldStonks:LoadData()
            
            -- Initialize debug mode if not set
            if FuldStonksDB.debug == nil then
                FuldStonksDB.debug = false
            end
            
            -- Initialize state versioning
            if not FuldStonksDB.stateVersion then
                FuldStonksDB.stateVersion = 0
            end
            if not FuldStonksDB.syncNonce then
                FuldStonksDB.syncNonce = 0
            end
            
            -- Start state sync timer (every 5 seconds)
            if FuldStonks.syncTicker then
                FuldStonks.syncTicker:Cancel()
            end
            FuldStonks.syncTicker = C_Timer.NewTicker(5, function()
                FuldStonks:BroadcastStateSync()
            end)
            
            -- Send initial state sync after a short delay
            C_Timer.After(2.0, function()
                FuldStonks:BroadcastStateSync()
            end)
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessageReceived(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Debounce roster updates to prevent spam
        if FuldStonks.rosterUpdateTimer then
            FuldStonks.rosterUpdateTimer:Cancel()
        end
        FuldStonks.rosterUpdateTimer = C_Timer.NewTimer(1.5, function()
            FuldStonks:BroadcastStateSync()  -- Sync state on roster change
            FuldStonks.rosterUpdateTimer = nil
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Entering world/instance, request sync and broadcast our state
        C_Timer.After(2.0, function()
            FuldStonks:BroadcastStateSync()
            FuldStonks:RequestSync()
        end)
    elseif event == "PLAYER_LOGOUT" then
        -- Clean up timers on logout
        if FuldStonks.syncTicker then
            FuldStonks.syncTicker:Cancel()
            FuldStonks.syncTicker = nil
        end
        if FuldStonks.rosterUpdateTimer then
            FuldStonks.rosterUpdateTimer:Cancel()
            FuldStonks.rosterUpdateTimer = nil
        end
    elseif event == "TRADE_SHOW" then
        OnTradeShow()
    elseif event == "TRADE_MONEY_CHANGED" then
        OnTradeMoneyChanged()
    elseif event == "TRADE_ACCEPT_UPDATE" then
        OnTradeAcceptUpdate(...)
    elseif event == "TRADE_CLOSED" then
        OnTradeClosed()
    end
end)

-- Register events
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("TRADE_SHOW")
eventFrame:RegisterEvent("TRADE_MONEY_CHANGED")
eventFrame:RegisterEvent("TRADE_ACCEPT_UPDATE")
eventFrame:RegisterEvent("TRADE_CLOSED")

-- ============================================
-- FUTURE EXPANSION HOOKS
-- ============================================

-- Hook for bet management
function FuldStonks:CreateBet(betData)
    -- Generate unique bet ID
    local betId = GenerateBetId()
    
    -- Increment state version
    local stateVersion = IncrementStateVersion()
    
    -- Create bet object
    local bet = {
        id = betId,
        title = betData.title,
        betType = betData.betType or "YesNo",
        options = betData.options or {"Yes", "No"},
        createdBy = playerFullName,
        timestamp = GetTime(),
        participants = {},
        totalPot = 0,
        status = "active",
        stateVersion = stateVersion,
        pendingTrades = {}  -- Track pending gold trades
    }
    
    -- Add to active bets
    FuldStonksDB.activeBets[betId] = bet
    
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Bet created: " .. bet.title)
    DebugPrint("Created bet: " .. betId .. " (v" .. stateVersion .. ")")
    
    -- State will be broadcast in next sync cycle (every 5s)
    -- No need to immediately broadcast
    
    -- Force UI update if frame exists
    if self.frame then
        -- Schedule update slightly delayed to ensure DB is saved
        C_Timer.After(0.1, function()
            if self.frame and self.frame.UpdateBetList then
                self.frame:UpdateBetList()
            end
        end)
    end
    
    return betId
end

function FuldStonks:PlaceBet(betId, option, amount)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet not found!")
        return
    end
    
    if bet.status ~= "active" then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet is not active!")
        return
    end
    
    -- Validate option
    local validOption = false
    for _, opt in ipairs(bet.options) do
        if opt == option then
            validOption = true
            break
        end
    end
    
    if not validOption then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Invalid option!")
        return
    end
    
    -- Check if player is the bet creator
    local isCreator = (bet.createdBy == playerFullName)
    
    if isCreator then
        -- Bet creator can participate without trading (can't trade with themselves)
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Placing bet as creator (no trade required)...")
        
        -- Directly confirm the bet
        self:ConfirmBetTrade(playerFullName, betId, option, amount)
        
        -- Clear any pending bet
        self.pendingBets[playerFullName] = nil
        
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Bet placed successfully!")
        print("  Bet: " .. bet.title)
        print("  Choice: " .. COLOR_YELLOW .. option .. COLOR_RESET)
        print("  Amount: " .. amount .. "g")
        
        return
    end
    
    -- Store pending bet (waiting for gold trade)
    self.pendingBets[playerFullName] = {
        betId = betId,
        option = option,
        amount = amount,
        timestamp = GetTime()
    }
    
    -- Broadcast pending bet notification to bet creator
    -- Use current channel (GUILD/PARTY/RAID/INSTANCE) instead of WHISPER for addon messages
    local betTitle = bet.title
    local betCreator = bet.createdBy
    
    -- Send addon message to bet creator with pending bet info via broadcast channel
    local pendingMsg = betId .. DELIMITER .. option .. DELIMITER .. tostring(amount)
    DebugPrint("Sending pending bet notification: " .. pendingMsg)
    self:BroadcastMessage(MSG_BET_PENDING, betId, option, tostring(amount))
    
    -- Also send regular whisper for visibility
    local whisperMsg = string.format("FuldStonks: Trading you %dg for '%s' (betting %s)", amount, betTitle, option)
    SendChatMessage(whisperMsg, "WHISPER", nil, betCreator)
    
    print(COLOR_YELLOW .. "FuldStonks" .. COLOR_RESET .. " Please trade " .. amount .. "g to " .. GetPlayerBaseName(betCreator) .. " to confirm your bet.")
    print("  Bet: " .. betTitle)
    print("  Choice: " .. COLOR_YELLOW .. option .. COLOR_RESET)
    print("  " .. COLOR_ORANGE .. "Type /fs cancel to cancel this pending bet" .. COLOR_RESET)
    
    DebugPrint("Pending bet: " .. betId .. " | " .. option .. " | " .. amount .. "g - awaiting trade")
end

-- Cancel a pending bet
function FuldStonks:CancelPendingBet()
    local pendingBet = self.pendingBets[playerFullName]
    if not pendingBet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " You have no pending bets to cancel.")
        return
    end
    
    local bet = FuldStonksDB.activeBets[pendingBet.betId]
    if bet then
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Cancelled pending bet: " .. bet.title)
        print("  Choice: " .. COLOR_YELLOW .. pendingBet.option .. COLOR_RESET .. " (" .. pendingBet.amount .. "g)")
    end
    
    self.pendingBets[playerFullName] = nil
    DebugPrint("Cancelled pending bet")
end

-- Confirm bet after gold trade (called by bet holder)
function FuldStonks:ConfirmBetTrade(playerName, betId, option, amount)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet not found for confirmation!")
        return
    end
    
    -- Increment state version for this change
    IncrementStateVersion()
    
    -- Record bet placement (handle bet changes by subtracting old amount)
    local oldAmount = 0
    if bet.participants[playerName] then
        oldAmount = bet.participants[playerName].amount or 0
    end
    
    bet.participants[playerName] = {
        option = option,
        amount = amount,
        confirmed = true,
        timestamp = GetTime()  -- Add timestamp for conflict resolution
    }
    
    bet.totalPot = bet.totalPot - oldAmount + amount
    bet.stateVersion = FuldStonksDB.stateVersion  -- Update bet's state version
    
    -- Whisper confirmation to the player
    local betTitle = bet.title
    local confirmMsg = string.format("FuldStonks: Confirmed %dg for '%s' (%s). Pot now: %dg", amount, betTitle, option, bet.totalPot)
    SendChatMessage(confirmMsg, "WHISPER", nil, playerName)
    
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Confirmed " .. GetPlayerBaseName(playerName) .. "'s bet: " .. amount .. "g on " .. COLOR_YELLOW .. option .. COLOR_RESET)
    DebugPrint("Confirmed bet: " .. betId .. " | " .. playerName .. " | " .. option .. " | " .. amount .. "g (v" .. FuldStonksDB.stateVersion .. ")")
    
    -- State will be broadcast in next sync cycle
    
    -- Update UI if open
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
end

function FuldStonks:HideBet(betId)
    FuldStonksDB.ignoredBets[betId] = true
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Bet hidden from view. Use /fs showhidden to see hidden bets.")
end

function FuldStonks:ShowHiddenBets()
    local count = 0
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Hidden bets:")
    for betId, _ in pairs(FuldStonksDB.ignoredBets) do
        local bet = FuldStonksDB.activeBets[betId]
        if bet then
            print("  " .. bet.title)
            count = count + 1
        else
            -- Clean up reference to non-existent bet
            FuldStonksDB.ignoredBets[betId] = nil
        end
    end
    if count == 0 then
        print("  No hidden bets.")
    else
        print("Use /fs unhideall to unhide all bets.")
    end
end

function FuldStonks:UnhideAllBets()
    local count = 0
    for _ in pairs(FuldStonksDB.ignoredBets) do
        count = count + 1
    end
    FuldStonksDB.ignoredBets = {}
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Unhidden " .. count .. " bet(s).")
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
end

function FuldStonks:CancelBet(betId)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet not found!")
        return
    end
    
    -- Only bet creator can cancel
    if bet.createdBy ~= playerFullName then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Only the bet creator can cancel this bet!")
        return
    end
    
    -- Increment state version
    IncrementStateVersion()
    
    print(COLOR_YELLOW .. "FuldStonks" .. COLOR_RESET .. " Bet cancelled! Returning all bets...")
    print("  Bet: " .. bet.title)
    
    -- Return bets to participants
    if next(bet.participants) then
        print("  Returned:")
        for playerName, participation in pairs(bet.participants) do
            print("    " .. GetPlayerBaseName(playerName) .. ": " .. participation.amount .. "g")
        end
    else
        print("  No bets to return.")
    end
    
    -- Mark as cancelled and move to history
    bet.status = "cancelled"
    bet.cancelledAt = GetTime()
    bet.stateVersion = FuldStonksDB.stateVersion
    
    FuldStonksDB.betHistory[betId] = bet
    FuldStonksDB.activeBets[betId] = nil
    
    -- Clear any pending bets for this bet
    for playerName, pendingBet in pairs(self.pendingBets) do
        if pendingBet.betId == betId then
            self.pendingBets[playerName] = nil
        end
    end
    
    -- State will be broadcast in next sync cycle (bet removal)
    
    -- Update UI if open
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
    
    -- Close inspect dialog if open
    if self.inspectDialog and self.inspectDialog:IsShown() then
        self.inspectDialog:Hide()
    end
    
    -- Show payout dialog
    self:ShowPayoutDialog(betId, nil)
end

function FuldStonks:ResolveBet(betId, winningOption)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet not found!")
        return
    end
    
    -- Increment state version
    IncrementStateVersion()
    
    -- Calculate winners and payouts
    local totalWinningBets = 0
    local winners = {}
    
    for playerName, participation in pairs(bet.participants) do
        if participation.option == winningOption then
            totalWinningBets = totalWinningBets + participation.amount
            table.insert(winners, {name = playerName, amount = participation.amount})
        end
    end
    
    if totalWinningBets == 0 then
        print(COLOR_YELLOW .. "FuldStonks" .. COLOR_RESET .. " No winners! Pot returned.")
        -- Return bets to participants
        for playerName, participation in pairs(bet.participants) do
            print("  " .. GetPlayerBaseName(playerName) .. ": " .. participation.amount .. "g returned")
        end
    else
        -- Distribute winnings proportionally
        print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Bet resolved! Winners:")
        for _, winner in ipairs(winners) do
            local share = (winner.amount / totalWinningBets) * bet.totalPot
            local profit = share - winner.amount
            print("  " .. GetPlayerBaseName(winner.name) .. ": " .. math.floor(share) .. "g (+" .. math.floor(profit) .. "g)")
        end
    end
    
    -- Mark as resolved and move to history
    bet.status = "resolved"
    bet.winningOption = winningOption
    bet.resolvedAt = GetTime()
    bet.stateVersion = FuldStonksDB.stateVersion
    
    FuldStonksDB.betHistory[betId] = bet
    FuldStonksDB.activeBets[betId] = nil
    
    -- State will be broadcast in next sync cycle (bet removal)
    
    -- Whisper all participants about their result
    if totalWinningBets == 0 then
        -- No winners - everyone gets refunded
        for playerName, participation in pairs(bet.participants) do
            if playerName ~= playerFullName then
                local whisperMsg = string.format("FuldStonks: Bet '%s' resolved - No winners! Your %dg has been returned.", bet.title, participation.amount)
                SendChatMessage(whisperMsg, "WHISPER", nil, playerName)
            end
        end
    else
        -- Whisper winners
        for _, winner in ipairs(winners) do
            if winner.name ~= playerFullName then
                local share = math.floor((winner.amount / totalWinningBets) * bet.totalPot)
                local profit = share - winner.amount
                local whisperMsg = string.format("FuldStonks: You WON! Bet: '%s'. Your payout is %dg (+%dg profit)", bet.title, share, profit)
                SendChatMessage(whisperMsg, "WHISPER", nil, winner.name)
            end
        end
        
        -- Whisper losers
        for playerName, participation in pairs(bet.participants) do
            if participation.option ~= winningOption and playerName ~= playerFullName then
                local whisperMsg = string.format("FuldStonks: You lost. Bet: '%s' - %s won. You lost %dg.", bet.title, winningOption, participation.amount)
                SendChatMessage(whisperMsg, "WHISPER", nil, playerName)
            end
        end
    end
    
    -- Update UI if open
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
    
    -- Show payout dialog
    self:ShowPayoutDialog(betId, winningOption)
end

-- Hook for data persistence
function FuldStonks:SaveData()
    -- SavedVariables automatically persists FuldStonksDB
    DebugPrint("Data saved to SavedVariables")
end

function FuldStonks:LoadData()
    -- Ensure structures exist
    FuldStonksDB.activeBets = FuldStonksDB.activeBets or {}
    FuldStonksDB.myBets = FuldStonksDB.myBets or {}
    FuldStonksDB.betHistory = FuldStonksDB.betHistory or {}
    FuldStonksDB.ignoredBets = FuldStonksDB.ignoredBets or {}
    DebugPrint("Data loaded from SavedVariables")
end
