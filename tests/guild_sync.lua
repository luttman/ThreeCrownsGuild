-- Run from the addon directory: lua tests/guild_sync.lua
local file = assert(io.open("ThreeCrownsGuild.lua", "r"))
local source = file:read("*a")
file:close()
local chatCode = assert(source:match("(local function addChat.-)\n%-%- %-+ window"))
local events = assert(source:match('(local ev = CreateFrame%("Frame"%).-)\nSLASH_THREECROWNSGUILD1'))
local commands = assert(source:match("(SLASH_THREECROWNSGUILD1.-)$"))
local compile = loadstring or load
local packets, echoes, warnings = {}, {}, {}
local time, failSend = 0, false
local secretValue = {}
local frame = { registered = {} }
function frame:RegisterEvent(event) self.registered[event] = true end
function frame:SetScript(_, handler) self.handler = handler end
CreateFrame = function() return frame end
UnitGUID = function() return "own-guid" end
UnitName = function() return "Anna" end
UnitClass = function() return "Mage", "MAGE" end
GetTime = function() return time end
Ambiguate = function(name) return name:gsub("%-.*", "") end
strtrim = function(text) return text:match("^%s*(.-)%s*$") end
function strsplit(separator, text, limit)
    local parts = {}
    while #parts < limit - 1 do
        local at = text:find(separator, 1, true)
        if not at then break end
        parts[#parts + 1], text = text:sub(1, at - 1), text:sub(at + 1)
    end
    parts[#parts + 1] = text
    return unpack(parts)
end
tinsert, tremove = table.insert, table.remove
DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) echoes[#echoes + 1] = text end }
print = function(text) warnings[#warnings + 1] = text end
ThreeCrownsGuild_Refresh = function() end
RegisterPrefix = function() end
IsInGuild = function() return false end
C_Timer = { NewTicker = function() end, After = function() end }
SlashCmdList = {}
GuildFriendsDB = { history = {}, nicks = {} }
local send = function(kind, body)
    if failSend then return false end
    local packet = kind .. "#G1#" .. body
    assert(#packet <= 250, "Oversized addon packet")
    packets[#packets + 1] = packet
    return true
end
local init = [[
local send, secretValue = ...
local db = GuildFriendsDB
local peers, rx = {}, {}
local GREEN, HISTORY_MAX, JOIN_DELAY, PFX = "", 200, 15, "GF1"
local function myTag() return "G1" end
local function render(rec) return rec.msg end
local function secret(value) return value == secretValue end
]]
local onAddonMsg = assert(compile(init .. chatCode .. events .. commands .. "\nreturn onAddonMsg"))(send, secretValue)
assert(frame.registered.CHAT_MSG_GUILD)
frame.handler(nil, "PLAYER_LOGIN")
assert(GuildFriendsDB.sync == true)
local function guildEvent(msg, guid)
    frame.handler(nil, "CHAT_MSG_GUILD", msg, "Anna", nil, nil, nil, nil, nil, nil, nil, nil, 1, guid)
end
guildEvent("Hej", "other-guid")
guildEvent(secretValue, "own-guid")
guildEvent("Hej", secretValue)
assert(#packets == 0, "Forwarded another player or a secret value")
guildEvent("Hej", "own-guid")
assert(#packets == 1 and #GuildFriendsDB.history == 1 and #echoes == 0)
onAddonMsg(packets[1], "Anna-Realm")
assert(#GuildFriendsDB.history == 1, "Own message was duplicated")
onAddonMsg(packets[1], "Bob-Realm")
assert(#GuildFriendsDB.history == 2 and #echoes == 0, "Own guild echoed twice")
onAddonMsg("G#G2#MAGE;3;Hej", "Carl-Realm")
assert(#echoes == 1 and GuildFriendsDB.history[3].name == "Carl")
assert(#packets == 1, "Received message was forwarded again")

SlashCmdList.THREECROWNSGUILD("sync off")
assert(GuildFriendsDB.sync == false and SLASH_THREECROWNSGUILD2 == "/tc")
guildEvent("Privat", "own-guid")
assert(#packets == 1)
frame.handler(nil, "PLAYER_LOGIN")
assert(GuildFriendsDB.sync == false, "Login reset the saved opt-out")
SlashCmdList.THREECROWNSGUILD("sync on")
local long = string.rep("Å", 120) .. " |Hitem:123|h[Link]|h #;"
guildEvent(long, "own-guid")
local before = #GuildFriendsDB.history
for i = 2, #packets do onAddonMsg(packets[i]:gsub("#G1#", "#G2#", 1), "Carl-Realm") end
assert(#GuildFriendsDB.history == before + 1)
assert(GuildFriendsDB.history[#GuildFriendsDB.history].msg == long, "Message or link was truncated")
before = #GuildFriendsDB.history
onAddonMsg("G#G2#MAGE;5;He", "Carl-Realm")
time = 11
onAddonMsg("g#G2#llo", "Carl-Realm")
onAddonMsg("G#G2#MAGE;99999;bad", "Carl-Realm")
onAddonMsg("G#G2#MAGE;2;long", "Carl-Realm")
assert(#GuildFriendsDB.history == before, "Accepted expired or malformed fragments")
failSend = true
guildEvent("Failed", "own-guid")
assert(#GuildFriendsDB.history == before, "Failed send was added to history")
io.write("Guild sync checks passed.\n")
