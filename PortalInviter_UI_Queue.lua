-- Portal queue UI: small docked ticket panel.
--
-- Self-managing: auto-opens when the queue goes non-empty, auto-hides when
-- empty. Users can minimize it (only while tickets exist) into a small
-- movable pill, or force-close it via an X (prompts a confirmation dialog).

local ADDON_NAME, PI = ...

local Print              = PI.Print
local ClassColorHex      = PI.ClassColorHex
local DestinationColor   = PI.DestinationColor
local DestinationColorHex= PI.DestinationColorHex
local DisplayDestination = PI.DisplayDestination

local expandedFrame
local minimizedFrame
local userForcedHidden = false  -- true between an accepted close and the next new ticket

-- Row / group widget pools so refresh doesn't churn the GC while tickets
-- flicker in and out.
local groupPool = {}
local rowPool = {}

-- ---------------------------------------------------------------------------
-- Saved state
-- ---------------------------------------------------------------------------
local function GetQueueUIDB()
    if type(PortalInviterByIllusionDB) ~= "table" then return nil end
    if type(PortalInviterByIllusionDB.ui) ~= "table" then PortalInviterByIllusionDB.ui = {} end
    if type(PortalInviterByIllusionDB.ui.queueFrame) ~= "table" then
        PortalInviterByIllusionDB.ui.queueFrame = {
            expanded  = {},
            minimized = {},
            lastState = "expanded",  -- "expanded" | "minimized"
        }
    end
    local q = PortalInviterByIllusionDB.ui.queueFrame
    if type(q.expanded)  ~= "table" then q.expanded  = {} end
    if type(q.minimized) ~= "table" then q.minimized = {} end
    if q.lastState ~= "expanded" and q.lastState ~= "minimized" then
        q.lastState = "expanded"
    end
    return q
end

-- ---------------------------------------------------------------------------
-- Close-confirmation popup
-- ---------------------------------------------------------------------------
StaticPopupDialogs["PORTALINVITERBYILLUSION_QUEUE_CLOSE_CONFIRM"] = {
    text         = "Close the Portal Queue?\nPending tickets will be dismissed.",
    button1      = "Close",
    button2      = "Cancel",
    OnAccept     = function()
        userForcedHidden = true
        if PI.QueueClearAll then PI.QueueClearAll() end
        -- QueueClearAll triggers RefreshQueueFrame; it'll hide both frames.
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Row widgets
-- ---------------------------------------------------------------------------
local function AcquireRow(parent)
    local row = table.remove(rowPool)
    if not row then
        row = CreateFrame("Frame", nil, parent)
        row:SetHeight(18)

        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        name:SetPoint("LEFT", 8, 0)
        name:SetPoint("RIGHT", row, "RIGHT", -22, 0)  -- stop before dismiss button
        name:SetJustifyH("LEFT")
        row.name = name

        local dismiss = CreateFrame("Button", nil, row)
        dismiss:SetSize(14, 14)
        dismiss:SetPoint("RIGHT", -4, 0)
        dismiss:SetNormalTexture("Interface\\Buttons\\UI-StopButton")
        dismiss:GetNormalTexture():SetVertexColor(1, 0.6, 0.6, 0.8)
        dismiss:SetHighlightTexture("Interface\\Buttons\\UI-StopButton")
        dismiss:GetHighlightTexture():SetBlendMode("ADD")
        dismiss:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Dismiss ticket", 1, 1, 1)
            GameTooltip:Show()
        end)
        dismiss:SetScript("OnLeave", GameTooltip_Hide)
        row.dismiss = dismiss
    end
    row:SetParent(parent)
    row:Show()
    return row
end

