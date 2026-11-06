local _, addon = ...
local interface = select(4, GetBuildInfo())
local isForever = interface >= 16000 and interface < 17000
if not (isForever or interface >= 20000 and interface < 21000) then return end

local secret = issecretvalue or function() return false end
local PREFIX = "TCGSTATS1"
local SendAddon = C_ChatInfo and C_ChatInfo.SendAddonMessage or SendAddonMessage
local RegisterPrefix = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
local db, player, playerRealm, guild, settings, guildStats
local played, playedRequested
local sentPosition
local groupMembers = {}
local views = {
    stats = {
        { "quests", "Quests", 98 }, { "kills", "Mob kills", 107 }, { "dungeons", "Dungeons", 932 },
        { "raid10", "10p raids", 933 }, { "raid20", "20p raids", 934 }, { "raid40", "40p raids", 64184 },
        { "posted", "Posted", 329 }, { "bought", "Purchases", 330 },
        { "peakGold", "Peak gold" }, { "played", "Played" },
    },
    deaths = {
        { "deaths", "Total", 60 }, { "dungeonDeaths", "Dungeon", 918 }, { "raid10Deaths", "10p raids", 917 },
        { "raid20Deaths", "20p raids", 64183 }, { "raid40Deaths", "40p raids", 64185 },
        { "players", "Players", 1501 }, { "falling", "Falling", 114 }, { "drowning", "Drowning", 112 },
        { "fire", "Fire/lava", 115 }, { "fatigue", "Fatigue", 113 },
    },
    race = {},
}
local fields, raceFields, milestones = {}, {}, {}
for _, view in ipairs({ views.stats, views.deaths }) do
    for _, column in ipairs(view) do fields[#fields + 1] = column end
end
for level = 10, 60, 10 do
    local column = { "level" .. level, tostring(level), "reached" .. level }
    milestones[level] = column
    views.race[#views.race + 1] = column
    raceFields[#raceFields + 1] = column
    raceFields[#raceFields + 1] = { column[3] }
end

local function send(message)
    if guild then
        local ok, result = pcall(SendAddon, PREFIX, message, "GUILD")
        return ok and (result == nil or result == true or result == 0)
    end
end

local function requestPlayed(force)
    if RequestTimePlayed and (force or not playedRequested or GetTime() - playedRequested >= 10) then
        playedRequested = GetTime()
        RequestTimePlayed()
    end
end

local function readStatistic(id)
    local value = GetStatistic(id)
    if secret(value) then return end
    if type(value) == "number" then return value >= 0 and value or nil end
    if type(value) ~= "string" then return end
    if value == "--" then return 0 end
    -- Blizzard returns localized, grouped integers for these counters.
    local digits = value:gsub("[,%.%s']", ""):gsub("\194\160", ""):gsub("\226\128\175", "")
    if digits:match("^%d+$") then return tonumber(digits) end
end

local function snapshot()
    local record = { played = played }
    if GetAchievementCriteriaInfo then
        -- The criterion returns copper without the localized money formatting in GetStatistic.
        local ok, _, _, _, copper = pcall(GetAchievementCriteriaInfo, 334, 1, true)
        if ok and not secret(copper) and type(copper) == "number" and copper >= 0 then
            record.peakGold = copper
        end
    end
    if GetStatistic then
        for _, field in ipairs(fields) do
            if field[3] then record[field[1]] = readStatistic(field[3]) end
        end
    end
    return record
end

local function sendValues(kind, values, columns)
    local packet = { kind }
    for _, field in ipairs(columns) do
        local value = values[field[1]]
        packet[#packet + 1] = value and tostring(value) or "-"
    end
    send(table.concat(packet, ";"))
end

local function shareStats()
    if not guild then return end
    if settings.shareStats then
        sendValues("B", snapshot(), fields)
        if next(settings.race) then sendValues("L", settings.race, raceFields) end
    elseif settings.shareStats == false then
        send("D")
    end
end

local function sharePosition()
    local message = settings.sharePosition and guild and addon.MapPacket()
    if message then
        sentPosition = send(message) or sentPosition
    elseif sentPosition and send("H") then
        sentPosition = nil
    end
end

local function receiveStats(sender, message, columns)
    local record, index = {}, 1
    if not message:match("^[ABL];[%d;%-]+$") or message:find(";;", 1, true) or message:sub(-1) == ";" then return end
    for token in message:gmatch(";([^;]+)") do
        local field = columns[index]
        local number = token:match("^%d+$") and tonumber(token)
        if not field or (token ~= "-" and (not number or number > 99999999999)) then return end
        if number and field[1]:match("^reached") and (number == 0 or number > GetServerTime() + 60) then return end
        if number then record[field[1]] = number end
        index = index + 1
    end
    if index ~= #columns + 1 then return end
    local row = guildStats[sender] or {}
    local legacy = message:sub(1, 1) == "A"
    for _, field in ipairs(columns) do
        local key = field[1]
        if not legacy or key ~= "peakGold" then row[key] = record[key] end
    end
    guildStats[sender] = row
end

function addon.ForeverName(name)
    -- Forever can send the full name with a trailing realm or separate the surname with a hyphen.
    return name:match("^(%S+ [^%-]+)") or (name:gsub("^([^%-]+)%-([^%-]+).*$", "%1 %2"))
end

local function playerKey(name)
    if isForever then return addon.ForeverName(name) end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. playerRealm
end

local function updateGroupMembers()
    wipe(groupMembers)
    local raid = IsInRaid()
    local prefix = raid and "raid" or "party"
    local count = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
    for i = 1, count do
        local name = GetUnitName(prefix .. i, true)
        if not secret(name) and name then groupMembers[playerKey(name)] = true end
    end
end

local function updateGuild()
    local name = GetGuildInfo("player")
    local newGuild = name and GetRealmName() .. "#" .. name
    if newGuild == guild then return end
    addon.ClearPositions()
    guild, sentPosition = newGuild, nil
    guildStats = nil
    if guild then
        local saved = db.guildApiStats[guild] or {}
        guildStats = {}
        for name, record in pairs(saved) do
            local key = playerKey(name)
            if key ~= player then guildStats[key] = saved[key] or record end
        end
        db.guildApiStats[guild] = guildStats
    end
end

local function duration(seconds)
    return ("%dh %02dm"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60)
end

local window, scroll, content, headers, rows
local currentView, sortKey, reversed
local function redraw()
    if not window or not window:IsShown() then return end
    local columns = views[currentView]
    local own = currentView == "race" and settings.race or snapshot()
    local list = { { name = player, record = own } }
    for name, record in pairs(guildStats or {}) do
        if name ~= player then list[#list + 1] = { name = name, record = record } end
    end
    table.sort(list, function(a, b)
        local av, bv = a.record[sortKey], b.record[sortKey]
        if av == bv then return a.name < b.name end
        if av == nil or bv == nil then return bv == nil end
        if reversed then return av < bv end
        return av > bv
    end)
    local columnWidth = (content:GetWidth() - 126) / #columns
    for i, header in ipairs(headers) do
        local column = columns[i]
        header:SetShown(column ~= nil)
        if column then
            header:SetPoint("TOPLEFT", window, "TOPLEFT", 140 + (i - 1) * columnWidth, -56)
            header:SetWidth(columnWidth)
            header:SetText(column[2])
        end
    end
    local rowHeight = currentView == "race" and 38 or 23
    content:SetHeight(math.max(scroll:GetHeight(), #list * rowHeight))
    for index, entry in ipairs(list) do
        local row = rows[index]
        if not row then
            row = CreateFrame("Frame", nil, content)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", 3, 0)
            row.name:SetWidth(120)
            row.name:SetJustifyH("LEFT")
            for i = 1, #views.stats do row[i] = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") end
            rows[index] = row
        end
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(index - 1) * rowHeight)
        row:SetSize(content:GetWidth(), rowHeight)
        row.name:SetText(isForever and entry.name or Ambiguate(entry.name, "none"))
        row.name:SetTextColor(1, entry.record == own and 0.82 or 1, entry.record == own and 0 or 1)
        for i = 1, #views.stats do
            local cell, column = row[i], columns[i]
            cell:SetShown(column ~= nil)
            if column then
                local key = column[1]
                local number = entry.record[key]
                local label = number and tostring(number) or "—"
                if number and key == "peakGold" then label = ("%.4f"):format(number / 10000)
                elseif number and key == "played" then label = duration(number)
                elseif currentView == "race" then
                    local reached = entry.record[column[3]]
                    if reached then label = (number and duration(number) or "—") .. "\n" .. date("%Y-%m-%d", reached) end
                end
                cell:SetPoint("LEFT", row, "LEFT", 126 + (i - 1) * columnWidth, 0)
                cell:SetWidth(columnWidth)
                cell:SetText(label)
            end
        end
        row:Show()
    end
    for i = #list + 1, #rows do rows[i]:Hide() end
end

local function show(view)
    currentView, sortKey, reversed = view, views[view][1][1], view == "race"
    if not window then
        window = CreateFrame("Frame", "ThreeCrownsGuildStats", UIParent, "BasicFrameTemplateWithInset")
        local width = math.min(900, UIParent:GetWidth() - 40)
        window:SetSize(width, 410)
        window:SetPoint("CENTER")
        window:SetFrameStrata("DIALOG")
        if window.TitleText then window.TitleText:SetText("ThreeCrownsGuild — Guild stats") end
        UISpecialFrames[#UISpecialFrames + 1] = window:GetName()
        scroll = CreateFrame("ScrollFrame", nil, window, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -81)
        scroll:SetPoint("BOTTOMRIGHT", -34, 28)
        content = CreateFrame("Frame", nil, scroll)
        content:SetWidth(width - 48)
        scroll:SetScrollChild(content)
        local note = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetPoint("BOTTOMLEFT", 14, 10)
        note:SetText("Use /tc share on or off to control guild stats and level race sharing.")
        for i, tab in ipairs({ { "stats", "Stats" }, { "deaths", "Deaths" }, { "race", "Level race" } }) do
            local button = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
            button:SetSize(100, 22)
            button:SetPoint("TOPLEFT", 14 + (i - 1) * 104, -29)
            button:SetText(tab[2])
            button:SetScript("OnClick", function() show(tab[1]) end)
        end
        headers, rows = {}, {}
        for i = 1, #views.stats do
            local header = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
            header:SetHeight(22)
            header:SetScript("OnClick", function()
                local key = views[currentView][i][1]
                if sortKey == key then reversed = not reversed else sortKey, reversed = key, currentView == "race" end
                redraw()
            end)
            headers[i] = header
        end
    end
    window:Show()
    scroll:SetVerticalScroll(0)
    redraw()
    if view == "stats" or view == "race" then requestPlayed() end
end

function addon.GuildMapStatus()
    if not settings then return end
    return ("Map dots %s. Position sharing %s. Guildmates sharing a recent position: %d."):format(
        db.mapPins == false and "off" or "on", settings.sharePosition and "on" or "off", addon.CountGuildPositions())
end

function addon.GuildCommand(command)
    if not settings then return false end
    if command == "" or views[command] then
        show(command == "" and "stats" or command)
    elseif command == "hide" or command == "show" then
        settings.sharePosition = command == "show"
        if command == "hide" then
            if send("H") then sentPosition = nil end
        else
            sharePosition()
        end
        print("[TCG] Guild position sharing " .. (settings.sharePosition and "on." or "off."))
    elseif command == "pins on" or command == "pins off" then
        db.mapPins = command == "pins on"
        addon.DrawPositions(db.mapPins, groupMembers)
        print("[TCG] Guild map dots " .. (db.mapPins and "on." or "off."))
    elseif command == "share on" or command == "share off" then
        settings.shareStats = command == "share on"
        if settings.shareStats then requestPlayed() end
        shareStats()
        print("[TCG] Guild stats sharing " .. (settings.shareStats and "on." or "off."))
    else
        return false
    end
    return true
end

local frame = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_GUILD_UPDATE",
    "GUILD_ROSTER_UPDATE", "GROUP_ROSTER_UPDATE", "CHAT_MSG_ADDON", "PLAYER_LEVEL_UP", "TIME_PLAYED_MSG" }) do frame:RegisterEvent(event) end

frame:SetScript("OnEvent", function(_, event, a, b, ...)
    if event == "PLAYER_LOGIN" then
        GuildFriendsDB = GuildFriendsDB or {}
        db = GuildFriendsDB
        db.characterStats, db.guildApiStats = db.characterStats or {}, db.guildApiStats or {}
        local name, realm = UnitFullName("player")
        playerRealm = GetNormalizedRealmName()
        local settingsKey = name .. "-" .. (realm and realm ~= "" and realm or playerRealm)
        player = isForever and GetUnitName("player") or settingsKey
        db.characterStats[settingsKey] = db.characterStats[settingsKey] or {}
        settings = db.characterStats[settingsKey]
        if settings.shareStats == nil then settings.shareStats = true end
        if settings.sharePosition == nil then settings.sharePosition = true end
        settings.race = settings.race or {}
        played = settings.apiPlayed
        RegisterPrefix(PREFIX)
        updateGuild()
        updateGroupMembers()
        C_Timer.NewTicker(8, sharePosition)
        C_Timer.NewTicker(60, function()
            if guild and settings.shareStats and not playedRequested then requestPlayed() end
            shareStats()
        end)
        C_Timer.NewTicker(0.25, function() addon.DrawPositions(db.mapPins ~= false, groupMembers) end)
        C_Timer.NewTicker(2, redraw)
    elseif not settings then
        return
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        updateGroupMembers()
        if event == "PLAYER_ENTERING_WORLD" then updateGuild() end
    elseif event == "PLAYER_GUILD_UPDATE" or event == "GUILD_ROSTER_UPDATE" then
        updateGuild()
    elseif event == "PLAYER_LOGOUT" then
        if sentPosition then send("H") end
        shareStats()
    elseif event == "PLAYER_LEVEL_UP" then
        if secret(a) or not milestones[a] then return end
        local milestone = milestones[a]
        if settings.race[milestone[3]] then return end
        settings.race[milestone[3]] = GetServerTime()
        requestPlayed(true)
        redraw()
    elseif event == "TIME_PLAYED_MSG" then
        if secret(a) or type(a) ~= "number" then return end
        played, settings.apiPlayed = a, a
        local level = UnitLevel("player")
        local milestone = not secret(level) and milestones[level]
        if milestone and settings.race[milestone[3]] and settings.race[milestone[1]] == nil
            and not secret(b) and type(b) == "number" and b >= 0 and b <= a then
            settings.race[milestone[1]] = a - b
        end
        if settings.shareStats then shareStats() end
        redraw()
    elseif event == "CHAT_MSG_ADDON" then
        local distribution, sender = ...
        if not guild or secret(a) or secret(b) or secret(sender) or secret(distribution) or a ~= PREFIX or distribution ~= "GUILD"
            or type(sender) ~= "string" or not sender:match("^[^|%c]+$") or type(b) ~= "string" or #b > 255 then return end
        sender = playerKey(sender)
        if sender == player then return end
        local kind = b:sub(1, 1)
        if kind == "M" or b == "H" then addon.ReceivePosition(sender, b)
        elseif b == "D" then guildStats[sender] = nil
        elseif kind == "A" or kind == "B" then receiveStats(sender, b, fields)
        elseif kind == "L" then receiveStats(sender, b, raceFields) end
    end
end)
