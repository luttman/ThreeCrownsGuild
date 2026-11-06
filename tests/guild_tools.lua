-- Run from the addon directory with Lua 5.1 or LuaJIT.
local addon, packets, timers, dots = {}, {}, {}, {}
local now, guild, requests, level = 100, "Test Guild", 0, 9
local party, raid = {}, {}
local frame
local function fire(event, ...)
    assert(frame.events[event], event)
    frame.handler(frame, event, ...)
end

GetBuildInfo = function() return "", "", "", 16001 end
GetTime = function() return now end
GetServerTime = function() return 1800000000 + now end
date = os.date
GetRealmName = function() return "Realm" end
GetNormalizedRealmName = GetRealmName
GetGuildInfo = function() return guild end
GetMoney = function() error("Peak gold must come from the native statistic") end
GetAchievementCriteriaInfo = function(id, index)
    assert(id == 334 and index == 1)
    return "Most gold ever owned", 86, false, 987654
end
local nativeStats = { [98] = "1,234", [107] = "2\226\128\175456", [329] = "--", [330] = 3,
    [932] = "4", [933] = "7", [60] = "10", [918] = "2", [1501] = "6", [114] = "1" }
GetStatistic = function(id) return nativeStats[id] end
IsInInstance = function() return false end
UnitFullName = function() return "Anna", "Forever" end
GetUnitName = function(unit)
    if unit == "player" then return "Anna Forever" end
    local index = tonumber(unit:match("%d+$"))
    return (unit:match("^raid") and raid or party)[index]