local function ReleaseRow(row)
    row:Hide()
    row:ClearAllPoints()
    row:SetParent(UIParent)
    row.dismiss:SetScript("OnClick", nil)
    rowPool[#rowPool + 1] = row
end

-- ---------------------------------------------------------------------------
-- Destination-group widgets
-- ---------------------------------------------------------------------------
local function AcquireGroup(parent)
    local grp = table.remove(groupPool)
    if not grp then
        grp = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        if grp.SetBackdrop then
            grp:SetBackdrop({
                bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
        end

        -- Header: clickable portal icon + destination label + dismiss-group X.
        -- SecureActionButtonTemplate keeps the spell cast in WoW's secure context,
        -- avoiding the "tainted string" block on CastSpellByName.
        local icon = CreateFrame("Button", nil, grp, "SecureActionButtonTemplate")
        icon:SetSize(30, 30)
        icon:SetPoint("TOPLEFT", 6, -4)
        icon:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        icon:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
        icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        icon:SetAttribute("type", "spell")
        icon:RegisterForClicks("AnyUp", "AnyDown")
        icon:SetScript("OnEnter", function(self)
            local destination = self._destination
            local spellInfo = destination and PI.GetPortalSpellForDestination and PI.GetPortalSpellForDestination(destination)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if spellInfo and spellInfo.name then
                GameTooltip:SetText(spellInfo.name, 1, 1, 1)
                GameTooltip:AddLine("Click to cast.", 0.8, 0.8, 0.8)
            else
                GameTooltip:SetText(destination or "Portal", 1, 1, 1)
                GameTooltip:AddLine("|cffff6060Portal spell not available.|r", 1, 0.3, 0.3)
            end
            GameTooltip:Show()
        end)
        icon:SetScript("OnLeave", GameTooltip_Hide)
        grp.icon = icon

        local label = grp:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", icon, "RIGHT", 8, 6)
        label:SetJustifyH("LEFT")
        grp.label = label

        local count = grp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        count:SetPoint("LEFT", label, "LEFT", 0, -14)
        count:SetJustifyH("LEFT")
        grp.count = count

        grp.rows = {}
    end
    grp:SetParent(parent)
    grp:Show()
    return grp
end

local function ReleaseGroup(grp)
    for _, row in ipairs(grp.rows) do
        ReleaseRow(row)
    end
    for i = #grp.rows, 1, -1 do grp.rows[i] = nil end
    grp:Hide()
    grp:ClearAllPoints()
    grp:SetParent(UIParent)
    if not InCombatLockdown() then
        grp.icon:SetAttribute("spell", "")
    end
    groupPool[#groupPool + 1] = grp
end

-- ---------------------------------------------------------------------------
-- Expanded frame
-- ---------------------------------------------------------------------------
local FRAME_WIDTH = 300
local PADDING_TOP = 34   -- title bar height
local PADDING_BOTTOM = 8
-- Scroll viewport: holds ~4 average-sized tickets before the scrollbar kicks in.
-- A group header is 40px and each row is 20px, so a single group with one
-- ticket is ~64px; four such groups ≈ 256px. Mixed stacks fit more.
local SCROLL_VIEWPORT_HEIGHT = 260

local function SaveExpandedGeometry()
    local q = GetQueueUIDB()
    if not q or not expandedFrame then return end
    local point, _, _, x, y = expandedFrame:GetPoint()
    q.expanded.point = point or "CENTER"
    q.expanded.x = x or 0
    q.expanded.y = y or 0
end

local function SaveMinimizedGeometry()
    local q = GetQueueUIDB()
    if not q or not minimizedFrame then return end
    local point, _, _, x, y = minimizedFrame:GetPoint()
    q.minimized.point = point or "CENTER"
    q.minimized.x = x or 0
    q.minimized.y = y or 0
end

local function CreateExpandedFrame()
    local f = CreateFrame("Frame", "PortalInviterByIllusionQueueFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(FRAME_WIDTH, PADDING_TOP + SCROLL_VIEWPORT_HEIGHT + PADDING_BOTTOM)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:Hide()

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
    end

    local q = GetQueueUIDB()
    if q and q.expanded.point and q.expanded.x and q.expanded.y then
        f:ClearAllPoints()
        f:SetPoint(q.expanded.point, UIParent, q.expanded.point, q.expanded.x, q.expanded.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 260, 0)
    end

    -- Title bar drag
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 8, -6)
    titleBar:SetPoint("TOPRIGHT", -8, -6)
    titleBar:SetHeight(20)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing(); SaveExpandedGeometry() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("|cff69ccf0Portal Queue|r")
    f.title = title

    -- Close X (with confirmation)
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", 2, 2)
    closeBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    closeBtn:SetScript("OnClick", function()
        StaticPopup_Show("PORTALINVITERBYILLUSION_QUEUE_CLOSE_CONFIRM")
    end)

    -- Minimize button
    local minBtn = CreateFrame("Button", nil, f)
    minBtn:SetSize(16, 16)
    minBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", 2, -6)
    minBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    minBtn:SetNormalTexture("Interface\\Buttons\\UI-MinusButton-Up")
    minBtn:SetPushedTexture("Interface\\Buttons\\UI-MinusButton-Down")
    minBtn:SetHighlightTexture("Interface\\Buttons\\UI-MinusButton-Hilight", "ADD")
    minBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Minimize", 1, 1, 1)
        GameTooltip:Show()
    end)
    minBtn:SetScript("OnLeave", GameTooltip_Hide)
    minBtn:SetScript("OnClick", function()
        local uidb = GetQueueUIDB()
        if uidb then uidb.lastState = "minimized" end
        f:Hide()
        if PI.RefreshQueueFrame then PI.RefreshQueueFrame() end
    end)
    f.minBtn = minBtn

    -- Scrollable content area. The outer frame has a fixed height; the inner
    -- `content` grows with the number of tickets and scrolls vertically when
    -- it exceeds the viewport. We use a FauxScrollFrame-style layout but with
    -- the simpler UIPanelScrollFrameTemplate (one ScrollFrame + one scroll
    -- child sized to fit all groups).
    local scroll = CreateFrame("ScrollFrame", "$parentScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT",     10, -PADDING_TOP)
    scroll:SetPoint("BOTTOMRIGHT", -28, PADDING_BOTTOM)  -- leave room for scrollbar
    f.scroll = scroll

    -- Scrollbar styling: nudge it a bit so it doesn't overlap the border.
    local sb = _G[scroll:GetName() .. "ScrollBar"]
    if sb then
        sb:ClearAllPoints()
        sb:SetPoint("TOPRIGHT",    scroll, "TOPRIGHT",     18, -16)
        sb:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT",  18,  16)
    end

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(FRAME_WIDTH - 38, 1)
    scroll:SetScrollChild(content)
    f.content = content

    f.activeGroups = {}

    return f
end

-- ---------------------------------------------------------------------------
-- Minimized frame — a collapsed version of the expanded window. Same width
-- and styling, but only the title bar is shown (no scroll area, no tickets).
-- Has its own drag, maximize (+), and close (X) controls.
-- ---------------------------------------------------------------------------
local MINIMIZED_HEIGHT = 34
local MINIMIZED_WIDTH  = 200

local function CreateMinimizedFrame()
    local f = CreateFrame("Frame", "PortalInviterByIllusionQueueMini", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(MINIMIZED_WIDTH, MINIMIZED_HEIGHT)
    f:SetFrameStrata("MEDIUM")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:Hide()

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 },
        })
    end

    local q = GetQueueUIDB()
    if q and q.minimized.point and q.minimized.x and q.minimized.y then
        f:ClearAllPoints()
        f:SetPoint(q.minimized.point, UIParent, q.minimized.point, q.minimized.x, q.minimized.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 260, 120)
    end

    -- Title bar drag
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 8, -6)
    titleBar:SetPoint("TOPRIGHT", -8, -6)
    titleBar:SetHeight(20)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() f:StopMovingOrSizing(); SaveMinimizedGeometry() end)
    titleBar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Portal Queue", 1, 1, 1)
        GameTooltip:AddLine("Drag to move. Click the + to expand.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    titleBar:SetScript("OnLeave", GameTooltip_Hide)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("|cff69ccf0Portal Queue|r")
    f.title = title

    -- Close X (same confirmation popup as the expanded frame).
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", 2, 2)
    closeBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    closeBtn:SetScript("OnClick", function()
        StaticPopup_Show("PORTALINVITERBYILLUSION_QUEUE_CLOSE_CONFIRM")
    end)

    -- Maximize (+) button — mirrors the expanded frame's minus button.
    local maxBtn = CreateFrame("Button", nil, f)
    maxBtn:SetSize(16, 16)
    maxBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", 2, -6)
    maxBtn:SetFrameLevel(titleBar:GetFrameLevel() + 5)
    maxBtn:SetNormalTexture("Interface\\Buttons\\UI-PlusButton-Up")
    maxBtn:SetPushedTexture("Interface\\Buttons\\UI-PlusButton-Down")
    maxBtn:SetHighlightTexture("Interface\\Buttons\\UI-PlusButton-Hilight", "ADD")
    maxBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Expand", 1, 1, 1)
        GameTooltip:Show()
    end)
    maxBtn:SetScript("OnLeave", GameTooltip_Hide)
    maxBtn:SetScript("OnClick", function()
        local uidb = GetQueueUIDB()
        if uidb then uidb.lastState = "expanded" end
        f:Hide()
        if PI.RefreshQueueFrame then PI.RefreshQueueFrame() end
    end)
    f.maxBtn = maxBtn

    return f
