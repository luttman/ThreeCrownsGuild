local interfaceVersion = select(4, GetBuildInfo())
-- Allow TBC in this local test build; published releases remain Forever-only.
local isForever = interfaceVersion >= 16000 and interfaceVersion < 17000
local isTBC = interfaceVersion >= 20000 and interfaceVersion < 21000
if not (isForever or isTBC) then return end
local _, addon = ...

-- ThreeCrownsGuild: online roster + shared chat (/tcg) across several guilds on one realm.
-- Config is read from Guild Info (like GreenWall), identical in every guild:
--   TCGc:channel:password
--   TCGp:Guild Name:TAG        (one line per guild, including your own)
-- Chat travels through the hidden channel. Idle presence uses addon whispers.
-- Message: <kind>#<tag>#<body>
--   C chat (CLASS;text) | P presence (level;CLASS;zone) | Q "who is online?" | X logout
local PFX, HEARTBEAT, EXPIRE, JOIN_DELAY, HISTORY_MAX = "GF1", 240, 600, 15, 200
local ENCODED_CHUNK = 248 -- leaves room for the marker and splits Base64 on a four-byte boundary
local GREEN = "|cff40ff40"
-- Guild chat forwarding is forced on. Set to false to let players turn it off again: their saved
-- choice (db.sync) is never overwritten while locked.
local SYNC_LOCKED = true
local SYNC_LOCKED_TEXT = "Guild chat sync is always on. We keep it on so that our guilds can talk "
    .. "and play together as one community."
if addon then addon.syncLocked = SYNC_LOCKED end -- Settings.lua reads this

local secret = issecretvalue or function() return false end
local db
local cfg = { guilds = {}, byName = {} }
local peers = {} -- ["Name"] = { tag, level, class, zone, seen }
local SendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local SendChannelChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
local Encoding = isForever and C_EncodingUtil
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local joinAt, lastAnnounce, lastQuery = 0, 0, 0
local warmup, lastResult, rx = 3, "-", {} -- warmup: a few quick announces after joining (first ones can be dropped)
local stats = { sent = 0, recv = 0, noConfig = 0, channelEcho = 0 } -- shown by /tc status
local f, chat -- UI, created on first open

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

local function chatName(sender)
    if isForever and addon and addon.ForeverName then return addon.ForeverName(sender) end
    return Ambiguate(sender, "none")
end

local function ownChatName()
    if isForever and GetUnitName then return GetUnitName("player") end
    return UnitName("player")
end

local function chatLocked()
    return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown()
end

local function chanId()
    if not cfg.channel then return nil end
    local id = GetChannelName(cfg.channel)
    if id and id > 0 then return id end
    return nil
end

-- The client only loads a channel's roster while it is the
-- selected one in the channel window, so we select it briefly, copy the roster and put the
-- player's own selection back. Everything else reads the copy.
local rosterCache, rosterAt, selectionBefore = {}, -math.huge, nil
local function channelWindowOpen() return _G.ChannelFrame and ChannelFrame:IsShown() end

local function ourIndex()
    if not chanId() or not GetNumDisplayChannels or not GetChannelDisplayInfo then return nil end
    for index = 1, GetNumDisplayChannels() do
        local name, header, _, number = GetChannelDisplayInfo(index)
        if not secret(name) and name and not header and number == chanId() and name:lower() == cfg.channel:lower() then return index end
    end
    return nil
end

local function readMembers(index)
    local members = {}
    for i = 1, select(5, GetChannelDisplayInfo(index)) or 0 do
        local member = C_ChatInfo.GetChannelRosterInfo(index, i)
        if not secret(member) and member then members[chatName(member)] = member end
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
    if InCombatLockdown() or not (C_ChatInfo and C_ChatInfo.GetChannelRosterInfo
        and GetSelectedDisplayChannel and SetSelectedDisplayChannel) then return end
    local index = ourIndex()
    if not index or selectionBefore then return end
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

