-- ThreeCrownsGuild: online roster + shared chat (/tcg) across several guilds on one realm.
-- Config is read from Guild Info (like GreenWall), identical in every guild:
--   TCGc:channel:password
--   TCGp:Guild Name:TAG        (one line per guild, including your own)
-- Transport (same as Olympus): addon messages, prefix GF1, over a hidden channel joined with
-- JoinChannelByName (a JoinTemporaryChannel channel is rejected as InvalidChatType).
-- Plain SendChatMessage to a channel is blocked outside key/click events. Message: <kind>#<tag>#<body>
--   C chat (CLASS;text) | P presence (level;CLASS;zone) | Q "who is online?" | X logout
local PFX, HEARTBEAT, EXPIRE, JOIN_DELAY, HISTORY_MAX, ROW_H = "GF1", 240, 600, 15, 200, 16
local GREEN = "|cff40ff40"

local secret = issecretvalue or function() return false end
local db
local cfg = { guilds = {}, byName = {} }
local peers = {} -- ["Name"] = { tag, level, class, zone, seen }
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local joinAt, lastAnnounce, lastQuery, replyPending = 0, 0, 0, false
local warmup, lastResult, rx = 3, "-", {} -- warmup: a few quick announces after joining (first ones can be dropped)
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
    if not cfg.channel then return end
    local id = GetChannelName(cfg.channel)
    if id and id > 0 then return id end
end

local function send(kind, body)
    local id, tag = chanId(), myTag()
    if not (id and tag) then return false end
    local ok, res = pcall(SendAddon, PFX, (("%s#%s#%s"):format(kind, tag, body or "")):sub(1, 250), "CHANNEL", id)
    lastResult = kind .. "=" .. tostring(ok and res) -- 0/true/nil = ok; other numbers = Enum.SendAddonMessageResult
    if not ok then print(GREEN .. "[TCG]|r send failed: " .. tostring(res)) end
    return ok and (res == nil or res == true or res == 0)
end

local function announce()
    local _, class = UnitClass("player")
    if send("P", ("%d;%s;%s"):format(UnitLevel("player"), class, GetRealZoneText() or "")) then
        lastAnnounce = GetTime()
        warmup = math.max(0, warmup - 1)
    end
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
    return ("%s[TCG] %s|Hplayer:%s|h%s%s%s|h: %s"):format(
        GREEN, db.tag and ("[" .. rec.tag .. "] ") or "", rec.name, classColor(rec.class), nick(rec.name), GREEN, rec.msg)
end

refreshChat = function()
    if not chat then return end
    chat:Clear()
    for _, rec in ipairs(db.history) do chat:AddMessage(render(rec)) end
    ThreeCrownsGuild_SyncBar()
end

local function addChat(tag, name, class, msg)
    local rec = { tag = tag, name = name, class = class, msg = msg }
    tinsert(db.history, rec)
    while #db.history > HISTORY_MAX do tremove(db.history, 1) end
    if chat then chat:AddMessage(render(rec)); ThreeCrownsGuild_SyncBar() end
    if db.echo then DEFAULT_CHAT_FRAME:AddMessage(render(rec)) end
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

local function onAddonMsg(text, sender)
    local kind, tag, body = strsplit("#", text, 3)
    if not tag then return end
    local name = Ambiguate(sender, "none")
    rx[kind] = (rx[kind] or 0) + 1
    if kind == "C" then
        if name == UnitName("player") then return end -- already shown locally on send
        local class, msg = strsplit(";", body or "", 2)
        local p = peers[name] or { level = 0, zone = "" }
        p.tag, p.class, p.seen = tag, class, GetTime()
        peers[name] = p
        addChat(tag, name, class, msg or "")
    elseif kind == "P" then
        local lvl, class, zone = strsplit(";", body or "", 3)
        peers[name] = { tag = tag, level = tonumber(lvl) or 0, class = class, zone = zone or "", seen = GetTime() }
    elseif kind == "X" then
        peers[name] = nil
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
    eb:SetScript("OnEnterPressed", function(s) sendChat(s:GetText()); s:SetText("") end)
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
    cfg = c
end

local function tick()
    for name, p in pairs(peers) do
        if GetTime() - p.seen > EXPIRE then peers[name] = nil end
    end
    if cfg.channel and myTag() and GetTime() >= joinAt then
        if not chanId() then
            JoinChannelByName(cfg.channel, cfg.password)
            C_Timer.After(3, function() -- the channel number appears a moment after joining
                for i = 1, NUM_CHAT_WINDOWS do ChatFrame_RemoveChannel(_G["ChatFrame" .. i], cfg.channel) end
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
for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
    ChatFrame_AddMessageEventFilter(ev, hideChannel)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "ZONE_CHANGED_NEW_AREA", "CHAT_MSG_ADDON", "ADDON_LOADED" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, text, dist, sender = ...
        if secret(text) or secret(sender) then return end
        if prefix == PFX and dist == "CHANNEL" then onAddonMsg(text, sender) end
    elseif event == "ADDON_LOADED" then -- the guild window can load after us
        local name = ...
        if name == "Blizzard_Communities" or name == "Blizzard_GuildUI" then pcall(scan) end
    elseif event == "PLAYER_LOGIN" then
        GuildFriendsDB = GuildFriendsDB or {}
        db = GuildFriendsDB
        RegisterPrefix(PFX)
        if db.tag == nil then db.tag = true end
        if db.echo == nil then db.echo = true end
        if db.surname == nil then db.surname = true end
        db.history = db.history or {}
        db.nicks = db.nicks or {}
        joinAt = GetTime() + JOIN_DELAY -- let General/Trade take their channel numbers first
        if IsInGuild() then (C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster)() end
        C_Timer.NewTicker(10, tick)
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
SlashCmdList.THREECROWNSGUILD = function(msg)
    msg = strtrim(msg)
    local key, val = msg:lower():match("^(%a+) (o[nf]+)$")
    if (key == "tag" or key == "echo" or key == "surname") and (val == "on" or val == "off") then
        db[key] = (val == "on")
        if key == "surname" then ThreeCrownsGuild_Refresh(); refreshChat() end
        print(GREEN .. "[TCG]|r " .. key .. " " .. val)
    elseif msg:lower() == "who" then
        lastQuery = 0; requestWho()
    elseif msg:lower() == "status" then
        local n = 0
        for _ in pairs(peers) do n = n + 1 end
        print(("%s[TCG]|r channel=%s joined=%s guildTag=%s peers=%d lastSend=%s rx P/Q/C=%d/%d/%d"):format(
            GREEN, tostring(cfg.channel), tostring(chanId()), tostring(myTag()), n, lastResult,
            rx.P or 0, rx.Q or 0, rx.C or 0))
    elseif msg == "" then
        toggle()
    else
        sendChat(msg)
    end
end
