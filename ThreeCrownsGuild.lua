local interfaceVersion = select(4, GetBuildInfo())
-- Allow TBC in this local test build; published releases remain Forever-only.
local isForever = interfaceVersion >= 16000 and interfaceVersion < 17000
local isTBC = interfaceVersion >= 20000 and interfaceVersion < 21000
if not (isForever or isTBC) then return end

-- ThreeCrownsGuild: online roster + shared chat (/tcg) across several guilds on one realm.
-- Config is read from Guild Info (like GreenWall), identical in every guild:
--   TCGc:channel:password
--   TCGp:Guild Name:TAG        (one line per guild, including your own)
-- Forever uses addon messages; the local TBC test uses GF1-prefixed chat in the hidden channel.
-- Message: <kind>#<tag>#<body>
--   C chat (CLASS;text) | P presence (level;CLASS;zone) | Q "who is online?" | X logout
local PFX, HEARTBEAT, EXPIRE, JOIN_DELAY, HISTORY_MAX, ROW_H = "GF1", 240, 600, 15, 200, 16
local GREEN = "|cff40ff40"

local secret = issecretvalue or function() return false end
local db
local cfg = { guilds = {}, byName = {} }
local peers = {} -- ["Name"] = { tag, level, class, zone, seen }
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local SendChannelChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local joinAt, lastAnnounce, lastQuery, replyPending = 0, 0, 0, false
local warmup, lastResult, rx = 3, "-", {} -- warmup: a few quick announces after joining (first ones can be dropped)
local stats = { sent = 0, recv = 0, noConfig = 0 } -- TBC whisper transport, shown by /tcg status
local f, chat, pool, content -- UI, created on first open

local function parseConfig(text)
    local c = { guilds = {}, byName = {} }
    for line in (text or ""):gmatch("[^\r\n]+") do
        line = (strtrim(line):gsub("^MG", "TCG"):gsub("^GF", "TCG")) -- old MG/GF prefixes still accepted
        local ch, pw = line:match("^TCGc:([^:]+):?(.*)$")
        if ch then c.channel, c.password = ch, pw end
        local name, tag = line:match("^TCGp:(.+):([^:]+)$")
        if name then
            tinsert(c.guilds, { name = name, tag = tag })
            c.byName[name:lower()] = tag
        end
    end
    return c
end

local function myTag()
    local g = GetGuildInfo("player")
    return g and cfg.byName[g:lower()]
end

local function chanId()
    if not cfg.channel then return nil end
    local id = GetChannelName(cfg.channel)
    if id and id > 0 then return id end
    return nil
end

-- TBC: members of the hidden channel. The client only loads a channel's roster while it is the
-- selected one in the channel window, so we select it briefly, copy the roster and put the
-- player's own selection back. Everything else reads the copy.
local rosterCache, rosterAt, selectionBefore = {}, -math.huge, nil
local function channelWindowOpen() return _G.ChannelFrame and ChannelFrame:IsShown() end

local function ourIndex()
    if not chanId() then return nil end
    for index = 1, GetNumDisplayChannels() do
        local name, header, _, number = GetChannelDisplayInfo(index)
        if not header and number == chanId() and name:lower() == cfg.channel:lower() then return index end
    end
    return nil
end

local function readMembers(index)
    local members = {}
    for i = 1, select(5, GetChannelDisplayInfo(index)) or 0 do
        local member = C_ChatInfo.GetChannelRosterInfo(index, i)
        if member and not secret(member) then members[Ambiguate(member, "none")] = member end
    end
    return members
end

local function finishRoster()
    local index = ourIndex()
    if index then
        local members = readMembers(index)
        if next(members) then rosterCache = members end
    end
    if selectionBefore then
        if not channelWindowOpen() then SetSelectedDisplayChannel(selectionBefore) end
        selectionBefore = nil
    end
end

local function refreshRoster()
    local index = ourIndex()
    if not index or not C_ChatInfo.GetChannelRosterInfo or selectionBefore then return end
    local selected = GetSelectedDisplayChannel()
    if selected == index then
        finishRoster() -- already loaded, e.g. the player has our channel open
    elseif not channelWindowOpen() then
        selectionBefore = selected
        SetSelectedDisplayChannel(index)
        C_Timer.After(2, finishRoster) -- the server answers a moment after selecting
    end
end

local function channelMembers()
    if not chanId() then return {} end
    if GetTime() - rosterAt > 60 then rosterAt = GetTime(); refreshRoster() end
    return rosterCache
end

local function whisper(target, kind, body)
    local tag = myTag()
    if not tag then return end
    local ok, res = pcall(SendAddon, PFX, (("%s#%s#%s"):format(kind, tag, body or "")):sub(1, 250), "WHISPER", target)
    lastResult = kind .. "=" .. tostring(ok and res)
    stats.sent = stats.sent + 1
    if not ok then print(GREEN .. "[TCG]|r send failed: " .. tostring(res)) end
end