end

-- ---------------------------------------------------------------------------
-- Refresh logic (state machine)
-- ---------------------------------------------------------------------------
local function FormatRelativeJoinTime(createdAt)
    if not createdAt then return "" end
    local secs = math.max(0, math.floor(GetTime() - createdAt))
    if secs < 60 then return string.format("%ds ago", secs) end
    local mins = math.floor(secs / 60)
    if mins < 60 then return string.format("%dm ago", mins) end
    return string.format("%dh ago", math.floor(mins / 60))
end

local function PopulateGroup(grp, groupData)
    local destination = groupData.destination
    grp._destination = destination
    grp.icon._destination = destination

    local r, g, b = 0.4, 0.55, 0.75
    if DestinationColor then r, g, b = DestinationColor(destination) end
    if grp.SetBackdropColor then
        grp:SetBackdropColor(0, 0, 0, 0.6)
        if groupData.hasCasting then
            grp:SetBackdropBorderColor(1.0, 0.85, 0.3, 1.0)  -- gold glow while casting
        else
            grp:SetBackdropBorderColor(r, g, b, 0.9)
        end
    end

    -- Icon
    local spellInfo = PI.GetPortalSpellForDestination and PI.GetPortalSpellForDestination(destination)
    if spellInfo and spellInfo.name then
        grp.icon:SetNormalTexture(spellInfo.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        grp.icon:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if not InCombatLockdown() then
            grp.icon:SetAttribute("spell", spellInfo.name)
        end
        grp.icon:Enable()
    else
        grp.icon:SetNormalTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        if not InCombatLockdown() then
            grp.icon:SetAttribute("spell", "")
        end
        grp.icon:Disable()
    end

    -- Label / count
    local destHex = DestinationColorHex and DestinationColorHex(destination) or "a8d9ff"
    local displayDest = DisplayDestination and DisplayDestination(destination) or destination
    grp.label:SetText(string.format("|cff%s%s|r", destHex, displayDest))
    local n = #groupData.entries
    grp.count:SetText(string.format("%d ticket%s", n, n == 1 and "" or "s"))

    -- Handlers
    -- (icon click is handled by SecureActionButtonTemplate via the "spell"
    --  attribute; per-row dismiss handlers are wired below. No per-group
    --  dismiss-all is exposed — dismissing the last row collapses the group.)

    -- Rows
    local rows = grp.rows
    -- Reuse / shrink
    for i = n + 1, #rows do
        ReleaseRow(rows[i])
        rows[i] = nil
    end
    for i = 1, n do
        local entry = groupData.entries[i]
        local row = rows[i]
        if not row then
            row = AcquireRow(grp)
            rows[i] = row
        end
        row:ClearAllPoints()
        if i == 1 then
            row:SetPoint("TOPLEFT",  grp, "TOPLEFT",  6, -38)
            row:SetPoint("TOPRIGHT", grp, "TOPRIGHT", -6, -38)
        else
            row:SetPoint("TOPLEFT",  rows[i - 1], "BOTTOMLEFT",  0, -2)
            row:SetPoint("TOPRIGHT", rows[i - 1], "BOTTOMRIGHT", 0, -2)
        end

        local classHex = ClassColorHex and ClassColorHex(entry.class) or "ffffff"
        local rel = FormatRelativeJoinTime(entry.createdAt)
        local markerTex = ""
        if entry.marker and entry.marker >= 1 and entry.marker <= 8 then
            -- Inline raid-target icon escape. Size 0 auto-sizes to line height.
            markerTex = string.format(
                "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:0|t ",
                entry.marker)
        end
        row.name:SetText(string.format("%s|cff%s%s|r  |cff888888%s|r",
            markerTex, classHex, entry.displayName or entry.normalized, rel))
        row.dismiss:SetScript("OnClick", function()
            if PI.QueueRemove then PI.QueueRemove(entry.normalized) end
        end)
    end

    -- Height: 34 (icon area) + n rows * 20 + padding
    local height = 40 + (n * 20) + 4
    grp:SetHeight(height)
    return height
end

local function LayoutExpandedFrame(groups)
    local f = expandedFrame
    local content = f.content

    -- Release old groups that aren't in the new snapshot.
    local active = f.activeGroups
    local seen = {}
    for _, g in ipairs(groups) do seen[g.destination] = true end
    for dest, grp in pairs(active) do
        if not seen[dest] then
            ReleaseGroup(grp)
            active[dest] = nil
        end
    end

    -- Place / create groups in order.
    local totalHeight = 0
    local prev
    for _, groupData in ipairs(groups) do
        local grp = active[groupData.destination]
        if not grp then
            grp = AcquireGroup(content)
            active[groupData.destination] = grp
        end
        grp:ClearAllPoints()
        if prev then
            grp:SetPoint("TOPLEFT",  prev, "BOTTOMLEFT", 0, -4)
            grp:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -4)
        else
            grp:SetPoint("TOPLEFT",  content, "TOPLEFT", 0, 0)
            grp:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
        end
        local h = PopulateGroup(grp, groupData)
        totalHeight = totalHeight + h + 4
        prev = grp
    end

    if totalHeight < 1 then totalHeight = 1 end
    content:SetHeight(totalHeight)
    -- Outer frame stays at a fixed height; the ScrollFrame clips overflow and
    -- shows its scrollbar automatically when content > viewport.
