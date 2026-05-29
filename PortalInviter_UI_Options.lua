-- Interface > AddOns > Portal Inviter by Illusion options panel.

local ADDON_NAME, PI = ...

local Print = PI.Print

local DEFAULT_ALREADY_GROUPED_WHISPER_MESSAGE = "I can invite you for the portal when you're free - just whisper me again."
local DEFAULT_JOIN_WHISPER_MESSAGE = "Hey %player%, I'm marked with a star. I'll make %destination% now - come to me when you're ready."
local DEFAULT_UNKNOWN_DESTINATION_WHISPER_MESSAGE = "Hey %player%, I'm marked with a star. Which portal do you need?"

local optionsCategory

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "Portal Inviter by Illusion"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Portal Inviter by Illusion")

    local whisperLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    whisperLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    whisperLabel:SetText("Auto-whisper message")

    local whisperDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    whisperDesc:SetPoint("TOPLEFT", whisperLabel, "BOTTOMLEFT", 0, -4)
    whisperDesc:SetWidth(380)
    whisperDesc:SetJustifyH("LEFT")
    whisperDesc:SetText("When an invite fails because the player is already in another group, whisper this. Leave blank to disable. Placeholders: %player%, %destination%.")

    local whisperBox = CreateFrame("EditBox", "PortalInviterByIllusionWhisperBox", panel, "InputBoxTemplate")
    whisperBox:SetPoint("TOPLEFT", whisperDesc, "BOTTOMLEFT", 4, -8)
    whisperBox:SetWidth(300)
    whisperBox:SetHeight(20)
    whisperBox:SetAutoFocus(false)
    whisperBox:SetMaxLetters(200)

    local function SaveWhisperBox()
        local text = (whisperBox:GetText() or ""):match("^%s*(.-)%s*$")
        PortalInviterByIllusionDB.autoWhisperMessage = text
    end

    whisperBox:SetScript("OnEnterPressed", function(self)
        SaveWhisperBox()
        self:ClearFocus()
        Print("Auto-whisper message saved.")
    end)
    whisperBox:SetScript("OnEscapePressed", function(self)
        whisperBox:SetText(PortalInviterByIllusionDB.autoWhisperMessage or "")
        self:ClearFocus()
    end)
    whisperBox:SetScript("OnEditFocusLost", function()
        SaveWhisperBox()
    end)

    local joinLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    joinLabel:SetPoint("TOPLEFT", whisperBox, "BOTTOMLEFT", -4, -18)
    joinLabel:SetText("Whisper after join")

    local joinDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    joinDesc:SetPoint("TOPLEFT", joinLabel, "BOTTOMLEFT", 0, -4)
    joinDesc:SetWidth(430)
    joinDesc:SetJustifyH("LEFT")
    joinDesc:SetText("Sent when a buyer joins and Portal Inviter by Illusion knows the destination. Placeholders: %player%, %destination%.")

    local joinWhisperBox = CreateFrame("EditBox", "PortalInviterByIllusionJoinWhisperBox", panel, "InputBoxTemplate")
    joinWhisperBox:SetPoint("TOPLEFT", joinDesc, "BOTTOMLEFT", 4, -8)
    joinWhisperBox:SetWidth(420)
    joinWhisperBox:SetHeight(20)
    joinWhisperBox:SetAutoFocus(false)
    joinWhisperBox:SetMaxLetters(200)

    local function SaveJoinWhisperBox()
        PortalInviterByIllusionDB.joinWhisperMessage = (joinWhisperBox:GetText() or ""):match("^%s*(.-)%s*$")
    end

    joinWhisperBox:SetScript("OnEnterPressed", function(self)
        SaveJoinWhisperBox()
        self:ClearFocus()
        Print("Join whisper saved.")
    end)
    joinWhisperBox:SetScript("OnEscapePressed", function(self)
        self:SetText(PortalInviterByIllusionDB.joinWhisperMessage or "")
        self:ClearFocus()
    end)
    joinWhisperBox:SetScript("OnEditFocusLost", SaveJoinWhisperBox)

    local unknownLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    unknownLabel:SetPoint("TOPLEFT", joinWhisperBox, "BOTTOMLEFT", -4, -18)
    unknownLabel:SetText("Whisper when destination is missing")

    local unknownDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    unknownDesc:SetPoint("TOPLEFT", unknownLabel, "BOTTOMLEFT", 0, -4)
    unknownDesc:SetWidth(430)
    unknownDesc:SetJustifyH("LEFT")
    unknownDesc:SetText("Sent when a buyer joins but the chat request did not include a clear destination. Leave blank to disable.")

    local unknownWhisperBox = CreateFrame("EditBox", "PortalInviterByIllusionUnknownWhisperBox", panel, "InputBoxTemplate")
    unknownWhisperBox:SetPoint("TOPLEFT", unknownDesc, "BOTTOMLEFT", 4, -8)
    unknownWhisperBox:SetWidth(420)
    unknownWhisperBox:SetHeight(20)
    unknownWhisperBox:SetAutoFocus(false)
    unknownWhisperBox:SetMaxLetters(200)

    local function SaveUnknownWhisperBox()
        PortalInviterByIllusionDB.unknownDestinationWhisperMessage = (unknownWhisperBox:GetText() or ""):match("^%s*(.-)%s*$")
    end

    unknownWhisperBox:SetScript("OnEnterPressed", function(self)
        SaveUnknownWhisperBox()
        self:ClearFocus()
        Print("Missing-destination whisper saved.")
    end)
    unknownWhisperBox:SetScript("OnEscapePressed", function(self)
        self:SetText(PortalInviterByIllusionDB.unknownDestinationWhisperMessage or "")
        self:ClearFocus()
    end)
    unknownWhisperBox:SetScript("OnEditFocusLost", SaveUnknownWhisperBox)

    local announceCheck = CreateFrame("CheckButton", "PortalInviterByIllusionAnnounceCheck", panel, "InterfaceOptionsCheckButtonTemplate")
    announceCheck:SetPoint("TOPLEFT", unknownWhisperBox, "BOTTOMLEFT", -4, -16)
    announceCheck.Text:SetText("Announce portal casts to party/raid")
    announceCheck:SetChecked(PortalInviterByIllusionDB.announcePortalCasts)
    announceCheck:SetScript("OnClick", function(self)
        PortalInviterByIllusionDB.announcePortalCasts = self:GetChecked() and true or false
    end)

    local openIncomeBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openIncomeBtn:SetSize(160, 24)
    openIncomeBtn:SetPoint("TOPLEFT", announceCheck, "BOTTOMLEFT", 4, -16)
    openIncomeBtn:SetText("Open Income Window")
    openIncomeBtn:SetScript("OnClick", function() if PI.ShowIncomeFrame then PI.ShowIncomeFrame() end end)

    local openTutorialBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    openTutorialBtn:SetSize(160, 24)
    openTutorialBtn:SetPoint("LEFT", openIncomeBtn, "RIGHT", 10, 0)
    openTutorialBtn:SetText("Open Tutorial")
    openTutorialBtn:SetScript("OnClick", function() if PI.ShowTutorial then PI.ShowTutorial() end end)

    panel:SetScript("OnShow", function()
        whisperBox:SetText(PortalInviterByIllusionDB.autoWhisperMessage or "")
        joinWhisperBox:SetText(PortalInviterByIllusionDB.joinWhisperMessage or "")
        unknownWhisperBox:SetText(PortalInviterByIllusionDB.unknownDestinationWhisperMessage or "")
        announceCheck:SetChecked(PortalInviterByIllusionDB.announcePortalCasts)
    end)

    -- Legacy InterfaceOptions OK/Cancel/Defaults support
    panel.okay = function()
        SaveWhisperBox()
        SaveJoinWhisperBox()
        SaveUnknownWhisperBox()
    end
    panel.cancel = function()
        whisperBox:SetText(PortalInviterByIllusionDB.autoWhisperMessage or "")
        joinWhisperBox:SetText(PortalInviterByIllusionDB.joinWhisperMessage or "")
        unknownWhisperBox:SetText(PortalInviterByIllusionDB.unknownDestinationWhisperMessage or "")
        announceCheck:SetChecked(PortalInviterByIllusionDB.announcePortalCasts)
    end
    panel.default = function()
        whisperBox:SetText(DEFAULT_ALREADY_GROUPED_WHISPER_MESSAGE)
        joinWhisperBox:SetText(DEFAULT_JOIN_WHISPER_MESSAGE)
        unknownWhisperBox:SetText(DEFAULT_UNKNOWN_DESTINATION_WHISPER_MESSAGE)
        PortalInviterByIllusionDB.autoWhisperMessage = DEFAULT_ALREADY_GROUPED_WHISPER_MESSAGE
        PortalInviterByIllusionDB.joinWhisperMessage = DEFAULT_JOIN_WHISPER_MESSAGE
        PortalInviterByIllusionDB.unknownDestinationWhisperMessage = DEFAULT_UNKNOWN_DESTINATION_WHISPER_MESSAGE
        PortalInviterByIllusionDB.announcePortalCasts = true
        announceCheck:SetChecked(true)
    end

    if Settings and Settings.RegisterCanvasLayoutCategory then
        optionsCategory = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(optionsCategory)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

PI.CreateOptionsPanel = CreateOptionsPanel
PI.GetOptionsCategory = function() return optionsCategory end