local sendingFromInput = false
local function send(kind, body)
    -- TBC channel chat requires player input; timers and incoming events cannot send it.
    local presence = kind == "P" or kind == "Q" or kind == "X"
    if isTBC and not presence and not sendingFromInput then return false end
    local id, tag = chanId(), myTag()
    if not (id and tag) then return false end
    local payload = (("%s#%s#%s"):format(kind, tag, body or "")):sub(1, 250)
    -- Idle: whisper each channel member. During player input: one channel message reaches everybody.
    if isTBC and presence and not sendingFromInput then
        local channel, queued, members = cfg.channel, 0, {}
        for name, target in pairs(channelMembers()) do members[name] = target end
        for name, p in pairs(peers) do members[name] = members[name] or p.from or name end
        for name, target in pairs(members) do
            if name ~= UnitName("player") then
                C_Timer.After(queued * 0.2, function()
                    if cfg.channel == channel and chanId() then whisper(target, kind, body) end
                end)
                queued = queued + 1
            end
        end
        -- an empty roster means "not loaded yet" (retry soon); only us in it means nobody to tell
        return queued > 0 or next(members) ~= nil
    end
    local ok, res
    if isTBC then
        ok, res = pcall(SendChannelChat, PFX .. "#" .. payload, "CHANNEL", nil, id)
    else
        ok, res = pcall(SendAddon, PFX, payload, "CHANNEL", id)
    end
    lastResult = kind .. "=" .. tostring(ok and res) -- 0/true/nil = ok; other numbers = Enum.SendAddonMessageResult
    if not ok then print(GREEN .. "[TCG]|r send failed: " .. tostring(res)) end
    return ok and (res == nil or res == true or res == 0)
end

local function presenceBody()
    local _, class = UnitClass("player")
    return ("%d;%s;%s"):format(UnitLevel("player"), class, GetRealZoneText() or "")
end

local function announce()
    if send("P", presenceBody()) then
        lastAnnounce = GetTime()
        warmup = math.max(0, warmup - 1)
    end
end

-- TBC: answer one player directly (kind R) instead of re-announcing to the whole channel
local lastReply = {}
local function replyTo(target)
    if lastReply[target] and GetTime() - lastReply[target] < 20 then return end
    lastReply[target] = GetTime()
    C_Timer.After(math.random() * 5, function() whisper(target, "R", presenceBody()) end)
end

local function classColor(class)
    local c = class and RAID_CLASS_COLORS[class]
    return c and ("|cff%02x%02x%02x"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255)) or ""
end

-- ---------------------------------------------------------------- roster

local f, chat, pool, content, dock -- UI (created on first open); dock = guild window we sit next to
local collapsed = {} -- guild tags whose list is folded

local function ownGuildOnline()
    local list = {}
    for i = 1, (GetNumGuildMembers()) do
        local name, _, _, level, _, zone, _, _, online, _, class = GetGuildRosterInfo(i)
        if online then tinsert(list, { name = Ambiguate(name, "none"), level = level, class = class, zone = zone or "" }) end
    end
    return list
end

local function membersOf(tag)
    local list = {}
    if tag == myTag() then
        list = ownGuildOnline()
    else
        local now = GetTime()
        for name, p in pairs(peers) do
            if p.tag == tag and now - p.seen < EXPIRE then
                tinsert(list, { name = name, level = p.level, class = p.class, zone = p.zone })
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- nicknames are local to this account; keep the real name for whispers and lookups
local refreshChat
local function nick(name)
    local firstName = name:match("^%S+") or name
    local nickname = db.nicks[name]
    if nickname then return firstName .. "(" .. nickname .. ")" end
    return db.surname and name or firstName
end

local function setNick(name, text)
    text = strtrim(text or "")
    db.nicks[name] = text ~= "" and text or nil
    ThreeCrownsGuild_Refresh()
    refreshChat()
end

local function editBoxOf(dialog) return dialog.editBox or dialog.EditBox or (dialog.GetEditBox and dialog:GetEditBox()) end
StaticPopupDialogs.THREECROWNSGUILD_NICK = {
    text = "Nickname for %s (only you see it; empty removes it):",
    button1 = ACCEPT, button2 = CANCEL, hasEditBox = 1, maxLetters = 24,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
    OnShow = function(self, who)
        local eb = editBoxOf(self)
        eb:SetText(db.nicks[who] or ""); eb:HighlightText()
    end,
    OnAccept = function(self, who) setNick(who, editBoxOf(self):GetText()) end,
    EditBoxOnEnterPressed = function(self)
        local d = self:GetParent()
        setNick(d.data, self:GetText()); d:Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
}

