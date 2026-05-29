-- PortalInviter — engine-only main file.
--
-- Hot path (chat -> match -> invite) is entirely file-local: no cross-module
-- dispatch is involved when evaluating a chat message. UI/income/tutorial/
-- slash bits live in sibling files and are reached only via user-initiated
-- events (clicks, slash commands, trade events) through the shared PI table.

local ADDON_NAME, PI = ...

local frame = CreateFrame("Frame")
local portalSpellNames = {}
local recentInvites = {}
local pendingDestinations = {}  -- [normalizedName] = { destination, time }; set on invite, cleared on group join
local groupSnapshot = {}        -- [normalizedName] = true; who was in the group at last GROUP_ROSTER_UPDATE
local groupSnapshotScratch = {} -- reused buffer for rebuilding groupSnapshot without allocating
local cachedDestinations
local cachedIsMage
local cachedPlayerNameNormalized = ""  -- set at PLAYER_LOGIN; the player's name never changes in-session
local inMatchmakingQueue = false  -- updated by LFG_UPDATE and UPDATE_BATTLEFIELD_STATUS
local canInviteCached = true      -- cached CanInviteFromCurrentGroup; refreshed on roster / leader / group-left
-- Resolve the invite API once at load so the hot path avoids a global + subtable
-- lookup per matched message.
local InviteUnitFn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
local cachedAliasMap   -- [word_alias]          = destination_label
local cachedBigramMap  -- ["word1 word2" alias]  = destination_label
local levenPrev = {}   -- reused row buffer for LevenshteinDistance
local levenCurr = {}   -- reused row buffer for LevenshteinDistance
local normalizeOut = {} -- reused output buffer for NormalizeText
local findWords = {}   -- reused word buffer for FindDestination
local pendingWhispers = {}      -- [normalizedName] = { target, time }; cleared on join or after whisper fires
local alreadyInGroupPattern     -- lazily built from ERR_ALREADY_IN_GROUP_S

-- Portal->destination correlation map (lives here because it's populated in
-- the invite hot path; Income module reads it from PI.recentPortalsByPlayer).
local recentPortalsByPlayer = {}       -- [normalizedName] = { destination, time, class }
local PORTAL_CORRELATION_TTL_SECONDS = 15 * 60

-- Map cast spell name -> destination label for correlation (populated lazily).
local portalSpellToDestination = {}

-- Stale-pending state is cleaned up whenever recentInvites is pruned.
local PENDING_STATE_TIMEOUT_SECONDS = 60

-- Portal queue: tickets for players who actually joined the group after a
-- pending portal request. This is the only ticket source (confirmed sales only)
-- so the hot path stays allocation-free — queue mutations happen on the cold
-- path in HandleGroupJoins.
--   portalQueue[normalizedName] = {
--       displayName, destination, class,
--       createdAt (GetTime), state = "pending" | "casting",
--   }
local portalQueue = {}
local QUEUE_TTL_SECONDS = 5 * 60
-- Lazy reverse map: destination label -> portal spell name (for CastSpellByName).
-- Rebuilt alongside portalSpellToDestination in RefreshPortalSpellNames.
local destinationToPortalSpell = {}
-- Forward declarations so AnnouncePortalCast (defined earlier than the queue
-- helpers) can still call into them as proper local upvalues.
local QueueAdd, QueueRemove, QueueClearDestination, QueueClearAll
local QueueMarkCasting, QueueClearCasting, QueueCompleteCast, QueueSnapshot
local QueueSetMarker