local whisperNotices, whisperRetryAt = {}, {}
local WHISPER_NOTICE_WINDOW, WHISPER_RETRY_DELAY = 5, 300
local function whisper(target, kind, body)
    local tag = myTag()
    if not tag or chatLocked() then return end
    local name, now = chatName(target), GetTime()
    if isForever then target = name end
    name = name:lower()
    if (whisperRetryAt[name] or 0) > now then return end
    local previous = whisperNotices[name]
    if previous and previous.expires > now and not previous.background then return end
    whisperNotices[name] = { expires = now + WHISPER_NOTICE_WINDOW, background = true }
    local ok, res = pcall(SendAddon, PFX, (("%s#%s#%s"):format(kind, tag, body or "")):sub(1, 250), "WHISPER", target)
    if not ok or (res ~= nil and res ~= true and res ~= 0) then whisperNotices[name] = previous end
    stats.sent = stats.sent + 1
    if not ok then print(GREEN .. "[TCG]|r send failed: " .. tostring(res)) end
end

local function sendLine(id, kind, marker, payload)
    local ok, res = pcall(SendChannelChat, PFX .. marker .. payload, "CHANNEL", nil, id)
    local submitted = ok and (res == nil or res == true or res == 0)
    lastResult = kind .. "=" .. (submitted and "submitted" or tostring(ok and res))
    if not ok then print(GREEN .. "[TCG]|r send failed: " .. tostring(res)) end
    return submitted
end

local sendingFromInput = false
local function send(kind, body)
    -- Channel chat requires player input. Timers can only send presence whispers.
    local presence = kind == "P" or kind == "Q" or kind == "X"
    if chatLocked() or (not presence and not sendingFromInput) then return false end
    local id, tag = chanId(), myTag()
    if not (id and tag) then return false end
    local payload = (("%s#%s#%s"):format(kind, tag, body or "")):sub(1, 250)
    -- Idle: whisper each channel member. During player input: one channel message reaches everybody.
    if presence and not sendingFromInput then
        local channel, queued, members = cfg.channel, 0, {}
        for name, target in pairs(channelMembers()) do members[name] = target end
        for name, p in pairs(peers) do members[name] = members[name] or p.from or name end
        local own = ownChatName()
        for name, target in pairs(members) do
            if not secret(own) and name ~= own then
                C_Timer.After(queued * 0.2, function()
                    if cfg.channel == channel and chanId() then whisper(target, kind, body) end
                end)
                queued = queued + 1
            end
        end
        -- an empty roster means "not loaded yet" (retry soon); only us in it means nobody to tell
        return queued > 0 or next(members) ~= nil
    end
    if Encoding then
        -- Channel chat can rewrite links and reject byte fragments that split UTF-8.
        local encoded = Encoding.EncodeBase64(payload)
        if not encoded then return false end
        if #encoded > ENCODED_CHUNK then
            return sendLine(id, kind, "+", encoded:sub(1, ENCODED_CHUNK))
                and sendLine(id, kind, "-", encoded:sub(ENCODED_CHUNK + 1))
        end
        return sendLine(id, kind, "@", encoded)
    end
    return sendLine(id, kind, "#", payload)
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

-- Answer one player directly (kind R) instead of re-announcing to the whole channel.
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

local f, chat, dock -- UI (created on first open); dock = guild window we sit next to
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
        local skin = addon.Skin
        skin.Apply()
        menu = CreateFrame("Frame", nil, UIParent)
        menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu:SetFrameLevel(catcher:GetFrameLevel() + 5)
        menu:SetSize(130, 8 + 4 * 22); menu:Hide()
        skin.Surface(menu, "BACKGROUND", skin.colors.border)
        local inner = menu:CreateTexture(nil, "BORDER")
        inner:SetPoint("TOPLEFT", 1, -1); inner:SetPoint("BOTTOMRIGHT", -1, 1)
        skin.Fill(inner, skin.colors.background)
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
            local b = skin.Button(menu, act[1], 122, function() menu:Hide(); act[2](menu.who) end)
            b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 22)
        end
    end
    menu.who = who
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    menu:Show()
end

-- One row of the roster list: a guild header (tag + online count) or a player (name + level).
local function fillRow(row, entry)
    local skin = addon.Skin
    if entry.tag then
        row.text:SetText(("%s (%d online)"):format(entry.tag, entry.online))
        skin.TextColor(row.text, skin.colors.gold)
        row.value:SetText("")
    else
        row.text:SetText(classColor(entry.class) .. nick(entry.who))
        skin.TextColor(row.text, skin.colors.text)
        row.value:SetText(entry.level > 0 and entry.level or "")
    end