local menu -- right-click menu on a player: whisper / who / invite / nickname
local function rowMenu(who)
    if not menu then
        local catcher = CreateFrame("Button", nil, UIParent) -- click anywhere else closes the menu
        catcher:SetAllPoints(); catcher:SetFrameStrata("FULLSCREEN_DIALOG"); catcher:Hide()
        menu = CreateFrame("Frame", nil, UIParent)
        menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu:SetFrameLevel(catcher:GetFrameLevel() + 5)
        menu:SetSize(130, 8 + 4 * 18); menu:Hide()
        menu.bg = menu:CreateTexture(nil, "BACKGROUND"); menu.bg:SetAllPoints(); menu.bg:SetColorTexture(0, 0, 0, 0.92)
        catcher:SetScript("OnClick", function() menu:Hide() end)
        menu:SetScript("OnShow", function() catcher:Show() end)
        menu:SetScript("OnHide", function() catcher:Hide() end)
        local actions = {
            { "Whisper", function(w) SetItemRef("player:" .. w, "|Hplayer:" .. w .. "|h[" .. w .. "]|h", "LeftButton") end },
            { "Who", function(w) (C_FriendList and C_FriendList.SendWho or SendWho)("n-" .. w) end },
            { "Invite", function(w) (C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit)(w) end },
            { "Set nickname", function(w) StaticPopup_Show("THREECROWNSGUILD_NICK", w, nil, w) end },
        }
        for i, act in ipairs(actions) do
            local b = CreateFrame("Button", nil, menu)
            b:SetSize(122, 18); b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 18)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            b.text = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 4, 0); b.text:SetText(act[1])
            b:SetScript("OnClick", function() menu:Hide(); act[2](menu.who) end)
        end
    end
    menu.who = who
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    menu:Show()
end

local function getRow(i)
    local r = pool[i]
    if r then return r end
    r = CreateFrame("Button", nil, content)
    r:SetSize(148, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    r.sep = r:CreateTexture(nil, "ARTWORK")
    r.sep:SetColorTexture(1, 1, 1, 0.25); r.sep:SetHeight(1)
    r.sep:SetPoint("TOPLEFT", 0, 0); r.sep:SetPoint("TOPRIGHT", 0, 0)
    r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r.name:SetPoint("LEFT", 4, 0); r.name:SetWidth(104); r.name:SetJustifyH("LEFT"); r.name:SetWordWrap(false)
    r.lvl = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r.lvl:SetPoint("RIGHT", -4, 0); r.lvl:SetWidth(34); r.lvl:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function(self, button)
        if self.tag then -- guild header: fold / unfold
            collapsed[self.tag] = not collapsed[self.tag]
            ThreeCrownsGuild_Refresh()
        elseif button == "RightButton" then
            rowMenu(self.who)
        else
            SetItemRef("player:" .. self.who, "|Hplayer:" .. self.who .. "|h[" .. self.who .. "]|h", "LeftButton")
        end
    end)
    pool[i] = r
    return r
end