local INVITE_COOLDOWN_SECONDS = 30
local INVITE_ALERT_SOUND = "Sound\\Interface\\AlarmClockWarning3.ogg"
local INVITE_ALERT_SOUND_KIT = 12867  -- ALARM_CLOCK_WARNING_3
local PORTAL_SPELL_IDS = { 10059, 11416, 11417, 11418, 11419, 11420, 32266, 32267, 33691, 35717, 49360, 49361 }
local DESTINATION_SOUNDS = {
    ["unknown"]      = "Interface\\AddOns\\PortalInviter\\Sound\\Destination.ogg",
    ["Stormwind"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Stormwind.ogg",
    ["Ironforge"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Ironforge.ogg",
    ["Darnassus"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Darnassus.ogg",
    ["Exodar"]       = "Interface\\AddOns\\PortalInviter\\Sound\\Exodar.ogg",
    ["Theramore"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Theramore.ogg",
    ["Orgrimmar"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Orgrimmar.ogg",
    ["Undercity"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Undercity.ogg",
    ["Thunder Bluff"] = "Interface\\AddOns\\PortalInviter\\Sound\\Thunderbluff.ogg",
    ["Silvermoon"]   = "Interface\\AddOns\\PortalInviter\\Sound\\Silvermoon.ogg",
    ["Stonard"]      = "Interface\\AddOns\\PortalInviter\\Sound\\Stonard.ogg",
    ["Shattrath"]    = "Interface\\AddOns\\PortalInviter\\Sound\\Shattrath.ogg",
}
local CAPITAL_CITY_ZONES = {
    ["Stormwind City"]  = true,
    ["Ironforge"]       = true,
    ["Darnassus"]       = true,
    ["The Exodar"]      = true,
    ["Orgrimmar"]       = true,
    ["Thunder Bluff"]   = true,
    ["Undercity"]       = true,
    ["Silvermoon City"] = true,
    ["Shattrath City"]  = true,
}
local CAPITAL_CITY_SUBZONES = {
    ["Theramore Isle"] = true,
    ["Stonard"]        = true,
}
-- Locale-independent capital city detection via uiMapID.
-- Classic WoW Anniversary uiMapIDs (patch 1.13.2 / 2.5.1):
--   1453=Stormwind, 1454=Orgrimmar, 1455=Ironforge, 1456=Thunder Bluff,
--   1457=Darnassus, 1458=Undercity, 1954=Silvermoon City, 1955=Shattrath
local CAPITAL_CITY_MAP_IDS = {
    -- Classic Anniversary (1.13.2 vanilla)
    [1453] = true, -- Stormwind City
    [1454] = true, -- Orgrimmar
    [1455] = true, -- Ironforge
    [1456] = true, -- Thunder Bluff
    [1457] = true, -- Darnassus
    [1458] = true, -- Undercity
    -- Classic Anniversary TBC (2.5.1)
    [1954] = true, -- Silvermoon City
    [1955] = true, -- Shattrath City
}

local SELF_STAR_MARK_ICON = 1

-- Pre-computed padded phrase constants — built once at load time so hot-path
-- matching never allocates temporary strings.
local P_WTS           = " wts "
local P_LFW           = " lfw "
local P_PORT          = " port "
local P_PORTS         = " ports "
local P_PORTAL        = " portal "
local P_PORTALS       = " portals "
local P_TP            = " tp "
local P_TELEPORT      = " teleport "
local P_TELEPORTS     = " teleports "
local P_MAGEPORT      = " mageport "
local P_MAGEPORTS     = " mageports "
local P_LFPORT        = " lfport "
local P_PORT_TO       = " port to "
local P_PORTAL_TO     = " portal to "
local P_TP_TO         = " tp to "
local P_TELEPORT_TO   = " teleport to "
local P_PORT_ME       = " port me "
local P_PORTAL_ME     = " portal me "
local P_TP_ME         = " tp me "
local P_TELEPORT_ME   = " teleport me "
local P_PLS           = " pls "
local P_PLSS          = " plss "
local P_PLIS          = " plis "
local P_PLEAS         = " pleas "
local P_PLEASE        = " please "
local P_PLZ           = " plz "
local P_PLZZ          = " plzz "
local P_PLOX          = " plox "
local P_CAN_I_GET     = " can i get "
local P_CAN_I_HAVE    = " can i have "
local P_COULD_I_GET   = " could i get "
local P_COULD_I_HAVE  = " could i have "
local P_CAN_U_PORT    = " can u port "
local P_CAN_U_PORTAL  = " can u portal "
local P_CAN_U_TP      = " can u tp "
local P_CAN_U_TEL     = " can u teleport "
local P_COULD_U_PORT  = " could u port "
local P_COULD_U_PORTAL = " could u portal "
local P_COULD_U_TP    = " could u tp "
local P_COULD_U_TEL   = " could u teleport "
local P_COULD_I_PORT  = " could i port "
local P_COULD_I_PORTAL = " could i portal "
local P_COULD_I_TP    = " could i tp "
local P_COULD_I_TEL   = " could i teleport "
local P_MAKE_ME       = " make me "
local P_GIVE_ME       = " give me "
local P_GIMME         = " gimme "
local P_NEED_PORT     = " need port "
local P_NEED_PORTAL   = " need portal "
local P_NEED_A_PORT   = " need a port "
local P_NEED_A_PORTAL = " need a portal "
local P_NEED_TP       = " need tp "
local P_NEED_TELEPORT = " need teleport "
local P_FOR_ME        = " for me "
local P_WTB           = " wtb "
local P_LF            = " lf "
local P_BUY           = " buy "
local P_BUYING        = " buying "
local P_ANY_PORT      = " any port "
local P_ANY_PORTS     = " any ports "
local P_ANY_PORTAL    = " any portal "
local P_ANY_PORTALS   = " any portals "
local P_PORT_READY    = " port ready "
local P_PORTS_READY   = " ports ready "
local P_PORTAL_READY  = " portal ready "
local P_PORTALS_READY = " portals ready "
local P_TP_READY      = " tp ready "
local P_GHETTO        = " ghetto "
local P_GETTO         = " getto "
local P_TIPS          = " tips "

-- minLevel: the player level at which this portal first becomes trainable.
-- BuildDestinations skips entries the mage is too low-level to have learned.
local ALLIANCE_DESTINATIONS = {
    { label = "Stormwind",     minLevel = 40, aliases = { "stormwind", "stormwnd", "stormwin", "stormwid", "stromwind", "stormwindd", "stormwing", "stomrwind", "storwmind", "strom", "storm", "sw" } },
    { label = "Ironforge",     minLevel = 40, aliases = { "ironforge", "ironfroge", "ironfrge", "ironforg", "irnforge", "irongorge", "ironfoge", "ironforeg", "ironf", "iron", "iforge", "if" } },
    { label = "Darnassus",     minLevel = 40, aliases = { "darnassus", "darnasus", "darnassuss", "daranssus", "darnasuss", "darnasuus", "darnasus", "darnass", "darnas", "darna", "darny", "darn" } },
    { label = "Exodar",        minLevel = 65, aliases = { "exodar", "eoxdar", "exodra", "exoda", "exodr", "exoar", "elxidor", "theexodar", "exod", "exd", "exo" } },
    { label = "Theramore",     minLevel = 35, aliases = { "theramore", "theramor", "theramre", "theramroe", "therramore", "theremor", "theramoor", "thera more", "theram", "thera" } },
}

local HORDE_DESTINATIONS = {
    { label = "Orgrimmar",     minLevel = 40, aliases = { "orgrimmar", "ogrimar", "ogrimmar", "orgrimmer", "origrimmar", "orgimar", "orgrimar", "orgimmar", "orgrimm", "ogrim", "orgrim", "orgri", "org" } },
    { label = "Undercity",     minLevel = 40, aliases = { "undercity", "undercty", "undrecity", "underciy", "undecity", "undrcity", "udnercity", "undecty", "underc", "under", "uc" } },
    { label = "Thunder Bluff", minLevel = 40, aliases = { "thunder bluff", "thunderbluff", "thunderbluf", "thundr bluff", "thudner bluff", "tunderbluff", "thunderblf", "thunderb", "thunder", "thundr", "tbluff", "tbluf", "tb" } },
    { label = "Silvermoon",    minLevel = 65, aliases = { "silvermoon", "silvermun", "silvremoon", "silvermoo", "silvrmoon", "slivermoon", "silvemoon", "silverm", "silver", "silv", "sm" } },
    { label = "Stonard",       minLevel = 35, aliases = { "stonard", "stonnard", "stonar", "stonnrd", "stoneard", "stonrd", "stonaard", "stona", "stond", "ston" } },
}

local NEUTRAL_DESTINATIONS = {
    { label = "Shattrath",     minLevel = 65, aliases = { "shattrath", "shatrath", "shatrrath", "shattath", "shatttrath", "shatrth", "shatrt", "shatr", "shatt", "shattr", "shat" } },
}

local function BuildDestinations()
    local factionDestinations = ALLIANCE_DESTINATIONS
    local _, _, _, factionGroup = UnitFactionGroup("player")
    if factionGroup == "Horde" then
        factionDestinations = HORDE_DESTINATIONS
    end

    local playerLevel = UnitLevel("player") or 1

    local result = {}
    for _, d in ipairs(factionDestinations) do
        if playerLevel >= (d.minLevel or 1) then
            result[#result + 1] = { label = d.label, aliases = d.aliases }
        end
    end
    for _, d in ipairs(NEUTRAL_DESTINATIONS) do
        if playerLevel >= (d.minLevel or 1) then
            result[#result + 1] = { label = d.label, aliases = d.aliases }
        end
    end

    -- Build O(1) lookup maps used by FindDestination.
    -- Single-word aliases go into aliasMap; space-containing aliases into bigramMap.
    local aliasMap  = {}
    local bigramMap = {}
    for _, d in ipairs(result) do
        for _, alias in ipairs(d.aliases) do
            if alias:find(" ", 1, true) then
                bigramMap[alias] = d.label
            else
                aliasMap[alias] = d.label
            end
        end
    end
    cachedAliasMap  = aliasMap
    cachedBigramMap = bigramMap

    return result
end

local function GetDestinations()
    if not cachedDestinations then
        cachedDestinations = BuildDestinations()
    end
    return cachedDestinations
end

local function Print(message)
    print(string.format("|cff69ccf0%s|r: %s", ADDON_NAME or "PortalInviter", message))
end

local function DebugPrint(fmt, ...)
    if not PortalInviterDB or not PortalInviterDB.debugEnabled then
        return
    end

    if select("#", ...) > 0 then
        Print("[debug] " .. string.format(fmt, ...))
    else
        Print("[debug] " .. fmt)
    end
end

local function EnsureDB()
    if type(PortalInviterDB) ~= "table" then
        PortalInviterDB = {}
    end

    if PortalInviterDB.userEnabled == nil then
        if PortalInviterDB.enabled == nil then
            PortalInviterDB.userEnabled = false
        else
            PortalInviterDB.userEnabled = PortalInviterDB.enabled and true or false
        end
    end

    if type(PortalInviterDB.minimapAngle) ~= "number" then
        PortalInviterDB.minimapAngle = 220
    end

    if PortalInviterDB.soundMuted == nil then
        PortalInviterDB.soundMuted = false
    end

    if PortalInviterDB.debugEnabled == nil then
        PortalInviterDB.debugEnabled = false
    end

    if PortalInviterDB.autoMode == nil then
        PortalInviterDB.autoMode = false
    end

    if PortalInviterDB.autoWhisperMessage == nil then
        PortalInviterDB.autoWhisperMessage = ""
    end

    if PortalInviterDB.announcePortalCasts == nil then
        PortalInviterDB.announcePortalCasts = true
    end

    if type(PortalInviterDB.characters) ~= "table" then
        PortalInviterDB.characters = {}
    end

    PortalInviterDB.enabled = PortalInviterDB.userEnabled and true or false
end

local function GetCharKey()
    local name = UnitName("player")
    if not name or name == "" then return nil end
    local realm = GetRealmName() or ""
    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm
end

local function GetCharDB()
    if type(PortalInviterDB) ~= "table" or type(PortalInviterDB.characters) ~= "table" then
        return nil
    end
    local key = GetCharKey()
    if not key then return nil end
    local entry = PortalInviterDB.characters[key]
    if type(entry) ~= "table" then
        entry = {
            version = 1,
            trades  = {},
        }
        PortalInviterDB.characters[key] = entry
    else
        if type(entry.trades) ~= "table"  then entry.trades = {} end
        if type(entry.version) ~= "number" then entry.version = 1 end
    end
    return entry
end

local function ShortName(name)
    if not name or name == "" then
        return ""
    end

    if Ambiguate then
        return Ambiguate(name, "short")
    end

    return string.match(name, "^[^-]+") or name
end

local function NormalizeName(name)
    return string.lower(ShortName(name))
end

local function NormalizeText(text)
    if not text or text == "" then return "" end

    local src = text
    local len = #src
    local out = normalizeOut
    local outN = 0
    local prevSpace = true
    local i = 1

    while i <= len do
        local b = src:byte(i)
        local skip = false

        -- Skip WoW color codes: |cXXXXXXXX (10 chars) and |r (2 chars)
        if b == 124 and i < len then -- '|'
            local nxt = src:byte(i + 1)
            if nxt == 99 or nxt == 67 then -- 'c' or 'C'
                i = i + 10
                if not prevSpace then outN = outN + 1; out[outN] = 32; prevSpace = true end
                skip = true
            elseif nxt == 114 or nxt == 82 then -- 'r' or 'R'
                i = i + 2
                if not prevSpace then outN = outN + 1; out[outN] = 32; prevSpace = true end
                skip = true
            end
        end

        if not skip then
            -- Skip bracketed content: [...]
            if b == 91 then -- '['
                local j = src:find("]", i + 1, true)
                i = j and (j + 1) or (i + 1)
                if not prevSpace then outN = outN + 1; out[outN] = 32; prevSpace = true end
            else
                -- Lowercase A-Z
                if b >= 65 and b <= 90 then
                    b = b + 32
                end

                -- Keep a-z, 0-9; everything else becomes space
                if (b >= 97 and b <= 122) or (b >= 48 and b <= 57) then
                    outN = outN + 1; out[outN] = b; prevSpace = false
                else
                    if not prevSpace then outN = outN + 1; out[outN] = 32; prevSpace = true end
                end

                i = i + 1
            end
        end
    end

    -- Trim trailing space
    if outN > 0 and out[outN] == 32 then outN = outN - 1 end
    -- Trim leading space
    local start = 1
    if outN > 0 and out[1] == 32 then start = 2 end

    if outN < start then return "" end
    return string.char(unpack(out, start, outN))
end

local function HasBlockedIntent(text)
    return text:find(P_WTS,          1, true) ~= nil
        or text:find(P_LFW,          1, true) ~= nil
        or text:find(P_PORT_READY,   1, true) ~= nil
        or text:find(P_PORTS_READY,  1, true) ~= nil
        or text:find(P_PORTAL_READY, 1, true) ~= nil
        or text:find(P_PORTALS_READY,1, true) ~= nil
        or text:find(P_TP_READY,     1, true) ~= nil
        or text:find(P_GHETTO,       1, true) ~= nil
        or text:find(P_GETTO,        1, true) ~= nil
        or text:find(P_TIPS,         1, true) ~= nil
end

local function HasPortalWord(text)
    return text:find(P_PORT,      1, true) ~= nil
        or text:find(P_PORTS,     1, true) ~= nil
        or text:find(P_PORTAL,    1, true) ~= nil
        or text:find(P_PORTALS,   1, true) ~= nil
        or text:find(P_TP,        1, true) ~= nil
        or text:find(P_TELEPORT,  1, true) ~= nil
        or text:find(P_TELEPORTS, 1, true) ~= nil
        or text:find(P_MAGEPORT,  1, true) ~= nil
        or text:find(P_MAGEPORTS, 1, true) ~= nil
        or text:find(P_LFPORT,    1, true) ~= nil
        -- Catch double-letter typos like "portall", "portalls" that miss the
        -- exact checks above. Matches any word starting with "port" + more letters.
        or text:find(" port%a+ ") ~= nil
end

local function HasDirectPortalRequest(paddedText, hasPortal)
    if not hasPortal then
        return false
    end

    if paddedText:find(P_PORT_TO,      1, true)
        or paddedText:find(P_PORTAL_TO,    1, true)
        or paddedText:find(P_TP_TO,        1, true)
        or paddedText:find(P_TELEPORT_TO,  1, true)
        or paddedText:find(P_PORT_ME,      1, true)
        or paddedText:find(P_PORTAL_ME,    1, true)
        or paddedText:find(P_TP_ME,        1, true)
        or paddedText:find(P_TELEPORT_ME,  1, true) then
        return true
    end

    if paddedText:find(P_PLS,            1, true)
        or paddedText:find(P_PLSS,           1, true)
        or paddedText:find(P_PLIS,           1, true)
        or paddedText:find(P_PLEAS,          1, true)
        or paddedText:find(P_PLEASE,         1, true)
        or paddedText:find(P_PLZ,            1, true)
        or paddedText:find(P_PLZZ,           1, true)
        or paddedText:find(P_PLOX,           1, true)
        or paddedText:find(P_CAN_I_GET,      1, true)
        or paddedText:find(P_CAN_I_HAVE,     1, true)
        or paddedText:find(P_COULD_I_GET,    1, true)
        or paddedText:find(P_COULD_I_HAVE,   1, true)
        or paddedText:find(P_CAN_U_PORT,     1, true)
        or paddedText:find(P_CAN_U_PORTAL,   1, true)
        or paddedText:find(P_CAN_U_TP,       1, true)
        or paddedText:find(P_CAN_U_TEL,      1, true)
        or paddedText:find(P_COULD_U_PORT,   1, true)
        or paddedText:find(P_COULD_U_PORTAL, 1, true)
        or paddedText:find(P_COULD_U_TP,     1, true)
        or paddedText:find(P_COULD_U_TEL,    1, true)
        or paddedText:find(P_COULD_I_PORT,   1, true)
        or paddedText:find(P_COULD_I_PORTAL, 1, true)
        or paddedText:find(P_COULD_I_TP,     1, true)
        or paddedText:find(P_COULD_I_TEL,    1, true)
        or paddedText:find(P_MAKE_ME,        1, true)
        or paddedText:find(P_GIVE_ME,        1, true)
        or paddedText:find(P_GIMME,          1, true)
        or paddedText:find(P_FOR_ME,         1, true)
        or paddedText:find(P_NEED_PORT,      1, true)
        or paddedText:find(P_NEED_PORTAL,    1, true)
        or paddedText:find(P_NEED_A_PORT,    1, true)
        or paddedText:find(P_NEED_A_PORTAL,  1, true)
        or paddedText:find(P_NEED_TP,        1, true)
        or paddedText:find(P_NEED_TELEPORT,  1, true)
        or paddedText:find(P_LFPORT,         1, true)
        or paddedText:find(P_ANY_PORT,       1, true)
        or paddedText:find(P_ANY_PORTS,      1, true)
        or paddedText:find(P_ANY_PORTAL,     1, true)
        or paddedText:find(P_ANY_PORTALS,    1, true) then
        return true
    end

    return false
end

local function HasRequestIntent(paddedText, hasPortal)
    -- HasBlockedIntent already checked by ExplainMessageMatch before this is called.
    if hasPortal and (
        paddedText:find(P_WTB,    1, true)
        or paddedText:find(P_LF,     1, true)
        or paddedText:find(P_BUY,    1, true)
        or paddedText:find(P_BUYING, 1, true)
    ) then
        return true
    end

    return HasDirectPortalRequest(paddedText, hasPortal)
end

local function LevenshteinDistance(a, b, maxDist)
    local lenA, lenB = #a, #b
    if lenA == 0 then return lenB end
    if lenB == 0 then return lenA end

    if maxDist and (lenA - lenB > maxDist or lenB - lenA > maxDist) then
        return maxDist + 1
    end

    local prev = levenPrev
    local curr = levenCurr
    for j = 0, lenB do prev[j] = j end

    for i = 1, lenA do
        curr[0] = i
        local rowMin = curr[0]
        for j = 1, lenB do
            local cost = (a:byte(i) == b:byte(j)) and 0 or 1
            local val = prev[j] + 1
            local ins = curr[j - 1] + 1
            local sub = prev[j - 1] + cost
            if ins < val then val = ins end
            if sub < val then val = sub end
            curr[j] = val
            if val < rowMin then rowMin = val end
        end
        if maxDist and rowMin > maxDist then
            return maxDist + 1
        end
        prev, curr = curr, prev
    end

    return prev[lenB]
end

local FUZZY_MIN_ALIAS_LENGTH = 4

local function FuzzyMaxDistance(aliasLength)
    if aliasLength >= 8 then return 2 end
    return 1
end

local function FuzzyFindDestination(words)
    local bestLabel
    local bestDistance
    local bestWordIndex

    for _, destination in ipairs(GetDestinations()) do
        for _, alias in ipairs(destination.aliases) do
            if #alias >= FUZZY_MIN_ALIAS_LENGTH then
                local maxDist = FuzzyMaxDistance(#alias)
                local hasSpace = alias:find(" ", 1, true)

                if hasSpace then
                    for i = 1, #words - 1 do
                        local pair = words[i] .. " " .. words[i + 1]
                        local dist = LevenshteinDistance(pair, alias, maxDist)
                        if dist > 0 and dist <= maxDist and (not bestDistance or dist < bestDistance or (dist == bestDistance and i < bestWordIndex)) then
                            bestDistance = dist
                            bestLabel = destination.label
                            bestWordIndex = i
                        end
                    end
                else
                    for i, word in ipairs(words) do
                        local dist = LevenshteinDistance(word, alias, maxDist)
                        if dist > 0 and dist <= maxDist and (not bestDistance or dist < bestDistance or (dist == bestDistance and i < bestWordIndex)) then
                            bestDistance = dist
                            bestLabel = destination.label
                            bestWordIndex = i
                        end
                    end
                end
            end
        end
    end

    return bestLabel
end

local function FindDestination(text)
    -- Lazy-init guard: maps are set by BuildDestinations; ensure they exist.
    if not cachedAliasMap then
        GetDestinations()
    end

    -- Split normalized text into words once; reused by both exact and fuzzy paths.
    local words = findWords
    local wordCount = 0
    for word in text:gmatch("%S+") do
        wordCount = wordCount + 1
        words[wordCount] = word
    end
    for i = wordCount + 1, #words do words[i] = nil end

    -- O(words) hash-map lookup — no iteration over all aliases.
    for i, word in ipairs(words) do
        local label = cachedAliasMap[word]
        if label then
            return label
        end
        if i < #words then
            local bigram = word .. " " .. words[i + 1]
            label = cachedBigramMap[bigram]
            if label then
                return label
            end
        end
    end

    return FuzzyFindDestination(words)
end

local function ExplainMessageMatch(message)
    local normalized = NormalizeText(message)

    if normalized == "" then
        return false, nil, "message was empty after normalization", normalized
    end

    local paddedText = " " .. normalized .. " "

    if HasBlockedIntent(paddedText) then
        return false, nil, "message looked like portal selling chatter", normalized
    end

    local hasPortal = HasPortalWord(paddedText)
    if not hasPortal then
        return false, nil, "message did not contain a portal keyword", normalized
    end

    local destination = FindDestination(normalized)

    if not HasRequestIntent(paddedText, hasPortal) then
        if destination then
            -- A bare "<portal-keyword> <destination>" message (exactly 2 words) is itself
            -- a request — e.g. "portal shatrak" or "port sw". Longer messages without a
            -- request signal (e.g. "portal trainer is in stormwind") stay rejected.
            local wordCount = 0
            for _ in normalized:gmatch("%S+") do wordCount = wordCount + 1 end
            if wordCount ~= 2 then
                return false, destination, "message mentioned a destination but did not look like a request", normalized
            end
        else
            return false, nil, "message did not look like a portal request", normalized
        end
    end

    if not destination and (UnitLevel("player") or 1) < 35 then
        return false, nil, "no destination specified and player level too low for portals", normalized
    end

    return true, destination or "unknown", "message matched a portal request", normalized
end

local function EvaluateMessage(message)
    local shouldInvite, destination = ExplainMessageMatch(message)
    return shouldInvite, destination
end

-- Hot-path matcher used by HandlePotentialCustomer.  Mirrors ExplainMessageMatch
-- but skips FindDestination on the common "has request intent" branch --
-- destination is only needed for the 2-word bare-request fallback and the
-- low-level gating check.  The caller resolves destination *after* InviteUnit
-- so the invite fires a hair sooner on unambiguous requests like "wtb port".
local function MatchRequestFast(message, event)
    local normalized = NormalizeText(message)
    if normalized == "" then return false end

    local paddedText = " " .. normalized .. " "

    if HasBlockedIntent(paddedText) then return false end

    local hasPortal = HasPortalWord(paddedText)
    if not hasPortal then return false end

    -- Whisper fast-path: someone whispering a mage with a portal word is
    -- effectively always a buyer (sellers broadcast in trade, not whispers),
    -- and casual phrasings like "can u make me a darnasus portal plz" don't
    -- hit the explicit intent patterns.  Still honor the level-35 guard.
    local isWhisper = event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER"
    if isWhisper then
        if (UnitLevel("player") or 1) < 35 then
            if not FindDestination(normalized) then
                return false
            end
        end
        return true, normalized
    end

    if HasRequestIntent(paddedText, hasPortal) then
        -- Below level 35 the mage has no portals; require a destination we
        -- actually matched so we don't invite when we can't help.
        if (UnitLevel("player") or 1) < 35 then
            if not FindDestination(normalized) then
                return false
            end
        end
        return true, normalized
    end

    -- Bare "<portal-keyword> <destination>" (exactly 2 words) is itself a request.
    local destination = FindDestination(normalized)
    if not destination then return false end

    local wordCount = 0
    for _ in normalized:gmatch("%S+") do wordCount = wordCount + 1 end
    if wordCount ~= 2 then return false end

    return true, normalized, destination
end

local function IsMage()
    if cachedIsMage ~= nil then return cachedIsMage end
    local _, classTag = UnitClass("player")
    cachedIsMage = classTag == "MAGE"
    return cachedIsMage
end

local function CanInviteFromCurrentGroup()
    if IsInRaid() then
        return UnitIsGroupLeader("player")
    end

    if IsInGroup() then
        return UnitIsGroupLeader("player")
    end

    return true
end

-- Refresh the leader-state cache.  Called on roster / leader / group-left
-- events; keeps the hot path away from UnitIsGroupLeader's C round-trip.
local function RefreshCanInvite()
    canInviteCached = CanInviteFromCurrentGroup()
end

local function UpdateQueueState()
    -- Dungeon finder (Classic Anniversary: only LFD category exists)
    if GetLFGMode and LE_LFG_CATEGORY_LFD then
        if GetLFGMode(LE_LFG_CATEGORY_LFD) ~= nil then
            inMatchmakingQueue = true
            return
        end
    end

    -- Battleground / arena queues (Classic supports up to 2 concurrent slots).
    if GetBattlefieldStatus then
        for i = 1, 2 do
            local status = GetBattlefieldStatus(i)
            if status == "queued" or status == "confirm" or status == "active" then
                inMatchmakingQueue = true
                return
            end
        end
    end

    -- Fallback: block inside any instanced dungeon/BG/arena even if LFG/BF APIs
    -- don't reflect it (e.g. manually-entered instance, or LFGMode reset on entry).
    if IsInInstance then
        local _, instanceType = IsInInstance()
        if instanceType == "party" or instanceType == "pvp" or instanceType == "arena" then
            inMatchmakingQueue = true
            return
        end
    end

    inMatchmakingQueue = false
end

local function ApplySelfStarMark()
    if SetRaidTarget then
        SetRaidTarget("player", SELF_STAR_MARK_ICON)
    end
end

local function ClearSelfStarMark()
    if SetRaidTarget then
        SetRaidTarget("player", 0)
    end
end

-- Raid-target icons we apply to confirmed portal buyers as they join the
-- group. We avoid star (reserved for the caster), skull, cross, and square —
-- those are commonly used for marking mobs/tanks. Cycled in order so multiple
-- buyers get distinct markers.
local JOINER_MARK_ICONS = { 5, 3, 2, 4 }  -- moon, diamond, circle, triangle
local joinerMarkCursor = 0

local function MarkJoiner(unit)
    if not unit or not SetRaidTarget then return nil end
    joinerMarkCursor = joinerMarkCursor + 1
    if joinerMarkCursor > #JOINER_MARK_ICONS then joinerMarkCursor = 1 end
    local icon = JOINER_MARK_ICONS[joinerMarkCursor]
    SetRaidTarget(unit, icon)
    return icon
end

local function RefreshPortalSpellNames()
    portalSpellNames = {}
    portalSpellToDestination = {}
    destinationToPortalSpell = {}

    -- Map rank-less portal spell name -> destination label by scanning the
    -- faction + neutral destination lists. Spell names look like
    -- "Portal: Stormwind", "Teleport: Stormwind", etc.
    local destinationLabels = {}
    for _, d in ipairs(ALLIANCE_DESTINATIONS) do destinationLabels[#destinationLabels + 1] = d.label end
    for _, d in ipairs(HORDE_DESTINATIONS)    do destinationLabels[#destinationLabels + 1] = d.label end
    for _, d in ipairs(NEUTRAL_DESTINATIONS)  do destinationLabels[#destinationLabels + 1] = d.label end

    for _, spellID in ipairs(PORTAL_SPELL_IDS) do
        local spellName, _, icon = GetSpellInfo(spellID)
        if spellName and spellName ~= "" then
            portalSpellNames[spellName] = true
            -- Only group-portal spells ("Portal: ...") are queue-castable.
            -- Teleport spells target self only and don't resolve tickets.
            local isGroupPortal = spellName:find("Portal", 1, true) ~= nil
            for _, label in ipairs(destinationLabels) do
                if spellName:find(label, 1, true) then
                    portalSpellToDestination[spellName] = label
                    if isGroupPortal and not destinationToPortalSpell[label] then
                        destinationToPortalSpell[label] = { name = spellName, icon = icon }
                    end
                    break
                end
            end
        end
    end
end

local function AnnouncePortalCast()
    local spellName = UnitCastingInfo("player")
    if not spellName or not portalSpellNames[spellName] then
        return
    end

    -- Correlate: every current group member who isn't us now has a fresh
    -- destination tag. Overwrites stale entries so trades after the cast
    -- attribute to the most-recent portal.
    local destination = portalSpellToDestination[spellName]
    if destination then
        -- Highlight the matching ticket group while the cast is in progress.
        QueueMarkCasting(destination)

        local now = GetTime()
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do
                local rosterName, _, _, _, _, classTag = GetRaidRosterInfo(i)
                if rosterName then
                    local norm = NormalizeName(rosterName)
                    if norm ~= cachedPlayerNameNormalized and recentPortalsByPlayer[norm] then
                        recentPortalsByPlayer[norm] = { destination = destination, time = now, class = classTag }
                    end
                end
            end
        elseif IsInGroup() then
            for i = 1, GetNumSubgroupMembers() do
                local unit = "party" .. i
                local partyName = UnitName(unit)
                if partyName then
                    local norm = NormalizeName(partyName)
                    if recentPortalsByPlayer[norm] then
                        local _, classTag = UnitClass(unit)
                        recentPortalsByPlayer[norm] = {
                            destination = destination, time = now, class = classTag,
                        }
                    end
                end
            end
        end
    end

    if not PortalInviterDB.announcePortalCasts then return end

    local channel
    if IsInRaid() then
        channel = "RAID"
    elseif IsInGroup() then
        channel = "PARTY"
    else
        return
    end

    -- Prefix with the caster's current raid-target marker so groupmates can
    -- spot "Casting ..." at a glance. {rt1}..{rt8} are auto-rendered by the
    -- chat frame as the matching icon. Default to star (what ApplySelfStarMark
    -- sets when a buyer joins) if nothing is set.
    local markerIdx = (GetRaidTargetIndex and GetRaidTargetIndex("player")) or SELF_STAR_MARK_ICON
    if type(markerIdx) ~= "number" or markerIdx < 1 or markerIdx > 8 then
        markerIdx = SELF_STAR_MARK_ICON
    end
    C_ChatInfo.SendChatMessage(string.format("{rt%d} Casting %s", markerIdx, spellName), channel)
end

local function IsPlayerInCurrentGroup(playerName)
    local normalizedTarget = NormalizeName(playerName)

    if normalizedTarget == "" then
        return false
    end

    if cachedPlayerNameNormalized == normalizedTarget then
        return true
    end

    -- groupSnapshot is maintained on GROUP_ROSTER_UPDATE so membership lookup
    -- is an O(1) hash hit here instead of iterating the raid/party roster.
    return groupSnapshot[normalizedTarget] == true
end

local function IsOnCooldown(playerName)
    local normalizedTarget = NormalizeName(playerName)
    local expiresAt = recentInvites[normalizedTarget]

    if not expiresAt then
        return false
    end

    if expiresAt <= GetTime() then
        recentInvites[normalizedTarget] = nil
        return false
    end

    return true
end

local function MarkInvited(playerName)
    recentInvites[NormalizeName(playerName)] = GetTime() + INVITE_COOLDOWN_SECONDS
end

local function ResolveWoWCharacterFromGameAccount(gameAccountID)
    if type(gameAccountID) ~= "number" then
        return nil
    end

    if C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
        local info = C_BattleNet.GetGameAccountInfoByID(gameAccountID)
        if info and info.clientProgram == BNET_CLIENT_WOW and info.characterName and info.characterName ~= "" then
            return info.characterName
        end
    end

    if BNGetGameAccountInfo then
        local _, characterName, clientProgram = BNGetGameAccountInfo(gameAccountID)
        if clientProgram == BNET_CLIENT_WOW and characterName and characterName ~= "" then
            return characterName
        end
    end

    return nil
end

local function ResolveWoWCharacterFromBNetAccount(accountID)
    if type(accountID) ~= "number" then
        return nil
    end

    if C_BattleNet and C_BattleNet.GetFriendAccountInfoByID then
        local accountInfo = C_BattleNet.GetFriendAccountInfoByID(accountID)
        if accountInfo and accountInfo.gameAccountInfo then
            local gameAccountInfo = accountInfo.gameAccountInfo
            if gameAccountInfo.clientProgram == BNET_CLIENT_WOW
                and gameAccountInfo.characterName
                and gameAccountInfo.characterName ~= "" then
                return gameAccountInfo.characterName
            end
        end
    end

    if BNGetFriendInfoByID then
        local accountName, battleTag, isBattleTagPresence, characterName, _, clientProgram = BNGetFriendInfoByID(accountID)
        if clientProgram == BNET_CLIENT_WOW and characterName and characterName ~= "" then
            return characterName
        end
    end

    return nil
end

local function ResolveWoWCharacterFromCandidateID(candidateID)
    return ResolveWoWCharacterFromGameAccount(candidateID) or ResolveWoWCharacterFromBNetAccount(candidateID)
end

local function ResolveBNWhisperTarget(sender, ...)
    local checkedIDs = {}

    for index = 1, select("#", ...) do
        local candidateID = select(index, ...)
        if type(candidateID) == "number" and not checkedIDs[candidateID] then
            checkedIDs[candidateID] = true

            local characterName = ResolveWoWCharacterFromCandidateID(candidateID)
            if characterName and characterName ~= "" then
                return characterName
            end
        end
    end

    if sender
        and not string.find(sender, "#", 1, true)
        and not string.find(sender, "[", 1, true)
        and not string.find(sender, "]", 1, true) then
        return sender
    end

    return nil
end

local function PlayInviteAlert()
    if PortalInviterDB.soundMuted then
        return
    end

    if PlaySoundFile then
        PlaySoundFile(INVITE_ALERT_SOUND, "Master")
    elseif PlaySound then
        PlaySound(INVITE_ALERT_SOUND_KIT, "Master")
    end
end

local function PlayDestinationSound(destination)
    if PortalInviterDB.soundMuted then
        return
    end

    local soundPath = destination and DESTINATION_SOUNDS[destination]
    if soundPath and PlaySoundFile then
        PlaySoundFile(soundPath, "Master")
    end
end

local function SetSoundMuted(isMuted)
    PortalInviterDB.soundMuted = isMuted and true or false
    Print(PortalInviterDB.soundMuted
        and "|cffff8800Sound muted.|r No invite alerts or city name cues. Middle-click minimap icon to unmute."
        or  "|cff00ff00Sound enabled.|r Playing invite alerts and city name cues. Middle-click minimap icon to mute.")
end

local function ToggleSoundMuted()
    SetSoundMuted(not PortalInviterDB.soundMuted)
end

local function SetDebugEnabled(enabled)
    PortalInviterDB.debugEnabled = enabled and true or false
    Print(PortalInviterDB.debugEnabled
        and "|cff00ff00Debug logging enabled.|r /port debug to disable."
        or  "|cffff6060Debug logging disabled.|r")
end

local function ToggleDebugEnabled()
    SetDebugEnabled(not PortalInviterDB.debugEnabled)
end

local function SetEnabled(enabled)
    PortalInviterDB.userEnabled = enabled and true or false
    PortalInviterDB.enabled = PortalInviterDB.userEnabled
    if PI.RefreshMinimapState then PI.RefreshMinimapState() end
    if PortalInviterDB.enabled then
        local msg = "|cff00ff00Portal Inviter enabled.|r Sending automated invites."
        if PortalInviterDB.autoMode then
            msg = msg .. " (Auto-mode: only when in a capital city)"
        else
            msg = msg .. " Left-click minimap icon to disable."
        end
        Print(msg)
    else
        Print("|cffff6060Portal Inviter disabled.|r No longer sending invites. Left-click minimap icon to re-enable.")
    end
end

local function ToggleEnabled()
    SetEnabled(not PortalInviterDB.enabled)
end

local function IsInCapitalCity()
    if C_Map and C_Map.GetBestMapForUnit then
        local mapID = C_Map.GetBestMapForUnit("player")
        if mapID and CAPITAL_CITY_MAP_IDS[mapID] then return true end
    end
    -- English-string fallback (for clients without C_Map, or unlisted IDs)
    if CAPITAL_CITY_ZONES[GetRealZoneText() or ""] then return true end
    if CAPITAL_CITY_SUBZONES[GetSubZoneText() or ""] then return true end
    return false
end

local function ApplyAutoModeZoneCheck()
    if not PortalInviterDB.autoMode then return end
    local inCity = IsInCapitalCity()
    if PortalInviterDB.enabled ~= inCity then
        PortalInviterDB.enabled     = inCity
        PortalInviterDB.userEnabled = inCity
        if PI.RefreshMinimapState then PI.RefreshMinimapState() end
        if inCity then
            Print("|cff00ff00Auto mode:|r Entered capital city. Now sending invites.")
        else
            Print("|cffff6060Auto mode:|r Left capital city. No longer sending invites.")
        end
    end
end

local function SetAutoMode(enabled)
    PortalInviterDB.autoMode = enabled and true or false
    if PI.RefreshMinimapState then PI.RefreshMinimapState() end
    Print(PortalInviterDB.autoMode
        and "|cff00ff00Auto mode enabled.|r Sending invites only while in a capital city. Shift+Left-click minimap icon to disable."
        or  "|cffff6060Auto mode disabled.|r Invites stay on/off until you toggle manually.")
    ApplyAutoModeZoneCheck()
end

local function ToggleAutoMode()
    SetAutoMode(not PortalInviterDB.autoMode)
end

local function IsSupportedChannel(channelName, channelNumber, channelBaseName)
    local numericChannel = tonumber(channelNumber)
    if numericChannel == 1 then
        return true
    end

    local base = string.lower(tostring(channelBaseName or ""))
    if base:find("general", 1, true) then
        return true
    end

    local full = string.lower(tostring(channelName or ""))
    if full:find("general", 1, true) then
        return true
    end

    local extractedNum = full:match("^(%d+)%.")
    if tonumber(extractedNum) == 1 then
        return true
    end

    return false
end

local function ResolveInviteTarget(event, sender, ...)
    if event == "CHAT_MSG_BN_WHISPER" then
        return ResolveBNWhisperTarget(sender, ...)
    end

    return sender
end

local EVENT_LABELS = {
    CHAT_MSG_SAY        = "say",
    CHAT_MSG_YELL       = "yell",
    CHAT_MSG_WHISPER    = "whisper",
    CHAT_MSG_BN_WHISPER = "Battle.net whisper",
}

local function GetEventLabel(event, channelName, channelNumber, channelBaseName)
    if event == "CHAT_MSG_CHANNEL" then
        local numericChannel = tonumber(channelNumber)
        if numericChannel then
            return string.format("channel %d (%s)", numericChannel, channelBaseName or channelName or "unknown")
        end

        return channelBaseName or channelName or "channel"
    end

    return EVENT_LABELS[event] or event or "unknown event"
end

local function CouldBePortalRequest(message)
    -- Every portal keyword (port, ports, portal, portals, mageport, mageports)
    -- contains "port", and every teleport keyword (tp, teleport, teleports)
    -- contains "tp".  If neither case-insensitive substring is present in the
    -- raw message the full NormalizeText + padded-find pipeline cannot match.
    -- Using a character-class pattern avoids allocating a lowercased copy of
    -- every chat message the addon sees.
    if message:find("[Pp][Oo][Rr][Tt]") then return true end
    if message:find("[Tt][Pp]")         then return true end
    return false
end

local function HandlePotentialCustomer(event, message, sender, languageName, channelName, target, flags, unknown, channelNumber, channelBaseName)
    -- Fast bail: skip everything if disabled or not a mage
    if not PortalInviterDB.enabled then return end
    if not IsMage() then return end

    -- Silently drop unsupported channels before any debug output
    if event == "CHAT_MSG_CHANNEL" and not IsSupportedChannel(channelName, channelNumber, channelBaseName) then
        return
    end

    -- Phase 1: cached-bool checks before any string work or WoW API calls.
    -- CouldBePortalRequest rejects the vast majority of chat messages with two
    -- C-level string.find calls on the *raw* message, so it runs first — ahead
    -- of NormalizeName(sender) which would allocate a lowercased copy.
    if not message or not CouldBePortalRequest(message) then
        return
    end

    if inMatchmakingQueue then
        DebugPrint("Ignoring %s from %s because you are queued for a battleground, arena, or dungeon finder.",
            event or "?", sender or "unknown")
        return
    end

    if not canInviteCached then
        if PortalInviterDB.debugEnabled then
            DebugPrint("Ignoring %s from %s because you are not the current group leader.",
                event or "?", sender or "unknown")
        end
        return
    end

    -- Phase 2: for non-BN events the sender *is* the character name — do cheap
    -- self-check and cooldown-check before any message analysis.  Compute the
    -- normalized form once and thread it through the rest of the function.
    local normalizedSender
    if event ~= "CHAT_MSG_BN_WHISPER" and sender then
        normalizedSender = NormalizeName(sender)
        if normalizedSender == cachedPlayerNameNormalized then
            return
        end
        local expiresAt = recentInvites[normalizedSender]
        if expiresAt then
            if expiresAt <= GetTime() then
                recentInvites[normalizedSender] = nil
            else
                DebugPrint("Skipping %s from %s because they are still on invite cooldown (early).",
                    event or "?", sender)
                return
            end
        end
    end

    local debugEnabled = PortalInviterDB.debugEnabled
    local eventLabel
    if debugEnabled then
        eventLabel = GetEventLabel(event, channelName, channelNumber, channelBaseName)
        DebugPrint(
            ">>> %s from %s | msg=%s | ch=%s chNum=%s chBase=%s",
            event or "?",
            tostring(sender or "?"),
            tostring(message or ""):sub(1, 60),
            tostring(channelName or "nil"),
            tostring(channelNumber or "nil"),
            tostring(channelBaseName or "nil")
        )
    end

    -- Phase 3: fast match — intent only.  Destination is resolved *after* the
    -- invite fires so we save a few hundred microseconds on unambiguous
    -- requests like "wtb port" / "wtb <location> port".
    local shouldInvite, normalizedMessage, earlyDestination = MatchRequestFast(message, event)
    if not shouldInvite then
        if debugEnabled then
            DebugPrint("Skipped %s from %s: no portal request match (normalized=\"%s\").",
                eventLabel, sender or "unknown", normalizedMessage or "")
        end
        return
    end

    local inviteTarget = ResolveInviteTarget(event, sender, languageName, channelName, target, flags, unknown, channelNumber, channelBaseName)
    if event == "CHAT_MSG_BN_WHISPER" and not inviteTarget then
        Print("Matched Battle.net whisper, but could not resolve the sender's character name.")
        return
    end

    local shortSender = ShortName(inviteTarget)
    if not inviteTarget or inviteTarget == "" or shortSender == "" then
        DebugPrint("Skipping matched %s request because the invite target \"%s\" was invalid.", eventLabel, tostring(inviteTarget))
        return
    end

    -- Reuse the sender's normalized name from Phase 2 when we already have it
    -- (non-BN events).  BN whispers only learn the WoW character name here.
    local normalizedInviteTarget = normalizedSender or NormalizeName(inviteTarget)

    if normalizedInviteTarget == cachedPlayerNameNormalized then
        DebugPrint("Skipping %s from %s because the sender is yourself.", eventLabel, tostring(inviteTarget))
        return
    end

    if IsPlayerInCurrentGroup(inviteTarget) then
        DebugPrint("Skipping invite for \"%s\" because they are already in your group.", inviteTarget)
        return
    end

    -- BN whispers only learned the WoW character name now, so cooldown check
    -- gets done here for them.  Non-BN cooldowns were already filtered in
    -- Phase 2.
    if event == "CHAT_MSG_BN_WHISPER" and IsOnCooldown(inviteTarget) then
        DebugPrint("Skipping invite for \"%s\" because they are still on invite cooldown.", inviteTarget)
        return
    end

    -- --- CRITICAL PATH: fire invite first, do bookkeeping afterwards. ---
    if InviteUnitFn then
        InviteUnitFn(inviteTarget)
    end
    MarkInvited(inviteTarget)

    -- Destination is only needed for logging, destination-sound (plays on group
    -- join many seconds later) and the pendingDestinations entry.  Compute it
    -- here so the InviteUnit call above isn't blocked by fuzzy matching.
    local destination = earlyDestination or FindDestination(normalizedMessage) or "unknown"

    local now = GetTime()
    pendingWhispers[normalizedInviteTarget] = { target = inviteTarget, time = now }
    pendingDestinations[normalizedInviteTarget] = { destination = destination, time = now }
    PlayInviteAlert()
    local playerEntry = recentPortalsByPlayer[normalizedInviteTarget]
    local nameHex = (playerEntry and playerEntry.class and PI.ClassColorHex(playerEntry.class)) or "a8d9ff"
    local destHex = PI.DestinationColorHex(destination)
    Print(string.format("Invited |cff%s%s|r. Portal to: |cff%s%s|r",
        nameHex, inviteTarget, destHex, destination))

    if debugEnabled then
        DebugPrint("Matched %s request from %s for %s (normalized=\"%s\").",
            eventLabel, sender or "unknown", destination, normalizedMessage or "")
    end
end

local function PruneExpiredInvites()
    local now = GetTime()
    for name, expiresAt in pairs(recentInvites) do
        if expiresAt <= now then
            recentInvites[name] = nil
        end
    end

    -- Also prune stale pending state so entries from players who ignored the
    -- invite (never joined, never produced an "already in a group" error) don't
    -- leak memory across a long session.
    local cutoff = now - PENDING_STATE_TIMEOUT_SECONDS
    for name, entry in pairs(pendingDestinations) do
        if type(entry) ~= "table" or (entry.time or 0) <= cutoff then
            pendingDestinations[name] = nil
        end
    end
    for name, entry in pairs(pendingWhispers) do
        if (entry.time or 0) <= cutoff then
            pendingWhispers[name] = nil
        end
    end

    -- Sweep the portal correlation map (GetTime-based TTL).
    local correlationCutoff = now - PORTAL_CORRELATION_TTL_SECONDS
    for name, entry in pairs(recentPortalsByPlayer) do
        if (entry.time or 0) <= correlationCutoff then
            recentPortalsByPlayer[name] = nil
        end
    end

    -- Sweep queue tickets older than the TTL so abandoned requests don't
    -- linger in the UI.
    local queueCutoff = now - QUEUE_TTL_SECONDS
    local queueChanged = false
    for name, entry in pairs(portalQueue) do
        if (entry.createdAt or 0) <= queueCutoff then
            portalQueue[name] = nil
            queueChanged = true
        end
    end
    if queueChanged and PI.RefreshQueueFrame then PI.RefreshQueueFrame() end
end

local function HandleInviteFailedWhisper(errorMessage)
    if not next(pendingWhispers) then return end

    -- Build capture pattern lazily from locale string.
    if not alreadyInGroupPattern then
        local fmt = ERR_ALREADY_IN_GROUP_S
        if not fmt then return end
        local escaped = fmt:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
        alreadyInGroupPattern = "^" .. escaped:gsub("%%%%s", "(.-)") .. "$"
    end

    local capturedName = errorMessage:match(alreadyInGroupPattern)
    if not capturedName then return end

    local normalizedCaptured = NormalizeName(capturedName)
    local entry = pendingWhispers[normalizedCaptured]
    if not entry then return end

    -- Discard stale state: the error fires within a second of the invite
    -- attempt. If more than 15 seconds have passed, this entry is expired.
    if (GetTime() - entry.time) > 15 then
        pendingWhispers[normalizedCaptured] = nil
        return
    end

    local whisperMsg = PortalInviterDB.autoWhisperMessage
    if not whisperMsg or whisperMsg == "" then
        pendingWhispers[normalizedCaptured] = nil
        return
    end

    C_ChatInfo.SendChatMessage(whisperMsg, "WHISPER", nil, entry.target)
    DebugPrint("Sent auto-whisper to \"%s\" (already in a group): %s", entry.target, whisperMsg)
    Print(string.format("Whispered \"%s\": %s", entry.target, whisperMsg))
    pendingWhispers[normalizedCaptured] = nil
end

-- Rebuilds groupSnapshotScratch in place from the current roster, then swaps
-- it with groupSnapshot.  Avoids allocating a fresh table on every
-- GROUP_ROSTER_UPDATE, which can fire in bursts.
local function RefreshGroupSnapshot()
    local scratch = groupSnapshotScratch
    for k in pairs(scratch) do scratch[k] = nil end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name then
                scratch[NormalizeName(name)] = true
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local name = UnitName("party" .. i)
            if name then
                scratch[NormalizeName(name)] = true
            end
        end
    end

    groupSnapshotScratch = groupSnapshot
    groupSnapshot = scratch
    return groupSnapshot
end

-- ---------------------------------------------------------------------------
-- Portal queue (ticket system).
--
-- Tickets are created ONLY for confirmed sales — i.e. when a player who
-- whispered for a portal actually joins the group (cold path, see
-- HandleGroupJoins below). All mutations route through these helpers so the
-- UI module can hook PI.RefreshQueueFrame to refresh idempotently.
-- ---------------------------------------------------------------------------
local function QueueRefreshUI()
    if PI.RefreshQueueFrame then PI.RefreshQueueFrame() end
end

function QueueAdd(normalizedName, displayName, destination, class)
    if not normalizedName or normalizedName == "" then return end
    portalQueue[normalizedName] = {
        displayName = displayName or normalizedName,
        destination = destination or "unknown",
        class       = class,
        createdAt   = GetTime(),
        state       = "pending",
    }
    QueueRefreshUI()
end

function QueueRemove(normalizedName)
    if portalQueue[normalizedName] then
        portalQueue[normalizedName] = nil
        QueueRefreshUI()
    end
end

-- Store the raid-target icon index (1..8) we applied to a joined buyer so the
-- ticket UI can render the matching glyph in front of their name.
function QueueSetMarker(normalizedName, markerIdx)
    local entry = portalQueue[normalizedName]
    if not entry then return end
    if type(markerIdx) ~= "number" or markerIdx < 1 or markerIdx > 8 then return end
    if entry.marker == markerIdx then return end
    entry.marker = markerIdx
    QueueRefreshUI()
end

function QueueClearDestination(destination)
    if not destination then return end
    local changed = false
    for name, entry in pairs(portalQueue) do
        if entry.destination == destination then
            portalQueue[name] = nil
            changed = true
        end
    end
    if changed then QueueRefreshUI() end
end

function QueueClearAll()
    if next(portalQueue) == nil then return end
    for name in pairs(portalQueue) do portalQueue[name] = nil end
    QueueRefreshUI()
end

local function QueueSetState(destination, newState)
    if not destination then return end
    local changed = false
    for _, entry in pairs(portalQueue) do
        if entry.destination == destination and entry.state ~= newState then
            entry.state = newState
            changed = true
        end
    end
    if changed then QueueRefreshUI() end
end

function QueueMarkCasting(destination)
    QueueSetState(destination, "casting")
end

function QueueClearCasting(destination)
    QueueSetState(destination, "pending")
end

function QueueCompleteCast(destination)
    if not destination then return end
    local changed = false
    for name, entry in pairs(portalQueue) do
        if entry.destination == destination then
            portalQueue[name] = nil
            changed = true
        end
    end
    if changed then QueueRefreshUI() end
end

-- Snapshot for UI rendering. Returns: { { destination, entries={ {normalized,
-- displayName, class, createdAt, state}, ... } }, ... } grouped by destination,
-- and totalCount for convenience.
local queueSnapshotBuffer = {}
local queueSnapshotGroups = {}
function QueueSnapshot()
    -- Bucket entries by destination.
    for k in pairs(queueSnapshotBuffer) do queueSnapshotBuffer[k] = nil end
    for i = #queueSnapshotGroups, 1, -1 do queueSnapshotGroups[i] = nil end

    local total = 0
    for normalized, entry in pairs(portalQueue) do
        local dest = entry.destination or "unknown"
        local bucket = queueSnapshotBuffer[dest]
        if not bucket then
            bucket = { destination = dest, entries = {}, hasCasting = false }
            queueSnapshotBuffer[dest] = bucket
            queueSnapshotGroups[#queueSnapshotGroups + 1] = bucket
        end
        bucket.entries[#bucket.entries + 1] = {
            normalized  = normalized,
            displayName = entry.displayName,
            class       = entry.class,
            createdAt   = entry.createdAt,
            state       = entry.state,
            marker      = entry.marker,
        }
        if entry.state == "casting" then bucket.hasCasting = true end
        total = total + 1
    end

    -- Stable alphabetical ordering by destination, plus per-group by createdAt.
    table.sort(queueSnapshotGroups, function(a, b)
        return (a.destination or "") < (b.destination or "")
    end)
    for _, g in ipairs(queueSnapshotGroups) do
        table.sort(g.entries, function(a, b)
            return (a.createdAt or 0) < (b.createdAt or 0)
        end)
    end

    return queueSnapshotGroups, total
end

local function HandleGroupJoins()
    local hasPending = next(pendingDestinations) ~= nil
    local hasQueue = next(portalQueue) ~= nil
    if not hasPending and not hasQueue then
        RefreshGroupSnapshot()
        return
    end

    local previous = groupSnapshot
    local current = RefreshGroupSnapshot()
    for normalizedName in pairs(current) do
        if not previous[normalizedName] then
            -- This person just joined the group.
            local entry = pendingDestinations[normalizedName]
            if entry then
                local destination = entry.destination
                DebugPrint("%s joined the group; playing destination sound for %s.", normalizedName, destination)
                PlayDestinationSound(destination)
                ApplySelfStarMark()

                -- Capture class + display name for nicer UI / log colouring.
                local class
                local displayName
                local joinerUnit
                if IsInRaid() then
                    for i = 1, GetNumGroupMembers() do
                        local rosterName, _, _, _, _, classTag = GetRaidRosterInfo(i)
                        if rosterName and NormalizeName(rosterName) == normalizedName then
                            class = classTag
                            displayName = rosterName
                            joinerUnit = "raid" .. i
                            break
                        end
                    end
                else
                    for i = 1, GetNumSubgroupMembers() do
                        local unit = "party" .. i
                        local partyName = UnitName(unit)
                        if partyName and NormalizeName(partyName) == normalizedName then
                            local _, classTag = UnitClass(unit)
                            class = classTag
                            displayName = partyName
                            joinerUnit = unit
                            break
                        end
                    end
                end

                recentPortalsByPlayer[normalizedName] = {
                    destination = destination,
                    time        = GetTime(),
                    class       = class,
                }

                -- Create a ticket for this confirmed sale.
                QueueAdd(normalizedName, displayName or normalizedName, destination, class)

                -- Mark the joiner with one of the unused raid icons so they
                -- stand out vs. the caster's star. No-op if we failed to
                -- resolve a unit token (e.g. roster race condition). The
                -- returned icon index is mirrored onto the queue entry so the
                -- ticket UI can render a matching glyph in front of the name.
                local markerIcon = MarkJoiner(joinerUnit)
                if markerIcon then
                    QueueSetMarker(normalizedName, markerIcon)
                end

                pendingDestinations[normalizedName] = nil
                -- Clear the pending whisper entry so a later unrelated
                -- "already in a group" error doesn't whisper this person.
                pendingWhispers[normalizedName] = nil
            end
        end
    end

    -- Drop tickets for players who left the group (leavers were in the
    -- previous snapshot but are absent from the current one).
    if hasQueue then
        for normalizedName in pairs(previous) do
            if not current[normalizedName] and portalQueue[normalizedName] then
                QueueRemove(normalizedName)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Expose engine API to sibling modules.
-- Population happens here (after all local functions exist, before the event
-- handler runs) so module files loaded AFTER this one can consume PI.* safely.
-- ---------------------------------------------------------------------------
PI.Print                        = Print
PI.DebugPrint                   = DebugPrint
PI.ShortName                    = ShortName
PI.NormalizeName                = NormalizeName
PI.NormalizeText                = NormalizeText
PI.GetCharDB                    = GetCharDB
PI.recentPortalsByPlayer        = recentPortalsByPlayer
PI.PORTAL_CORRELATION_TTL_SECONDS = PORTAL_CORRELATION_TTL_SECONDS
PI.ExplainMessageMatch          = ExplainMessageMatch
PI.EvaluateMessage              = EvaluateMessage
PI.SetEnabled                   = SetEnabled
PI.ToggleEnabled                = ToggleEnabled
PI.SetAutoMode                  = SetAutoMode
PI.ToggleAutoMode               = ToggleAutoMode
PI.SetSoundMuted                = SetSoundMuted
PI.ToggleSoundMuted             = ToggleSoundMuted
PI.SetDebugEnabled              = SetDebugEnabled
PI.ToggleDebugEnabled           = ToggleDebugEnabled
PI.IsInMatchmakingQueue         = function() return inMatchmakingQueue end
PI.QueueSnapshot                = QueueSnapshot
PI.QueueAdd                     = QueueAdd
PI.QueueRemove                  = QueueRemove
PI.QueueClearDestination        = QueueClearDestination
PI.QueueClearAll                = QueueClearAll
PI.QueueMarkCasting             = QueueMarkCasting
PI.QueueClearCasting            = QueueClearCasting
PI.QueueSetMarker               = QueueSetMarker
PI.GetPortalSpellForDestination = function(destination)
    return destinationToPortalSpell[destination]
end

-- ---------------------------------------------------------------------------
-- Event dispatcher. Trade events, login-time UI bringup, and the slash command
-- registration all delegate to sibling modules through PI.* hooks.
-- ---------------------------------------------------------------------------
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        EnsureDB()
        cachedIsMage = nil
        IsMage()
        cachedPlayerNameNormalized = NormalizeName(UnitName("player"))
        cachedDestinations = BuildDestinations()
        RefreshPortalSpellNames()

        SLASH_PORTALINVITER1 = "/port"
        SlashCmdList.PORTALINVITER = PI.HandleSlashCommand
        if PI.CreateMinimapButton then PI.CreateMinimapButton() end
        if PI.RefreshMinimapState then PI.RefreshMinimapState() end
        if PI.CreateOptionsPanel then PI.CreateOptionsPanel() end

        RefreshGroupSnapshot()
        RefreshCanInvite()
        UpdateQueueState()
        if PI.PruneOldTrades then PI.PruneOldTrades() end
        if PortalInviterDB.enabled then
            if PortalInviterDB.autoMode then
                Print("Loaded. |cff00ff00Auto mode active|r, sending invites in capital cities.")
            else
                Print("Loaded. |cff00ff00Sending automated invites.|r Left-click minimap icon to disable.")
            end
        else
            Print("Loaded. |cffff6060Invites disabled.|r Left-click minimap icon or /port on to enable.")
        end
        return
    end

    if event == "PLAYER_LOGOUT" then
        if type(PortalInviterDB) == "table" and not PortalInviterDB.autoMode then
            PortalInviterDB.userEnabled = PortalInviterDB.enabled and true or false
        end
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        HandleGroupJoins()
        RefreshCanInvite()
        PruneExpiredInvites()
        return
    end

    if event == "PARTY_LEADER_CHANGED" then
        RefreshCanInvite()
        return
    end

    if event == "GROUP_LEFT" then
        ClearSelfStarMark()
        RefreshCanInvite()
        QueueClearAll()
        return
    end

    if event == "UNIT_SPELLCAST_START" then
        local unitToken = ...
        if unitToken == "player" then
            AnnouncePortalCast()
        end
        return
    end

    if event == "UNIT_SPELLCAST_SUCCEEDED"
        or event == "UNIT_SPELLCAST_FAILED"
        or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local unitToken, _, spellID = ...
        if unitToken == "player" and spellID then
            local spellName = GetSpellInfo(spellID)
            local destination = spellName and portalSpellToDestination[spellName]
            if destination then
                if event == "UNIT_SPELLCAST_SUCCEEDED" then
                    QueueCompleteCast(destination)
                else
                    QueueClearCasting(destination)
                end
            end
        end
        return
    end

    if event == "PLAYER_LEVEL_UP" then
        -- Invalidate destination cache so newly available portals are included.
        cachedDestinations = nil
        cachedAliasMap     = nil
        cachedBigramMap    = nil
        -- A new level may grant a new portal rank; refresh the cast-announce
        -- spell name set so its cast is recognized.
        RefreshPortalSpellNames()
        return
    end

    if event == "SPELLS_CHANGED" then
        -- Catches mid-session spell learns that aren't tied to leveling (e.g.
        -- trainer visits, book items).
        RefreshPortalSpellNames()
        return
    end

    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" then
        ApplyAutoModeZoneCheck()
        UpdateQueueState()
        return
    end

    if event == "LFG_UPDATE" or event == "UPDATE_BATTLEFIELD_STATUS" then
        UpdateQueueState()
        return
    end

    if event == "CHAT_MSG_SYSTEM" then
        local message = ...
        if message then
            HandleInviteFailedWhisper(message)
        end
        return
    end

    if event == "TRADE_SHOW" then
        if PI.HandleTradeShow then PI.HandleTradeShow() end
        return
    end

    if event == "TRADE_CLOSED" then
        if PI.HandleTradeClosed then PI.HandleTradeClosed() end
        return
    end

    if event == "TRADE_ACCEPT_UPDATE" then
        if PI.HandleTradeAcceptUpdate then
            local playerAccepted, targetAccepted = ...
            PI.HandleTradeAcceptUpdate(playerAccepted, targetAccepted)
        end
        return
    end

    if event == "TRADE_MONEY_CHANGED"
        or event == "PLAYER_TRADE_MONEY" then
        if PI.UpdateTradeMoney then PI.UpdateTradeMoney() end
        return
    end

    if event == "UI_INFO_MESSAGE" then
        -- Signature differs by client: (messageType, message) on Retail/Anni,
        -- (message) on very old Classic. Grab the last string argument.
        local arg1, arg2 = ...
        local message = type(arg2) == "string" and arg2 or arg1
        if type(message) == "string" and ERR_TRADE_COMPLETE
            and (message == ERR_TRADE_COMPLETE or message:find(ERR_TRADE_COMPLETE, 1, true)) then
            if PI.HandleTradeComplete then PI.HandleTradeComplete() end
        end
        return
    end

    HandlePotentialCustomer(event, ...)
end)

frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PARTY_LEADER_CHANGED")
frame:RegisterEvent("UNIT_SPELLCAST_START")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("UNIT_SPELLCAST_FAILED")
frame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
frame:RegisterEvent("CHAT_MSG_SAY")
frame:RegisterEvent("CHAT_MSG_YELL")
frame:RegisterEvent("CHAT_MSG_CHANNEL")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("CHAT_MSG_BN_WHISPER")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("GROUP_LEFT")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("ZONE_CHANGED")
frame:RegisterEvent("LFG_UPDATE")
frame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_MONEY_CHANGED")
frame:RegisterEvent("PLAYER_TRADE_MONEY")
frame:RegisterEvent("UI_INFO_MESSAGE")
