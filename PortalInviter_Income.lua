-- Income tracking: trade detection, bucketing, formatting.
-- The UI window lives in PortalInviter_UI_Income.lua; this file only owns
-- the data model and trade-session state.

local ADDON_NAME, PI = ...

local Print         = PI.Print
local DebugPrint    = PI.DebugPrint
local ShortName     = PI.ShortName
local NormalizeName = PI.NormalizeName
local GetCharDB     = PI.GetCharDB

local INCOME_SCHEMA_VERSION = 1
local INCOME_TRADES_CAP = 5000
local INCOME_DEFAULT_RETENTION_DAYS = 365
PI.INCOME_SCHEMA_VERSION = INCOME_SCHEMA_VERSION

-- Active trade session state (cleared on TRADE_CLOSED).
local tradeSession = nil
local tradeCommitted = false

local CLASS_COLORS_FALLBACK = {
    MAGE        = "3FC7EB",
    WARRIOR     = "C79C6E",
    PALADIN     = "F58CBA",
    HUNTER      = "ABD473",
    ROGUE       = "FFF569",
    PRIEST      = "FFFFFF",
    SHAMAN      = "0070DE",
    WARLOCK     = "9482C9",
    DRUID       = "FF7D0A",
    DEATHKNIGHT = "C41F3B",
    MONK        = "00FF96",
    DEMONHUNTER = "A330C9",
    EVOKER      = "33937F",
}

-- Per-destination accent color for the Stats detail bars. Anything not listed
-- falls back to a neutral blue-grey.
local DESTINATION_COLORS = {
    ["Stormwind"]      = { 0.27, 0.47, 0.95 },
    ["Ironforge"]      = { 0.80, 0.65, 0.30 },
    ["Darnassus"]      = { 0.40, 0.85, 0.65 },
    ["Exodar"]         = { 0.45, 0.75, 0.95 },
    ["Theramore"]      = { 0.55, 0.75, 0.95 },
    ["Orgrimmar"]      = { 0.85, 0.25, 0.25 },
    ["Undercity"]      = { 0.40, 0.65, 0.35 },
    ["Thunder Bluff"]  = { 0.80, 0.55, 0.30 },
    ["Silvermoon"]     = { 0.95, 0.45, 0.65 },
    ["Stonard"]        = { 0.70, 0.50, 0.25 },
    ["Shattrath"]      = { 0.75, 0.45, 0.95 },
    ["unknown"]        = { 0.55, 0.55, 0.55 },
}

local function ClassColorHex(class)
    if not class then return "ffffff" end
    if RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] and RAID_CLASS_COLORS[class].colorStr then
        -- colorStr is "ffRRGGBB"
        return RAID_CLASS_COLORS[class].colorStr:sub(3)
    end
    return CLASS_COLORS_FALLBACK[class] or "ffffff"
end

local function DestinationColor(name)
    local c = DESTINATION_COLORS[name]
    if c then return c[1], c[2], c[3] end
    return 0.40, 0.55, 0.75
end

local function DestinationColorHex(name)
    local r, g, b = DestinationColor(name)
    return string.format("%02x%02x%02x",
        math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5),
        math.floor(b * 255 + 0.5))
end

local function DisplayDestination(dest)
    return (dest == nil or dest == "unknown" or dest == "any") and "Unspecified" or dest
end

local function FormatCopper(copper)
    copper = tonumber(copper) or 0
    if GetCoinTextureString then
        return GetCoinTextureString(copper)
    end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return string.format("%dg %ds %dc", g, s, c)
end

local function FormatRelativeTime(epoch)
    local now = time()
    local diff = now - (epoch or now)
    if diff < 60       then return diff .. "s ago" end
    if diff < 3600     then return math.floor(diff / 60)   .. "m ago" end
    if diff < 86400    then return math.floor(diff / 3600) .. "h ago" end
    if diff < 86400*7  then return math.floor(diff / 86400).. "d ago" end
    return date("%Y-%m-%d %H:%M", epoch)