function ThreeCrownsGuild_Refresh()
    if not (f and f:IsShown()) then return end
    f.note:SetShown(not cfg.channel)
    local n = 0
    for i, g in ipairs(cfg.guilds) do
        local list = membersOf(g.tag)
        n = n + 1
        local r = getRow(n)
        r.tag, r.who = g.tag, nil
        r.sep:SetShown(i > 1)
        r.name:SetText(("|cffffd100%s|r (%d online)"):format(g.tag, #list))
        r.lvl:SetText("")
        r:Show()
        if not collapsed[g.tag] then
            for _, m in ipairs(list) do
                n = n + 1
                r = getRow(n)
                r.tag, r.who = nil, m.name
                r.sep:Hide()
                r.name:SetText(classColor(m.class) .. nick(m.name))
                r.lvl:SetText(m.level > 0 and m.level or "")
                r:Show()
            end
        end
    end
    for i = n + 1, #pool do pool[i]:Hide() end
    content:SetHeight(math.max(1, n * ROW_H))
end

-- ---------------------------------------------------------------- chat

local function render(rec)
    return ("%s%s|Hplayer:%s|h%s%s%s|h: %s"):format(
        GREEN, db.tag and ("[" .. rec.tag .. "] ") or "", rec.name, classColor(rec.class), nick(rec.name), GREEN, rec.msg)
end

refreshChat = function()
    if not chat then return end
    chat:Clear()
    for _, rec in ipairs(db.history) do chat:AddMessage(render(rec)) end
    ThreeCrownsGuild_SyncBar()
end

local function addChat(tag, name, class, msg, guildMessage)
    local rec = { tag = tag, name = name, class = class, msg = msg }
    tinsert(db.history, rec)
    while #db.history > HISTORY_MAX do tremove(db.history, 1) end
    if chat then chat:AddMessage(render(rec)); ThreeCrownsGuild_SyncBar() end
    if db.echo and not (guildMessage and tag == myTag()) then DEFAULT_CHAT_FRAME:AddMessage(render(rec)) end
end

local function sendChat(msg)
    msg = strtrim(msg or "")
    if msg == "" then return end
    local _, class = UnitClass("player")
    if send("C", class .. ";" .. msg) then
        addChat(myTag(), UnitName("player"), class, msg) -- addon messages don't echo to the sender
    else
        print(("%s[TCG]|r not sent: channel=%s guildTag=%s lastSend=%s"):format(GREEN, tostring(chanId()), tostring(myTag()), lastResult))
    end
end

local function chatInput(callback, ...)
    local previous = sendingFromInput
    sendingFromInput = true
    local ok, err = pcall(callback, ...)
    sendingFromInput = previous
    if not ok then error(err) end
end

-- ---------------------------------------------------------------- LFM
-- One button tells every guild which roles the current party is still missing.
-- Kind L, body: <tank>,<healer>,<dps>;<dungeon>;<name,name,...>
local ROLE = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }
local lastLFM, lastLFMFrom = -math.huge, {}
local toast, lfmDialog

local function clean(text) return (tostring(text or ""):gsub("[|;#]", "")) end

-- Role assigned in the group if the client has roles, otherwise a guess (the dialog lets the player correct it).
local function roleOf(unit)
    local assigned = UnitGroupRolesAssigned and ROLE[UnitGroupRolesAssigned(unit)]
    if assigned then return assigned end
    local _, class = UnitClass(unit)
    return class == "PRIEST" and "healer" or "dps"
end

-- Returns the missing tank/healer/dps for a 5-man party, and the member names.
local function missingRoles()
    local have, names = { tank = 0, healer = 0, dps = 0 }, {}
    local units = { "player" }
    for i = 1, GetNumSubgroupMembers and GetNumSubgroupMembers() or 0 do units[#units + 1] = "party" .. i end
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local role = roleOf(unit)
            have[role] = have[role] + 1
            names[#names + 1] = UnitName(unit)
        end
    end
    return math.max(0, 1 - have.tank), math.max(0, 1 - have.healer), math.max(0, 3 - have.dps), names
end

local function needsText(tank, healer, dps)
    local parts = {}
    if tank > 0 then parts[#parts + 1] = "Tank" end
    if healer > 0 then parts[#parts + 1] = "Healer" end
    if dps > 0 then parts[#parts + 1] = dps .. " DPS" end
    return table.concat(parts, " + ")
end

local function showToast(text)
    if not toast then
        toast = CreateFrame("Frame", nil, UIParent)
        toast:SetSize(900, 100); toast:SetPoint("CENTER", 0, 150)
        toast:SetFrameStrata("FULLSCREEN_DIALOG"); toast:EnableMouse(false)
        toast.text = toast:CreateFontString(nil, "OVERLAY")
        toast.text:SetFont(STANDARD_TEXT_FONT, 26, "OUTLINE")
        toast.text:SetAllPoints(); toast.text:SetJustifyH("CENTER")
    end
    toast.text:SetText(text)
    toast:SetAlpha(1); toast:Show()
    toast.token = (toast.token or 0) + 1
    local token = toast.token
    C_Timer.After(8, function() if toast.token == token then UIFrameFadeOut(toast, 1.5, 1, 0) end end)
end

local function announceLFM(tag, name, tank, healer, dps, dungeon, names)
    local who = names ~= "" and names or name
    local needs = needsText(tank, healer, dps)
    showToast(("|cffaaaaaa[%s]|r |cff40ff40%s|r %s looking for |cffffd100%s|r\n%s"):format(
        tag, who, who:find(",") and "are" or "is", needs, dungeon))
    DEFAULT_CHAT_FRAME:AddMessage(("%s[LFM] [%s] |Hplayer:%s|h[%s]|h: %s for %s (%s)"):format(
        GREEN, tag, name, name, needs, dungeon, who))
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
end

local function sendLFM(dungeon, tank, healer, dps)
    dungeon = strtrim(clean(dungeon))
    if dungeon == "" then print(GREEN .. "[TCG]|r LFM: enter a dungeon name."); return false end
    if tank + healer + dps == 0 then print(GREEN .. "[TCG]|r LFM: the party is already full."); return false end
    if GetTime() - lastLFM < 30 then print(GREEN .. "[TCG]|r LFM: wait a little before sending again."); return false end
    local names = select(4, missingRoles())
    for i, n in ipairs(names) do names[i] = clean(n) end
    local joined = table.concat(names, ",")
    if send("L", ("%d,%d,%d;%s;%s"):format(tank, healer, dps, dungeon, joined)) then
        lastLFM = GetTime()
        announceLFM(myTag(), UnitName("player"), tank, healer, dps, dungeon, joined) -- we get no echo
        return true
    end
    print(("%s[TCG]|r LFM not sent: channel=%s guildTag=%s"):format(GREEN, tostring(chanId()), tostring(myTag())))
    return false
end

local function openLFM()
    if not lfmDialog then
        local d = CreateFrame("Frame", "ThreeCrownsGuildLFM", UIParent, "BasicFrameTemplateWithInset")
        lfmDialog = d
        d:SetSize(290, 170); d:SetPoint("CENTER", 0, 80); d:SetFrameStrata("DIALOG")
        d:SetMovable(true); d:EnableMouse(true); d:SetClampedToScreen(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving); d:SetScript("OnDragStop", d.StopMovingOrSizing)
        if d.TitleText then d.TitleText:SetText("Looking for more") end
        tinsert(UISpecialFrames, "ThreeCrownsGuildLFM")

        local label = d:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        label:SetPoint("TOPLEFT", 16, -34); label:SetText("Dungeon")
        d.dungeon = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        d.dungeon:SetPoint("TOPLEFT", 22, -50); d.dungeon:SetSize(246, 24)
        d.dungeon:SetAutoFocus(false); d.dungeon:SetMaxBytes(60)
        d.dungeon:SetScript("OnEscapePressed", function(e) e:ClearFocus() end)

        -- click a role to cycle how many of it you still need
        local function need(name, max, x)
            local b = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
            b:SetSize(82, 24); b:SetPoint("TOPLEFT", x, -86)
            function b:Set(n) self.n = n; self:SetText(("%s: %d"):format(name, n)) end
            b:SetScript("OnClick", function(self) self:Set((self.n + 1) % (max + 1)) end)
            return b
        end
        d.tank, d.healer, d.dps = need("Tank", 1, 16), need("Healer", 1, 102), need("DPS", 3, 188)

        local sendButton = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
        sendButton:SetSize(180, 26); sendButton:SetPoint("BOTTOM", 0, 14); sendButton:SetText("Send to all guilds")
        sendButton:SetScript("OnClick", function()
            local ok = false
            chatInput(function() ok = sendLFM(d.dungeon:GetText(), d.tank.n, d.healer.n, d.dps.n) end)
            if ok then d:Hide() end
        end)
    end
    local tank, healer, dps = missingRoles()
    lfmDialog.tank:Set(tank); lfmDialog.healer:Set(healer); lfmDialog.dps:Set(dps)
    if lfmDialog.dungeon:GetText() == "" and IsInInstance() then lfmDialog.dungeon:SetText(GetRealZoneText() or "") end
    lfmDialog:Show()
end

local function onLFM(tag, name, body)
    if db.lfm == false or GetTime() - (lastLFMFrom[name] or -math.huge) < 10 then return end
    lastLFMFrom[name] = GetTime()
    local needs, dungeon, names = strsplit(";", body or "", 3)
    local tank, healer, dps = strsplit(",", needs or "", 3)
    tank, healer, dps = tonumber(tank) or 0, tonumber(healer) or 0, tonumber(dps) or 0
    tank, healer, dps = math.min(math.max(tank, 0), 1), math.min(math.max(healer, 0), 1), math.min(math.max(dps, 0), 3)
    if tank + healer + dps == 0 then return end
    announceLFM(clean(tag), name, tank, healer, dps, clean(dungeon), (clean(names):gsub(",", ", ")))
end

local function syncGuildChat(msg, guid)
    if not db or not db.sync or secret(msg) or secret(guid) or guid ~= UnitGUID("player") then return end
    local tag = myTag()
    if not tag or msg == "" then return end
    local _, class = UnitClass("player")
    local payload = class .. ";" .. #msg .. ";" .. msg
    local size = 250 - #("G#" .. tag .. "#")
    if size <= #(class .. ";" .. #msg .. ";") or #msg > 4096 then return end
    -- Split by bytes, then reassemble before display to preserve UTF-8 and links.
    for offset = 1, #payload, size do
        if not send(offset == 1 and "G" or "g", payload:sub(offset, offset + size - 1)) then
            print(GREEN .. "[TCG]|r Guild message could not be synced. Check /tc status.")
            return
        end
    end
    addChat(tag, UnitName("player"), class, msg, true)
end

if isTBC then
    local function onChatSent(msg, chatType)
        if not secret(chatType) and chatType == "GUILD" and not secret(msg) then
            chatInput(syncGuildChat, msg, UnitGUID("player"))
        end
    end
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        hooksecurefunc(C_ChatInfo, "SendChatMessage", onChatSent)
    else
        hooksecurefunc("SendChatMessage", onChatSent)
    end
end

local guildParts = {}
local function onAddonMsg(text, sender)
    local kind, tag, body = strsplit("#", text, 3)
    if not tag then return end
    local name = Ambiguate(sender, "none")
    rx[kind] = (rx[kind] or 0) + 1
    if kind == "G" or kind == "g" then
        if name == UnitName("player") then return end
        if kind == "G" then
            local class, length, msg = strsplit(";", body or "", 3)
            length = tonumber(length)
            guildParts[sender] = nil
            if not class or not msg or not length or length < 1 or length > 4096 or length % 1 ~= 0 then return end
            guildParts[sender] = { tag = tag, class = class, length = length, msg = msg, time = GetTime() }
        else
            local part = guildParts[sender]
            if not part or part.tag ~= tag or GetTime() - part.time > 10 then
                guildParts[sender] = nil
                return
            end
            part.msg = part.msg .. (body or "")
        end
        local part = guildParts[sender]
        if #part.msg >= part.length then
            guildParts[sender] = nil
            if #part.msg == part.length then addChat(tag, name, part.class, part.msg, true) end
        end
        return
    elseif kind == "L" then
        if name ~= UnitName("player") then onLFM(tag, name, body) end
        return
    elseif kind == "C" then
        if name == UnitName("player") then return end -- already shown locally on send
        local class, msg = strsplit(";", body or "", 2)
        local p = peers[name] or { level = 0, zone = "" }
        p.tag, p.class, p.seen, p.from = tag, class, GetTime(), sender
        peers[name] = p
        addChat(tag, name, class, msg or "")
    elseif kind == "P" or kind == "R" then
        local lvl, class, zone = strsplit(";", body or "", 3)
        local known = peers[name] ~= nil
        peers[name] = { tag = tag, level = tonumber(lvl) or 0, class = class, zone = zone or "", seen = GetTime(), from = sender }
        if isTBC and kind == "P" and not known and name ~= UnitName("player") then replyTo(sender) end
    elseif kind == "X" then
        peers[name] = nil
    elseif kind == "Q" and isTBC and name ~= UnitName("player") then
        replyTo(sender)
    elseif kind == "Q" and name ~= UnitName("player") and not replyPending then
        -- jitter so everyone doesn't answer at once; skip if we just announced
        replyPending = true
        C_Timer.After(math.random() * 15, function()
            replyPending = false
            if GetTime() - lastAnnounce > 20 then announce() end
        end)
    end
    if kind ~= "C" then ThreeCrownsGuild_Refresh() end
end

-- ---------------------------------------------------------------- window

local function requestWho()
    if GetTime() - lastQuery > 60 and send("Q") then lastQuery = GetTime() end
end

local function place()
    f:ClearAllPoints()
    if dock and dock:IsVisible() then
        -- like Olympus: right of the guild window, past its side tabs (32 wide) and the usual
        -- 32 px gap between panels; the old Social window just overlaps its border; same height
        local tab = dock.ChatTab
        local tabs = tab and tab.IsShown and tab:IsShown()
        f:SetPoint("TOPLEFT", dock, "TOPRIGHT", dock == _G.FriendsFrame and -2 or ((tabs and 32 or 0) + 32), 0)
        f:SetHeight(dock:GetHeight() > 200 and dock:GetHeight() or 440)
    else
        dock = nil
        f:SetHeight(440)
        f:SetPoint("CENTER")
    end
end

local function inset(parent) -- dark framed panel, like the Communities window's
    local ok, p = pcall(CreateFrame, "Frame", nil, parent, "BackdropTemplate")
    if not ok then p = CreateFrame("Frame", nil, parent) end
    if p.SetBackdrop then
        p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        p:SetBackdropColor(0, 0, 0, 0.55); p:SetBackdropBorderColor(0.7, 0.7, 0.7, 1)
    end
    return p
end

local function createUI()
    f = CreateFrame("Frame", "ThreeCrownsGuildFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(560, 440)
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) dock = nil; self:StartMoving() end)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText("ThreeCrownsGuild") end
    tinsert(UISpecialFrames, "ThreeCrownsGuildFrame")

    local lfmButton = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lfmButton:SetSize(54, 20); lfmButton:SetPoint("TOPLEFT", 8, -4); lfmButton:SetText("LFM")
    lfmButton:SetScript("OnClick", openLFM)

    -- left: framed chat with a scrollbar, input below
    local cp = inset(f)
    cp:SetPoint("TOPLEFT", 10, -30); cp:SetPoint("BOTTOMLEFT", 10, 40); cp:SetWidth(348)
    chat = CreateFrame("ScrollingMessageFrame", nil, cp)
    chat:SetPoint("TOPLEFT", 8, -8); chat:SetPoint("BOTTOMRIGHT", -28, 8)
    chat:SetFontObject(ChatFontNormal); chat:SetJustifyH("LEFT")
    chat:SetFading(false); chat:SetMaxLines(500); chat:SetHyperlinksEnabled(true)
    chat:EnableMouseWheel(true)
    local bar = CreateFrame("Slider", nil, cp, "UIPanelScrollBarTemplate")
    bar:SetPoint("TOPRIGHT", -6, -24); bar:SetPoint("BOTTOMRIGHT", -6, 24)
    bar:SetValueStep(1); bar.scrollStep = 3
    local syncing
    function ThreeCrownsGuild_SyncBar() -- value 0 = oldest line at the top, max = newest at the bottom
        local max = chat.GetMaxScrollRange and chat:GetMaxScrollRange() or chat:GetNumMessages()
        bar.max = max
        syncing = true
        bar:SetMinMaxValues(0, max); bar:SetValue(max - chat:GetScrollOffset())
        syncing = false
    end
    bar:SetScript("OnValueChanged", function(_, v)
        if not syncing then chat:SetScrollOffset(math.floor((bar.max or 0) - v + 0.5)) end
    end)
    chat:SetScript("OnMouseWheel", function(s, d)
        if d > 0 then s:ScrollUp() else s:ScrollDown() end
        ThreeCrownsGuild_SyncBar()
    end)
    chat:SetScript("OnHyperlinkClick", function(_, link, text, button) SetItemRef(link, text, button) end)
    for _, rec in ipairs(db.history) do chat:AddMessage(render(rec)) end
    ThreeCrownsGuild_SyncBar()
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetPoint("BOTTOMLEFT", 18, 12); eb:SetSize(334, 24)
    eb:SetAutoFocus(false); eb:SetMaxBytes(220)
    eb:SetScript("OnEnterPressed", function(s) chatInput(sendChat, s:GetText()); s:SetText("") end)
    eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)

    -- right: framed list of every guild with its online players, with its own scrollbar
    local rp = inset(f)
    rp:SetPoint("TOPLEFT", 366, -30); rp:SetPoint("BOTTOMRIGHT", -10, 12)
    local sf = CreateFrame("ScrollFrame", nil, rp, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 6, -6); sf:SetPoint("BOTTOMRIGHT", -28, 6)
    content = CreateFrame("Frame", nil, sf)
    content:SetSize(148, 1); sf:SetScrollChild(content)
    pool = {}
    f.note = rp:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.note:SetPoint("TOPLEFT", 10, -10); f.note:SetWidth(140); f.note:SetJustifyH("LEFT")
    f.note:SetText("No TCGc:/TCGp: config found in Guild Info (see README).")

    f:SetScript("OnShow", function() requestWho(); ThreeCrownsGuild_Refresh() end)
    f:Hide() -- new frames start shown; open() shows it (and fires OnShow)
end

local function open(host) -- host: guild window to sit next to, nil = wherever it was
    if not f then createUI() end
    if host then dock = host end
    place()
    f:Show()
end

local function toggle(host)
    if f and f:IsShown() and (not host or dock == host) then f:Hide() else open(host) end
end

-- An icon in Blizzard's guild windows (Guild & Communities, or the old Guild tab) that opens
-- our window next to them. Only hooks and our own child button: Blizzard's frames stay untouched.
local hooked = {}
local function attach(frame, host, oldTab)
    if hooked[frame] then return end
    hooked[frame] = true
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(22, 22)
    b:SetNormalTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    if oldTab then
        b:SetPoint("TOPLEFT", host, "TOPLEFT", 62, -26)
    else -- title bar, left of minimize/close
        local anchor = frame.MaximizeMinimizeFrame or frame.CloseButton
        if anchor then b:SetPoint("RIGHT", anchor, "LEFT", 0, 0) else b:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -50, 0) end
        b:SetFrameLevel(math.max(frame:GetFrameLevel() + 10, anchor and anchor:GetFrameLevel() or 0))
    end
    b:SetScript("OnClick", function() toggle(host) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("ThreeCrownsGuild", 1, 0.82, 0)
        GameTooltip:AddLine("Online members and chat across your guilds.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    frame:HookScript("OnHide", function() if f and dock == host then f:Hide() end end)
    -- the Communities window can be resized, and its side tabs come and go: follow it
    local function follow() if f and f:IsShown() and dock == host then place() end end
    if not oldTab then frame:HookScript("OnSizeChanged", follow) end
    local tabs = frame.ChatTab
    if tabs and tabs.HookScript then tabs:HookScript("OnShow", follow); tabs:HookScript("OnHide", follow) end
end

local function scan()
    if _G.CommunitiesFrame then attach(CommunitiesFrame, CommunitiesFrame) end
    local guild, social = _G.GuildFrame, _G.FriendsFrame
    if guild then
        local inside = social and guild:GetParent() == social
        attach(guild, inside and social or guild, inside)
    end
end

-- ---------------------------------------------------------------- lifecycle

local function reloadConfig()
    local c = parseConfig(GetGuildInfoText())
    if cfg.channel and (c.channel ~= cfg.channel) and chanId() then LeaveChannelByName(cfg.channel) end
    if c.channel ~= cfg.channel then rosterCache, rosterAt = {}, -math.huge end
    cfg = c
end

local function tick()
    for sender, part in pairs(guildParts) do
        if GetTime() - part.time > 10 then guildParts[sender] = nil end
    end
    for name, p in pairs(peers) do
        if GetTime() - p.seen > EXPIRE then peers[name] = nil end
    end
    if cfg.channel and myTag() and GetTime() >= joinAt then
        if not chanId() then
            JoinChannelByName(cfg.channel, cfg.password)
            C_Timer.After(3, function() -- the channel number appears a moment after joining
                for i = 1, NUM_CHAT_WINDOWS do
                    local frame = _G["ChatFrame" .. i]
                    if frame.RemoveChannel then frame:RemoveChannel(cfg.channel)
                    else ChatFrame_RemoveChannel(frame, cfg.channel) end
                end
            end)
        elseif GetTime() - lastAnnounce >= (warmup > 0 and 20 or HEARTBEAT) then
            if lastAnnounce == 0 then requestWho() end
            announce()
        end
    end
    ThreeCrownsGuild_Refresh()
end

-- keep the transport channel out of the normal chat frames
local function hideChannel(_, _, ...)
    local base = select(9, ...)
    return cfg.channel and base and not secret(base) and base:lower() == cfg.channel:lower()
end
local AddMessageEventFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
    AddMessageEventFilter(ev, hideChannel)
end

-- TBC: any key press or mouse click is player input, so an active player announces with one
-- channel message (the transport that works for chat) instead of a whisper per channel member.
local function onPlayerInput()
    if InCombatLockdown() or GetTime() < joinAt or not (chanId() and myTag()) then return end
    if GetTime() - lastAnnounce >= (warmup > 0 and 20 or HEARTBEAT) then pcall(chatInput, announce) end
end

local function setupInput()
    local input = CreateFrame("Frame", nil, UIParent)
    input:EnableKeyboard(true)
    input:SetPropagateKeyboardInput(true) -- never swallow keys meant for the game
    input:SetScript("OnKeyDown", onPlayerInput)
    WorldFrame:HookScript("OnMouseDown", onPlayerInput)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "ZONE_CHANGED_NEW_AREA", "CHAT_MSG_ADDON", "CHAT_MSG_CHANNEL", "CHAT_MSG_GUILD", "ADDON_LOADED" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_GUILD" then
        if not isTBC then syncGuildChat(select(1, ...), select(12, ...)) end
    elseif event == "CHAT_MSG_CHANNEL" then
        if not isTBC then return end
        local text, sender = ...
        local channel = select(9, ...)
        if secret(text) or secret(sender) or secret(channel) then return end
        if cfg.channel and channel and channel:lower() == cfg.channel:lower()
            and text:sub(1, #PFX + 1) == PFX .. "#" then
            onAddonMsg(text:sub(#PFX + 2), sender)
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, dist, sender = ...
        if secret(text) or secret(sender) then return end
        if prefix == PFX and dist == "CHANNEL" then onAddonMsg(text, sender) end
        if isTBC and prefix == PFX and dist == "WHISPER" then
            local kind, tag = strsplit("#", text, 3)
            local configured = false
            for _, guild in ipairs(cfg.guilds) do if guild.tag == tag then configured = true; break end end
            stats.recv = stats.recv + 1
            if not configured then stats.noConfig = stats.noConfig + 1 end
            -- The channel roster the client gives us is incomplete, so it is not used as a filter:
            -- a configured guild tag and a known presence kind are enough.
            if configured and (kind == "P" or kind == "R" or kind == "Q" or kind == "X") then
                onAddonMsg(text, sender)
            end
        end
    elseif event == "ADDON_LOADED" then -- the guild window can load after us
        local name = ...
        if name == "Blizzard_Communities" or name == "Blizzard_GuildUI" then pcall(scan) end
    elseif event == "PLAYER_LOGIN" then
        GuildFriendsDB = GuildFriendsDB or {}
        db = GuildFriendsDB
        RegisterPrefix(PFX)
        if db.tag == nil then db.tag = true end
        if db.echo == nil then db.echo = true end
        if db.sync == nil then db.sync = true end
        if db.lfm == nil then db.lfm = true end
        if db.surname == nil then db.surname = true end
        db.history = db.history or {}
        db.nicks = db.nicks or {}
        joinAt = GetTime() + JOIN_DELAY -- let General/Trade take their channel numbers first
        if IsInGuild() then (C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster)() end
        C_Timer.NewTicker(10, tick)
        if isTBC then pcall(setupInput) end
        pcall(scan) -- a problem with Blizzard's guild window must never stop the rest
        if _G.FriendsFrame then pcall(FriendsFrame.HookScript, FriendsFrame, "OnShow", scan) end -- old Guild tab is built late
    elseif event == "PLAYER_LOGOUT" then
        send("X")
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if GetTime() - lastAnnounce > 30 then announce() end
    else -- GUILD_ROSTER_UPDATE / PLAYER_GUILD_UPDATE
        reloadConfig()
        ThreeCrownsGuild_Refresh()
    end
end)

SLASH_THREECROWNSGUILD1 = "/tcg"
SLASH_THREECROWNSGUILD2 = "/tc"
SlashCmdList.THREECROWNSGUILD = function(msg)
    msg = strtrim(msg)
    local key, val = msg:lower():match("^(%a+) (o[nf]+)$")
    if (key == "tag" or key == "echo" or key == "surname" or key == "sync" or key == "lfm") and (val == "on" or val == "off") then
        db[key] = (val == "on")
        if key == "surname" then ThreeCrownsGuild_Refresh(); refreshChat() end
        print(GREEN .. "[TCG]|r " .. key .. " " .. val)
    elseif msg:lower() == "lfm" then
        openLFM()
    elseif msg:lower():match("^lfm ") then -- /tc lfm <dungeon>: send now with the roles we detect
        local tank, healer, dps = missingRoles()
        chatInput(sendLFM, msg:sub(5), tank, healer, dps)
    elseif msg:lower() == "who" then
        lastQuery = 0; chatInput(requestWho)
    elseif msg:lower() == "status" then
        local n = 0
        for _ in pairs(peers) do n = n + 1 end
        local members = 0
        for _ in pairs(rosterCache) do members = members + 1 end
        print(("%s[TCG]|r channel=%s joined=%s guildTag=%s peers=%d lastSend=%s rx P/Q/C=%d/%d/%d"
            .. " whispers out/in=%d/%d dropped(unknown guild)=%d roster=%d"):format(
            GREEN, tostring(cfg.channel), tostring(chanId()), tostring(myTag()), n, lastResult,
            rx.P or 0, rx.Q or 0, rx.C or 0, stats.sent, stats.recv, stats.noConfig, members))
    elseif msg:lower() == "roster" then
        local names = {}
        for name in pairs(rosterCache) do names[#names + 1] = name end
        table.sort(names)
        print(("%s[TCG]|r channel members (%d): %s"):format(GREEN, #names, table.concat(names, ", ")))
    elseif msg == "" then
        chatInput(toggle)
    else
        chatInput(sendChat, msg)
    end
end
