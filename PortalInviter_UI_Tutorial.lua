-- Tutorial window: paginated guide. Opened via /port tutorial or the
-- "Open Tutorial" button in the options panel.

local ADDON_NAME, PI = ...

local tutorialFrame

local function ShowTutorial()
    if tutorialFrame then
        if tutorialFrame:IsShown() then
            tutorialFrame:Hide()
        else
            tutorialFrame:Show()
        end
        return
    end

    -- Page definitions: { title, body }
    local pages = {
        {
            title = "Guide",
            body =
                "Portal Inviter detects portal requests in chat and auto-invites the sender.\n\n" ..

                "|cff69ccf0In This Guide|r\n" ..
                "  |cffbbbbbb2.|r Quick Start\n" ..
                "  |cffbbbbbb3.|r Capital City Auto-Pilot\n" ..
                "  |cffbbbbbb4.|r Automated Features\n" ..
                "  |cffbbbbbb5.|r Income Tracking\n" ..
                "  |cffbbbbbb6.|r Winning the Portal Race\n" ..
                "  |cffbbbbbb7.|r Troubleshooting\n" ..
                "  |cffbbbbbb8.|r Settings & Preferences\n\n" ..

                "|cff69ccf0Channels|r\n" ..
                "Listens on |cffffff00Say|r, |cffffff00Yell|r, |cffffff00General|r (/1), " ..
                "|cffffff00Whisper|r, and |cffffff00Battle.net Whisper|r.\n\n" ..

                "|cff69ccf0Supported Destinations|r\n" ..
                "|cff00ff00Alliance:|r Stormwind, Ironforge, Darnassus, Exodar, Theramore\n" ..
                "|cffff6060Horde:|r Orgrimmar, Undercity, Thunder Bluff, Silvermoon, Stonard\n" ..
                "|cffffff00Neutral:|r Shattrath",
        },
        {
            title = "Quick Start",
            body =
                "|cff69ccf0Minimap Icon|r\n" ..
                "  |cffffff00Left-click|r — toggle invites on/off (bright = on, dim = off)\n" ..
                "  |cffffff00Shift+Left-click|r — toggle auto mode\n" ..
                "  |cffffff00Ctrl+Left-click|r — open income window\n" ..
                "  |cffffff00Middle-click|r — toggle invite sound\n" ..
                "  |cffffff00Right-click|r — quick help\n" ..
                "  |cffffff00Shift+Right-click|r — open settings panel\n" ..
                "  |cffffff00Drag|r — reposition the icon around the minimap\n\n" ..

                "|cff69ccf0Slash Commands|r\n" ..
                "  |cffffff00/port on|r / |cffffff00off|r — toggle invites\n" ..
                "  |cffffff00/port auto|r — toggle capital-city-only mode\n" ..
                "  |cffffff00/port mute|r / |cffffff00unmute|r — toggle sound\n" ..
                "  |cffffff00/port status|r — show current settings\n" ..
                "  |cffffff00/port income|r — open income window (Stats tab)\n" ..
                "  |cffffff00/port log|r — open income window (Log tab)\n" ..
                "  |cffffff00/port debug|r — toggle match diagnostics\n" ..
                "  |cffffff00/port check <msg>|r — test a message against the matcher\n" ..
                "  |cffffff00/port test|r — run the built-in filter test suite",
        },
        {
            title = "Capital City Auto-Pilot",
            body =
                "|cff69ccf0Automated Invites Only in Capitals|r\n" ..
                "Auto mode enables invites when you enter a capital city and disables " ..
                "them when you leave. No need to toggle manually between sessions.\n\n" ..

                "|cff69ccf0How to Enable|r\n" ..
                "  - |cffffff00Shift+Left-click|r the minimap icon, or type |cffffff00/port auto|r\n" ..
                "  - The minimap icon switches to a Theramore portal texture so you " ..
                "can tell at a glance that auto mode is active\n\n" ..

                "|cff69ccf0Recognized Cities|r\n" ..
                "|cff00ff00Alliance:|r Stormwind, Ironforge, Darnassus, Exodar\n" ..
                "|cffff6060Horde:|r Orgrimmar, Undercity, Thunder Bluff, Silvermoon\n" ..
                "|cffffff00Neutral:|r Shattrath\n" ..
                "|cffbbbbbbSubzones:|r Theramore Isle, Stonard\n\n" ..

                "|cff69ccf0Ideal For|r\n" ..
                "AFK portal selling in a capital, or just making quick money while " ..
                "passing through one. Enable auto mode and the addon handles invites " ..
                "while you are in town. Walk outside and they stop automatically.",
        },
        {
            title = "Automated Features",
            body =
                "|cff69ccf0Queue Guard|r\n" ..
                "Invites pause automatically while you are queued for a battleground, " ..
                "arena, or dungeon finder. They resume the moment you leave the queue " ..
                "or the match ends. No toggle required.\n\n" ..

                "|cff69ccf0Auto-Whisper|r\n" ..
                "When an invite fails because the buyer is already grouped, the addon " ..
                "whispers them a message of your choice (e.g. |cffffff00\"inv for portal\"|r). " ..
                "Set the message in the settings panel (|cffffff00Shift+Right-click|r minimap icon). " ..
                "Leave it blank to disable.\n\n" ..

                "|cff69ccf0Portal Cast Announcements|r\n" ..
                "When you begin casting a portal, the addon posts the spell name to " ..
                "party or raid chat (e.g. |cffffff00\"Casting Portal: Stormwind\"|r). " ..
                "Toggle this in the settings panel.\n\n" ..

                "|cff69ccf0Star Marker|r\n" ..
                "When a buyer joins your group, the addon marks you with a |cffffff00star|r " ..
                "raid icon so they can find you in a crowd. The mark is removed " ..
                "automatically when you leave the group.\n\n" ..

                "|cff69ccf0Destination Audio|r\n" ..
                "City-specific voice cues play when a buyer joins your group, telling " ..
                "you which portal to cast without reading chat. Mute all sounds with " ..
                "|cffffff00/port mute|r or |cffffff00Middle-click|r the minimap icon.",
        },
        {
            title = "Income Tracking",
            body =
                "|cff69ccf0Opening the Window|r\n" ..
                "  |cffffff00Ctrl+Left-click|r the minimap icon, or type |cffffff00/port income|r\n" ..
                "  Use |cffffff00/port log|r to open directly to the Log tab\n\n" ..

                "|cff69ccf0Log Tab|r\n" ..
                "Newest-first list of completed trades showing time, amount, buyer " ..
                "(class-colored when known), and destination. " ..
                "|cffffff00Left-click|r a row to filter by its destination; " ..
                "|cffffff00Right-click|r a row to clear all filters.\n\n" ..

                "|cff69ccf0Stats Tab|r\n" ..
                "Totals broken down by Today, Yesterday, This Week, Last Week, " ..
                "This Month, Last Month, This Year, and All Time. " ..
                "A range selector also shows per-destination counts and percentages, " ..
                "plus busiest hour, weekday, and month for the chosen range.\n\n" ..

                "|cff69ccf0Settings Tab|r\n" ..
                "  - |cffffff00Reset all income data|r — wipe trade history for this character\n" ..
                "  - |cffffff00Export as CSV…|r — copy all trades to clipboard\n" ..
                "  - |cffffff00Reset window size/position|r — restore default layout\n" ..
                "  History is auto-pruned to the last 365 days each login.\n\n" ..

                "|cff69ccf0How Destinations Get Labeled|r\n" ..
                "When a buyer joins your group after an invite, or you cast a portal " ..
                "on someone in your group, the addon remembers their destination for " ..
                "15 minutes. Trades that complete within that window are auto-tagged. " ..
                "Trades outside it are logged as |cffbbbbbbunknown|r.\n\n" ..

                "|cff69ccf0Quick Chat Summaries|r\n" ..
                "  |cffffff00/port income today|r / |cffffff00yesterday|r / |cffffff00week|r / " ..
                "|cffffff00lastweek|r / |cffffff00month|r / |cffffff00year|r / |cffffff00all|r",
        },
        {
            title = "Winning the Portal Race",
            body =
                "|cff69ccf0It's a Competition|r\n" ..
                "When someone says |cffffff00\"wtb port\"|r, every mage addon in range fires at " ..
                "once. Portal Inviter is designed to catch a wider range of requests " ..
                "than most — including |cffffff00shorthand|r, |cffffff00misspellings|r, and " ..
                "|cffffff00fuzzy destination wording|r — so you see invites others miss.\n\n" ..

                "|cff69ccf0Pick the Right Spot|r\n" ..
                "Busy areas with all three local channels active (|cffffff00Say|r, |cffffff00Yell|r, " ..
                "|cffffff00General|r) give the best results. Channels are layer-specific, so if " ..
                "your layer feels heavily contested, switching layers can help.\n\n" ..

                "|cff69ccf0Maximize Your Chances|r\n" ..
                "  - Stay in |cffffff00high-traffic areas|r\n" ..
                "  - Keep |cffffff00auto-invite enabled|r so you never miss a request\n" ..
                "  - Use |cffffff00auto mode|r to toggle invites with zero effort\n" ..
                "  - Enable |cffffff00sound alerts|r to react the moment an invite fires\n" ..
                "  - Set an |cffffff00auto-whisper message|r to catch buyers who are already grouped",
        },
        {
            title = "Troubleshooting",
            body =
                "|cff69ccf0\"Already in a Group\"|r\n" ..
                "This usually means another mage invited the target first. It is normal " ..
                "in competitive areas and not a bug. Sometimes the player genuinely is " ..
                "grouped — set an |cffffff00auto-whisper message|r in settings to let them " ..
                "know you are available.\n\n" ..

                "|cff69ccf0Not Getting Invites?|r\n" ..
                "  - Type |cffffff00/port status|r and check that invites are |cff00ff00ON|r\n" ..
                "  - If you are queued for a BG, arena, or dungeon finder, invites are " ..
                "blocked automatically until you leave the queue\n" ..
                "  - If you are in a group, you must be the |cffffff00party or raid leader|r\n" ..
                "  - The addon only works on |cffffff00Mage|r characters\n\n" ..

                "|cff69ccf0Diagnosing Match Issues|r\n" ..
                "  - |cffffff00/port debug|r — enables live logging of every message the addon " ..
                "evaluates, showing why it matched or was skipped\n" ..
                "  - |cffffff00/port check <msg>|r — paste a specific message to see if the " ..
                "matcher picks it up and which destination it resolves",
        },
        {
            title = "Settings & Preferences",
            body =
                "|cff69ccf0Opening the Settings Panel|r\n" ..
                "  - |cffffff00Shift+Right-click|r the minimap icon\n" ..
                "  - Or open |cffffff00Interface > AddOns > PortalInviter|r\n\n" ..

                "|cff69ccf0Auto-Whisper Message|r\n" ..
                "When an invite fails because the player is already grouped, the addon " ..
                "can automatically whisper them (e.g. |cffffff00\"inv for portal\"|r). " ..
                "Grouped players are often questing with a friend and still want a port. " ..
                "Leave the field blank to disable.\n\n" ..

                "|cff69ccf0Announce Portal Casts|r\n" ..
                "Posts a message to party or raid chat when you start casting a portal " ..
                "(e.g. |cffffff00\"Casting Portal: Stormwind\"|r). Toggle in settings.\n\n" ..

                "|cff69ccf0Minimap Icon Position|r\n" ..
                "|cffffff00Click and drag|r the icon to reposition it. The position is saved " ..
                "between sessions.\n\n" ..

                "|cff69ccf0Auto-Save|r\n" ..
                "All settings persist automatically — enabled state, auto mode, sound, " ..
                "auto-whisper message, cast announcements, and minimap position.",
        },
    }

    local currentPage = 1

    local f = CreateFrame("Frame", "PortalInviterTutorialFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(520, 460)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("DIALOG")

    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 8, right = 8, top = 8, bottom = 8 },
        })
    end

    -- Title bar drag
    local titleBar = CreateFrame("Frame", nil, f)
    titleBar:SetPoint("TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", -28, -8)
    titleBar:SetHeight(24)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -14)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -2, -2)

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", "PortalInviterTutorialScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 16, -42)
    scrollFrame:SetPoint("BOTTOMRIGHT", -34, 40)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetWidth(454)
    scrollFrame:SetScrollChild(content)

    local body = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", 0, 0)
    body:SetWidth(454)
    body:SetJustifyH("LEFT")
    body:SetSpacing(3)

    -- Page indicator
    local pageIndicator = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pageIndicator:SetPoint("BOTTOM", 0, 16)

    -- Navigation buttons
    local prevBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    prevBtn:SetSize(80, 22)
    prevBtn:SetPoint("BOTTOMLEFT", 16, 12)
    prevBtn:SetText("Previous")

    local nextBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    nextBtn:SetSize(80, 22)
    nextBtn:SetPoint("BOTTOMRIGHT", -16, 12)
    nextBtn:SetText("Next")

    local function SetPage(page)
        currentPage = page
        local p = pages[currentPage]
        title:SetText("|cff69ccf0Portal Inviter|r — " .. p.title)
        body:SetText(p.body)
        content:SetHeight(body:GetStringHeight() + 20)
        scrollFrame:SetVerticalScroll(0)
        pageIndicator:SetText(currentPage .. " / " .. #pages)
        prevBtn:SetEnabled(currentPage > 1)
        nextBtn:SetEnabled(currentPage < #pages)
    end

    prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then SetPage(currentPage - 1) end
    end)
    nextBtn:SetScript("OnClick", function()
        if currentPage < #pages then SetPage(currentPage + 1) end
    end)

    -- Defer height recalculation after layout
    content:SetScript("OnShow", function(self)
        self:SetHeight(body:GetStringHeight() + 20)
    end)

    -- ESC to close
    table.insert(UISpecialFrames, "PortalInviterTutorialFrame")

    tutorialFrame = f
    SetPage(1)
    f:Show()
end

PI.ShowTutorial = ShowTutorial