end

local function PruneOldTrades()
    local db = GetCharDB()
    if not db then return end
    local trades = db.trades
    local days = INCOME_DEFAULT_RETENTION_DAYS
    if days and days > 0 then
        local cutoff = time() - days * 86400
        local kept = {}
        for _, t in ipairs(trades) do
            if (t.t or 0) >= cutoff then kept[#kept + 1] = t end
        end
        db.trades = kept
        trades = kept
    end
    -- Hard cap
    local overflow = #trades - INCOME_TRADES_CAP
    if overflow > 0 then
        for i = 1, overflow do table.remove(trades, 1) end
    end
end

-- ---------------------------------------------------------------------------
-- Trade session handling
-- ---------------------------------------------------------------------------

local function ResetTradeSession()
    tradeSession = nil
    tradeCommitted = false
end

local function CaptureTradePartner()
    local partner = UnitName("NPC")
    if (not partner or partner == "") and TradeFrameRecipientNameText then
        partner = TradeFrameRecipientNameText:GetText()
    end
    if not partner or partner == "" then return nil end
    return partner
end

local function RecordTrade(partner, copper)
    copper = tonumber(copper) or 0
    local db = GetCharDB()
    if not db then return end

    local shortPartner = ShortName(partner)
    local normalizedPartner = NormalizeName(partner)

    local recentPortalsByPlayer = PI.recentPortalsByPlayer
    local correlation = recentPortalsByPlayer and recentPortalsByPlayer[normalizedPartner]
    if not correlation then
        DebugPrint("Trade with %s skipped: not tracked as a portal customer.", shortPartner)
        return
    end
    -- Consume immediately to prevent re-tagging on follow-up trades.
    recentPortalsByPlayer[normalizedPartner] = nil
    -- Re-check freshness inline so stale entries don't log a trade.
    local age = GetTime() - (correlation.time or 0)
    if age > (PI.PORTAL_CORRELATION_TTL_SECONDS or 900) then
        DebugPrint("Trade with %s skipped: portal correlation is stale (%ds old).", shortPartner, math.floor(age))
        return
    end
    local destination = correlation.destination or "unknown"
    local class = correlation.class

    local entry = {
        t           = time(),
        copper      = copper,
        player      = shortPartner,
        destination = destination,
        class       = class,
    }
    db.trades[#db.trades + 1] = entry

    -- Enforce hard cap.
    if #db.trades > INCOME_TRADES_CAP then
        table.remove(db.trades, 1)
    end

    Print(string.format("Logged %s from %s (%s)", FormatCopper(copper), shortPartner, destination))

    -- Let the UI refresh if it's open; PI.RefreshIncomeFrame is installed by
    -- PortalInviter_UI_Income.lua once the frame has been created.
    if PI.RefreshIncomeFrame then
        PI.RefreshIncomeFrame()
    end
end

local function HandleTradeShow()
    ResetTradeSession()
    tradeSession = {
        partner       = nil,
        targetCopper  = 0,
        playerCopper  = 0,
        bothAccepted  = false,
    }
end

local function UpdateTradeMoney()
    if not tradeSession then return end
    -- Freeze once both sides have accepted. After that point the trade frame
    -- is tearing down and API calls return 0, which would clobber the correct
    -- value (fixes: put in 10g, remove, put in 5g — logs 5g not 10g, and also
    -- fixes income not logging at all when teardown events zero the value).
    if tradeSession.bothAccepted then return end
    if GetTargetTradeMoney then
        tradeSession.targetCopper = GetTargetTradeMoney() or 0
    end
    if GetPlayerTradeMoney then
        tradeSession.playerCopper = GetPlayerTradeMoney() or 0
    end
end

local function HandleTradeAcceptUpdate(playerAccepted, targetAccepted)
    if not tradeSession then return end
    local pa = (playerAccepted == 1 or playerAccepted == true)
    local ta = (targetAccepted == 1 or targetAccepted == true)
    -- Do NOT call UpdateTradeMoney here. Money changes are already tracked
    -- via TRADE_MONEY_CHANGED / PLAYER_TRADE_MONEY while the frame is live.
    -- Reading on accept events is dangerous: by the time the final (1,1)
    -- event fires, Classic has already started tearing down the trade frame
    -- and GetTargetTradeMoney() returns 0, which would overwrite the value.
    if not tradeSession.partner then
        tradeSession.partner = CaptureTradePartner()
    end
    -- Snapshot the current target copper whenever *either* side is in the
    -- accepted state.  On item+gold trades Classic revalidates and clears the
    -- accept flags before firing ERR_TRADE_COMPLETE, so we may never observe
    -- the clean (1,1) state that latches bothAccepted.  Without this snapshot,
    -- the teardown-fired TRADE_MONEY_CHANGED(0) clobbers targetCopper and the
    -- gold portion of the trade is lost.  Always overwrite so the latest live
    -- value wins (e.g. put in 10g, remove, put in 5g -> snapshot ends at 5g).
    if pa or ta then
        tradeSession.acceptSnapshotCopper = tradeSession.targetCopper or 0
    end
    -- Sticky: once both sides have been observed accepted at any point, keep
    -- the flag set. This also activates the freeze in UpdateTradeMoney so the
    -- teardown-fired TRADE_MONEY_CHANGED(0) event can't clobber our value.
    if pa and ta then
        tradeSession.bothAccepted = true
        tradeSession.acceptedAt = GetTime()
    end
end

local function CommitTradeIfEligible(reason)
    if not tradeSession or tradeCommitted then return end
    -- ERR_TRADE_COMPLETE is the authoritative success signal; no other path
    -- commits. Our own accept bookkeeping is unreliable on its own because
    -- Classic clears the accept flags right before firing ERR_TRADE_COMPLETE.

    -- Do NOT re-fetch money here. By the time ERR_TRADE_COMPLETE fires the
    -- trade frame is being torn down and GetTargetTradeMoney() can return 0,
    -- which would wipe out the peak value we captured during the session.
    local copper = tradeSession.targetCopper or 0
    -- Fallback: if live targetCopper was clobbered to 0 by the trade-frame
    -- teardown (common on item+gold trades where the server clears accept
    -- flags mid-trade), use the last value snapshotted while an accept was
    -- active.  ERR_TRADE_COMPLETE is the authoritative success signal, so we
    -- trust the snapshot was real gold that changed hands.
    if copper <= 0 and (tradeSession.acceptSnapshotCopper or 0) > 0 then
        copper = tradeSession.acceptSnapshotCopper
        DebugPrint("Trade complete (%s): live copper=0, using accept snapshot=%d.",
            reason or "?", copper)
    end
    if copper <= 0 then
        DebugPrint("Trade complete (%s) but target copper=0; skipping.", reason or "?")
        tradeCommitted = true
        return
    end

    local partner = tradeSession.partner or CaptureTradePartner()
    if not partner or partner == "" then
        DebugPrint("Trade complete (%s) but partner unknown; skipping.", reason or "?")
        tradeCommitted = true
        return
    end

    tradeCommitted = true
    RecordTrade(partner, copper)
end

-- Called by the main event dispatcher when UI_INFO_MESSAGE fires with
-- ERR_TRADE_COMPLETE. Kept here so trade-session state stays private to
-- this module.
local function HandleTradeComplete()
    if tradeSession and not tradeSession.partner then
        tradeSession.partner = CaptureTradePartner()
    end
    CommitTradeIfEligible("UI_INFO_MESSAGE")
end

local function HandleTradeClosed()
    -- ERR_TRADE_COMPLETE via UI_INFO_MESSAGE is the ONLY authoritative
    -- success signal. We intentionally do not commit on TRADE_CLOSED:
    -- bothAccepted is sticky (necessary for the final accept-clear that
    -- Classic fires right before ERR_TRADE_COMPLETE), which means a
    -- user-cancelled trade that previously reached both-accepted would
    -- otherwise be logged as income. Missing a rare trade log beats
    -- recording phantom gold.
    --
    -- However, TRADE_CLOSED can fire *before* the ERR_TRADE_COMPLETE
    -- UI_INFO_MESSAGE on Classic/Anniversary, so we can't reset the
    -- session here — the commit path would see a nil tradeSession and
    -- silently no-op. Defer the reset so the info message (if any)
    -- arrives first. If a new TRADE_SHOW fires before the timer,
    -- HandleTradeShow will reset and re-init anyway.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function()
            if tradeSession and not tradeCommitted then
                DebugPrint("Trade closed without ERR_TRADE_COMPLETE; discarding session.")
            end
            ResetTradeSession()
        end)
    else
        ResetTradeSession()
    end
end

-- ---------------------------------------------------------------------------
-- Stats helpers
-- ---------------------------------------------------------------------------

local function StartOfDay(epoch)
    local t = date("*t", epoch)
    t.hour, t.min, t.sec = 0, 0, 0
    return time(t)
end

local function StartOfMonth(epoch)
    local t = date("*t", epoch)
    t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
    return time(t)
end

local function StartOfYear(epoch)
    local t = date("*t", epoch)
    t.month, t.day, t.hour, t.min, t.sec = 1, 1, 0, 0, 0
    return time(t)
end

local function StartOfWeek(epoch)
    -- Week starts Monday. date("*t").wday is 1=Sunday..7=Saturday.
    local dayStart = StartOfDay(epoch)
    local wday = date("*t", dayStart).wday
    local offset = (wday - 2) % 7  -- Monday = 0, Sunday = 6
    return dayStart - offset * 86400
end

local function AddMonths(epoch, delta)
    local t = date("*t", epoch)
    local monthIndex = (t.year * 12 + (t.month - 1)) + delta
    t.year  = math.floor(monthIndex / 12)
    t.month = (monthIndex % 12) + 1
    t.day, t.hour, t.min, t.sec = 1, 0, 0, 0
    return time(t)
end

local function BucketTrades(trades, fromEpoch, toEpoch)
    local total = 0
    local count = 0
    local byDestination = {}  -- [destination] = { copper, count, players = {name=true}, uniquePlayers }
    local uniquePlayers = {}
    local byHour = {}
    local byWeekday = {}  -- 1..7 as returned by date("*t").wday
    local byMonth = {}    -- 1..12
    local byClass = {}    -- [classKey] = { copper, count }
    local topBuyersMap = {}

    fromEpoch = fromEpoch or 0
    toEpoch = toEpoch or math.huge

    for _, entry in ipairs(trades or {}) do
        local t = entry.t or 0
        if t >= fromEpoch and t <= toEpoch then
            local copper = entry.copper or 0
            total = total + copper
            count = count + 1

            local destination = entry.destination or "unknown"
            local destBucket = byDestination[destination]
            if not destBucket then
                destBucket = { copper = 0, count = 0, players = {} }
                byDestination[destination] = destBucket
            end
            destBucket.copper = destBucket.copper + copper
            destBucket.count  = destBucket.count  + 1
            if entry.player then destBucket.players[entry.player] = true end

            if entry.player then uniquePlayers[entry.player] = true end

            local tt = date("*t", t)
            byHour[tt.hour]    = (byHour[tt.hour]    or 0) + copper
            byWeekday[tt.wday] = (byWeekday[tt.wday] or 0) + copper
            byMonth[tt.month]  = (byMonth[tt.month]  or 0) + copper

            local classKey = (entry.class and entry.class ~= "") and entry.class or "UNKNOWN"
            local cb = byClass[classKey]
            if not cb then
                cb = { copper = 0, count = 0 }
                byClass[classKey] = cb
            end
            cb.copper = cb.copper + copper
            cb.count  = cb.count  + 1

            local p  = entry.player or "?"
            local pb = topBuyersMap[p]
            if not pb then
                pb = { player = p, copper = 0, count = 0, class = entry.class }
                topBuyersMap[p] = pb
            end
            pb.copper = pb.copper + copper
            pb.count  = pb.count  + 1
        end
    end

    -- Finalize unique-player counts per destination.
    for _, bucket in pairs(byDestination) do
        local n = 0
        for _ in pairs(bucket.players) do n = n + 1 end
        bucket.uniquePlayers = n
    end

    local uniqueCount = 0
    for _ in pairs(uniquePlayers) do uniqueCount = uniqueCount + 1 end

    local topBuyers = {}
    for _, v in pairs(topBuyersMap) do topBuyers[#topBuyers + 1] = v end
    table.sort(topBuyers, function(a, b)
        if a.copper ~= b.copper then return a.copper > b.copper end
        return a.count > b.count
    end)

    return {
        totalCopper   = total,
        tradeCount    = count,
        uniquePlayers = uniqueCount,
        byDestination = byDestination,
        byHour        = byHour,
        byWeekday     = byWeekday,
        byMonth       = byMonth,
        byClass       = byClass,
        topBuyers     = topBuyers,
    }
end

local function GetRangeBounds(rangeKey)
    local now = time()
    if rangeKey == "today"     then return StartOfDay(now), now end
    if rangeKey == "yesterday" then
        local startToday = StartOfDay(now)
        return startToday - 86400, startToday - 1
    end
    if rangeKey == "thisWeek"  then return StartOfWeek(now), now end
    if rangeKey == "lastWeek"  then
        local startThisWeek = StartOfWeek(now)
        return startThisWeek - 7 * 86400, startThisWeek - 1
    end
    if rangeKey == "thisMonth" then return StartOfMonth(now), now end
    if rangeKey == "lastMonth" then
        local startThis = StartOfMonth(now)
        return AddMonths(startThis, -1), startThis - 1
    end
    if rangeKey == "thisYear"  then return StartOfYear(now), now end
    return 0, now  -- "allTime"
end

local function GetIncomeSummary(rangeKey)
    local db = GetCharDB()
    if not db then return nil end
    local from, to = GetRangeBounds(rangeKey)
    return BucketTrades(db.trades, from, to)
end

-- Per-destination deep summary: like BucketTrades but filtered to one destination,
-- with an added byClass breakdown and topBuyers list.
local function GetDestinationSummary(rangeKey, destination)
    local db = GetCharDB()
    if not db then return nil end
    local from, to = GetRangeBounds(rangeKey)
    local trades = db.trades or {}

    local total = 0
    local count = 0
    local uniquePlayers = {}
    local byHour    = {}
    local byWeekday = {}
    local byMonth   = {}
    local byClass   = {}
    local topBuyersMap = {}
    local largestTrade = 0
    local firstTime, lastTime

    for _, entry in ipairs(trades) do
        local t = entry.t or 0
        if t >= from and t <= to and (entry.destination or "unknown") == destination then
            local copper = entry.copper or 0
            total = total + copper
            count = count + 1

            if copper > largestTrade then largestTrade = copper end
            if not firstTime or t < firstTime then firstTime = t end
            if not lastTime  or t > lastTime  then lastTime  = t end

            if entry.player then uniquePlayers[entry.player] = true end

            local tt = date("*t", t)
            byHour[tt.hour]    = (byHour[tt.hour]    or 0) + copper
            byWeekday[tt.wday] = (byWeekday[tt.wday] or 0) + copper
            byMonth[tt.month]  = (byMonth[tt.month]  or 0) + copper

            local classKey = (entry.class and entry.class ~= "") and entry.class or "UNKNOWN"
            local cb = byClass[classKey]
            if not cb then
                cb = { copper = 0, count = 0 }
                byClass[classKey] = cb
            end
            cb.copper = cb.copper + copper
            cb.count  = cb.count  + 1

            local p  = entry.player or "?"
            local pb = topBuyersMap[p]
            if not pb then
                pb = { player = p, copper = 0, count = 0, class = entry.class }
                topBuyersMap[p] = pb
            end
            pb.copper = pb.copper + copper
            pb.count  = pb.count  + 1
        end
    end

    local uniqueCount = 0
    for _ in pairs(uniquePlayers) do uniqueCount = uniqueCount + 1 end

    local topBuyers = {}
    for _, v in pairs(topBuyersMap) do topBuyers[#topBuyers + 1] = v end
    table.sort(topBuyers, function(a, b)
        if a.copper ~= b.copper then return a.copper > b.copper end
        return a.count > b.count
    end)

    return {
        totalCopper    = total,
        tradeCount     = count,
        uniquePlayers  = uniqueCount,
        byHour         = byHour,
        byWeekday      = byWeekday,
        byMonth        = byMonth,
        byClass        = byClass,
        topBuyers      = topBuyers,
        largestTrade   = largestTrade,
        firstTradeTime = firstTime,
        lastTradeTime  = lastTime,
    }
end

-- Produce CSV text for all trades currently stored for this character.
local function BuildTradesCSV()
    local db = GetCharDB()
    if not db then return "" end
    local lines = { "timestamp_utc,timestamp_local,player,class,destination,copper" }
    local trades = db.trades or {}
    for i = 1, #trades do
        local e = trades[i]
        local t = e.t or 0
        local utc = date("!%Y-%m-%dT%H:%M:%SZ", t)
        local loc = date("%Y-%m-%d %H:%M:%S", t)
        local player = (e.player or ""):gsub(",", " ")
        local class  = (e.class  or ""):gsub(",", " ")
        local dest   = (e.destination or "unknown"):gsub(",", " ")
        lines[#lines + 1] = string.format("%s,%s,%s,%s,%s,%d",
            utc, loc, player, class, dest, tonumber(e.copper) or 0)
    end
    return table.concat(lines, "\n")
end

local WEEKDAY_NAMES = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTH_NAMES   = { "January", "February", "March", "April", "May", "June",
                        "July", "August", "September", "October", "November", "December" }

local RANGE_ORDER = {
    { key = "today",     label = "Today"      },
    { key = "yesterday", label = "Yesterday"  },
    { key = "thisWeek",  label = "This week"  },
    { key = "lastWeek",  label = "Last week"  },
    { key = "thisMonth", label = "This month" },
    { key = "lastMonth", label = "Last month" },
    { key = "thisYear",  label = "This year"  },
    { key = "allTime",   label = "All time"   },
}

-- Expose on PI
PI.HandleTradeShow         = HandleTradeShow
PI.HandleTradeAcceptUpdate = HandleTradeAcceptUpdate
PI.UpdateTradeMoney        = UpdateTradeMoney
PI.HandleTradeComplete     = HandleTradeComplete
PI.HandleTradeClosed       = HandleTradeClosed
PI.CommitTradeIfEligible   = CommitTradeIfEligible
PI.PruneOldTrades          = PruneOldTrades

PI.FormatCopper         = FormatCopper
PI.FormatRelativeTime   = FormatRelativeTime
PI.ClassColorHex        = ClassColorHex
PI.DestinationColor     = DestinationColor
PI.DestinationColorHex  = DestinationColorHex
PI.DisplayDestination   = DisplayDestination
PI.BucketTrades         = BucketTrades
PI.GetRangeBounds       = GetRangeBounds
PI.GetIncomeSummary        = GetIncomeSummary
PI.GetDestinationSummary   = GetDestinationSummary
PI.BuildTradesCSV          = BuildTradesCSV

PI.WEEKDAY_NAMES = WEEKDAY_NAMES
PI.MONTH_NAMES   = MONTH_NAMES
PI.RANGE_ORDER   = RANGE_ORDER
