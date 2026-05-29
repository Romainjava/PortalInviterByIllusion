-- Interface > AddOns > PortalInviter options panel.

local ADDON_NAME, PI = ...

local Print = PI.Print

local optionsCategory

local function CreateOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "PortalInviter"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("PortalInviter")

    local whisperLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    whisperLabel:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -24)
    whisperLabel:SetText("Auto-whisper message")

    local whisperDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    whisperDesc:SetPoint("TOPLEFT", whisperLabel, "BOTTOMLEFT", 0, -4)
    whisperDesc:SetWidth(380)
    whisperDesc:SetJustifyH("LEFT")
    whisperDesc:SetText("When an invite fails because the player is already in another group, automatically whisper them this message (e.g. \"inv for portal\"). Leave blank to disable.")

    local whisperBox = CreateFrame("EditBox", "PortalInviterWhisperBox", panel, "InputBoxTemplate")
    whisperBox:SetPoint("TOPLEFT", whisperDesc, "BOTTOMLEFT", 4, -8)
    whisperBox:SetWidth(300)
    whisperBox:SetHeight(20)
    whisperBox:SetAutoFocus(false)
    whisperBox:SetMaxLetters(200)

    local function SaveWhisperBox()
        local text = (whisperBox:GetText() or ""):match("^%s*(.-)%s*$")
        PortalInviterDB.autoWhisperMessage = text
    end

    whisperBox:SetScript("OnEnterPressed", function(self)
        SaveWhisperBox()
        self:ClearFocus()
        Print("Auto-whisper message saved.")
    end)
    whisperBox:SetScript("OnEscapePressed", function(self)
        whisperBox:SetText(PortalInviterDB.autoWhisperMessage or "")
        self:ClearFocus()
    end)
    whisperBox:SetScript("OnEditFocusLost", function()
        SaveWhisperBox()
    end)

    local announceCheck = CreateFrame("CheckButton", "PortalInviterAnnounceCheck", panel, "InterfaceOptionsCheckButtonTemplate")
    announceCheck:SetPoint("TOPLEFT", whisperBox, "BOTTOMLEFT", -4, -16)
    announceCheck.Text:SetText("Announce portal casts to party/raid")
    announceCheck:SetChecked(PortalInviterDB.announcePortalCasts)
    announceCheck:SetScript("OnClick", function(self)
        PortalInviterDB.announcePortalCasts = self:GetChecked() and true or false
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
        whisperBox:SetText(PortalInviterDB.autoWhisperMessage or "")
        announceCheck:SetChecked(PortalInviterDB.announcePortalCasts)
    end)

    -- Legacy InterfaceOptions OK/Cancel/Defaults support
    panel.okay = function() SaveWhisperBox() end
    panel.cancel = function()
        whisperBox:SetText(PortalInviterDB.autoWhisperMessage or "")
        announceCheck:SetChecked(PortalInviterDB.announcePortalCasts)
    end
    panel.default = function()
        whisperBox:SetText("")
        PortalInviterDB.announcePortalCasts = true
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
