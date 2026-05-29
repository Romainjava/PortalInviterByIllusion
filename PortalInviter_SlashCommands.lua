-- Slash commands: /port and subcommands.

local ADDON_NAME, PI = ...

local Print = PI.Print

local function PrintHelp()
    Print("|cffffff00/port on|r / |cffffff00off|r — toggle invites")
    Print("|cffffff00/port auto|r — capital-city-only mode  |  |cffffff00/port status|r — current settings")
    Print("|cffffff00/port mute|r — toggle sound  |  |cffffff00/port debug|r — match diagnostics")
    Print("|cffffff00/port check <msg>|r — test a message against the matcher")
    Print("|cffffff00/port debug ui|r — seed fake tickets in the queue UI  |  |cffffff00/port debug ui clear|r — clear them")
    Print("|cffffff00/port income|r — open earnings stats  |  |cffffff00/port log|r — open trade log")
    Print("|cffffff00/port income today|week|month|lastmonth|year|all|r — chat summary")
    Print("|cffffff00/port tutorial|r — open the full guide")
end

local function PrintIncomeRange(rangeKey, label)
    local summary = PI.GetIncomeSummary and PI.GetIncomeSummary(rangeKey)
    if not summary or summary.tradeCount == 0 then
        Print(string.format("%s: no trades.", label))
        return
    end
    Print(string.format("%s: %s from %d trade%s (%d unique player%s)",
        label,
        PI.FormatCopper(summary.totalCopper),
        summary.tradeCount, summary.tradeCount == 1 and "" or "s",
        summary.uniquePlayers, summary.uniquePlayers == 1 and "" or "s"))
end