end

local function UpdateMinimizedTitle(total)
    local f = minimizedFrame
    if not f or not f.title then return end
    f.title:SetText(string.format("|cff69ccf0Portal Queue|r  |cffaaaaaa(%d)|r", total))
end

local function RefreshQueueFrame()
    if not expandedFrame then expandedFrame = CreateExpandedFrame() end
    if not minimizedFrame then minimizedFrame = CreateMinimizedFrame() end

    local groups, total
    if PI.QueueSnapshot then
        groups, total = PI.QueueSnapshot()
    end
    total = total or 0

    -- Empty queue → hide everything; reset force-hidden so the next ticket
    -- re-opens cleanly.
    if total == 0 then
        expandedFrame:Hide()
        minimizedFrame:Hide()
        userForcedHidden = false
        return
    end

    -- Non-empty but user force-closed: stay hidden until queue clears.
    if userForcedHidden then
        expandedFrame:Hide()
        minimizedFrame:Hide()
        return
    end

    local uidb = GetQueueUIDB()
    local state = (uidb and uidb.lastState) or "expanded"

    if state == "minimized" then
        expandedFrame:Hide()
        UpdateMinimizedTitle(total)
        minimizedFrame:Show()
    else
        minimizedFrame:Hide()
        LayoutExpandedFrame(groups or {})
        expandedFrame:Show()
    end
end

PI.RefreshQueueFrame = RefreshQueueFrame

-- Periodic tick so relative "Xs ago" labels stay current while the panel is
-- open. Extremely cheap: only fires when the expanded frame is visible.
local ticker = CreateFrame("Frame")
ticker.elapsed = 0
ticker:SetScript("OnUpdate", function(self, dt)
    self.elapsed = self.elapsed + dt
    if self.elapsed < 5 then return end
    self.elapsed = 0
    if expandedFrame and expandedFrame:IsShown() then
        RefreshQueueFrame()
    end
end)
