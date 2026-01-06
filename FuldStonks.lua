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
local COLOR_ORANGE = "|cFFFF8800"

-- Addon state
FuldStonks.version = "0.1.0"
FuldStonks.frame = nil
FuldStonks.peers = {}           -- Track connected peers: [fullName] = { lastSeen = time, betCount = 0 }
FuldStonks.lastBroadcast = 0    -- Rate limiting for broadcasts
FuldStonks.syncRequested = false
FuldStonks.heartbeatTicker = nil  -- Store heartbeat ticker for cleanup
FuldStonks.rosterUpdateTimer = nil  -- Debounce timer for roster updates
FuldStonks.betIdCounter = 0      -- Counter for generating unique bet IDs
FuldStonks.pendingBets = {}      -- Track pending bets awaiting gold trade: {betId, option, amount}

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
            if bet.status == "active" then
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
                title:SetWidth(500)
                
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
                    
                    -- Show resolve button if we created this bet
                    if bet.createdBy == playerFullName then
                        local resolveButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                        resolveButton:SetSize(80, 22)
                        resolveButton:SetPoint("TOPLEFT", info, "BOTTOMLEFT", buttonOffset, -5)
                        resolveButton:SetText("Resolve")
                        resolveButton:SetScript("OnClick", function()
                            FuldStonks:ShowBetResolutionDialog(betId)
                        end)
                        buttonOffset = buttonOffset + 85
                    end
                    
                    -- Add Inspect button for all bets with participants
                    local participantCount = 0
                    for _ in pairs(bet.participants) do
                        participantCount = participantCount + 1
                    end
                    
                    if participantCount > 0 then
                        local inspectButton = CreateFrame("Button", nil, betFrame, "UIPanelButtonTemplate")
                        inspectButton:SetSize(80, 22)
                        inspectButton:SetPoint("TOPLEFT", info, "BOTTOMLEFT", buttonOffset, -5)
                        inspectButton:SetText("Inspect")
                        inspectButton:SetScript("OnClick", function()
                            FuldStonks:ShowBetInspectDialog(betId)
                        end)
                    end
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
        dialog.title:SetText("Inspect Bet")
        
        dialog.betTitle = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.betTitle:SetPoint("TOP", dialog, "TOP", 0, -35)
        dialog.betTitle:SetWidth(420)
        dialog.betTitle:SetJustifyH("CENTER")
        
        -- Scrollable participant list
        dialog.scrollFrame = CreateFrame("ScrollFrame", nil, dialog, "UIPanelScrollFrameTemplate")
        dialog.scrollFrame:SetPoint("TOPLEFT", dialog, "TOPLEFT", 20, -70)
        dialog.scrollFrame:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -30, 50)
        
        dialog.scrollContent = CreateFrame("Frame", nil, dialog.scrollFrame)
        dialog.scrollContent:SetSize(390, 1)
        dialog.scrollFrame:SetScrollChild(dialog.scrollContent)
        
        dialog.participantsText = dialog.scrollContent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dialog.participantsText:SetPoint("TOPLEFT", dialog.scrollContent, "TOPLEFT", 0, 0)
        dialog.participantsText:SetWidth(390)
        dialog.participantsText:SetJustifyH("LEFT")
        
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
        
        self.inspectDialog = dialog
    end
    
    -- Set bet info
    self.inspectDialog.betTitle:SetText(COLOR_YELLOW .. bet.title .. COLOR_RESET)
    
    -- Build participant list
    local participantInfo = "Total Pot: " .. COLOR_GREEN .. bet.totalPot .. "g" .. COLOR_RESET .. "\n"
    participantInfo = participantInfo .. "Created by: " .. GetPlayerBaseName(bet.createdBy) .. "\n\n"
    
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
    
    -- Show breakdown for each option
    for _, option in ipairs(bet.options) do
        local group = optionGroups[option] or {}
        local totalBets = 0
        for _, p in ipairs(group) do
            totalBets = totalBets + p.amount
        end
        
        participantInfo = participantInfo .. COLOR_YELLOW .. option .. ":" .. COLOR_RESET .. " " .. #group .. " bets, " .. totalBets .. "g total"
        
        if totalBets > 0 then
            local percentage = math.floor((totalBets / bet.totalPot) * 100)
            participantInfo = participantInfo .. " (" .. percentage .. "%)"
        end
        participantInfo = participantInfo .. "\n"
        
        if #group > 0 then
            for _, p in ipairs(group) do
                local baseName = GetPlayerBaseName(p.name)
                local percentage = math.floor((p.amount / bet.totalPot) * 100)
                participantInfo = participantInfo .. "  " .. baseName .. ": " .. p.amount .. "g (" .. percentage .. "%)\n"
            end
        else
            participantInfo = participantInfo .. "  No bets\n"
        end
        participantInfo = participantInfo .. "\n"
    end
    
    self.inspectDialog.participantsText:SetText(participantInfo)
    
    -- Update scroll content height
    local textHeight = self.inspectDialog.participantsText:GetStringHeight()
    self.inspectDialog.scrollContent:SetHeight(math.max(textHeight + 20, 200))
    
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
        -- Handle bet creation from peer
        local betString = arg1
        if betString then
            local bet = DeserializeBet(betString)
            if bet and not FuldStonksDB.activeBets[bet.id] then
                FuldStonksDB.activeBets[bet.id] = bet
                local creatorName = GetPlayerBaseName(sender)
                print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. creatorName .. " created bet: " .. bet.title)
                DebugPrint("Received " .. bet.title .. " bet from " .. sender)
                
                -- Update UI if open
                if FuldStonks.frame and FuldStonks.frame:IsShown() then
                    FuldStonks.frame:UpdateBetList()
                end
            end
        end
        
    elseif msgType == MSG_BET_PLACED then
        -- Handle bet placement from peer
        local betId = arg1
        local playerName = arg2
        local option = arg3
        local amount = tonumber(arg4) or 0
        
        local bet = FuldStonksDB.activeBets[betId]
        if bet then
            -- Update or add participant (handle existing bets properly)
            local oldAmount = 0
            if bet.participants[playerName] then
                oldAmount = bet.participants[playerName].amount or 0
            end
            
            bet.participants[playerName] = {
                option = option,
                amount = amount
            }
            bet.totalPot = bet.totalPot - oldAmount + amount
            
            local baseName = GetPlayerBaseName(playerName)
            DebugPrint("Received bet placement from " .. sender .. ": " .. baseName .. " bet " .. amount .. "g on " .. option)
            
            -- Update UI if open
            if FuldStonks.frame and FuldStonks.frame:IsShown() then
                FuldStonks.frame:UpdateBetList()
            end
        end
        
    elseif msgType == MSG_BET_RESOLVED then
        -- Handle bet resolution from peer
        local betId = arg1
        local winningOption = arg2
        
        local bet = FuldStonksDB.activeBets[betId]
        if bet then
            -- Calculate winners
            local totalWinningBets = 0
            local winners = {}
            
            for playerName, participation in pairs(bet.participants) do
                if participation.option == winningOption then
                    totalWinningBets = totalWinningBets + participation.amount
                    table.insert(winners, {name = playerName, amount = participation.amount})
                end
            end
            
            local creatorName = GetPlayerBaseName(sender)
            print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " " .. creatorName .. " resolved bet: " .. bet.title)
            print("  Winning option: " .. COLOR_YELLOW .. winningOption .. COLOR_RESET)
            
            if totalWinningBets == 0 then
                print("  No winners! Bets returned.")
            else
                print("  Winners:")
                for _, winner in ipairs(winners) do
                    local share = (winner.amount / totalWinningBets) * bet.totalPot
                    local profit = share - winner.amount
                    print("    " .. GetPlayerBaseName(winner.name) .. ": " .. math.floor(share) .. "g (+" .. math.floor(profit) .. "g)")
                end
            end
            
            -- Mark as resolved and move to history
            bet.status = "resolved"
            bet.winningOption = winningOption
            bet.resolvedAt = GetTime()
            
            FuldStonksDB.betHistory[betId] = bet
            FuldStonksDB.activeBets[betId] = nil
            
            DebugPrint("Received bet resolution from " .. sender)
            
            -- Update UI if open
            if FuldStonks.frame and FuldStonks.frame:IsShown() then
                FuldStonks.frame:UpdateBetList()
            end
        end
        
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
            FuldStonks:LoadData()
            
            -- Initialize debug mode if not set
            if FuldStonksDB.debug == nil then
                FuldStonksDB.debug = false
            end
            
            -- Start heartbeat timer (every 30 seconds)
            if FuldStonks.heartbeatTicker then
                FuldStonks.heartbeatTicker:Cancel()
            end
            FuldStonks.heartbeatTicker = C_Timer.NewTicker(30, function()
                FuldStonks:SendHeartbeat()
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
            FuldStonks:SendHeartbeat()
            FuldStonks.rosterUpdateTimer = nil
        end)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Entering world/instance, request sync
        C_Timer.After(2.0, function()
            FuldStonks:SendHeartbeat()
            FuldStonks:RequestSync()
        end)
    elseif event == "PLAYER_LOGOUT" then
        -- Clean up timers on logout
        if FuldStonks.heartbeatTicker then
            FuldStonks.heartbeatTicker:Cancel()
            FuldStonks.heartbeatTicker = nil
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

