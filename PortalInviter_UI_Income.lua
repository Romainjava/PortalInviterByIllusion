-- Income window: Log / Stats / Settings tabs.
-- Pure UI — all data model / stats helpers live in PortalInviter_Income.lua.

local ADDON_NAME, PI = ...

local Print              = PI.Print
local GetCharDB          = PI.GetCharDB
local FormatCopper       = PI.FormatCopper
local FormatRelativeTime = PI.FormatRelativeTime
local ClassColorHex      = PI.ClassColorHex
local DestinationColor   = PI.DestinationColor
local DestinationColorHex= PI.DestinationColorHex
local DisplayDestination = PI.DisplayDestination
local BucketTrades       = PI.BucketTrades
local GetRangeBounds     = PI.GetRangeBounds
local GetIncomeSummary        = PI.GetIncomeSummary
local GetDestinationSummary   = PI.GetDestinationSummary
local BuildTradesCSV          = PI.BuildTradesCSV
local WEEKDAY_NAMES      = PI.WEEKDAY_NAMES
local MONTH_NAMES        = PI.MONTH_NAMES
local RANGE_ORDER        = PI.RANGE_ORDER

-- Classifies each range key into a "scope" so the highlight strips can hide
-- figures that don't make sense for the selected window:
--   day  : single day        -> weekday/month buckets are meaningless
--   week : week or month      -> weekday useful, month meaningless
--   year : year or all-time   -> weekday and month both useful
local RANGE_SCOPE = {
    today     = "day",  yesterday = "day",
    thisWeek  = "week", lastWeek  = "week",
    thisMonth = "week", lastMonth = "week",
    thisYear  = "year", allTime   = "year",
}

local incomeFrame
local ShowIncomeFrame  -- forward declared

