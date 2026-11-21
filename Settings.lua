local _, addon = ...

-- { key, label, guild }. Booleans saved in GuildFriendsDB (addon.db, set up in ThreeCrownsGuild.lua).
-- Rows with guild = true live in GuildStats.lua (they are saved per character and send packets).
local options = {
    { "sync", "Forward my guild chat to the other guilds" },
    { "tag", "Show the guild tag in chat" },
    { "surname", "Show surnames" },
    { "echo", "Print shared chat in a chat window" },
    { "alsoDefault", "Also print it in the default chat window" },
    { "lfm", "Show looking-for-more notices" },
    { "sharePosition", "Share my map position with my guild", true },
    { "shareStats", "Share my stats with my guild", true },
    { "mapPins", "Show guild members on the map", true },
    { "minimapButton", "Show the minimap button" },
}
local perColumn = math.ceil(#options / 2)

local toggles, guildKeys = {}, {}
for _, row in ipairs(options) do guildKeys[row[1]] = row[3] end

function addon.GetSetting(key)
    if guildKeys[key] then return addon.GetGuildSetting(key) end
    return addon.db and addon.db[key] == true
end

function addon.SetSetting(key, value)
    if guildKeys[key] then
        addon.SetGuildSetting(key, value)
    else
        addon.db[key] = value
    end
    if toggles[key] then toggles[key]:SetChecked(value) end
    if key == "minimapButton" and addon.RefreshMinimap then addon.RefreshMinimap() end
    if addon.RefreshWindow then addon.RefreshWindow() end
end

-- The chat windows the player already has, plus the default one.
local function windows()
    local list = { { name = "Default chat window" } }
    for i = 1, NUM_CHAT_WINDOWS do
        local name = addon.ChatWindowName(i)
        if name then list[#list + 1] = { index = i, name = name } end
    end
    return list
end

local page
function addon.RefreshSettings() -- the page is shown: read every value again
    if not (page and page:IsVisible()) then return end
    for key, check in pairs(toggles) do check:SetChecked(addon.GetSetting(key)) end
    page.windows:SetEntries(windows())
end

-- Builds the settings inside `parent`, a page of the main window.
function addon.BuildSettings(parent)
    local skin = addon.Skin
    page = parent
    skin.SkinPicker(page, 0, 0)
    for index, row in ipairs(options) do
        local key = row[1]
        local check = skin.Check(page, row[2], function(value) addon.SetSetting(key, value) end)
        local column, line = math.floor((index - 1) / perColumn), (index - 1) % perColumn
        check:SetPoint("TOPLEFT", column * 372, -35 - line * 25)
        toggles[key] = check
    end
    local label = skin.Label(page, "GameFontHighlight", skin.colors.text)
    label:SetPoint("TOPLEFT", 0, -45 - perColumn * 25)
    label:SetText("Print chat in")
    page.windows = skin.List(page, 20, function(row, entry)
        row.text:SetText(entry.name)
        row.background:SetShown(entry.index == addon.db.chatWindow)
    end, function(row)
        row:SetScript("OnClick", function(self)
            addon.SetChatWindow(self.entry.index)
            addon.RefreshSettings()
        end)
    end)
    page.windows:SetPoint("TOPLEFT", 0, -65 - perColumn * 25)
    page.windows:SetSize(250, 120)
end