end

local function createRow(row)
    row:SetScript("OnClick", function(self, button)
        local entry = self.entry
        if entry.tag then -- guild header: fold / unfold
            collapsed[entry.tag] = not collapsed[entry.tag]
            ThreeCrownsGuild_Refresh()
        elseif button == "RightButton" then
            rowMenu(entry.who)
        else
            SetItemRef("player:" .. entry.who, "|Hplayer:" .. entry.who .. "|h[" .. entry.who .. "]|h", "LeftButton")
        end
    end)
end

function ThreeCrownsGuild_Refresh()
    if not (f and f:IsShown()) then return end
    f.note:SetShown(not cfg.channel)
    local entries = {}
    for _, g in ipairs(cfg.guilds) do
        local list = membersOf(g.tag)
        entries[#entries + 1] = { tag = g.tag, online = #list }
        if not collapsed[g.tag] then
            for _, m in ipairs(list) do
                entries[#entries + 1] = { who = m.name, class = m.class, level = m.level }
            end
        end
    end
    f.list:SetEntries(entries)
end

function addon.RefreshWindow() -- the skin and the settings call this
    ThreeCrownsGuild_Refresh()
    refreshChat()
end

-- ---------------------------------------------------------------- chat

-- Where echoed chat and LFM notices are printed: one of the player's own chat windows, saved by
-- number so renaming the tab changes nothing. Closed or missing window = the default chat frame.
-- "alsoDefault" prints in the default chat frame (General) as well.
local function chatWindowName(i)
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
    if name and name ~= "" and (shown or docked) then return name end
end

local function echo(text)
    local i = db.chatWindow
    local frame = i and chatWindowName(i) and _G["ChatFrame" .. i]
    if frame then frame:AddMessage(text) end
    if (not frame or db.alsoDefault) and frame ~= DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(text) end
end

local function setChatWindow(i) -- nil = default chat frame
    db.chatWindow = i
    if addon and addon.RefreshSettings then addon.RefreshSettings() end
end
if addon then addon.ChatWindowName, addon.SetChatWindow = chatWindowName, setChatWindow end

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
    if db.echo and not (guildMessage and tag == myTag()) then echo(render(rec)) end
end

local function sendChat(msg)
    msg = strtrim(msg or "")
    if msg == "" then return end
    local _, class = UnitClass("player")
    if send("C", class .. ";" .. msg) then
        addChat(myTag(), ownChatName(), class, msg) -- draw the sender's copy locally
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

-- The skin has no text field, so this one is drawn with its colors (a border and a panel fill).
local function editBox(parent, width)
    local skin = addon.Skin
    local box = CreateFrame("EditBox", nil, parent)
    box:SetFrameLevel(parent:GetFrameLevel() + 3) -- above the window's drag strip
    box:SetSize(width, 22); box:SetAutoFocus(false); box:SetFontObject(ChatFontNormal); box:SetTextInsets(6, 6, 0, 0)
    local edge = box:CreateTexture(nil, "BACKGROUND")
    edge:SetAllPoints(); skin.Fill(edge, skin.colors.border)
    local inner = box:CreateTexture(nil, "BORDER")
    inner:SetPoint("TOPLEFT", 1, -1); inner:SetPoint("BOTTOMRIGHT", -1, 1); skin.Fill(inner, skin.colors.panel)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
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
    echo(("%s[LFM] [%s] |Hplayer:%s|h[%s]|h: %s for %s (%s)"):format(
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
        local skin = addon.Skin
        local d = skin.Window("ThreeCrownsGuildLFM", 290, 190, "Looking for more", "DIALOG")
        lfmDialog = d
        local top = d.top

        local label = skin.Label(d, "GameFontHighlight", skin.colors.text)
        label:SetPoint("TOPLEFT", 18, -40 - top); label:SetText("Dungeon")
        d.dungeon = editBox(d, 254)
        d.dungeon:SetPoint("TOPLEFT", 18, -60 - top); d.dungeon:SetMaxBytes(60)

        -- click a role to cycle how many of it you still need
        local function need(name, max, x)
            local b
            b = skin.Button(d, name, 82, function() b:Set((b.n + 1) % (max + 1)) end)
            b:SetPoint("TOPLEFT", x, -94 - top)
            function b:Set(n) self.n = n; self.label:SetText(("%s: %d"):format(name, n)) end
            return b
        end
        d.tank, d.healer, d.dps = need("Tank", 1, 18), need("Healer", 1, 104), need("DPS", 3, 190)

        local sendButton = skin.Button(d, "Send to all guilds", 180, function()
            local ok = false
            chatInput(function() ok = sendLFM(d.dungeon:GetText(), d.tank.n, d.healer.n, d.dps.n) end)
            if ok then d:Hide() end
        end)
        sendButton:SetPoint("BOTTOM", 0, 12)
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
    if not db or not (SYNC_LOCKED or db.sync) or secret(msg) or secret(guid) or guid ~= UnitGUID("player") then return end
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
    addChat(tag, ownChatName(), class, msg, true)
end

do
    local function onChatSent(msg, chatType, _, target)
        if secret(chatType) then return end
        if chatType == "GUILD" and not secret(msg) then
            chatInput(syncGuildChat, msg, UnitGUID("player"))
        elseif chatType == "WHISPER" and not secret(target) and type(target) == "string" then
            whisperNotices[chatName(target):lower()] = { expires = GetTime() + WHISPER_NOTICE_WINDOW }
        end
    end
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        hooksecurefunc(C_ChatInfo, "SendChatMessage", onChatSent)
    else
        hooksecurefunc("SendChatMessage", onChatSent)
    end
end

local guildParts, channelParts = {}, {}
local function onAddonMsg(text, sender, fromChannelChat)
    local kind, tag, body = strsplit("#", text, 3)
    if not tag then return end
    local name, own = chatName(sender), ownChatName()
    if not secret(own) and name == own then
        if fromChannelChat then stats.channelEcho = stats.channelEcho + 1 end
        return
    end
    rx[kind] = (rx[kind] or 0) + 1
    if kind == "G" or kind == "g" then
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
        onLFM(tag, name, body)
        return
    elseif kind == "C" then
        local class, msg = strsplit(";", body or "", 2)
        local p = peers[name] or { level = 0, zone = "" }
        p.tag, p.class, p.seen, p.from = tag, class, GetTime(), sender
        peers[name] = p
        addChat(tag, name, class, msg or "")
    elseif kind == "P" or kind == "R" then
        local lvl, class, zone = strsplit(";", body or "", 3)
        local known = peers[name] ~= nil
        whisperRetryAt[name:lower()] = nil
        peers[name] = { tag = tag, level = tonumber(lvl) or 0, class = class, zone = zone or "", seen = GetTime(), from = sender }
        if kind == "P" and not known then replyTo(sender) end
    elseif kind == "X" then
        peers[name] = nil
    elseif kind == "Q" then
        replyTo(sender)
    end
    if kind ~= "C" then ThreeCrownsGuild_Refresh() end
end

local function receiveChannelPacket(text, sender)
    if text:sub(1, #PFX) ~= PFX or #text > 254 then return end
    local marker, body = text:sub(#PFX + 1, #PFX + 1), text:sub(#PFX + 2)
    if marker == "#" then onAddonMsg(body, sender, true); return end
    if not Encoding then return end
    if marker == "+" and #body == ENCODED_CHUNK then
        channelParts[sender] = { body = body, time = GetTime() }
    elseif marker == "@" or marker == "-" then
        local part = channelParts[sender]
        channelParts[sender] = nil
        if marker == "-" then
            if not part or GetTime() - part.time > 10 then return end
            body = part.body .. body
        end
        local ok, payload = pcall(Encoding.DecodeBase64, body)
        if ok and payload and #payload <= 250 then onAddonMsg(payload, sender, true) end
    end
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
        local saved = addon.db.positions[f:GetName()]
        if saved then f:SetPoint(saved.point, UIParent, saved.relative, saved.x, saved.y) else f:SetPoint("CENTER") end
    end
end

-- One window, five tabs over three pages: chat (with the roster), stats (stats, deaths, level race), settings.
local PAGE_OF = { chat = "chat", stats = "stats", deaths = "stats", race = "stats", settings = "settings" }
local selectTab

local function selectPage(key)
    key = PAGE_OF[key] and key or "chat"
    f.key = key
    for name, page in pairs(f.pages) do page:SetShown(name == PAGE_OF[key]) end
    if PAGE_OF[key] == "stats" then
        addon.ShowStats(key)
    elseif key == "settings" then
        addon.RefreshSettings()
    else
        ThreeCrownsGuild_Refresh(); refreshChat()
    end
    selectTab(key, true)
end

local function createUI()
    local skin = addon.Skin
    local colors = skin.colors
    local width = 760
    f = skin.Window("ThreeCrownsGuildFrame", width, 440, "ThreeCrownsGuild", "HIGH")
    local top = f.top
    -- a drag takes the window off the guild window it sat next to
    for _, region in ipairs({ f, f.drag }) do region:HookScript("OnDragStart", function() dock = nil end) end

    local lfmButton = skin.Button(f, "LFM", 54, openLFM)
    if f.blizzard then
        lfmButton:SetPoint("TOPRIGHT", -10, -7 - top)
    else
        lfmButton:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
    end
    local _, Select = skin.Tabs(f, { { "chat", "Chat", 56 }, { "stats", "Stats", 56 }, { "deaths", "Deaths", 60 },
        { "race", "Level race", 80 }, { "settings", "Settings", 70 } }, selectPage, f.blizzard and 10 or 150, -7 - top)
    selectTab = Select

    f.pages = {}
    for _, name in ipairs({ "chat", "stats", "settings" }) do
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", 8, -40 - top); page:SetPoint("BOTTOMRIGHT", -8, 8)
        page:Hide()
        f.pages[name] = page
    end
    addon.BuildStats(f.pages.stats, width)
    addon.BuildSettings(f.pages.settings)

    -- chat page, right: every guild with its online players
    local chatPage = f.pages.chat
    f.list = skin.List(chatPage, 20, fillRow, createRow)
    f.list:SetPoint("TOPRIGHT", 0, 0); f.list:SetPoint("BOTTOMRIGHT", 0, 0); f.list:SetWidth(190)
    f.note = skin.Label(f.list, "GameFontHighlight", colors.muted)
    f.note:SetPoint("TOPLEFT", 8, -8); f.note:SetWidth(168); f.note:SetJustifyH("LEFT"); f.note:SetWordWrap(true)
    f.note:SetText("No TCGc:/TCGp: config found in Guild Info (see README).")

    -- chat page, left: chat with a slim scrollbar, input below
    local cp = CreateFrame("Frame", nil, chatPage)
    cp:SetPoint("TOPLEFT", 0, 0); cp:SetPoint("BOTTOMLEFT", 0, 32); cp:SetPoint("RIGHT", f.list, "LEFT", -8, 0)
    skin.Surface(cp, "BACKGROUND", colors.panel)
    chat = CreateFrame("ScrollingMessageFrame", nil, cp)
    chat:SetPoint("TOPLEFT", 8, -8); chat:SetPoint("BOTTOMRIGHT", -16, 8)
    chat:SetFontObject(ChatFontNormal); chat:SetJustifyH("LEFT")
    chat:SetFading(false); chat:SetMaxLines(500); chat:SetHyperlinksEnabled(true)
    chat:EnableMouseWheel(true)
    local bar = CreateFrame("Slider", nil, cp)
    bar:SetOrientation("VERTICAL")
    bar:SetPoint("TOPRIGHT", -2, -2); bar:SetPoint("BOTTOMRIGHT", -2, 2); bar:SetWidth(6)
    bar:SetValueStep(1); bar:SetObeyStepOnDrag(true); bar:EnableMouse(true)
    local thumb = bar:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(6, 24); skin.Fill(thumb, colors.bar)
    bar:SetThumbTexture(thumb)
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
    local eb = editBox(chatPage, 300)
    eb:SetPoint("BOTTOMLEFT", 0, 0); eb:SetPoint("RIGHT", cp, "RIGHT", 0, 0); eb:SetMaxBytes(220)
    eb:SetScript("OnEnterPressed", function(s) chatInput(sendChat, s:GetText()); s:SetText("") end)

    f:SetScript("OnShow", function() requestWho(); selectPage(f.key) end)
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

function addon.OpenWindow(key) -- "chat", "stats", "deaths", "race" or "settings"
    open()
    selectPage(key)
end
addon.Toggle = toggle
function addon.OpenSettings() addon.OpenWindow("settings") end

-- An icon in Blizzard's guild windows (Guild & Communities, or the old Guild tab) that opens
-- our window next to them. Only hooks and our own child button: Blizzard's frames stay untouched.
local hooked = {}
local function attach(frame, host, oldTab)
    if hooked[frame] then return end
    hooked[frame] = true
    local b = CreateFrame("Button", nil, frame)
    b:SetSize(22, 22)
    b:SetNormalTexture("Interface\\AddOns\\ThreeCrownsGuild\\Media\\Logo")
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

local GetInfoText = (C_GuildInfo and C_GuildInfo.GetInfoText) or GetGuildInfoText
local configReloadPending = false
local function reloadConfig()
    if not GetInfoText then return end
    if InCombatLockdown() or chatLocked() then
        configReloadPending = true
        return
    end
    local info = GetInfoText()
    configReloadPending = secret(info)
    if configReloadPending then return end
    local c = parseConfig(info)
    if cfg.channel and (c.channel ~= cfg.channel) and chanId() then LeaveChannelByName(cfg.channel) end
    if c.channel ~= cfg.channel then rosterCache, rosterAt = {}, -math.huge end
    cfg = c
end

local function tick()
    if configReloadPending then reloadConfig() end
    local now = GetTime()
    for name, notice in pairs(whisperNotices) do
        if notice.expires <= now then whisperNotices[name] = nil end
    end
    for name, retryAt in pairs(whisperRetryAt) do
        if retryAt <= now then whisperRetryAt[name] = nil end
    end
    for sender, part in pairs(guildParts) do
        if GetTime() - part.time > 10 then guildParts[sender] = nil end
    end
    for sender, part in pairs(channelParts) do
        if GetTime() - part.time > 10 then channelParts[sender] = nil end
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

-- The client asks for a password when a join has none (its own rejoin at login) or a wrong one.
-- Answer once with the Guild Info password; if that fails too, the prompt stays for the player.
local lastPasswordTry = -math.huge
if StaticPopup_Show and StaticPopup_Hide and hooksecurefunc then
    hooksecurefunc("StaticPopup_Show", function(which, channel)
        if which ~= "CHAT_CHANNEL_PASSWORD" or not (cfg.channel and cfg.password) then return end
        if secret(channel) or type(channel) ~= "string" or channel:lower() ~= cfg.channel:lower() then return end
        if GetTime() - lastPasswordTry < 30 then return end
        lastPasswordTry = GetTime()
        StaticPopup_Hide(which)
        JoinChannelByName(cfg.channel, cfg.password)
    end)
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
if ERR_CHAT_PLAYER_NOT_FOUND_S then
    local before, after = ERR_CHAT_PLAYER_NOT_FOUND_S:match("^(.-)%%s(.*)$")
    if not before then before, after = ERR_CHAT_PLAYER_NOT_FOUND_S:match("^(.-)%%1%$s(.*)$") end
    if before then
        local pattern = "^" .. before:gsub("(%W)", "%%%1") .. "(.+)" .. after:gsub("(%W)", "%%%1") .. "$"
        AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, text)
            if secret(text) or type(text) ~= "string" then return end
            local target = text:match(pattern)
            local name = target and chatName(target):lower()
            local notice = name and whisperNotices[name]
            local now = GetTime()
            if notice and notice.background and notice.expires > now then
                whisperRetryAt[name] = now + WHISPER_RETRY_DELAY
                return true
            end
        end)
    end
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

StaticPopupDialogs.THREECROWNSGUILD_SYNC_RESET = {
    text = "ThreeCrownsGuild turned off automatic guild chat forwarding for your account.\n\n"
        .. "Type /tcg to open shared chat, or /tcg Hello! to send a message to connected guilds.\n\n"
        .. "Type /tcg sync on to forward your /g messages automatically.\n"
        .. "Type /tcg help for more chat commands.\n"
        .. "Type /tc stats to open the guild leaderboard.",
    button1 = OKAY or "OK", timeout = 0, whileDead = 1, hideOnEscape = 1,
}

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_LOGOUT", "GUILD_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE",
    "ZONE_CHANGED_NEW_AREA", "CHAT_MSG_ADDON", "CHAT_MSG_CHANNEL", "ADDON_LOADED" }) do ev:RegisterEvent(e) end
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_CHANNEL" then
        local text, sender = ...
        local channel = select(9, ...)
        if secret(text) or secret(sender) or secret(channel) then return end
        if cfg.channel and channel and channel:lower() == cfg.channel:lower() then
            receiveChannelPacket(text, sender)
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, dist, sender = ...
        if secret(text) or secret(sender) then return end
        if prefix == PFX and dist == "CHANNEL" then onAddonMsg(text, sender) end
        if prefix == PFX and dist == "WHISPER" then
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
        local syncReset = not db.syncDefaultOffApplied and db.sync == true
        if not db.syncDefaultOffApplied or db.sync == nil then db.sync = false end
        db.syncDefaultOffApplied = true
        if db.lfm == nil then db.lfm = true end
        if db.surname == nil then db.surname = true end
        if db.minimapButton == nil then db.minimapButton = true end
        db.history = db.history or {}
        db.nicks = db.nicks or {}
        if addon then addon.db = db; db.positions = db.positions or {} end -- Skin.lua and Settings.lua read these
        joinAt = GetTime() + JOIN_DELAY -- let General/Trade take their channel numbers first
        if IsInGuild() then (C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster)() end
        C_Timer.NewTicker(10, tick)
        if isTBC then pcall(setupInput) end
        pcall(scan) -- a problem with Blizzard's guild window must never stop the rest
        if addon and addon.RefreshMinimap then pcall(addon.RefreshMinimap) end
        if _G.FriendsFrame then pcall(FriendsFrame.HookScript, FriendsFrame, "OnShow", scan) end -- old Guild tab is built late
        local syncStatus = (SYNC_LOCKED or db.sync) and (GREEN .. "on") or "|cffff6060off"
        print(GREEN .. "[TCG]|r Sync " .. syncStatus .. "|r. /tcg help for chat. /tc help for guild tools.")
        if syncReset and not SYNC_LOCKED then StaticPopup_Show("THREECROWNSGUILD_SYNC_RESET") end
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
-- Everything /tc does also works with /tcg, except hide and show: a chat message "show" must never
-- switch position sharing. Use /tc hide, /tc show, or the settings tab for those.
local TOOLS = { who = true, status = true, roster = true, lfm = true, stats = true, deaths = true, race = true }
SlashCmdList.THREECROWNSGUILD = function(msg)
    msg = strtrim(msg)
    local command = msg:lower()
    local key, val = command:match("^(%a+)%s+(%a+)$")
    if SYNC_LOCKED and key == "sync" and (val == "on" or val == "off") then
        print(GREEN .. "[TCG]|r " .. SYNC_LOCKED_TEXT)
    elseif (key == "tag" or key == "echo" or key == "surname" or key == "sync") and (val == "on" or val == "off") then
        db[key] = (val == "on")
        if key == "surname" then ThreeCrownsGuild_Refresh(); refreshChat() end
        print(GREEN .. "[TCG]|r " .. key .. " " .. val)
    elseif command == "settings" then
        addon.OpenSettings()
    elseif command == "window" or command:match("^window%s") then
        local arg = command:match("^window%s+(%S+)")
        local n = tonumber(arg)
        if arg == "default" then setChatWindow(nil) elseif n and chatWindowName(n) then setChatWindow(n) end
        if arg and (arg == "default" or n and chatWindowName(n)) then
            print(GREEN .. "[TCG]|r Chat is printed in: "
                .. (db.chatWindow and chatWindowName(db.chatWindow) or "the default chat window"))
        else
            print(GREEN .. "[TCG]|r Chat windows (use /tcg window <number> or /tcg window default):")
            for i = 1, NUM_CHAT_WINDOWS do
                local name = chatWindowName(i)
                if name then print(("%d %s%s"):format(i, name, db.chatWindow == i and " (selected)" or "")) end
            end
        end
    elseif command == "help" then
        print(GREEN .. "[TCG]|r /tcg opens or closes shared chat. /tcg <message> sends a message.")
        print(SYNC_LOCKED and SYNC_LOCKED_TEXT
            or "/tcg sync on enables guild chat forwarding. /tcg sync off disables it.")
        print("Use /tcg tag, echo, or surname with on or off to change chat display settings.")
        print("/tcg settings opens the settings tab. /tcg stats, deaths, or race open the stats tabs.")
        print("/tcg window lists your chat windows for echoed chat. /tcg who, status, roster, lfm, pins, and share work as /tc does.")
    elseif TOOLS[command] or command:match("^lfm%s") or command:match("^pins%s+%a+$") or command:match("^share%s+%a+$") then
        SlashCmdList.THREECROWNSGUILDTOOLS(msg)
    elseif msg == "" then
        chatInput(toggle)
    else
        chatInput(sendChat, msg)
    end
end

SLASH_THREECROWNSGUILDTOOLS1 = "/tc"
SlashCmdList.THREECROWNSGUILDTOOLS = function(msg)
    msg = strtrim(msg)
    local command = msg:lower()
    local key, val = command:match("^(%a+)%s+(%a+)$")
    if key == "lfm" and (val == "on" or val == "off") then
        db.lfm = val == "on"
        print(GREEN .. "[TCG]|r lfm " .. val)
    elseif command == "settings" then
        addon.OpenSettings()
    elseif command == "lfm" then
        openLFM()
    elseif command:match("^lfm ") then
        local tank, healer, dps = missingRoles()
        chatInput(sendLFM, msg:sub(5), tank, healer, dps)
    elseif command == "who" then
        lastQuery = 0; chatInput(requestWho)
    elseif command == "status" then
        local n = 0
        for _ in pairs(peers) do n = n + 1 end
        local members = 0
        for _ in pairs(rosterCache) do members = members + 1 end
        print(("%s[TCG]|r channel=%s joined=%s guildTag=%s peers=%d lastSend=%s rx P/Q/R/C/G=%d/%d/%d/%d/%d"
            .. " channelEcho=%d whispers out/in=%d/%d dropped(unknown guild)=%d roster=%d"):format(
            GREEN, tostring(cfg.channel), tostring(chanId()), tostring(myTag()), n, lastResult,
            rx.P or 0, rx.Q or 0, rx.R or 0, rx.C or 0, rx.G or 0, stats.channelEcho, stats.sent, stats.recv, stats.noConfig, members))
        local mapStatus = addon and addon.GuildMapStatus and addon.GuildMapStatus()
        if mapStatus then print(GREEN .. "[TCG]|r " .. mapStatus) end
    elseif command == "roster" then
        local names = {}
        for name in pairs(rosterCache) do names[#names + 1] = name end
        table.sort(names)
        print(("%s[TCG]|r channel members (%d): %s"):format(GREEN, #names, table.concat(names, ", ")))
    elseif command == "help" then
        print(GREEN .. "[TCG]|r /tc stats opens guild stats. Use /tc deaths or /tc race to switch views.")
        print("Outdoor position sharing with your guild is on by default. Use /tc hide to stop sharing or /tc show to resume.")
        print("Guild map dots are on by default. Use /tc pins off to hide them or /tc pins on to show them.")
        print("Use /tc status to check map settings and received positions.")
        print("/tc share on or off controls stat sharing. /tc who refreshes the roster.")
        print("/tc lfm opens group finder. Use /tc lfm <dungeon> to send a request or /tc lfm on or off for notices.")
        print("/tc status and /tc roster show diagnostics. Use /tcg help for chat commands.")
    elseif addon and addon.GuildCommand and addon.GuildCommand(command) then
        return
    elseif key == "sync" or key == "tag" or key == "echo" or key == "surname" then
        SlashCmdList.THREECROWNSGUILD(msg)
    else
        print(GREEN .. "[TCG]|r See /tc help for guild tools or /tcg help for chat.")
    end
end