-- ============================================
-- TRADE HANDLING FOR BET HOLDER
-- ============================================

-- Track trade information
FuldStonks.currentTrade = {
    player = nil,
    amount = 0,
    betInfo = nil
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
    
    DebugPrint("Trade window opened with: " .. tradeFullName)
    
    -- Check if someone is trading us for a bet we created
    -- Try both full name and base name for same-realm compatibility
    for playerName, pendingBet in pairs(FuldStonks.pendingBets) do
        local playerBaseName = GetPlayerBaseName(playerName)
        local tradeBaseName = GetPlayerBaseName(tradeFullName)
        
        -- Match by full name OR base name (for same-realm players)
        if playerName == tradeFullName or playerBaseName == tradeBaseName then
            local bet = FuldStonksDB.activeBets[pendingBet.betId]
            -- Only accept trades if we are the bet creator
            if bet and bet.createdBy == playerFullName then
                FuldStonks.currentTrade.betInfo = pendingBet
                FuldStonks.currentTrade.traderName = playerName  -- Store the actual key used in pendingBets
                print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Trade detected for pending bet:")
                print("  Bet: " .. bet.title)
                print("  Expected: " .. pendingBet.amount .. "g")
                DebugPrint("Trade opened with " .. tradeBaseName .. " who has pending bet for " .. pendingBet.amount .. "g")
                break
            end
        end
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

-- Handle trade completion
local function OnTradeAcceptUpdate(player, target)
    if player == 1 and target == 1 then
        -- Both players accepted the trade
        if FuldStonks.currentTrade.betInfo and FuldStonks.currentTrade.amount > 0 then
            local pendingBet = FuldStonks.currentTrade.betInfo
            local traderName = FuldStonks.currentTrade.traderName or FuldStonks.currentTrade.player
            local bet = FuldStonksDB.activeBets[pendingBet.betId]
            
            DebugPrint("Trade accepted by both parties. Amount: " .. FuldStonks.currentTrade.amount .. "g")
            
            -- Only confirm if we are the bet creator
            if bet and bet.createdBy == playerFullName then
                print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Trade completing...")
                
                -- Confirm the bet after a short delay (to ensure trade completes)
                C_Timer.After(0.5, function()
                    FuldStonks:ConfirmBetTrade(traderName, pendingBet.betId, pendingBet.option, FuldStonks.currentTrade.amount)
                    
                    -- Remove from pending
                    FuldStonks.pendingBets[traderName] = nil
                    
                    DebugPrint("Removed pending bet for " .. traderName)
                end)
            end
        end
    end
end

-- ============================================
-- FUTURE EXPANSION HOOKS
-- ============================================

-- Hook for bet management
function FuldStonks:CreateBet(betData)
    -- Generate unique bet ID
    local betId = GenerateBetId()
    
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
        pendingTrades = {}  -- Track pending gold trades
    }
    
    -- Add to active bets
    FuldStonksDB.activeBets[betId] = bet
    
    -- Broadcast to other players
    local serialized = SerializeBet(bet)
    self:BroadcastMessage(MSG_BET_CREATED, serialized)
    
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Bet created: " .. bet.title)
    DebugPrint("Created bet: " .. betId)
    
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
    
    -- Store pending bet (waiting for gold trade)
    self.pendingBets[playerFullName] = {
        betId = betId,
        option = option,
        amount = amount,
        timestamp = GetTime()
    }
    
    -- Whisper the bet creator to initiate trade
    local betTitle = bet.title
    local betCreator = bet.createdBy
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
    
    -- Record bet placement (handle bet changes by subtracting old amount)
    local oldAmount = 0
    if bet.participants[playerName] then
        oldAmount = bet.participants[playerName].amount or 0
    end
    
    bet.participants[playerName] = {
        option = option,
        amount = amount,
        confirmed = true
    }
    
    bet.totalPot = bet.totalPot - oldAmount + amount
    
    -- Broadcast to other players
    self:BroadcastMessage(MSG_BET_PLACED, betId, playerName, option, amount)
    
    -- Whisper confirmation to the player
    local betTitle = bet.title
    local confirmMsg = string.format("FuldStonks: Confirmed %dg for '%s' (%s). Pot now: %dg", amount, betTitle, option, bet.totalPot)
    SendChatMessage(confirmMsg, "WHISPER", nil, playerName)
    
    print(COLOR_GREEN .. "FuldStonks" .. COLOR_RESET .. " Confirmed " .. GetPlayerBaseName(playerName) .. "'s bet: " .. amount .. "g on " .. COLOR_YELLOW .. option .. COLOR_RESET)
    DebugPrint("Confirmed bet: " .. betId .. " | " .. playerName .. " | " .. option .. " | " .. amount .. "g")
    
    -- Update UI if open
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
end

function FuldStonks:ResolveBet(betId, winningOption)
    local bet = FuldStonksDB.activeBets[betId]
    if not bet then
        print(COLOR_RED .. "FuldStonks" .. COLOR_RESET .. " Error: Bet not found!")
        return
    end
    
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
    
    FuldStonksDB.betHistory[betId] = bet
    FuldStonksDB.activeBets[betId] = nil
    
    -- Broadcast resolution
    self:BroadcastMessage(MSG_BET_RESOLVED, betId, winningOption)
    
    -- Update UI if open
    if self.frame and self.frame:IsShown() then
        self.frame:UpdateBetList()
    end
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
    DebugPrint("Data loaded from SavedVariables")
end