StaticPopupDialogs["PORTALINVITER_RESET_INCOME"] = {
    text         = "Really delete all PortalInviter income history for this character?",
    button1      = "Delete",
    button2      = "Cancel",
    OnAccept     = function()
        local db = GetCharDB()
        if db then db.trades = {} end
        if incomeFrame and incomeFrame.Refresh then incomeFrame:Refresh() end
        Print("Income history cleared.")
    end,
    timeout      = 0,
    whileDead    = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function FormatRangeLabel(rangeKey, summary)
    if not summary then return "—" end
    return string.format("%s  |cffbbbbbb(%d trade%s)|r",
        FormatCopper(summary.totalCopper),
        summary.tradeCount,
        summary.tradeCount == 1 and "" or "s")
end

-- Persistent, per-account UI state (frame geometry, scale). Kept in the top
-- level PortalInviterDB so it survives across characters.
local function GetUIDB()
    if type(PortalInviterDB) ~= "table" then return nil end
    if type(PortalInviterDB.ui) ~= "table" then PortalInviterDB.ui = {} end
    local ui = PortalInviterDB.ui
    if type(ui.frame) ~= "table" then ui.frame = {} end
    return ui
end

-- Small factory: one "stat tile" (label over value) used on the Stats page.
local function CreateStatTile(parent, labelText, width, height)
    local tile = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tile:SetSize(width or 100, height or 42)
    if tile.SetBackdrop then
        tile:SetBackdrop({
            bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        tile:SetBackdropColor(0, 0, 0, 0.45)
        tile:SetBackdropBorderColor(0.35, 0.35, 0.40, 1)
    end

    local lbl = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 6, -4)
    lbl:SetText(labelText)
    tile.label = lbl

    local val = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    val:SetPoint("BOTTOMLEFT", 6, 5)
    val:SetPoint("BOTTOMRIGHT", -6, 5)
    val:SetJustifyH("LEFT")
    tile.value = val

    return tile
end

local function CreateIncomeFrame()
    if incomeFrame then return incomeFrame end

    local ui = GetUIDB() or { frame = {} }

    local f = CreateFrame("Frame", "PortalInviterIncomeFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    local savedW = tonumber(ui.frame.w) or 780
    local savedH = tonumber(ui.frame.h) or 520
    if savedW < 680 then savedW = 680 end
    if savedH < 440 then savedH = 440 end
    f:SetSize(savedW, savedH)
    if ui.frame.point and ui.frame.x and ui.frame.y then
        f:ClearAllPoints()
        f:SetPoint(ui.frame.point, UIParent, ui.frame.point, ui.frame.x, ui.frame.y)
    else
        f:SetPoint("CENTER")
    end
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(680, 520, 1400, 900)
    elseif f.SetMinResize then
        f:SetMinResize(680, 520)
        f:SetMaxResize(1400, 900)
    end
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")
    f:Hide()

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    local function SaveGeometry()
        local uidb = GetUIDB()
        if not uidb then return end
        local point, _, _, x, y = f:GetPoint()
        uidb.frame.point = point or "CENTER"
        uidb.frame.x = x or 0
        uidb.frame.y = y or 0
        uidb.frame.w = f:GetWidth()
        uidb.frame.h = f:GetHeight()
    end

    -- Title / drag
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", -28, -8)
    titleBar:SetHeight(26)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop",  function() f:StopMovingOrSizing(); SaveGeometry() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)
    title:SetText("|cff69ccf0PortalInviter|r — Income")

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Resize handle (bottom-right corner).
    local resizer = CreateFrame("Button", nil, f)
    resizer:SetSize(16, 16)
    resizer:SetPoint("BOTTOMRIGHT", -4, 4)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizer:SetScript("OnMouseDown", function(self)
        f:StartSizing("BOTTOMRIGHT")
    end)
    resizer:SetScript("OnMouseUp", function(self)
        f:StopMovingOrSizing()
        SaveGeometry()
        if f.Refresh then f:Refresh() end
    end)

    -- Content inset (holds all tab pages so they sit on the standard dark panel).
    local content = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
    content:SetPoint("TOPLEFT", 12, -72)
    content:SetPoint("BOTTOMRIGHT", -12, 32)

    -- Footer status bar (below content inset, above resize grip).
    local footer = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    footer:SetPoint("TOPLEFT", content, "BOTTOMLEFT", 0, -2)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 6)
    if footer.SetBackdrop then
        footer:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = nil,
        })
        footer:SetBackdropColor(0, 0, 0, 0.35)
    end

    local footerLeft = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footerLeft:SetPoint("LEFT", 8, 0)
    footerLeft:SetJustifyH("LEFT")

    local footerRight = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footerRight:SetPoint("RIGHT", -8, 0)
    footerRight:SetJustifyH("RIGHT")

    -- Nav buttons (plain UIPanelButtonTemplate, active one stays highlighted).
    local tabs = {}
    local tabFrames = {}
    local TAB_DEFS = { "Log", "Stats", "Settings" }
    local activeTab = 1
    local detailDestination = nil  -- nil = Stats overview; string = drilled-in destination
    local ShowDestinationDetail    -- forward-declared; assigned after detailPage is built
    local HideDestinationDetail    -- forward-declared; assigned after detailPage is built

    local function SetActiveTab(index)
        -- Leaving the Stats tab clears any active drill-in so re-entering shows the overview.
        if index ~= 2 and HideDestinationDetail then HideDestinationDetail() end
        activeTab = index
        for i, btn in ipairs(tabs) do
            if i == index then
                btn:LockHighlight()
            else
                btn:UnlockHighlight()
            end
            tabFrames[i]:SetShown(i == index)
        end
        if f.Refresh then f:Refresh() end
    end

    for i, name in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", "PortalInviterIncomeTab" .. i, f, "UIPanelButtonTemplate")
        btn:SetSize(70, 22)
        btn:SetText(name)
        if i == 1 then
            btn:SetPoint("BOTTOMLEFT", content, "TOPLEFT", 4, -1)
        else
            btn:SetPoint("LEFT", tabs[i - 1], "RIGHT", 4, 0)
        end
        btn:SetScript("OnClick", function() SetActiveTab(i) end)
        tabs[i] = btn

        local page = CreateFrame("Frame", nil, content)
        page:SetPoint("TOPLEFT", 8, -8)
        page:SetPoint("BOTTOMRIGHT", -8, 8)
        page:Hide()
        tabFrames[i] = page
    end

    -- Cross-tab communication: setting a filter here (destination/range)
    -- switches to Log and applies it. Populated after RefreshLog exists.
    local ApplyLogFilter  -- forward declaration

    ----------------------------------------------------------------
    -- Log tab
    ----------------------------------------------------------------
    local logPage = tabFrames[1]

    -- Filter bar: search box + destination dropdown + range dropdown.
    local filterBar = CreateFrame("Frame", nil, logPage)
    filterBar:SetPoint("TOPLEFT", 0, 0)
    filterBar:SetPoint("TOPRIGHT", 0, 0)
    filterBar:SetHeight(28)

    local searchLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    searchLabel:SetPoint("LEFT", 2, 0)
    searchLabel:SetText("Search:")

    local searchBox = CreateFrame("EditBox", "PortalInviterLogSearch", filterBar, "InputBoxTemplate")
    searchBox:SetSize(140, 20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(40)

    local destLabel = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    destLabel:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
    destLabel:SetText("Destination:")

    local destFilter = CreateFrame("Frame", "PortalInviterLogDestFilter", filterBar, "UIDropDownMenuTemplate")
    destFilter:SetPoint("LEFT", destLabel, "RIGHT", -6, -2)

    local rangeLabelLog = filterBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rangeLabelLog:SetPoint("LEFT", destFilter, "RIGHT", 0, 2)
    rangeLabelLog:SetText("Range:")

    local rangeFilter = CreateFrame("Frame", "PortalInviterLogRangeFilter", filterBar, "UIDropDownMenuTemplate")
    rangeFilter:SetPoint("LEFT", rangeLabelLog, "RIGHT", -6, -2)

    local clearFilterBtn = CreateFrame("Button", nil, filterBar, "UIPanelButtonTemplate")
    clearFilterBtn:SetSize(90, 20)
    clearFilterBtn:SetPoint("LEFT", rangeFilter, "RIGHT", 0, 2)
    clearFilterBtn:SetText("Clear filters")

    -- Forward declaration so rows (created before the button script) can call it.
    local ClearLogFilters

    -- Filter state
    local logSearchText     = ""
    local logDestFilter     = nil     -- nil = all; "unknown" = only unknown
    local logRangeFilter    = "allTime"
    local logSortKey        = "time"  -- "time" | "amount" | "player" | "destination"
    local logSortDir        = -1      -- 1 asc, -1 desc (default newest first)

    -- Sortable column headers
    local header = CreateFrame("Frame", nil, logPage)
    header:SetPoint("TOPLEFT", 0, -32)
    header:SetPoint("TOPRIGHT", 0, -32)
    header:SetHeight(20)

    local headerBG = header:CreateTexture(nil, "BACKGROUND")
    headerBG:SetAllPoints()
    headerBG:SetColorTexture(1, 1, 1, 0.04)

    -- Each header is a button so clicking toggles sort.
    local headerButtons = {}
    local function MakeHeaderButton(key, labelText, xOffset, width, justify)
        local btn = CreateFrame("Button", nil, header)
        btn:SetPoint("LEFT", header, "LEFT", xOffset, 0)
        btn:SetSize(width, 20)
        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn.text:SetPoint("LEFT", btn, "LEFT", 0, 0)
        btn.text:SetPoint("RIGHT", btn, "RIGHT", -10, 0)
        btn.text:SetJustifyH(justify or "LEFT")
        btn.arrow = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn.arrow:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
        btn.labelText = labelText
        btn.sortKey   = key
        btn:SetScript("OnClick", function()
            if logSortKey == key then
                logSortDir = -logSortDir
            else
                logSortKey = key
                logSortDir = (key == "time" or key == "amount") and -1 or 1
            end
            if f.Refresh then f:Refresh() end
        end)
        headerButtons[#headerButtons + 1] = btn
        return btn
    end

    local hTime   = MakeHeaderButton("time",        "Time",        4,   150, "LEFT")
    local hAmount = MakeHeaderButton("amount",      "Amount",      160, 150, "LEFT")
    local hPlayer = MakeHeaderButton("player",      "Player",      320, 180, "LEFT")
    local hDest   = MakeHeaderButton("destination", "Destination", 504, 160, "LEFT")

    local function UpdateHeaderArrows()
        for _, btn in ipairs(headerButtons) do
            btn.text:SetText(btn.labelText)
            btn.arrow:SetText(
                btn.sortKey == logSortKey
                    and (logSortDir == 1 and "|cffffd100^|r" or "|cffffd100v|r")
                    or ""
            )
        end
    end

    local ROW_HEIGHT = 18
    local function VisibleRows()
        local h = logPage:GetHeight() - 32 - 20 - 16  -- filter bar + header + pagination
        if h < ROW_HEIGHT then h = ROW_HEIGHT end
        return math.max(4, math.floor(h / ROW_HEIGHT))
    end

    local scrollFrame = CreateFrame("ScrollFrame", "PortalInviterIncomeLogScroll", logPage, "FauxScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 0, -52)
    scrollFrame:SetPoint("BOTTOMRIGHT", -24, 16)

    -- Pagination footer (bottom-right of the log page).
    local pagination = logPage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pagination:SetPoint("BOTTOMRIGHT", 0, 0)
    pagination:SetJustifyH("RIGHT")

    -- Empty-state label (centered in the scroll area).
    local emptyState = logPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    emptyState:SetPoint("CENTER", scrollFrame, "CENTER", 0, 0)
    emptyState:SetJustifyH("CENTER")
    emptyState:Hide()

    local rows = {}
    local MAX_ROWS = 60  -- created once, only VisibleRows() are shown at a time

    -- Tooltip helper
    local function ShowRowTooltip(self)
        local entry = self.entry
        if not entry then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine("PortalInviter", 0.4, 0.8, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Time",        date("%Y-%m-%d %H:%M:%S", entry.t or 0), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Player",      entry.player or "?",                    1, 1, 1, 1, 1, 1)
        if entry.class and entry.class ~= "" then
            GameTooltip:AddDoubleLine("Class",   entry.class,                            1, 1, 1, 1, 1, 1)
        end
        GameTooltip:AddDoubleLine("Destination", DisplayDestination(entry.destination),  1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Amount",      FormatCopper(entry.copper),             1, 1, 1, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaaLeft-click:|r filter by this destination", 1, 1, 1)
        GameTooltip:AddLine("|cffaaaaaaRight-click:|r clear filters", 1, 1, 1)
        GameTooltip:Show()
    end

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, logPage)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", 0, -(i - 1) * ROW_HEIGHT)

        -- Alternating stripe background
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        if i % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.04)
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
        end

        -- Hover highlight
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0.4, 0.6, 0.9, 0.15)

        row.time = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.time:SetWidth(150); row.time:SetJustifyH("LEFT")

        row.amount = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.amount:SetPoint("LEFT", row, "LEFT", 160, 0)
        row.amount:SetWidth(150); row.amount:SetJustifyH("LEFT")

        row.player = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.player:SetPoint("LEFT", row, "LEFT", 320, 0)
        row.player:SetWidth(180); row.player:SetJustifyH("LEFT")

        row.destination = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.destination:SetPoint("LEFT", row, "LEFT", 504, 0)
        row.destination:SetWidth(160); row.destination:SetJustifyH("LEFT")

        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnEnter", ShowRowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self, button)
            if not self.entry then return end
            if button == "LeftButton" then
                if ApplyLogFilter then
                    ApplyLogFilter({ destination = self.entry.destination or "unknown" })
                end
            elseif button == "RightButton" then
                if ClearLogFilters then ClearLogFilters() end
            end
        end)
        rows[i] = row
    end

    -- Apply a filter from another tab (Stats drill-down) and jump to Log.
    ApplyLogFilter = function(filters)
        if filters.destination ~= nil then logDestFilter = filters.destination end
        if filters.range       ~= nil then logRangeFilter = filters.range      end
        SetActiveTab(1)
    end

    local function PassesFilters(entry)
        if logDestFilter ~= nil then
            local d = entry.destination or "unknown"
            if d ~= logDestFilter then return false end
        end
        if logSearchText ~= "" then
            local p = (entry.player or ""):lower()
            if not p:find(logSearchText, 1, true) then return false end
        end
        return true
    end

    local function RefreshLog()
        local db = GetCharDB()
        local trades = db and db.trades or {}

        -- Apply range
        local from, to = GetRangeBounds(logRangeFilter or "allTime")

        local filtered = {}
        for i = 1, #trades do
            local e = trades[i]
            local t = e.t or 0
            if t >= from and t <= to and PassesFilters(e) then
                filtered[#filtered + 1] = e
            end
        end

        -- Sort
        local key = logSortKey
        local dir = logSortDir
        table.sort(filtered, function(a, b)
            local av, bv
            if key == "amount" then
                av, bv = a.copper or 0, b.copper or 0
            elseif key == "player" then
                av, bv = (a.player or ""):lower(), (b.player or ""):lower()
            elseif key == "destination" then
                av, bv = (a.destination or ""):lower(), (b.destination or ""):lower()
            else
                av, bv = a.t or 0, b.t or 0
            end
            if av == bv then
                return (a.t or 0) > (b.t or 0)
            end
            if dir == 1 then return av < bv else return av > bv end
        end)

        local numEntries = #filtered
        local visible    = VisibleRows()

        -- Hide rows we're not using this layout cycle.
        for i = visible + 1, MAX_ROWS do rows[i]:Hide() end

        if numEntries == 0 then
            local hasAny = (#trades > 0)
            if hasAny then
                emptyState:SetText("|cffaaaaaaNo trades match your filters.|r")
            else
                emptyState:SetText("|cffaaaaaaNo trades recorded yet.|r")
            end
            emptyState:Show()
            for i = 1, MAX_ROWS do rows[i]:Hide() end
            FauxScrollFrame_Update(scrollFrame, 0, visible, ROW_HEIGHT)
            pagination:SetText(string.format("0 of %d trades", #trades))
            UpdateHeaderArrows()
            return
        else
            emptyState:Hide()
        end

        FauxScrollFrame_Update(scrollFrame, numEntries, visible, ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(scrollFrame)

        for i = 1, visible do
            local idx = i + offset
            local row = rows[i]
            local entry = filtered[idx]
            if entry then
                row.entry = entry
                row.time:SetText(FormatRelativeTime(entry.t))
                row.amount:SetText(FormatCopper(entry.copper))
                local playerText = entry.player or "?"
                if entry.class then
                    playerText = string.format("|cff%s%s|r", ClassColorHex(entry.class), playerText)
                end
                row.player:SetText(playerText)
                local dest = entry.destination or "unknown"
                row.destination:SetText(string.format("|cff%s%s|r", DestinationColorHex(dest), DisplayDestination(dest)))
                row:Show()
            else
                row:Hide()
                row.entry = nil
            end
        end

        local firstVisible = offset + 1
        local lastVisible  = math.min(numEntries, offset + visible)
        pagination:SetText(string.format("Showing %d–%d of %d  (total: %d)",
            firstVisible, lastVisible, numEntries, #trades))

        UpdateHeaderArrows()
    end

    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshLog)
    end)

    searchBox:SetScript("OnTextChanged", function(self)
        logSearchText = (self:GetText() or ""):lower()
        RefreshLog()
    end)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    ClearLogFilters = function()
        logSearchText  = ""
        logDestFilter  = nil
        logRangeFilter = "allTime"
        searchBox:SetText("")
        UIDropDownMenu_SetText(destFilter,  "All")
        UIDropDownMenu_SetText(rangeFilter, "All time")
        RefreshLog()
    end
    clearFilterBtn:SetScript("OnClick", ClearLogFilters)

    -- Initialize dropdowns (menus populated fresh each open so newly seen
    -- destinations show up without a reload).
    UIDropDownMenu_SetWidth(destFilter, 110)
    UIDropDownMenu_Initialize(destFilter, function(self, level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All"; info.notCheckable = false
        info.checked = (logDestFilter == nil)
        info.func = function()
            logDestFilter = nil
            UIDropDownMenu_SetText(destFilter, "All")
            RefreshLog()
        end
        UIDropDownMenu_AddButton(info, level)

        local seen = {}
        local db = GetCharDB()
        for _, t in ipairs(db and db.trades or {}) do
            local d = t.destination or "unknown"
            seen[d] = true
        end
        local sorted = {}
        for d in pairs(seen) do sorted[#sorted + 1] = d end
        table.sort(sorted)
        for _, d in ipairs(sorted) do
            local info2 = UIDropDownMenu_CreateInfo()
            info2.text = DisplayDestination(d)
            info2.notCheckable = false
            info2.checked = (logDestFilter == d)
            info2.func = function()
                logDestFilter = d
                UIDropDownMenu_SetText(destFilter, DisplayDestination(d))
                RefreshLog()
            end
            UIDropDownMenu_AddButton(info2, level)
        end
    end)
    UIDropDownMenu_SetText(destFilter, "All")

    UIDropDownMenu_SetWidth(rangeFilter, 110)
    UIDropDownMenu_Initialize(rangeFilter, function(self, level)
        for _, def in ipairs(RANGE_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = def.label
            info.checked = (def.key == logRangeFilter)
            info.func    = function()
                logRangeFilter = def.key
                UIDropDownMenu_SetText(rangeFilter, def.label)
                RefreshLog()
            end
            UIDropDownMenu_AddButton(info, level)
        end
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All time"
        info.checked = (logRangeFilter == "allTime")
        info.func = function()
            logRangeFilter = "allTime"
            UIDropDownMenu_SetText(rangeFilter, "All time")
            RefreshLog()
        end
    end)
    UIDropDownMenu_SetText(rangeFilter, "All time")

    ----------------------------------------------------------------
    -- Stats tab
    ----------------------------------------------------------------
    local statsPage = tabFrames[2]

    -- Two columns: Summary list on the left, Detail panel on the right.
    local leftCol = CreateFrame("Frame", nil, statsPage)
    leftCol:SetPoint("TOPLEFT", 0, 0)
    leftCol:SetPoint("BOTTOMLEFT", 0, 0)
    leftCol:SetWidth(230)

    local rightCol = CreateFrame("Frame", nil, statsPage)
    rightCol:SetPoint("TOPLEFT", leftCol, "TOPRIGHT", 12, 0)
    rightCol:SetPoint("BOTTOMRIGHT", 0, 0)

    -- ---- Left column: summary ---------------------------------------------
    local summaryHeader = leftCol:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    summaryHeader:SetPoint("TOPLEFT", 0, 0)
    summaryHeader:SetText("Summary")

    local selectedRangeKey = "thisMonth"
    local destSortMode     = "copper"  -- "copper" | "count"
    local rangeDropdown                 -- created below; forward-declared for summary row closures

    -- Saved range rows: clicking one becomes the detail range.
    local summaryRows = {}
    for i, def in ipairs(RANGE_ORDER) do
        local row = CreateFrame("Button", nil, leftCol)
        row:SetPoint("TOPLEFT", 0, -24 - (i - 1) * 38)
        row:SetPoint("TOPRIGHT", 0, -24 - (i - 1) * 38)
        row:SetHeight(36)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 1, 1, 0)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0.4, 0.6, 0.9, 0.15)

        -- Accent stripe on the left edge
        row.accent = row:CreateTexture(nil, "ARTWORK")
        row.accent:SetPoint("TOPLEFT", 0, 0)
        row.accent:SetPoint("BOTTOMLEFT", 0, 0)
        row.accent:SetWidth(3)
        row.accent:SetColorTexture(0.27, 0.47, 0.95, 0.9)

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.label:SetPoint("LEFT", 8, 0)
        row.label:SetWidth(90); row.label:SetJustifyH("LEFT")
        row.label:SetText(def.label .. ":")

        row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.value:SetPoint("TOPLEFT", 100, -4)
        row.value:SetJustifyH("LEFT")

        row.trades = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.trades:SetPoint("TOPLEFT", 100, -18)
        row.trades:SetJustifyH("LEFT")

        row.key = def.key

        row:SetScript("OnClick", function(self)
            selectedRangeKey = self.key
            UIDropDownMenu_SetSelectedValue(rangeDropdown, self.key)
            UIDropDownMenu_SetText(rangeDropdown, def.label)
            if f.Refresh then f:Refresh() end
        end)

        summaryRows[def.key] = row
    end

    -- ---- Right column: detail ---------------------------------------------
    local detailAnchor = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    detailAnchor:SetPoint("TOPLEFT", 0, 0)
    detailAnchor:SetText("Detail")

    local rangeLabel = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    rangeLabel:SetPoint("TOPLEFT", 0, -24)
    rangeLabel:SetText("Range:")

    rangeDropdown = CreateFrame("Frame", "PortalInviterIncomeRange", rightCol, "UIDropDownMenuTemplate")
    rangeDropdown:SetPoint("TOPLEFT", 44, -18)

    -- Three stat tiles for the selected range (Total / Trades / Avg per trade).
    local tileTotal  = CreateStatTile(rightCol, "Total income",    150, 46)
    local tileCount  = CreateStatTile(rightCol, "Trades",          100, 46)
    local tileUnique = CreateStatTile(rightCol, "Unique players",  110, 46)
    local tileAvg    = CreateStatTile(rightCol, "Avg per trade",   120, 46)

    tileTotal:SetPoint("TOPLEFT", 0, -56)
    tileCount:SetPoint("LEFT",  tileTotal, "RIGHT", 6, 0)
    tileUnique:SetPoint("LEFT", tileCount, "RIGHT", 6, 0)
    tileAvg:SetPoint("LEFT",    tileUnique,"RIGHT", 6, 0)

    -- Sort toggle (By income / By popularity)
    local sortLabel = rightCol:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sortLabel:SetPoint("TOPLEFT", 0, -112)
    sortLabel:SetText("|cff69ccf0By destination|r   sort:")

    local sortIncomeBtn = CreateFrame("Button", nil, rightCol, "UIPanelButtonTemplate")
    sortIncomeBtn:SetSize(80, 18)
    sortIncomeBtn:SetPoint("LEFT", sortLabel, "RIGHT", 6, 0)
    sortIncomeBtn:SetText("Income")

    local sortCountBtn = CreateFrame("Button", nil, rightCol, "UIPanelButtonTemplate")
    sortCountBtn:SetSize(82, 18)
    sortCountBtn:SetPoint("LEFT", sortIncomeBtn, "RIGHT", 4, 0)
    sortCountBtn:SetText("Popularity")

    -- Destination table column headers
    local destHeader = CreateFrame("Frame", nil, rightCol)
    destHeader:SetPoint("TOPLEFT", 0, -136)
    destHeader:SetPoint("TOPRIGHT", 0, -136)
    destHeader:SetHeight(16)

    local destHeaderBG = destHeader:CreateTexture(nil, "BACKGROUND")
    destHeaderBG:SetAllPoints()
    destHeaderBG:SetColorTexture(1, 1, 1, 0.04)

    local function DestHeaderLabel(text, xOff, width, justify)
        local fs = destHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("LEFT", destHeader, "LEFT", xOff, 0)
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "LEFT")
        fs:SetText(text)
        return fs
    end

    DestHeaderLabel("Destination", 4,   100, "LEFT")
    DestHeaderLabel("Trades",      108, 40,  "RIGHT")
    DestHeaderLabel("Income",      152, 70,  "RIGHT")
    DestHeaderLabel("Buyers",      226, 48,  "RIGHT")
    DestHeaderLabel("Share",       280, -1,  "LEFT")  -- grows with table width

    -- Scrollable destination list
    local destScroll = CreateFrame("ScrollFrame", "PortalInviterIncomeDestScroll", rightCol, "FauxScrollFrameTemplate")
    destScroll:SetPoint("TOPLEFT", 0, -154)
    destScroll:SetPoint("BOTTOMRIGHT", -24, 96)

    local DEST_ROW_HEIGHT   = 18
    local DEST_MAX_ROWS     = 14
    local destRows = {}

    local function ShowDestRowTooltip(self)
        local data = self.data
        if not data then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(DisplayDestination(data.destination), 1, 1, 1)
        GameTooltip:AddDoubleLine("Trades",  tostring(data.count),        1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Income",  FormatCopper(data.copper),   1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Buyers",  tostring(data.uniquePlayers or 0), 1, 1, 1, 1, 1, 1)
        if data.topBuyers and #data.topBuyers > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff69ccf0Top buyers|r", 1, 1, 1)
            for i, tb in ipairs(data.topBuyers) do
                if i > 3 then break end
                GameTooltip:AddDoubleLine(tb.player, FormatCopper(tb.copper), 1, 1, 1, 1, 1, 1)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("|cffaaaaaaClick:|r show destination details", 1, 1, 1)
        GameTooltip:Show()
    end

    for i = 1, DEST_MAX_ROWS do
        local row = CreateFrame("Button", nil, rightCol)
        row:SetHeight(DEST_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", destScroll, "TOPLEFT", 0, -(i - 1) * DEST_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", destScroll, "TOPRIGHT", 0, -(i - 1) * DEST_ROW_HEIGHT)

        -- Stripe bg
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        if i % 2 == 0 then
            row.bg:SetColorTexture(1, 1, 1, 0.04)
        else
            row.bg:SetColorTexture(0, 0, 0, 0)
        end

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(0.4, 0.6, 0.9, 0.15)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.name:SetWidth(100); row.name:SetJustifyH("LEFT")

        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("LEFT", row, "LEFT", 108, 0)
        row.count:SetWidth(40); row.count:SetJustifyH("RIGHT")

        row.income = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.income:SetPoint("LEFT", row, "LEFT", 152, 0)
        row.income:SetWidth(70); row.income:SetJustifyH("RIGHT")

        row.buyers = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.buyers:SetPoint("LEFT", row, "LEFT", 226, 0)
        row.buyers:SetWidth(48); row.buyers:SetJustifyH("RIGHT")

        -- Full-width gradient share bar (under the overlaid percentage label).
        row.barTrack = row:CreateTexture(nil, "BORDER")
        row.barTrack:SetPoint("LEFT", row, "LEFT", 280, 0)
        row.barTrack:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.barTrack:SetHeight(DEST_ROW_HEIGHT - 4)
        row.barTrack:SetColorTexture(1, 1, 1, 0.05)

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT", row.barTrack, "TOPLEFT", 0, 0)
        row.bar:SetPoint("BOTTOMLEFT", row.barTrack, "BOTTOMLEFT", 0, 0)
        row.bar:SetWidth(1)
        row.bar:SetColorTexture(0.4, 0.6, 0.9, 0.8)

        row.share = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.share:SetPoint("LEFT", row.barTrack, "LEFT", 4, 0)
        row.share:SetPoint("RIGHT", row.barTrack, "RIGHT", -4, 0)
        row.share:SetJustifyH("RIGHT")

        row:RegisterForClicks("LeftButtonUp")
        row:SetScript("OnEnter", ShowDestRowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:SetScript("OnClick", function(self)
            if self.data and ShowDestinationDetail then
                ShowDestinationDetail(self.data.destination)
            end
        end)

        row:Hide()
        destRows[i] = row
    end

    -- "Busiest" three-card strip.
    local busiestStrip = CreateFrame("Frame", nil, rightCol)
    busiestStrip:SetPoint("BOTTOMLEFT", 0, 22)
    busiestStrip:SetPoint("BOTTOMRIGHT", 0, 22)
    busiestStrip:SetHeight(64)

    local function CreateBusyCard(label)
        local card = CreateStatTile(busiestStrip, label, 100, 60)
        card.value:SetFontObject("GameFontHighlight")  -- bit smaller than default large
        return card
    end

    local busyHour    = CreateBusyCard("Busiest hour")
    local busyWeekday = CreateBusyCard("Busiest weekday")
    local busyMonth   = CreateBusyCard("Busiest month")
    local busyTopClass= CreateBusyCard("Top class")
    local busyTopBuyer= CreateBusyCard("Top buyer")

    -- Layout: 3-5 cards depending on range scope; distribute evenly.
    local function LayoutBusyCards(scope, w)
        local cards
        if scope == "day" then
            cards = { busyHour, busyTopClass, busyTopBuyer }
            busyWeekday:Hide(); busyMonth:Hide()
        elseif scope == "week" then
            cards = { busyHour, busyWeekday, busyTopClass, busyTopBuyer }
            busyMonth:Hide()
        else -- "year"
            cards = { busyHour, busyWeekday, busyMonth, busyTopClass, busyTopBuyer }
        end
        local n = #cards
        local gap = 4
        local each = math.floor((w - gap * (n - 1)) / n)
        if each < 40 then each = 40 end
        for i, c in ipairs(cards) do
            c:ClearAllPoints()
            if i == 1 then
                c:SetPoint("TOPLEFT", busiestStrip, "TOPLEFT", 0, 0)
            else
                c:SetPoint("TOPLEFT", cards[i - 1], "TOPRIGHT", gap, 0)
            end
            c:SetSize(each, busiestStrip:GetHeight())
            c:Show()
        end
    end
    -- Initialise to year scope until the first refresh sets the right one.
    busiestStrip:SetScript("OnSizeChanged", function(self, w, h)
        LayoutBusyCards(RANGE_SCOPE[selectedRangeKey] or "year", w)
    end)

    -- Hall of Fame: persistent all-time top buyer (independent of selected range).
    local hallOfFame = rightCol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hallOfFame:SetPoint("BOTTOMLEFT",  0, 4)
    hallOfFame:SetPoint("BOTTOMRIGHT", 0, 4)
    hallOfFame:SetJustifyH("CENTER")
    hallOfFame:SetText("")

    -- Destination table render state
    local sortedDestinations = {}

    local function UpdateSortButtons()
        if destSortMode == "copper" then
            sortIncomeBtn:LockHighlight()
            sortCountBtn:UnlockHighlight()
        else
            sortIncomeBtn:UnlockHighlight()
            sortCountBtn:LockHighlight()
        end
    end

    local function RefreshDestRows()
        local numEntries = #sortedDestinations
        FauxScrollFrame_Update(destScroll, numEntries, DEST_MAX_ROWS, DEST_ROW_HEIGHT)
        local offset = FauxScrollFrame_GetOffset(destScroll)

        local total = sortedDestinations.total or 0
        local trackWidth = destRows[1] and destRows[1].barTrack:GetWidth() or 100
        if trackWidth < 10 then trackWidth = 100 end

        for i = 1, DEST_MAX_ROWS do
            local row = destRows[i]
            local data = sortedDestinations[i + offset]
            if data then
                row.data = data
                local dim = (data.destination == "unknown" or data.destination == "any" or data.destination == nil)
                local displayName = DisplayDestination(data.destination)
                local nameText
                if dim then
                    nameText = "|cff999999" .. displayName .. "|r"
                else
                    nameText = string.format("|cff%s%s|r", DestinationColorHex(data.destination), displayName)
                end
                row.name:SetText(nameText)
                row.count:SetText(tostring(data.count))
                row.income:SetText(FormatCopper(data.copper))
                row.buyers:SetText(tostring(data.uniquePlayers or 0))

                local pct
                if destSortMode == "count" then
                    local totalBuyers = sortedDestinations.totalBuyers or 0
                    pct = totalBuyers > 0 and ((data.uniquePlayers or 0) / totalBuyers) or 0
                else
                    pct = total > 0 and (data.copper / total) or 0
                end
                row.share:SetText(string.format("%.1f%%", pct * 100))
                local r, g, b = DestinationColor(data.destination)
                row.bar:SetColorTexture(r, g, b, 0.75)
                row.bar:SetWidth(math.max(1, math.floor(trackWidth * pct)))
                row:Show()
            else
                row:Hide()
                row.data = nil
            end
        end
    end

    destScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, DEST_ROW_HEIGHT, RefreshDestRows)
    end)

    local function BusiestKey(bucket, namesTable)
        local bestKey, bestValue
        for k, v in pairs(bucket) do
            if not bestValue or v > bestValue then
                bestKey, bestValue = k, v
            end
        end
        if not bestKey then return "—", nil end
        if namesTable then
            return namesTable[bestKey] or tostring(bestKey), bestValue
        end
        return string.format("%d:00", bestKey), bestValue
    end

    -- Build per-destination top-buyer list for the tooltip.
    local function ComputeTopBuyers(summary, destination)
        local db = GetCharDB()
        if not db or not destination then return nil end
        local from, to = GetRangeBounds(selectedRangeKey)
        local perPlayer = {}
        for _, e in ipairs(db.trades or {}) do
            local t = e.t or 0
            if t >= from and t <= to and (e.destination or "unknown") == destination then
                local p = e.player or "?"
                perPlayer[p] = (perPlayer[p] or 0) + (e.copper or 0)
            end
        end
        local list = {}
        for player, copper in pairs(perPlayer) do
            list[#list + 1] = { player = player, copper = copper }
        end
        table.sort(list, function(a, b) return a.copper > b.copper end)
        return list
    end

    -- Hall of Fame: all-time top buyer across every trade ever recorded.
    -- Persistent regardless of the selected range; updated on every refresh.
    local function UpdateHallOfFame()
        local allSummary = GetIncomeSummary("allTime")
        local b = allSummary and allSummary.topBuyers and allSummary.topBuyers[1]
        if not b then
            hallOfFame:SetText("")
            return
        end
        local bName = b.player or "?"
        if b.class and b.class ~= "" then
            bName = string.format("|cff%s%s|r", ClassColorHex(b.class), bName)
        end
        hallOfFame:SetText(string.format("|cffffd200Hall of Fame|r  —  %s  |cffaaaaaa(%s all time)|r",
            bName, FormatCopper(b.copper)))
    end

    local function RefreshStats()
        -- Summary rows + accent highlight for the active range.
        for _, def in ipairs(RANGE_ORDER) do
            local summaryForRow = GetIncomeSummary(def.key)
            local row = summaryRows[def.key]
            if row then
                if summaryForRow and summaryForRow.tradeCount > 0 then
                    row.value:SetText(FormatCopper(summaryForRow.totalCopper))
                    row.trades:SetText(string.format("|cff888888(%d trade%s)|r",
                        summaryForRow.tradeCount,
                        summaryForRow.tradeCount == 1 and "" or "s"))
                else
                    row.value:SetText("|cff888888—|r")
                    row.trades:SetText("")
                end
                if def.key == selectedRangeKey then
                    row.bg:SetColorTexture(0.4, 0.6, 0.9, 0.18)
                    row.accent:SetColorTexture(1.0, 0.82, 0.0, 1)
                else
                    row.bg:SetColorTexture(1, 1, 1, 0)
                    row.accent:SetColorTexture(0.27, 0.47, 0.95, 0.7)
                end
            end
        end

        local summary = GetIncomeSummary(selectedRangeKey)

        if not summary or summary.tradeCount == 0 then
            tileTotal.value:SetText("—")
            tileCount.value:SetText("0")
            tileUnique.value:SetText("0")
            tileAvg.value:SetText("—")

            for i = 1, #sortedDestinations do sortedDestinations[i] = nil end
            sortedDestinations.total = 0
            RefreshDestRows()

            LayoutBusyCards(RANGE_SCOPE[selectedRangeKey] or "year", busiestStrip:GetWidth())
            busyHour.value:SetText("—")
            busyWeekday.value:SetText("—")
            busyMonth.value:SetText("—")
            busyTopClass.value:SetText("—")
            busyTopBuyer.value:SetText("—")
            UpdateHallOfFame()
            UpdateSortButtons()
            return
        end

        tileTotal.value:SetText(FormatCopper(summary.totalCopper))
        tileCount.value:SetText(tostring(summary.tradeCount))
        tileUnique.value:SetText(tostring(summary.uniquePlayers))
        local avg = summary.tradeCount > 0 and math.floor(summary.totalCopper / summary.tradeCount) or 0
        -- Shrink font when all three coin types (g/s/c) are present so the value fits the tile.
        local avgAllThree = math.floor(avg / 10000) > 0
                         and math.floor((avg % 10000) / 100) > 0
                         and (avg % 100) > 0
        tileAvg.value:SetFontObject(avgAllThree and GameFontHighlight or GameFontHighlightLarge)
        tileAvg.value:SetText(FormatCopper(avg))

        -- Build sorted destination list.
        for i = 1, #sortedDestinations do sortedDestinations[i] = nil end
        sortedDestinations.total       = summary.totalCopper
        sortedDestinations.totalBuyers = summary.uniquePlayers

        for destination, bucket in pairs(summary.byDestination) do
            sortedDestinations[#sortedDestinations + 1] = {
                destination   = destination,
                copper        = bucket.copper,
                count         = bucket.count,
                uniquePlayers = bucket.uniquePlayers,
                topBuyers     = ComputeTopBuyers(summary, destination),
            }
        end

        if destSortMode == "count" then
            table.sort(sortedDestinations, function(a, b)
                local ap, bp = a.uniquePlayers or 0, b.uniquePlayers or 0
                if ap ~= bp then return ap > bp end
                if a.count ~= b.count then return a.count > b.count end
                return a.copper > b.copper
            end)
        else
            table.sort(sortedDestinations, function(a, b)
                if a.copper == b.copper then return a.count > b.count end
                return a.copper > b.copper
            end)
        end

        RefreshDestRows()

        local hourKey, hourValue = BusiestKey(summary.byHour, nil)
        local wdayKey, wdayValue = BusiestKey(summary.byWeekday, WEEKDAY_NAMES)
        local monKey,  monValue  = BusiestKey(summary.byMonth,   MONTH_NAMES)

        -- Lay out the strip first so per-card widths/visibility match the scope.
        local scope = RANGE_SCOPE[selectedRangeKey] or "year"
        LayoutBusyCards(scope, busiestStrip:GetWidth())

        busyHour.value:SetText(hourValue and string.format("%s\n|cffffffff%s|r", hourKey, FormatCopper(hourValue)) or "—")
        if scope ~= "day" then
            busyWeekday.value:SetText(wdayValue and string.format("%s\n|cffffffff%s|r", wdayKey, FormatCopper(wdayValue)) or "—")
        end
        if scope == "year" then
            busyMonth.value:SetText(monValue and string.format("%s\n|cffffffff%s|r", monKey, FormatCopper(monValue)) or "—")
        end

        -- Top class of the selected range (always shown).
        local topClassKey, topClassCopper = nil, 0
        for k, v in pairs(summary.byClass or {}) do
            if v.copper > topClassCopper then topClassKey, topClassCopper = k, v.copper end
        end
        if topClassKey then
            local pretty = string.format("|cff%s%s|r",
                ClassColorHex(topClassKey),
                topClassKey:sub(1,1) .. topClassKey:sub(2):lower())
            busyTopClass.value:SetText(string.format("%s\n|cffffffff%s|r", pretty, FormatCopper(topClassCopper)))
        else
            busyTopClass.value:SetText("—")
        end

        -- Top buyer of the selected range (always shown).
        local topBuyer = summary.topBuyers and summary.topBuyers[1]
        if topBuyer then
            local bName = topBuyer.player or "?"
            if topBuyer.class and topBuyer.class ~= "" then
                bName = string.format("|cff%s%s|r", ClassColorHex(topBuyer.class), bName)
            end
            busyTopBuyer.value:SetText(string.format("%s\n|cffffffff%s|r", bName, FormatCopper(topBuyer.copper)))
        else
            busyTopBuyer.value:SetText("—")
        end

        UpdateHallOfFame()
        UpdateSortButtons()
    end

    sortIncomeBtn:SetScript("OnClick", function()
        destSortMode = "copper"
        RefreshStats()
    end)
    sortCountBtn:SetScript("OnClick", function()
        destSortMode = "count"
        RefreshStats()
    end)

    ----------------------------------------------------------------
    -- Destination detail page (drill-in from Stats row click)
    ----------------------------------------------------------------
    local detailPage = CreateFrame("Frame", nil, statsPage)
    detailPage:SetAllPoints()
    detailPage:Hide()

    -- Header row: Back | Destination name | Range | View in Log ---
    local detailBackBtn = CreateFrame("Button", nil, detailPage, "UIPanelButtonTemplate")
    detailBackBtn:SetSize(60, 22)
    detailBackBtn:SetPoint("TOPLEFT", 0, 0)
    detailBackBtn:SetText("Back")

    local detailIcon = detailPage:CreateTexture(nil, "ARTWORK")
    detailIcon:SetSize(20, 20)
    detailIcon:SetPoint("LEFT", detailBackBtn, "RIGHT", 8, -1)
    detailIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local detailTitle = detailPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    detailTitle:SetPoint("LEFT", detailIcon, "RIGHT", 6, 0)
    detailTitle:SetPoint("RIGHT", detailPage, "TOPRIGHT", -330, -12)
    detailTitle:SetJustifyH("LEFT")

    local detailLogBtn = CreateFrame("Button", nil, detailPage, "UIPanelButtonTemplate")
    detailLogBtn:SetSize(110, 22)
    detailLogBtn:SetPoint("TOPRIGHT", 0, 0)
    detailLogBtn:SetText("View in Log")

    local detailRangeDropdown = CreateFrame("Frame", "PortalInviterDetailRangeDropdown", detailPage, "UIDropDownMenuTemplate")
    detailRangeDropdown:SetPoint("RIGHT", detailLogBtn, "LEFT", -4, -3)

    local detailRangeLabel = detailPage:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    detailRangeLabel:SetPoint("RIGHT", detailRangeDropdown, "LEFT", 8, 3)
    detailRangeLabel:SetText("Range:")

    local detailSep = detailPage:CreateTexture(nil, "BACKGROUND")
    detailSep:SetPoint("TOPLEFT", 0, -28)
    detailSep:SetPoint("TOPRIGHT", 0, -28)
    detailSep:SetHeight(1)
    detailSep:SetColorTexture(0.4, 0.6, 0.9, 0.3)

    -- Scrollable content area (everything below the header scrolls) --
    local detailScroll = CreateFrame("ScrollFrame", "PortalInviterDetailScroll", detailPage, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT",     detailPage, "TOPLEFT",      0, -32)
    detailScroll:SetPoint("BOTTOMRIGHT", detailPage, "BOTTOMRIGHT", -24, 0)

    local detailScrollChild = CreateFrame("Frame", nil, detailScroll)
    detailScrollChild:SetSize(1, 490)   -- width set via OnSizeChanged; height fixed
    detailScroll:SetScrollChild(detailScrollChild)
    detailScroll:SetScript("OnSizeChanged", function(self, w, h)
        detailScrollChild:SetWidth(w)
    end)

    -- Primary stat tiles ------------------------------------------
    local dtileIncome = CreateStatTile(detailScrollChild, "Income",          140, 54)
    local dtileTrades = CreateStatTile(detailScrollChild, "Trades",           80, 54)
    local dtileBuyers = CreateStatTile(detailScrollChild, "Unique buyers",   110, 54)
    local dtileAvg    = CreateStatTile(detailScrollChild, "Avg per trade",   140, 54)
    local dtileShareI = CreateStatTile(detailScrollChild, "Share of income", 110, 54)
    local dtileShareT = CreateStatTile(detailScrollChild, "Share of trades", 110, 54)

    dtileIncome:SetPoint("TOPLEFT", 0, 0)
    dtileTrades:SetPoint("LEFT", dtileIncome, "RIGHT", 4, 0)
    dtileBuyers:SetPoint("LEFT", dtileTrades, "RIGHT", 4, 0)
    dtileAvg:SetPoint("LEFT",    dtileBuyers, "RIGHT", 4, 0)
    dtileShareI:SetPoint("LEFT", dtileAvg,    "RIGHT", 4, 0)
    dtileShareT:SetPoint("LEFT", dtileShareI, "RIGHT", 4, 0)

    -- Smaller font so long 3-currency strings fit inside the tile width
    dtileIncome.value:SetFontObject("GameFontHighlight")
    dtileTrades.value:SetFontObject("GameFontHighlight")
    dtileBuyers.value:SetFontObject("GameFontHighlight")
    dtileAvg.value:SetFontObject("GameFontHighlight")
    dtileShareI.value:SetFontObject("GameFontHighlight")
    dtileShareT.value:SetFontObject("GameFontHighlight")

    -- Busiest strip -----------------------------------------------
    local detailBusiestStrip = CreateFrame("Frame", nil, detailScrollChild)
    detailBusiestStrip:SetPoint("TOPLEFT",  0, -66)
    detailBusiestStrip:SetPoint("TOPRIGHT", 0, -66)
    detailBusiestStrip:SetHeight(64)

    local dBusyHour    = CreateStatTile(detailBusiestStrip, "Busiest hour",    100, 64)
    local dBusyWeekday = CreateStatTile(detailBusiestStrip, "Busiest weekday", 100, 64)
    local dBusyMonth   = CreateStatTile(detailBusiestStrip, "Busiest month",   100, 64)
    dBusyHour.value:SetFontObject("GameFontHighlight")
    dBusyWeekday.value:SetFontObject("GameFontHighlight")
    dBusyMonth.value:SetFontObject("GameFontHighlight")

    detailBusiestStrip:SetScript("OnSizeChanged", function(self, w, h)
        local third = math.floor((w - 8) / 3)
        dBusyHour:ClearAllPoints();    dBusyHour:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0);              dBusyHour:SetSize(third, h)
        dBusyWeekday:ClearAllPoints(); dBusyWeekday:SetPoint("TOPLEFT", dBusyHour, "TOPRIGHT", 4, 0);     dBusyWeekday:SetSize(third, h)
        dBusyMonth:ClearAllPoints();   dBusyMonth:SetPoint("TOPLEFT", dBusyWeekday, "TOPRIGHT", 4, 0);    dBusyMonth:SetSize(third, h)
    end)

    local detailSep2 = detailScrollChild:CreateTexture(nil, "BACKGROUND")
    detailSep2:SetPoint("TOPLEFT",  0, -140)
    detailSep2:SetPoint("TOPRIGHT", 0, -140)
    detailSep2:SetHeight(1)
    detailSep2:SetColorTexture(0.4, 0.6, 0.9, 0.15)

    -- Sort mode state (resets to income-first each time the page opens)
    local classSortMode = "copper"
    local buyerSortMode = "copper"

    -- Class breakdown (left column) -------------------------------
    local classHeader = detailScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    classHeader:SetPoint("TOPLEFT", 0, -150)
    classHeader:SetText("|cff69ccf0Class breakdown|r")

    local classSortIncomeBtn = CreateFrame("Button", nil, detailScrollChild, "UIPanelButtonTemplate")
    classSortIncomeBtn:SetSize(50, 16)
    classSortIncomeBtn:SetPoint("LEFT", classHeader, "RIGHT", 8, 1)
    classSortIncomeBtn:SetText("Income")

    local classSortCountBtn = CreateFrame("Button", nil, detailScrollChild, "UIPanelButtonTemplate")
    classSortCountBtn:SetSize(50, 16)
    classSortCountBtn:SetPoint("LEFT", classSortIncomeBtn, "RIGHT", 2, 0)
    classSortCountBtn:SetText("Count")

    local CLASS_ROW_H    = 20
    local CLASS_MAX_ROWS = 6
    local classRows = {}
    for i = 1, CLASS_MAX_ROWS do
        local row = CreateFrame("Frame", nil, detailScrollChild)
        row:SetHeight(CLASS_ROW_H)
        row:SetPoint("TOPLEFT", 0, -168 - (i - 1) * CLASS_ROW_H)
        row:SetWidth(310)
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints(); stripe:SetColorTexture(1, 1, 1, 0.04)
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.name:SetWidth(90); row.name:SetJustifyH("LEFT")

        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("LEFT", row, "LEFT", 96, 0)
        row.count:SetWidth(28); row.count:SetJustifyH("RIGHT")

        row.copper = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.copper:SetPoint("LEFT", row, "LEFT", 128, 0)
        row.copper:SetWidth(84); row.copper:SetJustifyH("RIGHT")

        row.barTrack = row:CreateTexture(nil, "BORDER")
        row.barTrack:SetPoint("LEFT", row, "LEFT", 218, 0)
        row.barTrack:SetWidth(68)
        row.barTrack:SetHeight(CLASS_ROW_H - 4)
        row.barTrack:SetColorTexture(1, 1, 1, 0.05)

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT",    row.barTrack, "TOPLEFT",    0, 0)
        row.bar:SetPoint("BOTTOMLEFT", row.barTrack, "BOTTOMLEFT", 0, 0)
        row.bar:SetWidth(1)
        row.bar:SetColorTexture(0.4, 0.6, 0.9, 0.8)

        row.share = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.share:SetPoint("LEFT", row.barTrack, "RIGHT", 4, 0)
        row.share:SetWidth(32); row.share:SetJustifyH("RIGHT")

        row:Hide()
        classRows[i] = row
    end

    -- Top buyers (right column) -----------------------------------
    local buyersHeader = detailScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    buyersHeader:SetPoint("TOPLEFT", 342, -150)
    buyersHeader:SetText("|cff69ccf0Top buyers|r")

    local buyerSortIncomeBtn = CreateFrame("Button", nil, detailScrollChild, "UIPanelButtonTemplate")
    buyerSortIncomeBtn:SetSize(50, 16)
    buyerSortIncomeBtn:SetPoint("LEFT", buyersHeader, "RIGHT", 8, 1)
    buyerSortIncomeBtn:SetText("Income")

    local buyerSortCountBtn = CreateFrame("Button", nil, detailScrollChild, "UIPanelButtonTemplate")
    buyerSortCountBtn:SetSize(50, 16)
    buyerSortCountBtn:SetPoint("LEFT", buyerSortIncomeBtn, "RIGHT", 2, 0)
    buyerSortCountBtn:SetText("Count")

    local BUYER_ROW_H    = 20
    local BUYER_MAX_ROWS = 6
    local buyerRows = {}
    for i = 1, BUYER_MAX_ROWS do
        local row = CreateFrame("Frame", nil, detailScrollChild)
        row:SetHeight(BUYER_ROW_H)
        row:SetPoint("TOPLEFT",  342, -168 - (i - 1) * BUYER_ROW_H)
        row:SetPoint("TOPRIGHT",   0, -168 - (i - 1) * BUYER_ROW_H)
        if i % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints(); stripe:SetColorTexture(1, 1, 1, 0.04)
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.name:SetWidth(120); row.name:SetJustifyH("LEFT")

        row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.count:SetPoint("LEFT", row, "LEFT", 128, 0)
        row.count:SetWidth(24); row.count:SetJustifyH("RIGHT")

        row.copper = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.copper:SetPoint("LEFT", row, "LEFT", 156, 0)
        row.copper:SetWidth(80); row.copper:SetJustifyH("RIGHT")

        row.barTrack = row:CreateTexture(nil, "BORDER")
        row.barTrack:SetPoint("LEFT",  row, "LEFT",  240, 0)
        row.barTrack:SetPoint("RIGHT", row, "RIGHT",  -4, 0)
        row.barTrack:SetHeight(BUYER_ROW_H - 4)
        row.barTrack:SetColorTexture(1, 1, 1, 0.05)

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT",    row.barTrack, "TOPLEFT",    0, 0)
        row.bar:SetPoint("BOTTOMLEFT", row.barTrack, "BOTTOMLEFT", 0, 0)
        row.bar:SetWidth(1)
        row.bar:SetColorTexture(0.4, 0.6, 0.9, 0.8)

        row:Hide()
        buyerRows[i] = row
    end

    -- Histograms: weekday (7 bars), then hour (24 bars) below it ---

    -- Generic bar-drawing helper; values keyed 0-based.
    -- Returns barW, xOff, totalW so callers can reposition labels.
    local function DrawBars(container, bars, barCount, values, r, g, b)
        local w = container:GetWidth()
        if w < 10 then w = 240 end
        local h = container:GetHeight()
        if h < 4  then h = 36 end
        local barW   = math.max(2, math.floor((w - barCount) / barCount))
        local totalW = (barW + 1) * barCount
        local xOff   = math.floor((w - totalW) / 2)
        local maxVal = 0
        for i = 0, barCount - 1 do
            if (values[i] or 0) > maxVal then maxVal = values[i] end
        end
        for i = 0, barCount - 1 do
            local val  = values[i] or 0
            local frac = (maxVal > 0) and (val / maxVal) or 0
            if val == 0 then
                bars[i]:SetHeight(3)
                bars[i]:SetColorTexture(0.52, 0.36, 0.08, 0.45)
            else
                bars[i]:SetHeight(math.max(4, math.floor(h * frac)))
                bars[i]:SetColorTexture(r, g, b, 0.85)
            end
            bars[i]:SetWidth(barW)
            bars[i]:ClearAllPoints()
            bars[i]:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", xOff + i * (barW + 1), 1)
        end
        return barW, xOff, totalW
    end

    local HISTO_ROW_H = 52

    -- Weekday histogram (first) -----------------------------------
    local histoWeekdayHeader = detailScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    histoWeekdayHeader:SetPoint("TOPLEFT", 0, -300)
    histoWeekdayHeader:SetText("|cff69ccf0Trades by weekday|r")

    local WEEKDAY_BAR_COUNT = 7
    local histoWeekdayContainer = CreateFrame("Frame", nil, detailScrollChild)
    histoWeekdayContainer:SetPoint("TOPLEFT",  0, -316)
    histoWeekdayContainer:SetPoint("TOPRIGHT", 0, -316)
    histoWeekdayContainer:SetHeight(HISTO_ROW_H)

    local histoWeekdayBars = {}
    for i = 0, WEEKDAY_BAR_COUNT - 1 do
        histoWeekdayBars[i] = histoWeekdayContainer:CreateTexture(nil, "ARTWORK")
        histoWeekdayBars[i]:SetHeight(1)
    end
    local weekdayBaseLine = histoWeekdayContainer:CreateTexture(nil, "BORDER")
    weekdayBaseLine:SetPoint("BOTTOMLEFT",  0, 0)
    weekdayBaseLine:SetPoint("BOTTOMRIGHT", 0, 0)
    weekdayBaseLine:SetHeight(1)
    weekdayBaseLine:SetColorTexture(0.4, 0.6, 0.9, 0.3)

    -- Weekday labels: Sun Mon Tue Wed Thu Fri Sat
    -- WoW wday: 1=Sunday, 2=Monday, …, 7=Saturday → bar index i = wday-1
    local WEEKDAY_SHORT = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
    local histoWeekdayLabels = {}
    for i = 0, WEEKDAY_BAR_COUNT - 1 do
        local lbl = histoWeekdayContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetText(WEEKDAY_SHORT[i + 1])
        lbl.key = i
        histoWeekdayLabels[i] = lbl
    end

    -- Hour histogram (second) -------------------------------------
    local histoHourHeader = detailScrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    histoHourHeader:SetPoint("TOPLEFT", 0, -388)
    histoHourHeader:SetText("|cff69ccf0Trades by hour of day|r")

    local HOUR_BAR_COUNT = 24
    local histoHourContainer = CreateFrame("Frame", nil, detailScrollChild)
    histoHourContainer:SetPoint("TOPLEFT",  0, -404)
    histoHourContainer:SetPoint("TOPRIGHT", 0, -404)
    histoHourContainer:SetHeight(HISTO_ROW_H)

    local histoHourBars = {}
    for i = 0, HOUR_BAR_COUNT - 1 do
        histoHourBars[i] = histoHourContainer:CreateTexture(nil, "ARTWORK")
        histoHourBars[i]:SetHeight(1)
    end
    local hourBaseLine = histoHourContainer:CreateTexture(nil, "BORDER")
    hourBaseLine:SetPoint("BOTTOMLEFT",  0, 0)
    hourBaseLine:SetPoint("BOTTOMRIGHT", 0, 0)
    hourBaseLine:SetHeight(1)
    hourBaseLine:SetColorTexture(0.4, 0.6, 0.9, 0.3)

    local HOUR_LABEL_KEYS = { 0, 6, 12, 18, 23 }
    local histoHourLabels = {}
    for _, h in ipairs(HOUR_LABEL_KEYS) do
        local lbl = histoHourContainer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        lbl:SetText(tostring(h))
        lbl.key = h
        histoHourLabels[#histoHourLabels + 1] = lbl
    end

    -- Empty-state label for the detail page
    local detailEmpty = detailPage:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailEmpty:SetPoint("CENTER", detailPage, "CENTER", 0, 0)
    detailEmpty:SetJustifyH("CENTER")
    detailEmpty:Hide()

    -- Initialize detail range dropdown ----------------------------
    UIDropDownMenu_SetWidth(detailRangeDropdown, 120)
    UIDropDownMenu_Initialize(detailRangeDropdown, function(self, level)
        for _, def in ipairs(RANGE_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = def.label
            info.value   = def.key
            info.checked = (def.key == selectedRangeKey)
            info.func    = function()
                selectedRangeKey = def.key
                UIDropDownMenu_SetText(detailRangeDropdown, def.label)
                UIDropDownMenu_SetSelectedValue(detailRangeDropdown, def.key)
                UIDropDownMenu_SetText(rangeDropdown, def.label)
                UIDropDownMenu_SetSelectedValue(rangeDropdown, def.key)
                if f.Refresh then f:Refresh() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetText(detailRangeDropdown, "This month")

    -- RefreshDestinationDetail ------------------------------------
    local function RefreshDestinationDetail()
        if not detailDestination then return end

        local ds      = GetDestinationSummary(selectedRangeKey, detailDestination)
        local overall = GetIncomeSummary(selectedRangeKey)

        local displayName = DisplayDestination(detailDestination)
        detailTitle:SetText(displayName)
        local _spellInfo = PI.GetPortalSpellForDestination and PI.GetPortalSpellForDestination(detailDestination)
        detailIcon:SetTexture(_spellInfo and _spellInfo.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

        -- Sync detail range dropdown label to selectedRangeKey
        for _, def in ipairs(RANGE_ORDER) do
            if def.key == selectedRangeKey then
                UIDropDownMenu_SetText(detailRangeDropdown, def.label)
                break
            end
        end

        -- Sort button highlights
        if classSortMode == "copper" then
            classSortIncomeBtn:LockHighlight(); classSortCountBtn:UnlockHighlight()
        else
            classSortIncomeBtn:UnlockHighlight(); classSortCountBtn:LockHighlight()
        end
        if buyerSortMode == "copper" then
            buyerSortIncomeBtn:LockHighlight(); buyerSortCountBtn:UnlockHighlight()
        else
            buyerSortIncomeBtn:UnlockHighlight(); buyerSortCountBtn:LockHighlight()
        end

        if not ds or ds.tradeCount == 0 then
            dtileIncome.value:SetText("—")
            dtileTrades.value:SetText("0")
            dtileBuyers.value:SetText("0")
            dtileAvg.value:SetText("—")
            dtileShareI.value:SetText("—")
            dtileShareT.value:SetText("—")
            dBusyHour.label:SetText("Busiest hour")
            dBusyWeekday.label:SetText("Busiest weekday")
            dBusyMonth.label:SetText("Busiest month")
            dBusyHour.value:SetText("—")
            dBusyWeekday.value:SetText("—")
            dBusyMonth.value:SetText("—")
            for i = 1, CLASS_MAX_ROWS do classRows[i]:Hide() end
            for i = 1, BUYER_MAX_ROWS do buyerRows[i]:Hide() end
            for h = 0, HOUR_BAR_COUNT    - 1 do histoHourBars[h]:SetHeight(1)    end
            for h = 0, WEEKDAY_BAR_COUNT - 1 do histoWeekdayBars[h]:SetHeight(1) end
            classHeader:Hide(); buyersHeader:Hide()
            histoHourHeader:Hide(); histoWeekdayHeader:Hide()
            detailEmpty:SetText(string.format("|cffaaaaaaNo trades for %s in this range.|r", displayName))
            detailEmpty:Show()
            return
        end

        detailEmpty:Hide()
        classHeader:Show(); buyersHeader:Show()
        histoHourHeader:Show(); histoWeekdayHeader:Show()

        -- Primary tiles
        dtileIncome.value:SetText(FormatCopper(ds.totalCopper))
        dtileTrades.value:SetText(tostring(ds.tradeCount))
        dtileBuyers.value:SetText(tostring(ds.uniquePlayers))
        local avg = ds.tradeCount > 0 and math.floor(ds.totalCopper / ds.tradeCount) or 0
        dtileAvg.value:SetText(FormatCopper(avg))
        if overall and overall.totalCopper > 0 then
            dtileShareI.value:SetText(string.format("%.1f%%", ds.totalCopper / overall.totalCopper * 100))
        else
            dtileShareI.value:SetText("—")
        end
        if overall and overall.tradeCount > 0 then
            dtileShareT.value:SetText(string.format("%.1f%%", ds.tradeCount / overall.tradeCount * 100))
        else
            dtileShareT.value:SetText("—")
        end

        -- Highlight strip: three tiers based on RANGE_SCOPE.
        --   day  -> Busiest hour | Top class | Top buyer
        --   week -> Busiest hour | Busiest weekday | Top buyer
        --   year -> Busiest hour | Busiest weekday | Busiest month
        local function BusiestLocal(bucket, namesTable)
            local bestKey, bestVal
            for k, v in pairs(bucket) do
                if not bestVal or v > bestVal then bestKey, bestVal = k, v end
            end
            if not bestKey then return "—", nil end
            if namesTable then return namesTable[bestKey] or tostring(bestKey), bestVal end
            return string.format("%d:00", bestKey), bestVal
        end
        local function TopClassText()
            local topKey, topCopper = nil, 0
            for k, v in pairs(ds.byClass or {}) do
                if v.copper > topCopper then topKey, topCopper = k, v.copper end
            end
            if not topKey then return nil end
            local pretty = string.format("|cff%s%s|r",
                ClassColorHex(topKey),
                topKey:sub(1,1) .. topKey:sub(2):lower())
            return string.format("%s\n|cffffffff%s|r", pretty, FormatCopper(topCopper))
        end
        local function TopBuyerText()
            local b = ds.topBuyers and ds.topBuyers[1]
            if not b then return nil end
            local bName = b.player or "?"
            if b.class and b.class ~= "" then
                bName = string.format("|cff%s%s|r", ClassColorHex(b.class), bName)
            end
            return string.format("%s\n|cffffffff%s|r", bName, FormatCopper(b.copper))
        end

        local hK, hV = BusiestLocal(ds.byHour, nil)
        dBusyHour.label:SetText("Busiest hour")
        dBusyHour.value:SetText(hV and string.format("%s\n|cffffffff%s|r", hK, FormatCopper(hV)) or "—")

        local scope = RANGE_SCOPE[selectedRangeKey] or "year"
        if scope == "day" then
            dBusyWeekday.label:SetText("Top class")
            dBusyWeekday.value:SetText(TopClassText() or "—")
            dBusyMonth.label:SetText("Top buyer")
            dBusyMonth.value:SetText(TopBuyerText() or "—")
        elseif scope == "week" then
            local wK, wV = BusiestLocal(ds.byWeekday, WEEKDAY_NAMES)
            dBusyWeekday.label:SetText("Busiest weekday")
            dBusyWeekday.value:SetText(wV and string.format("%s\n|cffffffff%s|r", wK, FormatCopper(wV)) or "—")
            dBusyMonth.label:SetText("Top buyer")
            dBusyMonth.value:SetText(TopBuyerText() or "—")
        else -- "year"
            local wK, wV = BusiestLocal(ds.byWeekday, WEEKDAY_NAMES)
            local mK, mV = BusiestLocal(ds.byMonth,   MONTH_NAMES)
            dBusyWeekday.label:SetText("Busiest weekday")
            dBusyWeekday.value:SetText(wV and string.format("%s\n|cffffffff%s|r", wK, FormatCopper(wV)) or "—")
            dBusyMonth.label:SetText("Busiest month")
            dBusyMonth.value:SetText(mV and string.format("%s\n|cffffffff%s|r", mK, FormatCopper(mV)) or "—")
        end

        -- Muted green for histogram bars.
        local histoR, histoG, histoB = 0.40, 0.88, 0.52

        -- Class breakdown
        local classList = {}
        for classKey, cb in pairs(ds.byClass) do
            classList[#classList + 1] = { class = classKey, copper = cb.copper, count = cb.count }
        end
        table.sort(classList, function(a, b)
            if classSortMode == "count" then
                if a.count ~= b.count then return a.count > b.count end
                return a.copper > b.copper
            else
                if a.copper ~= b.copper then return a.copper > b.copper end
                return a.count > b.count
            end
        end)
        for i = 1, CLASS_MAX_ROWS do
            local row  = classRows[i]
            local data = classList[i]
            if data then
                if data.class == "UNKNOWN" then
                    row.name:SetText("|cff999999Unknown|r")
                else
                    local pretty = data.class:sub(1,1) .. data.class:sub(2):lower()
                    row.name:SetText(string.format("|cff%s%s|r", ClassColorHex(data.class), pretty))
                end
                row.count:SetText(tostring(data.count))
                row.copper:SetText(FormatCopper(data.copper))
                local pct = ds.totalCopper > 0 and (data.copper / ds.totalCopper) or 0
                row.share:SetText(string.format("%.0f%%", pct * 100))
                local _ch = ClassColorHex(data.class)
                local _cr = tonumber(_ch:sub(1,2),16)/255
                local _cg = tonumber(_ch:sub(3,4),16)/255
                local _cb = tonumber(_ch:sub(5,6),16)/255
                row.bar:SetColorTexture(_cr, _cg, _cb, 0.75)
                row.bar:SetWidth(math.max(1, math.floor(68 * pct)))
                row:Show()
            else
                row:Hide()
            end
        end

        -- Top buyers
        local buyerList = ds.topBuyers
        if buyerSortMode == "count" then
            buyerList = {}
            for _, entry in ipairs(ds.topBuyers) do buyerList[#buyerList + 1] = entry end
            table.sort(buyerList, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return a.copper > b.copper
            end)
        end
        for i = 1, BUYER_MAX_ROWS do
            local row   = buyerRows[i]
            local buyer = buyerList[i]
            if buyer then
                local nameStr = buyer.player or "?"
                if buyer.class and buyer.class ~= "" then
                    nameStr = string.format("|cff%s%s|r", ClassColorHex(buyer.class), nameStr)
                end
                row.name:SetText(nameStr)
                row.count:SetText(tostring(buyer.count))
                row.copper:SetText(FormatCopper(buyer.copper))
                local pct    = ds.totalCopper > 0 and (buyer.copper / ds.totalCopper) or 0
                local trackW = row.barTrack:GetWidth()
                if trackW < 10 then trackW = 80 end
                local _bh = (buyer.class and buyer.class ~= "") and ClassColorHex(buyer.class) or "888888"
                local _br = tonumber(_bh:sub(1,2),16)/255
                local _bg = tonumber(_bh:sub(3,4),16)/255
                local _bb = tonumber(_bh:sub(5,6),16)/255
                row.bar:SetColorTexture(_br, _bg, _bb, 0.75)
                row.bar:SetWidth(math.max(1, math.floor(trackW * pct)))
                row:Show()
            else
                row:Hide()
            end
        end

        -- Hour histogram (24 bars)
        local hBarW, hXOff, hTotalW = DrawBars(histoHourContainer, histoHourBars, HOUR_BAR_COUNT, ds.byHour, histoR, histoG, histoB)
        for _, lbl in ipairs(histoHourLabels) do
            local frac = lbl.key / (HOUR_BAR_COUNT - 1)
            lbl:ClearAllPoints()
            lbl:SetPoint("BOTTOM", histoHourContainer, "BOTTOMLEFT",
                math.floor(hXOff + frac * (hTotalW - hBarW)), -14)
        end

        -- Weekday histogram (7 bars; byWeekday is 1-indexed: 1=Sunday)
        local weekdayValues = {}
        for i = 0, WEEKDAY_BAR_COUNT - 1 do
            weekdayValues[i] = ds.byWeekday[i + 1] or 0
        end
        local wdBarW, wdXOff = DrawBars(histoWeekdayContainer, histoWeekdayBars, WEEKDAY_BAR_COUNT, weekdayValues, histoR, histoG, histoB)
        for i = 0, WEEKDAY_BAR_COUNT - 1 do
            histoWeekdayLabels[i]:ClearAllPoints()
            histoWeekdayLabels[i]:SetPoint("BOTTOM", histoWeekdayContainer, "BOTTOMLEFT",
                wdXOff + i * (wdBarW + 1) + math.floor(wdBarW / 2), -14)
        end

    end

    -- Sort button scripts (need RefreshDestinationDetail in scope) ----
    classSortIncomeBtn:SetScript("OnClick", function()
        classSortMode = "copper"; RefreshDestinationDetail()
    end)
    classSortCountBtn:SetScript("OnClick", function()
        classSortMode = "count"; RefreshDestinationDetail()
    end)
    buyerSortIncomeBtn:SetScript("OnClick", function()
        buyerSortMode = "copper"; RefreshDestinationDetail()
    end)
    buyerSortCountBtn:SetScript("OnClick", function()
        buyerSortMode = "count"; RefreshDestinationDetail()
    end)

    -- Assign the forward-declared show/hide functions ---------------
    ShowDestinationDetail = function(destination)
        detailDestination = destination
        leftCol:Hide()
        rightCol:Hide()
        detailPage:Show()
        detailScroll:SetVerticalScroll(0)
        if f.Refresh then f:Refresh() end
    end

    HideDestinationDetail = function()
        detailDestination = nil
        detailPage:Hide()
        leftCol:Show()
        rightCol:Show()
    end

    detailBackBtn:SetScript("OnClick", function()
        HideDestinationDetail()
        if f.Refresh then f:Refresh() end
    end)

    detailLogBtn:SetScript("OnClick", function()
        if ApplyLogFilter then
            ApplyLogFilter({
                destination = detailDestination,
                range       = selectedRangeKey,
            })
        end
    end)

    UIDropDownMenu_SetWidth(rangeDropdown, 140)
    UIDropDownMenu_Initialize(rangeDropdown, function(self, level)
        for _, def in ipairs(RANGE_ORDER) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = def.label
            info.value   = def.key
            info.checked = (def.key == selectedRangeKey)
            info.func    = function()
                selectedRangeKey = def.key
                UIDropDownMenu_SetSelectedValue(rangeDropdown, def.key)
                UIDropDownMenu_SetText(rangeDropdown, def.label)
                RefreshStats()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
    UIDropDownMenu_SetSelectedValue(rangeDropdown, selectedRangeKey)
    UIDropDownMenu_SetText(rangeDropdown, "This month")

    ----------------------------------------------------------------
    -- Settings tab
    ----------------------------------------------------------------
    local settingsPage = tabFrames[3]

    -- Data group --------------------------------------------------
    local dataHeader = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dataHeader:SetPoint("TOPLEFT", 0, 0)
    dataHeader:SetText("|cff69ccf0Data|r")

    local retentionNote = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    retentionNote:SetPoint("TOPLEFT", 0, -24)
    retentionNote:SetText("|cffaaaaaaTrade history is automatically pruned to the last 365 days each login.|r")

    local resetBtn = CreateFrame("Button", nil, settingsPage, "UIPanelButtonTemplate")
    resetBtn:SetSize(180, 24)
    resetBtn:SetPoint("TOPLEFT", 0, -50)
    resetBtn:SetText("Reset all income data")
    resetBtn:SetScript("OnClick", function()
        StaticPopup_Show("PORTALINVITER_RESET_INCOME")
    end)

    local exportBtn = CreateFrame("Button", nil, settingsPage, "UIPanelButtonTemplate")
    exportBtn:SetSize(180, 24)
    exportBtn:SetPoint("LEFT", resetBtn, "RIGHT", 10, 0)
    exportBtn:SetText("Export as CSV…")

    -- Reusable CSV export window (plain read-only multi-line edit box).
    local exportFrame
    local function ShowExportFrame()
        if not exportFrame then
            exportFrame = CreateFrame("Frame", "PortalInviterExportFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
            exportFrame:SetSize(520, 360)
            exportFrame:SetPoint("CENTER")
            exportFrame:SetFrameStrata("DIALOG")
            exportFrame:SetMovable(true)
            exportFrame:EnableMouse(true)
            exportFrame:RegisterForDrag("LeftButton")
            exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
            exportFrame:SetScript("OnDragStop",  exportFrame.StopMovingOrSizing)
            exportFrame:SetClampedToScreen(true)
            if exportFrame.SetBackdrop then
                exportFrame:SetBackdrop({
                    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
                    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
                    tile = true, tileSize = 32, edgeSize = 32,
                    insets = { left = 8, right = 8, top = 8, bottom = 8 },
                })
            end
            local t = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            t:SetPoint("TOPLEFT", 16, -14)
            t:SetText("|cff69ccf0PortalInviter|r — CSV Export")
            local close = CreateFrame("Button", nil, exportFrame, "UIPanelCloseButton")
            close:SetPoint("TOPRIGHT", -2, -2)
            local hint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            hint:SetPoint("TOPLEFT", 16, -40)
            hint:SetText("|cffaaaaaaPress Ctrl+A then Ctrl+C to copy.|r")

            local scroll = CreateFrame("ScrollFrame", "PortalInviterExportScroll", exportFrame, "UIPanelScrollFrameTemplate")
            scroll:SetPoint("TOPLEFT", 16, -60)
            scroll:SetPoint("BOTTOMRIGHT", -32, 16)

            local edit = CreateFrame("EditBox", "PortalInviterExportBox", scroll)
            edit:SetMultiLine(true)
            edit:SetFontObject(ChatFontNormal)
            edit:SetAutoFocus(true)
            edit:SetWidth(460)
            edit:SetScript("OnEscapePressed", function(self) exportFrame:Hide() end)
            scroll:SetScrollChild(edit)
            exportFrame.edit = edit
            exportFrame:SetScript("OnHide", function() f:Show() end)
            table.insert(UISpecialFrames, "PortalInviterExportFrame")
        end
        local text = BuildTradesCSV()
        exportFrame.edit:SetText(text)
        exportFrame.edit:HighlightText()
        f:Hide()
        exportFrame:Show()
    end

    exportBtn:SetScript("OnClick", ShowExportFrame)

    -- UI group ----------------------------------------------------
    local uiHeader = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    uiHeader:SetPoint("TOPLEFT", 0, -96)
    uiHeader:SetText("|cff69ccf0UI|r")

    local resetGeomBtn = CreateFrame("Button", nil, settingsPage, "UIPanelButtonTemplate")
    resetGeomBtn:SetSize(180, 22)
    resetGeomBtn:SetPoint("TOPLEFT", 0, -120)
    resetGeomBtn:SetText("Reset window size/position")
    resetGeomBtn:SetScript("OnClick", function()
        local uidb = GetUIDB()
        if uidb then
            uidb.frame = {}
        end
        f:ClearAllPoints()
        f:SetPoint("CENTER")
        f:SetSize(780, 520)
        if f.Refresh then f:Refresh() end
    end)

    -- Help hint at the bottom
    local hint = settingsPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMLEFT", 0, 0)
    hint:SetPoint("BOTTOMRIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    hint:SetText("|cffbbbbbbData is stored per character. Use /port income for chat summaries, or Ctrl+Left-click the minimap icon to open this window.|r")

    local function RefreshSettings()
    end

    ----------------------------------------------------------------
    -- Footer refresh (runs on every f:Refresh regardless of active tab)
    ----------------------------------------------------------------
    local function RefreshFooter()
        local db = GetCharDB()
        if not db then
            footerLeft:SetText("")
            footerRight:SetText("")
            return
        end
        local all = BucketTrades(db.trades, 0, math.huge)
        local today = GetIncomeSummary("today")
        local todayCopper = today and today.totalCopper or 0

        local charName = UnitName("player") or "?"
        footerLeft:SetText(string.format(
            "|cff69ccf0%s|r  |cffbbbbbb·|r  lifetime: |cffffd100%s|r  (%d trade%s)",
            charName, FormatCopper(all.totalCopper), all.tradeCount,
            all.tradeCount == 1 and "" or "s"))

        -- Last trade + today
        local lastEntry
        for _, e in ipairs(db.trades or {}) do
            if not lastEntry or (e.t or 0) > (lastEntry.t or 0) then lastEntry = e end
        end
        if lastEntry then
            footerRight:SetText(string.format(
                "today: |cffffd100%s|r  |cffbbbbbb·|r  last: %s",
                FormatCopper(todayCopper),
                FormatRelativeTime(lastEntry.t)))
        else
            footerRight:SetText(string.format("today: |cffffd100%s|r", FormatCopper(todayCopper)))
        end
    end

    ----------------------------------------------------------------

    function f:Refresh()
        RefreshFooter()
        if activeTab == 1 then RefreshLog()
        elseif activeTab == 2 then
            if detailDestination then RefreshDestinationDetail()
            else RefreshStats() end
        elseif activeTab == 3 then RefreshSettings()
        end
    end

    function f:SetActiveTab(i) SetActiveTab(i) end

    f:SetScript("OnShow", function(self) self:Refresh() end)
    f:SetScript("OnSizeChanged", function(self)
        if self:IsShown() and self.Refresh then self:Refresh() end
    end)

    -- ESC close
    table.insert(UISpecialFrames, "PortalInviterIncomeFrame")

    incomeFrame = f
    SetActiveTab(1)
    return f
end

ShowIncomeFrame = function(tabIndex)
    local f = CreateIncomeFrame()
    f:Show()
    if tabIndex then f:SetActiveTab(tabIndex) end
    f:Refresh()
end

-- Exposed so PortalInviter_Income.lua's RecordTrade can refresh the window
-- if the user has it open when a new trade is committed.
PI.RefreshIncomeFrame = function()
    if incomeFrame and incomeFrame:IsShown() and incomeFrame.Refresh then
        incomeFrame:Refresh()
    end
end

PI.ShowIncomeFrame = ShowIncomeFrame