local function RunSelfTest()
    if type(PortalInviterByIllusionTestMessages) ~= "table" or #PortalInviterByIllusionTestMessages == 0 then
        Print("No test messages found.")
        return
    end

    local passCount = 0

    for index, testCase in ipairs(PortalInviterByIllusionTestMessages) do
        local didMatch, destination = PI.EvaluateMessage(testCase.message)
        local expectedDestination = testCase.destination
        -- "any" is a wildcard the fixture uses for messages that match on
        -- intent alone without naming a city (e.g. "wtb port"). The engine
        -- returns "unknown" for those; treat them as equivalent.
        local destinationMatches =
            expectedDestination == nil
            or expectedDestination == destination
            or (expectedDestination == "any" and destination ~= nil)
        local passed = didMatch == testCase.shouldMatch and destinationMatches

        if passed then
            passCount = passCount + 1
        else
            Print(string.format(
                "Test %d failed: \"%s\" => matched=%s, destination=%s",
                index,
                testCase.message,
                didMatch and "true" or "false",
                destination or "nil"
            ))
        end
    end

    Print(string.format("Self-test complete: %d/%d passed.", passCount, #PortalInviterByIllusionTestMessages))
end

-- Seeds a handful of fake queue tickets so the queue UI (and its cast buttons)
-- can be tested without waiting for real whispers. Multiple fake players are
-- assigned to the same destinations so stacked tickets and the scroll view
-- get exercised. Destinations that actually have a portal spell available on
-- this character are preferred so the click-to-cast button is live. Tickets
-- are not persisted anywhere — they clear on /reload or via
-- `/port debug ui clear`.
local function SeedDebugQueue()
    if not PI.QueueAdd then
        Print("Queue API not available.")
        return
    end

    local candidates = {
        "Stormwind", "Ironforge", "Darnassus", "Exodar",
        "Orgrimmar", "Undercity", "Thunder Bluff", "Silvermoon",
        "Shattrath",
    }

    local available = {}
    if PI.GetPortalSpellForDestination then
        for _, dest in ipairs(candidates) do
            if PI.GetPortalSpellForDestination(dest) then
                available[#available + 1] = dest
            end
        end
    end
    -- Fall back to the first candidate so the UI still renders even if no
    -- portal spells are known (e.g. low-level mage, or a non-mage testing).
    if #available == 0 then
        available[1] = candidates[1]
    end

    -- Weighted layout: destinations at the front of the list get several
    -- tickets so stacked groups + the scrollbar are both exercised.
    local distribution = { 4, 3, 2, 1, 1, 1 }

    local fakePlayers = {
        { name = "Debugwind",   class = "MAGE"    },
        { name = "Testhunter",  class = "HUNTER"  },
        { name = "Mocklock",    class = "WARLOCK" },
        { name = "Fakepal",     class = "PALADIN" },
        { name = "Dummydruid",  class = "DRUID"   },
        { name = "Sampleshm",   class = "SHAMAN"  },
        { name = "Phonyrogue",  class = "ROGUE"   },
        { name = "Prankpriest", class = "PRIEST"  },
        { name = "Bogusdk",     class = "DEATHKNIGHT" },
        { name = "Spoofwarr",   class = "WARRIOR" },
        { name = "Riggedmonk",  class = "MONK"    },
        { name = "Stubdh",      class = "DEMONHUNTER" },
    }

    local seeded = 0
    local playerIdx = 1
    -- Mirror the engine's joiner-mark rotation plus star, so debug tickets
    -- render the same little glyphs in front of names that real buyers get.
    local debugMarkers = { 5, 3, 2, 4, 1 }  -- moon, diamond, circle, triangle, star
    local markerCursor = 0
    for destIdx, destination in ipairs(available) do
        local wanted = distribution[destIdx] or 1
        for _ = 1, wanted do
            local player = fakePlayers[playerIdx]
            if not player then break end
            playerIdx = playerIdx + 1
            -- Suffix a realm so normalized names stay unique across reloads.
            local displayName = player.name .. "-Debug"
            local normalizedName = PI.NormalizeText and PI.NormalizeText(displayName)
                or string.lower(displayName)
            PI.QueueAdd(normalizedName, displayName, destination, player.class)
            markerCursor = markerCursor + 1
            if markerCursor > #debugMarkers then markerCursor = 1 end
            if PI.QueueSetMarker then
                PI.QueueSetMarker(normalizedName, debugMarkers[markerCursor])
            end
            seeded = seeded + 1
        end
        if playerIdx > #fakePlayers then break end
    end

    Print(string.format("Seeded %d debug ticket%s across %d destination%s. Use |cffffff00/port debug ui clear|r to remove.",
        seeded, seeded == 1 and "" or "s",
        math.min(#available, #distribution), math.min(#available, #distribution) == 1 and "" or "s"))
end

local function HandleSlashCommand(message)
    local command = PI.NormalizeText(message)

    if command == "on" then
        PI.SetEnabled(true)
        return
    end

    if command == "off" then
        PI.SetEnabled(false)
        return
    end

    if command == "status" then
        Print("Auto-invite is " .. (PortalInviterByIllusionDB.enabled and "ON." or "OFF."))
        Print("Auto mode is " .. (PortalInviterByIllusionDB.autoMode and "ON." or "OFF."))
        Print("Queue block is " .. (PI.IsInMatchmakingQueue() and "|cffff0000ACTIVE|r (queued for BG, arena, or dungeon finder)." or "inactive."))
        Print("Invite alert sound is " .. (PortalInviterByIllusionDB.soundMuted and "MUTED." or "ON."))
        Print("Debug logging is " .. (PortalInviterByIllusionDB.debugEnabled and "ON." or "OFF."))
        return
    end

    if command == "test" then
        RunSelfTest()
        return
    end

    if command:sub(1, 6) == "check " then
        local testMsg = string.sub(message, 7)
        local matched, dest, reason, norm = PI.ExplainMessageMatch(testMsg)
        Print(string.format(
            "Check: match=%s dest=%s reason=\"%s\" normalized=\"%s\"",
            matched and "YES" or "no",
            dest or "none",
            reason or "?",
            norm or ""
        ))
        return
    end

    if command == "debug" then
        PI.ToggleDebugEnabled()
        return
    end

    if command == "debug on" then
        PI.SetDebugEnabled(true)
        return
    end

    if command == "debug off" then
        PI.SetDebugEnabled(false)
        return
    end

    if command == "debug ui" then
        SeedDebugQueue()
        return
    end

    if command == "debug ui clear" then
        if PI.QueueClearAll then PI.QueueClearAll() end
        Print("Cleared debug queue tickets.")
        return
    end

    if command == "mute" or command == "sound off" then
        PI.SetSoundMuted(true)
        return
    end

    if command == "unmute" or command == "sound on" then
        PI.SetSoundMuted(false)
        return
    end

    if command == "auto" then
        PI.ToggleAutoMode()
        return
    end

    if command == "auto on" then
        PI.SetAutoMode(true)
        return
    end

    if command == "auto off" then
        PI.SetAutoMode(false)
        return
    end

    if command == "tutorial" or command == "tips" then
        if PI.ShowTutorial then PI.ShowTutorial() end
        return
    end

    if command == "income" or command == "earnings" then
        if PI.ShowIncomeFrame then PI.ShowIncomeFrame(2) end
        return
    end

    if command == "log" or command == "trades" then
        if PI.ShowIncomeFrame then PI.ShowIncomeFrame(1) end
        return
    end

    if command == "income today"     then PrintIncomeRange("today",     "Today");      return end
    if command == "income yesterday" then PrintIncomeRange("yesterday", "Yesterday");  return end
    if command == "income week"      then PrintIncomeRange("thisWeek",  "This week");  return end
    if command == "income lastweek"  then PrintIncomeRange("lastWeek",  "Last week");  return end
    if command == "income month"     then PrintIncomeRange("thisMonth", "This month"); return end
    if command == "income lastmonth" then PrintIncomeRange("lastMonth", "Last month"); return end
    if command == "income year"      then PrintIncomeRange("thisYear",  "This year");  return end
    if command == "income all"       then PrintIncomeRange("allTime",   "All time");   return end

    PrintHelp()
end

PI.HandleSlashCommand = HandleSlashCommand
PI.RunSelfTest        = RunSelfTest
