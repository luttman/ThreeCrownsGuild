-- Run from the addon directory: lua tests/startup.lua
local compile = loadstring or load
local file = assert(io.open("ThreeCrownsGuild.lua", "r"))
local source = file:read("*a")
file:close()

for _, client in ipairs({ "forever", "tbc" }) do
    local filters, frames, output, sent, whispers = {}, {}, {}, {}, {}
    local roster = { "Anna-Realm", "Bob-Realm" }
    local selected = 1
    local ticker, removedChannel
    local hardwareInput, blockedCalls = false, 0
    local time, channelID = 0, 0
    local env = setmetatable({}, { __index = _G })
    env._G = env
    env.GetBuildInfo = function() return "", "", "", client == "forever" and 16001 or 20506 end
    env.SlashCmdList = {}
    env.StaticPopupDialogs = {}
    env.strtrim = function(text) return text:match("^%s*(.-)%s*$") end
    env.print = function(text) output[#output + 1] = text end
    env.GetTime = function() return time end
    env.IsInGuild = function() return false end
    env.GetGuildInfo = function() return "Test Guild" end
    env.GetGuildInfoText = function() return "TCGc:TestChannel:pw\nTCGp:Test Guild:G1" end
    env.GetChannelName = function() return channelID end
    env.GetNumDisplayChannels = function() return 3 end
    env.GetChannelDisplayInfo = function(index)
        if index == 3 then return "TestChannel", false, false, 5, #roster end
        return "OtherChannel", false, false, index, 1
    end
    env.GetSelectedDisplayChannel = function() return selected end
    env.SetSelectedDisplayChannel = function(index) selected = index end
    env.UnitName = function() return "Anna" end
    env.UnitGUID = function() return "own-guid" end
    env.UnitClass = function() return "Mage", "MAGE" end
    env.UnitLevel = function() return 70 end
    env.GetRealZoneText = function() return "Test Zone" end
    env.RAID_CLASS_COLORS = {}
    env.DEFAULT_CHAT_FRAME = { AddMessage = function() end }
    env.Ambiguate = function(name) return name:gsub("%-.*", "") end
    env.strsplit = function(separator, text, limit)
        local parts = {}
        while #parts < limit - 1 do
            local at = text:find(separator, 1, true)
            if not at then break end
            parts[#parts + 1], text = text:sub(1, at - 1), text:sub(at + 1)
        end
        parts[#parts + 1] = text
        return unpack(parts)
    end
    env.JoinChannelByName = function() end
    env.UIParent, env.InCombatLockdown = {}, function() return false end
    local worldClick
    env.WorldFrame = { HookScript = function(_, name, handler) if name == "OnMouseDown" then worldClick = handler end end }
    env.tinsert, env.tremove = table.insert, table.remove
    env.C_Timer = { NewTicker = function(_, callback) ticker = callback end,
        After = function(_, callback) callback() end }
    env.NUM_CHAT_WINDOWS = 1
    env.ChatFrame1 = {}
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        GetChannelRosterInfo = function(index, member)
            assert(index == 3, "Roster uses display index, not chat channel number")
            return roster[member]
        end,
        SendAddonMessage = function(prefix, message, distribution, target)
            if client == "tbc" then
                assert(prefix == "GF1" and distribution == "WHISPER" and (target == "Bob-Realm" or target == "Carl-Realm"))
                whispers[#whispers + 1] = message
                return 0
            end
            assert(prefix == "GF1" and distribution == "CHANNEL" and target == 5)
            sent[#sent + 1] = message
            return 0
        end,
    }
    env.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:SetScript(name, handler) self.handler = handler; self.scripts = self.scripts or {}; self.scripts[name] = handler end
        function frame:EnableKeyboard() end
        function frame:SetPropagateKeyboardInput() end
        frames[#frames + 1] = frame
        return frame
    end
    local registerFilter = function(event, callback) filters[event] = callback end
    if client == "forever" then
        env.ChatFrameUtil = { AddMessageEventFilter = registerFilter }
        env.ChatFrame1.RemoveChannel = function(_, channel) removedChannel = channel end
    else
        env.ChatFrame_AddMessageEventFilter = registerFilter
        env.ChatFrame_RemoveChannel = function(_, channel) removedChannel = channel end
        env.SendChatMessage = function(message, distribution, language, target)
            if not hardwareInput then
                blockedCalls = blockedCalls + 1
                error("Protected channel send outside player input")
            end
            if distribution == "GUILD" then return end
            assert(distribution == "CHANNEL" and language == nil and target == 5)
            assert(message:sub(1, 4) == "GF1#" and #message <= 254)
            sent[#sent + 1] = message
        end
    end
    env.hooksecurefunc = function(target, key, callback)
        if type(target) == "string" then callback, key, target = key, target, env end
        local original = assert(target[key])
        target[key] = function(...)
            local result = original(...)
            callback(...)
            return result
        end
    end
    local chunk = assert(compile(source))
    setfenv(chunk, env)
    chunk()
    assert(env.SLASH_THREECROWNSGUILD1 == "/tcg" and env.SLASH_THREECROWNSGUILD2 == "/tc", client)
    assert(type(env.SlashCmdList.THREECROWNSGUILD) == "function", client)
    assert(filters.CHAT_MSG_CHANNEL and filters.CHAT_MSG_CHANNEL_NOTICE, client)
    local frame = frames[#frames]
    assert(frame.events.PLAYER_LOGIN and frame.events.CHAT_MSG_GUILD, client)
    frame.handler(frame, "PLAYER_LOGIN")
    env.SlashCmdList.THREECROWNSGUILD("sync off")
    assert(env.GuildFriendsDB.sync == false, client)
    env.SlashCmdList.THREECROWNSGUILD("sync on")
    assert(env.GuildFriendsDB.sync == true, client)
    env.SlashCmdList.THREECROWNSGUILD("status")
    assert(#output == 3 and output[3]:find("guildTag="), client)
    frame.handler(frame, "GUILD_ROSTER_UPDATE")
    time = 20
    ticker()
    assert(removedChannel == "TestChannel", client)
    channelID = 5
    hardwareInput = true
    env.SlashCmdList.THREECROWNSGUILD("Hello")
    hardwareInput = false
    local initialSent = #sent
    assert(initialSent == 1 and #env.GuildFriendsDB.history == 1, client)
    if client == "tbc" then
        assert(#whispers == 0 and selected == 1, "Chat input must not announce presence")
        local function upvalue(callback, wanted)
            for index = 1, 100 do
                local name, value = debug.getupvalue(callback, index)
                if name == wanted then return value end
                if not name then break end
            end
            error("Missing upvalue " .. wanted)
        end
        local peers = upvalue(upvalue(frame.handler, "onAddonMsg"), "peers")
        local function presence(sender, message)
            frame.handler(frame, "CHAT_MSG_ADDON", "GF1", message or "P#G1#70;MAGE;Test Zone", "WHISPER", sender)
        end
        presence("Stranger-Realm", "P#NotOurs#70;MAGE;Test Zone")
        presence("Bob-Realm", "P#Unknown#70;MAGE;Test Zone")
        assert(not peers.Stranger and not peers.Bob, "Presence accepted outside configured channel/guilds")
        presence("Bob-Realm")
        assert(peers.Bob.level == 70 and peers.Bob.seen == time, "Silent channel member was not discovered")
        assert(#whispers == 1 and whispers[1]:find("^R#G1#"), "New member was not answered directly")
        assert(selected == 1, "Player's channel selection was not restored")
        presence("Bob-Realm")
        assert(#whispers == 1, "A known member triggered another reply")
        time = time + 21
        presence("Bob-Realm", "Q#G1#")
        assert(#whispers == 2 and whispers[2]:find("^R#G1#"), "Who-request was not answered to the requester only")
        presence("Bob-Realm", "C#G1#MAGE;Whisper chat")
        assert(#env.GuildFriendsDB.history == 1, "Whisper transport accepted chat")
        local function receive(channel, text)
            frame.handler(frame, "CHAT_MSG_CHANNEL", text, "Bob-Realm", nil, nil, nil, nil, nil, nil, channel)
        end
        receive("OtherChannel", "GF1#C#G2#MAGE;Wrong channel")
        receive("TestChannel", "Not an addon message")
        assert(#env.GuildFriendsDB.history == 1)
        receive("TestChannel", "GF1#C#G2#MAGE;Reply")
        assert(#env.GuildFriendsDB.history == 2 and env.GuildFriendsDB.history[2].msg == "Reply")
        assert(#sent == initialSent, "Channel input was sent back out")
        time = 80
        ticker()
        frame.handler(frame, "CHAT_MSG_GUILD", "Guild hello", "Anna", nil, nil, nil, nil, nil, nil, nil, nil, 1, "own-guid")
        assert(#sent == initialSent and blockedCalls == 0, "Timer or guild event attempted a protected send")
        assert(#whispers == 4 and whispers[3]:find("^Q#G1#") and whispers[4]:find("^P#G1#"), "Idle heartbeat was not sent")
        for now = 160, 880, 80 do
            time = now
            presence("Bob-Realm")
            ticker()
        end
        assert(peers.Bob and peers.Bob.seen == 880 and #whispers > 3, "Silent member expired after ten minutes")
        selected = 1
        env.ChannelFrame = { IsShown = function() return true end }
        time = 1100
        time = 1200
        ticker()
        assert(selected == 1, "Presence changed the open channel window")
        env.ChannelFrame = nil
        roster = { "Anna-Realm" }
        time = 1600
        ticker()
        assert(not peers.Bob, "Offline member did not expire")
        local beforeEmpty = #whispers
        time = 1900
        ticker()
        assert(#whispers == beforeEmpty, "Presence sent to a player who left the channel")
        assert(upvalue(upvalue(frame.handler, "onAddonMsg"), "lastAnnounce") == 1900,
            "Presence kept retrying when alone in the channel")
        roster = { "Anna-Realm", "Bob-Realm", "Carl-Realm" }
        presence("Carl-Realm") -- the channel roster copy is incomplete: it must not decide who is heard
        assert(peers.Carl and peers.Carl.tag == "G1", "Member missing from the roster copy was dropped")
        roster = { "Anna-Realm", "Bob-Realm" }
        hardwareInput = true
        env.SendChatMessage("Guild hello", "GUILD")
        hardwareInput = false
        assert(#env.GuildFriendsDB.history == 3 and env.GuildFriendsDB.history[3].msg == "Guild hello")
        local afterGuild = #sent
        env.SlashCmdList.THREECROWNSGUILD("sync off")
        hardwareInput = true
        env.SendChatMessage("Private", "GUILD")
        hardwareInput = false
        assert(#sent == afterGuild and blockedCalls == 0, "Sync off forwarded a guild message")
        frame.handler(frame, "PLAYER_LOGOUT")
        assert(blockedCalls == 0, "Logout attempted a protected send")
    end

    if client == "tbc" then
        -- an active player announces with ONE channel message on a key press or click
        local keyFrame
        for _, candidate in ipairs(frames) do
            if candidate.scripts and candidate.scripts.OnKeyDown then keyFrame = candidate end
        end
        assert(keyFrame and worldClick, "Input hooks were not installed")
        local channelBefore, whispersBefore = #sent, #whispers
        time = time + 400
        hardwareInput = true
        keyFrame.scripts.OnKeyDown(keyFrame, "W")
        hardwareInput = false
        assert(#sent == channelBefore + 1 and sent[#sent]:find("^GF1#P#G1#"), "Key press did not announce on the channel")
        assert(#whispers == whispersBefore, "Key press announced by whisper")
        hardwareInput = true
        keyFrame.scripts.OnKeyDown(keyFrame, "W") -- not due again yet
        worldClick()
        hardwareInput = false
        assert(#sent == channelBefore + 1, "Input announced twice within the heartbeat")
    end

    -- LFM: a centered notice for incoming requests, role detection on send
    local texts = {}
    local function widget()
        return setmetatable({}, { __index = function(_, key)
            if not key:match("^%u") or key == "TitleText" then return nil end -- methods are capitalized, fields are not
            return function(self, value)
                if key == "SetText" then texts[#texts + 1] = value end
                return self
            end
        end })
    end
    env.CreateFrame = widget
    env.UISpecialFrames, env.STANDARD_TEXT_FONT, env.UIFrameFadeOut = {}, "font", function() end
    env.UnitExists, env.IsInInstance, env.PlaySound = function() return true end, function() return false end, function() end
    local function lfmIn(body)
        if client == "forever" then
            frame.handler(frame, "CHAT_MSG_ADDON", "GF1", "L#G2#" .. body, "CHANNEL", "Bob-Realm")
        else
            frame.handler(frame, "CHAT_MSG_CHANNEL", "GF1#L#G2#" .. body, "Bob-Realm", nil, nil, nil, nil, nil, nil, "TestChannel")
        end
    end
    time = 5000
    lfmIn("1,0,2;Deadmines;Bob,Cid")
    local notice = texts[#texts]
    assert(notice and notice:find("Bob, Cid", 1, true) and notice:find("are looking for", 1, true)
        and notice:find("Tank + 2 DPS", 1, true) and notice:find("Deadmines", 1, true)
        and not notice:find("/w", 1, true) and notice:find("^|cffaaaaaa%[G2%]"), client .. ": LFM notice missing or wrong")
    local count = #texts
    lfmIn("0,1,0;Spam;Bob")
    assert(#texts == count, client .. ": LFM spam from one sender was shown")
    time = time + 11
    lfmIn("0,1,0;|cffff0000Evil|r;|HBob")
    assert(#texts == count + 1 and not texts[#texts]:find("|cffff0000", 1, true), client .. ": LFM text not sanitized")
    time = time + 11
    env.SlashCmdList.THREECROWNSGUILD("lfm off")
    lfmIn("1,0,0;Hidden;Bob")
    assert(#texts == count + 1, client .. ": LFM shown while muted")
    env.SlashCmdList.THREECROWNSGUILD("lfm on")
    env.SlashCmdList.THREECROWNSGUILD("lfm") -- dialog opens without errors
    local before = #sent
    hardwareInput = true
    env.SlashCmdList.THREECROWNSGUILD("lfm Karazhan")
    hardwareInput = false
    assert(#sent == before + 1 and sent[#sent]:find("L#G1#1,1,2;Karazhan;Anna", 1, true), client .. ": LFM not sent with detected roles")
    assert(texts[#texts]:find("Karazhan", 1, true), client .. ": sender got no confirmation notice")
    hardwareInput = true
    env.SlashCmdList.THREECROWNSGUILD("lfm Again")
    hardwareInput = false
    assert(#sent == before + 1, client .. ": LFM sent twice within 30 seconds")
end
print("Full addon startup and slash command checks passed (Forever + TBC).")
