-- Minimap button: toggles, tooltips, drag-to-reposition.
-- PI.RefreshMinimapState is called by main whenever enabled/auto state changes.

local ADDON_NAME, PI = ...

local Print = PI.Print

local minimapButton
local minimapIcon

local MINIMAP_RADIUS = 80
local MINIMAP_ICON_TEXTURE      = "Interface\\Icons\\Spell_Arcane_PortalShattrath"
local MINIMAP_ICON_TEXTURE_AUTO = "Interface\\Icons\\Spell_Arcane_PortalTheramore"

local function UpdateMinimapButtonPosition()
    if not minimapButton then
        return
    end

    local angle = math.rad(PortalInviterDB.minimapAngle or 220)
    local xOffset = math.cos(angle) * MINIMAP_RADIUS
    local yOffset = math.sin(angle) * MINIMAP_RADIUS

    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", xOffset, yOffset)
end

local function RefreshMinimapState()
    if not minimapIcon then
        return
    end

    minimapIcon:SetTexture(
        PortalInviterDB.autoMode and MINIMAP_ICON_TEXTURE_AUTO or MINIMAP_ICON_TEXTURE
    )

    if PortalInviterDB.enabled then
        if minimapIcon.SetDesaturated then
            minimapIcon:SetDesaturated(false)
        end
        minimapIcon:SetVertexColor(1, 1, 1)
    else
        if minimapIcon.SetDesaturated then
            minimapIcon:SetDesaturated(true)
        end
        minimapIcon:SetVertexColor(0.45, 0.45, 0.45)
    end
end

local function GetAngleDegrees(yOffset, xOffset)
    if math.atan2 then
        return math.deg(math.atan2(yOffset, xOffset))
    end

    if xOffset == 0 then
        return yOffset >= 0 and 90 or -90
    end

    local angle = math.deg(math.atan(yOffset / xOffset))
    if xOffset < 0 then
        angle = angle + 180
    end

    return angle
end

local function CreateMinimapButton()
    if minimapButton then
        return
    end

    minimapButton = CreateFrame("Button", "PortalInviterMinimapButton", Minimap)
    minimapButton:SetSize(32, 32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetMovable(true)
    minimapButton:RegisterForClicks("LeftButtonUp", "MiddleButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    local background = minimapButton:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    background:SetSize(54, 54)
    background:SetPoint("TOPLEFT")

    minimapIcon = minimapButton:CreateTexture(nil, "ARTWORK")
    minimapIcon:SetTexture(MINIMAP_ICON_TEXTURE)
    minimapIcon:SetSize(20, 20)
    minimapIcon:SetPoint("CENTER")
    minimapIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    if minimapButton.CreateMaskTexture and minimapIcon.AddMaskTexture then
        local iconMask = minimapButton:CreateMaskTexture()
        iconMask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        iconMask:SetPoint("TOPLEFT", minimapIcon, "TOPLEFT")
        iconMask:SetPoint("BOTTOMRIGHT", minimapIcon, "BOTTOMRIGHT")
        minimapIcon:AddMaskTexture(iconMask)
    end

    minimapButton:SetScript("OnClick", function(_, button)
        if button == "LeftButton" then
            if IsControlKeyDown() then
                if PI.ShowIncomeFrame then PI.ShowIncomeFrame(2) end
            elseif IsShiftKeyDown() then
                PI.ToggleAutoMode()
            else
                PI.ToggleEnabled()
            end
        elseif button == "MiddleButton" then
            PI.ToggleSoundMuted()
        elseif button == "RightButton" and IsShiftKeyDown() then
            local optionsCategory = PI.GetOptionsCategory and PI.GetOptionsCategory()
            if optionsCategory and Settings and Settings.OpenToCategory then
                Settings.OpenToCategory(optionsCategory)
            elseif InterfaceOptionsFrame_OpenToCategory then
                InterfaceOptionsFrame_OpenToCategory("PortalInviter")
                InterfaceOptionsFrame_OpenToCategory("PortalInviter")
            end
        else
            Print("|cff69ccf0--- Minimap Controls ---|r")
            Print("|cffffffffLeft-click:|r toggle invites on/off")
            Print("|cffffffffShift+Left-click:|r toggle auto mode (capital city detection)")
            Print("|cffffffffCtrl+Left-click:|r open income/earnings window")
            Print("|cffffffffMiddle-click:|r toggle invite sound")
            Print("|cffffffffShift+Right-click:|r open settings panel")
            Print("|cff69ccf0--- Slash Commands ---|r")
            Print("|cffffff00/port|r — show full command reference")
            Print("|cffffff00/port income|r — earnings stats  |  |cffffff00/port log|r — trade log")
            Print("|cffffff00/port tutorial|r — tips for getting the most out of Portal Inviter")
        end
    end)

    minimapButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("PortalInviter")
        GameTooltip:AddLine("Status: " .. (PortalInviterDB.enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        GameTooltip:AddLine("Auto mode: " .. (PortalInviterDB.autoMode and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        GameTooltip:AddLine("Sound: " .. (PortalInviterDB.soundMuted and "|cffff0000MUTED|r" or "|cff00ff00ON|r"))
        GameTooltip:AddLine("Left-click: toggle invites on/off", 1, 1, 1)
        GameTooltip:AddLine("Shift+Left-click: toggle auto mode", 1, 1, 1)
        GameTooltip:AddLine("Ctrl+Left-click: open income window", 1, 1, 1)
        GameTooltip:AddLine("Middle-click: toggle invite sound", 1, 1, 1)
        GameTooltip:AddLine("Right-click: show help", 1, 1, 1)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapButton:SetScript("OnDragStart", function(self)
        self.isDragging = true
    end)

    minimapButton:SetScript("OnDragStop", function(self)
        self.isDragging = false
    end)

    minimapButton:SetScript("OnUpdate", function(self)
        if not self.isDragging then
            return
        end

        local cursorX, cursorY = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        local centerX, centerY = Minimap:GetCenter()

        cursorX = cursorX / scale
        cursorY = cursorY / scale

        PortalInviterDB.minimapAngle = GetAngleDegrees(cursorY - centerY, cursorX - centerX)
        UpdateMinimapButtonPosition()
    end)

    UpdateMinimapButtonPosition()
    RefreshMinimapState()
end

PI.CreateMinimapButton = CreateMinimapButton
PI.RefreshMinimapState = RefreshMinimapState