end
IsInRaid = function() return #raid > 0 end
GetNumGroupMembers = function() return #raid end
GetNumSubgroupMembers = function() return #party end
UnitClass = function() return "Mage", "MAGE" end
UnitLevel = function() return level end
RequestTimePlayed = function() requests = requests + 1 end
C_Timer = {
    NewTicker = function(interval, callback) timers[interval] = callback end,
}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function(prefix) assert(prefix == "TCGSTATS1") end,
    SendAddonMessage = function(prefix, message, distribution)
        assert(prefix == "TCGSTATS1" and distribution == "GUILD" and #message <= 255)
        packets[#packets + 1] = message
        return 0
    end,
}
Ambiguate = function(name) return name:gsub("%-.*", "") end
wipe = function(values) for key in pairs(values) do values[key] = nil end end
RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
CreateVector2D = function(x, y) return { GetXY = function() return x, y end } end
C_Map = {
    GetBestMapForUnit = function() return 1411 end,
    GetPlayerMapPosition = function() return CreateVector2D(0.5, 0.5) end,
    GetWorldPosFromMapPos = function(_, point)
        local x, y = point:GetXY()
        return 1, CreateVector2D(1000 - y * 1000, 1000 - x * 1000)
    end,
}
C_Minimap = { GetViewRadius = function() return 100 end }
GetCVar = function() return "0" end
local mapCanvas = { GetWidth = function() return 500 end, GetHeight = function() return 400 end }
WorldMapFrame = { IsShown = function() return true end, GetCanvas = function() return mapCanvas end, GetMapID = function() return 1411 end }
Minimap = { IsShown = function() return true end, GetWidth = function() return 200 end, GetHeight = function() return 200 end }
UIParent = { GetWidth = function() return 1200 end }
UISpecialFrames = {}
local labels, buttons = {}, {}
local function widget(name)
    return setmetatable({
        GetName = function() return name end,
        SetWidth = function(self, width) self.width = width end,
        GetWidth = function(self) return self.width end,
        GetHeight = function() return 300 end,
        IsShown = function() return true end,
        CreateFontString = function() return widget() end,
        SetText = function(self, label) labels[label] = true; self.label = label end,
        SetScript = function(self, _, callback) self.click = callback end,
    }, { __index = function() return function() end end })
end
CreateFrame = function(kind, name, parent)
    if not parent then
        frame = { events = {}, RegisterEvent = function(self, event) self.events[event] = true end,
            SetScript = function(self, _, callback) self.handler = callback end }
        return frame
    end
    if parent ~= mapCanvas and parent ~= Minimap then
        local ui = widget(name)
        ui.TitleText = widget()
        if kind == "Button" then buttons[#buttons + 1] = ui end
        return ui
    end
    local dot = setmetatable({
        Show = function(self) self.visible = true end,
        Hide = function(self) self.visible = false end,
        SetPoint = function(self, _, _, _, x, y) self.x, self.y = x, y end,
        CreateTexture = function(self)
            return { SetAllPoints = function() end, SetTexture = function() end,
                SetVertexColor = function(_, r, g, b) self.color = { r, g, b } end }
        end,
    }, { __index = function() return function() end end })
    dots[parent] = dot
    return dot
end

assert(loadfile("GuildMap.lua"))("ThreeCrownsGuild", addon)
assert(loadfile("GuildStats.lua"))("ThreeCrownsGuild", addon)
GuildFriendsDB = {
    characterStats = { ["Anna-Forever"] = { quests = 99, played = 9999, words = 2 } },
    guildStats = { ["Realm#Test Guild"] = { ["Old-Realm"] = { quests = 99 } } },
    guildApiStats = { ["Realm#Test Guild"] = { ["Anna Forever-Forever"] = { quests = 99 } } },
}
fire("PLAYER_LOGIN")
timers[8](); timers[60]()
assert(#packets == 2 and packets[1] == "M;MAGE;1411;50000;50000" and packets[2]:match("^B;"),
    "Defaults must share positions and stats")
assert(addon.GuildMapStatus() == "Map dots on. Position sharing on. Guildmates sharing a recent position: 0.")
assert(requests == 1)
packets = {}
addon.GuildCommand("show")
assert(packets[#packets] == "M;MAGE;1411;50000;50000")
assert(addon.GuildMapStatus():find("Position sharing on", 1, true))
addon.GuildCommand("hide")
assert(packets[#packets] == "H")
timers[8]()
assert(#packets == 2, "Hiding still broadcast a position")

fire("CHAT_MSG_ADDON", "TCGSTATS1", "M;MAGE;1411;52000;51000", "CHANNEL", "Bob-Realm")
timers[0.25]()
assert(next(dots) == nil, "Map accepted a packet outside guild transport")
fire("CHAT_MSG_ADDON", "TCGSTATS1", "M;MAGE;1411;52000;51000", "GUILD", "Bob-Realm")
timers[0.25]()
assert(dots[mapCanvas].visible and dots[mapCanvas].x == 260 and dots[mapCanvas].y == -204)
assert(dots[Minimap].visible and dots[Minimap].x == 20 and dots[Minimap].y == -10)
assert(dots[Minimap].color[2] == 0.78)
party = { "Bob Other-Realm" }
fire("GROUP_ROSTER_UPDATE")
timers[0.25]()
assert(dots[mapCanvas].visible and dots[Minimap].visible, "A shared first name hid a guildmate's dots")
party = { "Bob Realm" }
fire("GROUP_ROSTER_UPDATE")
timers[0.25]()
assert(not dots[mapCanvas].visible and not dots[Minimap].visible, "Party member dots stayed visible")
party, raid = {}, { "Anna Forever", "Bob Realm-Realm" }
fire("GROUP_ROSTER_UPDATE")
timers[0.25]()
assert(not dots[mapCanvas].visible and not dots[Minimap].visible, "Raid member dots stayed visible")
raid = {}
fire("GROUP_ROSTER_UPDATE")
timers[0.25]()
assert(dots[mapCanvas].visible and dots[Minimap].visible, "Dots did not return after leaving the raid")
addon.GuildCommand("pins off")
assert(not dots[mapCanvas].visible and not dots[Minimap].visible)
assert(addon.GuildMapStatus() == "Map dots off. Position sharing off. Guildmates sharing a recent position: 1.")
addon.GuildCommand("pins on")
assert(dots[mapCanvas].visible and dots[Minimap].visible)
fire("CHAT_MSG_ADDON", "TCGSTATS1", "H", "GUILD", "Bob-Realm")
timers[0.25]()
assert(not dots[mapCanvas].visible and not dots[Minimap].visible)
fire("CHAT_MSG_ADDON", "TCGSTATS1", "M;MAGE;1411;52000;51000", "GUILD", "Bob-Realm")
now = now + 30
assert(addon.CountGuildPositions() == 0, "Map status counted an expired position")
timers[0.25]()
assert(not dots[mapCanvas].visible and not dots[Minimap].visible, "Old positions did not expire")

assert(not frame.events.QUEST_TURNED_IN and not frame.events.CHAT_MSG_SAY)
assert(addon.GuildCommand("stats"))
assert(requests == 2)
assert(labels["Quests"] and labels["Anna Forever"] and labels["Peak gold"] and labels["98.7654"] and labels["—"])
assert(labels["1234"] and labels["2456"] and labels["0"] and not labels["Old"] and not labels["99"])
assert(not labels["Swears"] and labels["Level race"])
buttons[4].click()
assert(addon.GuildCommand("deaths") and labels["Falling"] and labels["Players"] and not labels["Unknown"])

addon.GuildCommand("share on")
fire("TIME_PLAYED_MSG", 3603, 3)
local counters = packets[#packets]
assert(counters:match("^B;1234;2456;4;7;%-;%-;0;3;987654;3603;10;2;"))
now = now + 60
timers[60]()
assert(packets[#packets] == counters, "Shared play time was estimated locally")
fire("CHAT_MSG_ADDON", "TCGSTATS1", counters, "GUILD", "Bob-Realm")
fire("CHAT_MSG_ADDON", "TCGSTATS1", "S;999", "GUILD", "Bob-Realm")
fire("CHAT_MSG_ADDON", "TCGSTATS1", "A;999", "GUILD", "Bob-Realm")
local shared = GuildFriendsDB.guildApiStats["Realm#Test Guild"]
assert(shared["Bob Realm"].quests == 1234 and shared["Bob Realm"].peakGold == 987654 and shared["Bob Realm"].played == 3603)
local oldCounters = counters:gsub("^B;", "A;"):gsub(";987654;", ";123456;")
fire("CHAT_MSG_ADDON", "TCGSTATS1", oldCounters, "GUILD", "Bob-Realm")
fire("CHAT_MSG_ADDON", "TCGSTATS1", oldCounters, "GUILD", "Carl-Forever")
assert(shared["Bob Realm"].peakGold == 987654 and shared["Carl Forever"].peakGold == nil)
assert(shared["Carl Forever"].quests == 1234)
assert(shared["Bob Realm"].posted == 0 and shared["Bob Realm"].raid20 == nil)
fire("CHAT_MSG_ADDON", "TCGSTATS1", counters, "GUILD", "Anna Forever-Forever")
fire("CHAT_MSG_ADDON", "TCGSTATS1", counters, "GUILD", "Anna-Forever")
assert(not shared["Anna Forever"] and not shared["Anna Forever-Forever"] and not shared["Anna-Forever"])
fire("CHAT_MSG_ADDON", "TCGSTATS1", counters, "GUILD", "Anna Andersson-Forever")
assert(shared["Anna Andersson"].quests == 1234, "Two characters with the same first name were merged")
assert(addon.GuildCommand("stats"))
assert(labels["Bob Realm"] and labels["Anna Andersson"] and labels["1h 00m"])

assert(addon.GuildCommand("race"))
local requestsBefore = requests
fire("PLAYER_LEVEL_UP", 9)
assert(requests == requestsBefore)
level = 10
local reached = GetServerTime()
fire("PLAYER_LEVEL_UP", level)
assert(requests == requestsBefore + 1)
fire("TIME_PLAYED_MSG", 3650, 50)
local race = packets[#packets]
assert(race == "L;3600;" .. reached .. ";-;-;-;-;-;-;-;-;-;-")
assert(labels["1h 00m\n" .. os.date("%Y-%m-%d", reached)])
fire("CHAT_MSG_ADDON", "TCGSTATS1", race, "GUILD", "Bob-Realm")
fire("CHAT_MSG_ADDON", "TCGSTATS1", counters, "GUILD", "Bob-Realm")
assert(shared["Bob Realm"].quests == 1234 and shared["Bob Realm"].level10 == 3600 and shared["Bob Realm"].reached10 == reached)
fire("PLAYER_LEVEL_UP", level)
fire("TIME_PLAYED_MSG", 3700, 50)
assert(requests == requestsBefore + 1 and packets[#packets] == race, "The first milestone was overwritten")

addon.GuildCommand("share off")
assert(packets[#packets] == "D")
level = 20
fire("PLAYER_LEVEL_UP", level)
fire("TIME_PLAYED_MSG", 7200, 0)
assert(packets[#packets] == "D", "Race results were sent after sharing was disabled")
fire("CHAT_MSG_ADDON", "TCGSTATS1", "D", "GUILD", "Bob-Realm")
assert(shared["Bob Realm"] == nil)
addon.GuildCommand("pins off")
fire("PLAYER_LOGIN")
local packetsBefore = #packets
timers[8]()
timers[60]()
assert(#packets == packetsBefore + 1 and packets[#packets] == "D", "Login reset the saved sharing opt-out")
assert(addon.GuildMapStatus() == "Map dots off. Position sharing off. Guildmates sharing a recent position: 0.")
print("Guild map, native stats, and sharing checks passed.")
