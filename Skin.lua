-- Shared look for the Easy* addon family. Keep this file identical in every addon,
-- and copy improvements back into the template.
-- Call Skin.Apply() before you use colors outside a Skin widget, for example in a Surface.
-- It sets addon.Skin = { colors, Apply, Surface, Fill, TextColor, Label, Button, Window, Tabs, Check, List,
-- SkinPicker }.
-- It needs addon.db (see Settings.lua), which it reads lazily. The skin choice is addon.db.skin.
local addonName, addon = ...

local colors = {
    background = { 0.075, 0.085, 0.095 },
    panel = { 0.095, 0.105, 0.115 },
    button = { 0.13, 0.15, 0.17 },
    border = { 0.22, 0.25, 0.28 },
    group = { 0.15, 0.17, 0.19 },
    selected = { 0.07, 0.22, 0.32 },
    banner = { 0.18, 0.15, 0.075 },
    accent = { 0.33, 0.77, 1 },
    bar = { 0.07, 0.51, 0.79 },
    text = { 0.94, 0.95, 0.97 },
    muted = { 0.66, 0.71, 0.76 },
    gold = { 1, 0.83, 0.35 },
    gain = { 0.40, 0.88, 0.60 },
    loss = { 1, 0.47, 0.47 },
}
local fontSizes = { GameFontNormalLarge = 16, GameFontHighlight = 13, GameFontNormal = 13 }
local blizzard, fontFile, fontFlags

-- Everything drawn in the accent color goes through Paint, so it can be redrawn when
-- EllesmereUI's accent changes.
local repaint = {}
local function Paint(apply)
    repaint[#repaint + 1] = apply
    apply()
end

-- Three looks share one layout: Blizzard templates, EllesmereUI's theme, or the built-in flat theme.
-- ponytail: the skin is read once when the first window is built, so a change needs /reload.
-- Settings.lua puts the selector (Skin.SkinPicker) in the settings window and asks for the reload.
-- The skin in use: the saved choice ("flat", "ellesmere", or "blizzard"). With no choice saved it
-- is EllesmereUI's when that is installed, else flat. A saved EllesmereUI choice falls back to flat
-- when EllesmereUI is gone.
local function ResolveSkin()
    local choice = addon.db and addon.db.skin
    if choice == "blizzard" or choice == "flat" then return choice end
    if (choice == nil or choice == "ellesmere") and EllesmereUI then return "ellesmere" end
    return "flat"
end

local function ApplySkin()
    if fontFlags then return end
    local choice = ResolveSkin()
    blizzard = choice == "blizzard"
    local overrides
    if blizzard then
        fontFile, fontFlags = nil, ""
        overrides = {
            background = { 0, 0, 0, 0.3 }, panel = { 0, 0, 0, 0.3 }, group = { 1, 1, 1, 0.07 },
            selected = { 1, 0.82, 0, 0.22 }, banner = { 1, 0.82, 0, 0.12 }, accent = { 1, 0.82, 0 },
            bar = { 0.25, 0.5, 0.85 }, text = { 1, 1, 1 }, muted = { 0.62, 0.62, 0.62 }, gold = { 1, 0.82, 0 },
        }
    elseif choice == "ellesmere" then
        local accent = EllesmereUI.ACCENT_COLOR or EllesmereUI.ELLESMERE_GREEN or { r = 12 / 255, g = 210 / 255, b = 157 / 255 }
        local r, g, b = accent.r, accent.g, accent.b
        local ok, path = pcall(EllesmereUI.GetFontPath)
        local flagged, flags = pcall(EllesmereUI.GetFontOutlineFlag)
        fontFile = ok and type(path) == "string" and path ~= "" and path or ChatFontNormal:GetFont()
        fontFlags = flagged and type(flags) == "string" and flags or ""
        overrides = {
            background = { 0.08, 0.08, 0.08, 0.92 }, panel = { 0.04, 0.04, 0.04, 0.85 },
            button = { 0.11, 0.11, 0.11 }, border = { 0.20, 0.20, 0.20 }, group = { 0.14, 0.14, 0.14 },
            selected = { r * 0.3, g * 0.3, b * 0.3 }, banner = { 0.14, 0.14, 0.14 },
            accent = { r, g, b }, bar = { r, g, b }, text = { 1, 1, 1 }, muted = { 0.6, 0.6, 0.6 },
        }
        if EllesmereUI.RegAccent then
            EllesmereUI.RegAccent({ type = "callback", fn = function(red, green, blue)
                for _, key in ipairs({ "accent", "bar" }) do
                    colors[key][1], colors[key][2], colors[key][3] = red, green, blue
                end
                colors.selected[1], colors.selected[2], colors.selected[3] = red * 0.3, green * 0.3, blue * 0.3
                for _, apply in ipairs(repaint) do apply() end
                -- Rows and tabs take their colors when they are drawn.
                if addon.RefreshWindow then addon.RefreshWindow() end
            end })
        end
    else
        -- The chat font is Arial Narrow on Latin clients and a font with the right glyphs elsewhere.
        fontFile, fontFlags = ChatFontNormal:GetFont(), ""
    end
    for key, color in pairs(overrides or {}) do colors[key] = color end
end

local function TextColor(region, color)
    region:SetTextColor(unpack(color))
end

local function Fill(texture, color)
    texture:SetColorTexture(unpack(color))
end

local function Surface(parent, layer, color)
    local texture = parent:CreateTexture(nil, layer)
    texture:SetAllPoints()
    Fill(texture, color)
    return texture
end

local function Label(parent, font, color)
    ApplySkin()
    local text = parent:CreateFontString(nil, "OVERLAY", font)
    if fontFile then text:SetFont(fontFile, fontSizes[font] or 12, fontFlags) end
    TextColor(text, color)
    return text
end

-- Frame levels are strict, never equal: a window is at level L, its drag area at L + 1, and its
-- buttons at L + 3. Two frames at one level have no defined order, so one of them may take the mouse.
local function Button(parent, text, width, action)
    ApplySkin()
    if blizzard then
        local template = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        template:SetFrameLevel(parent:GetFrameLevel() + 3)
        template:SetSize(width, 22)
        template:SetText(text)
        template.label = template:GetFontString()
        template:SetScript("OnClick", action)
        return template
    end
    local button = CreateFrame("Button", nil, parent)
    button:SetFrameLevel(parent:GetFrameLevel() + 3)
    button:SetSize(width, 22)
    button:EnableMouse(true)
    button:RegisterForClicks("LeftButtonUp")
    Surface(button, "BACKGROUND", colors.border)
    button.inner = button:CreateTexture(nil, "BORDER")
    button.inner:SetPoint("TOPLEFT", 1, -1)
    button.inner:SetPoint("BOTTOMRIGHT", -1, 1)
    Fill(button.inner, colors.button)
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints(button.inner)
    Paint(function() Fill(hover, colors.accent) end)
    hover:SetAlpha(0.12)
    button.label = Label(button, "GameFontNormalSmall", colors.text)
    button.label:SetPoint("CENTER")
    button.label:SetText(text)
    button:SetScript("OnClick", action)
    button:SetScript("OnEnable", function() TextColor(button.label, colors.text) end)
    button:SetScript("OnDisable", function() TextColor(button.label, colors.muted) end)
    return button
end

-- A themed window with a title, a close button, and a drag area. The position is saved in addon.db.
-- Content starts at y = -40 - window.top. Settings, dialogs, and the main window all use it.
-- window.close is the close button and window.blizzard says which look is active.
local function Window(name, width, height, title, strata)
    ApplySkin()
    local frame = CreateFrame("Frame", name, UIParent, blizzard and "BasicFrameTemplateWithInset" or nil)
    frame:Hide()
    frame:SetSize(width, height)
    frame:SetFrameStrata(strata or "FULLSCREEN_DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame.blizzard, frame.top = blizzard, blizzard and 22 or 0

    local saved = addon.db and addon.db.positions and addon.db.positions[name]
    if saved then
        frame:SetPoint(saved.point, UIParent, saved.relative, saved.x, saved.y)
    else
        frame:SetPoint("CENTER")
    end

    -- The drag area is the title strip, above the window and below every button (see Button).
    -- The empty background of the window drags it too, so there is no spot to miss.
    local drag = CreateFrame("Frame", nil, frame)
    frame.drag = drag
    drag:SetFrameLevel(frame:GetFrameLevel() + 1)
    drag:SetPoint("TOPLEFT")
    drag:SetPoint("TOPRIGHT", blizzard and -28 or -40, 0)
    drag:SetHeight(blizzard and 22 or 34)
    drag:EnableMouse(true)
    local function StartDrag() if not InCombatLockdown() then frame:StartMoving() end end
    local function StopDrag()
        frame:StopMovingOrSizing()
        if not addon.db then return end
        local point, _, relative, x, y = frame:GetPoint()
        addon.db.positions = addon.db.positions or {}
        addon.db.positions[name] = { point = point, relative = relative, x = x, y = y }
    end
    for _, region in ipairs({ frame, drag }) do
        region:RegisterForDrag("LeftButton")
        region:SetScript("OnDragStart", StartDrag)
        region:SetScript("OnDragStop", StopDrag)
    end

    if blizzard then
        local backdrop = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        backdrop:SetPoint("TOPLEFT", 4, -4)
        backdrop:SetPoint("BOTTOMRIGHT", -4, 4)
        backdrop:SetColorTexture(0.055, 0.063, 0.073, 1)
        frame.title = frame.TitleText
        frame.close = frame.CloseButton
    else
        local edge = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
        edge:SetPoint("TOPLEFT", -1, 1)
        edge:SetPoint("BOTTOMRIGHT", 1, -1)
        edge:SetColorTexture(colors.border[1], colors.border[2], colors.border[3], 1)
        local backdrop = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
        backdrop:SetAllPoints()
        backdrop:SetColorTexture(colors.background[1], colors.background[2], colors.background[3], 1)
        frame.title = Label(frame, "GameFontNormalLarge", colors.accent)
        Paint(function() TextColor(frame.title, colors.accent) end)
        frame.title:SetPoint("TOPLEFT", 10, -11)
        frame.close = Button(frame, "X", 25, function() frame:Hide() end)
        frame.close:SetPoint("TOPRIGHT", -8, -7)
    end
    frame.title:SetText(title)
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = name end
    return frame
end

-- A row of buttons where one is active. defs = { { key, text, width }, ... }.
-- Returns the buttons by key and a Select(key, silent) function. A click calls Select(key),
-- which styles the tabs and calls onSelect(key). Select(key, true) only styles them, so a
-- refresh function can call it without a loop.
local function Tabs(parent, defs, onSelect, x, y)
    local tabs, previous = {}, nil
    local function Select(key, silent)
        for tabKey, tab in pairs(tabs) do
            local active = tabKey == key
            if tab.inner then
                Fill(tab.inner, active and colors.selected or colors.button)
                TextColor(tab.label, active and colors.accent or colors.text)
            elseif active then
                tab:LockHighlight()
            else
                tab:UnlockHighlight()
            end
        end
        if not silent then onSelect(key) end
    end
    for _, def in ipairs(defs) do
        local key, text, width = unpack(def)
        local tab = Button(parent, text, width, function() Select(key) end)
        if previous then tab:SetPoint("LEFT", previous, "RIGHT", 4, 0) else tab:SetPoint("TOPLEFT", x, y) end
        if parent.drag then tab:SetFrameLevel(parent.drag:GetFrameLevel() + 2) end
        tabs[key] = tab
        previous = tab
    end
    return tabs, Select
end

local function Check(parent, text, action)
    local check = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    check:SetFrameLevel(parent:GetFrameLevel() + 3)
    check:SetSize(22, 22)
    local label = Label(check, "GameFontHighlight", colors.text)
    label:SetPoint("LEFT", check, "RIGHT", 6, 0)
    label:SetText(text)
    check:SetHitRectInsets(0, -label:GetStringWidth() - 8, 0, 0)
    check:SetScript("OnClick", function(self) action(self:GetChecked() == true) end)
    return check
end

-- A list with pooled rows and a slim scrollbar. Set the size and position, then call
-- list:SetEntries(table). fill(row, entry) writes one row. create(row) runs once per row,
-- to add controls or scripts. Each row has row.text, row.value, row.background (shown by
-- you, for the selected row) and row.entry.
local function List(parent, rowHeight, fill, create)
    local list = CreateFrame("Frame", nil, parent)
    Surface(list, "BACKGROUND", colors.panel)
    list.rows, list.entries, list.offset = {}, {}, 0
    list:EnableMouseWheel(true)

    local slider = CreateFrame("Slider", nil, list)
    slider:SetOrientation("VERTICAL")
    slider:SetPoint("TOPRIGHT", -2, -2)
    slider:SetPoint("BOTTOMRIGHT", -2, 2)
    slider:SetWidth(6)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    local thumb = slider:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(6, 24)
    Paint(function() Fill(thumb, colors.bar) end)
    slider:SetThumbTexture(thumb)
    slider:EnableMouse(true)

    local function NewRow(index)
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(rowHeight)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * rowHeight)
        row:SetPoint("TOPRIGHT", -12, -(index - 1) * rowHeight)
        row.background = Surface(row, "BACKGROUND", colors.selected)
        row.background:Hide()
        local highlight = Surface(row, "HIGHLIGHT", colors.accent)
        Paint(function() Fill(highlight, colors.accent) end)
        highlight:SetAlpha(0.16)
        row.value = Label(row, "GameFontHighlightSmall", colors.text)
        row.value:SetPoint("RIGHT", -6, 0)
        row.value:SetJustifyH("RIGHT")
        row.text = Label(row, "GameFontHighlightSmall", colors.text)
        row.text:SetPoint("LEFT", 6, 0)
        row.text:SetPoint("RIGHT", row.value, "LEFT", -5, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        if create then create(row) end
        return row
    end

    function list:Draw()
        local visible = math.max(1, math.floor(self:GetHeight() / rowHeight))
        local maximum = math.max(0, #self.entries - visible)
        self.offset = math.min(self.offset, maximum)
        slider.syncing = true
        slider:SetMinMaxValues(0, maximum)
        slider:SetValue(self.offset)
        slider.syncing = false
        slider:SetShown(maximum > 0)
        for index = 1, visible do
            local entry = self.entries[index + self.offset]
            local row = self.rows[index]
            if entry then
                row = row or NewRow(index)
                self.rows[index] = row
                row.entry = entry
                fill(row, entry)
                row:Show()
            elseif row then
                row:Hide()
            end
        end
        for index = visible + 1, #self.rows do self.rows[index]:Hide() end
    end

    function list:SetEntries(entries)
        self.entries = entries
        self:Draw()
    end

    list:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta * 3)
        self:Draw()
    end)
    slider:SetScript("OnValueChanged", function(_, value)
        if not slider.syncing then
            list.offset = math.floor(value)
            list:Draw()
        end
    end)
    list:SetScript("OnSizeChanged", list.Draw)
    return list
end

-- The skin selector for the settings window: a "Skin" label and three tabs. A pick is saved in
-- addon.db.skin and asks for a reload, because the look is read once.
local function SkinPicker(parent, x, y)
    local popup = addonName:upper() .. "_SKIN_RELOAD"
    StaticPopupDialogs[popup] = {
        text = "The skin changes after a reload. Reload now?", button1 = YES, button2 = NO,
        OnAccept = ReloadUI, timeout = 0, whileDead = true, hideOnEscape = true,
        preferredIndex = 3, -- to avoid interfering with Blizzard UI popups
    }
    local label = Label(parent, "GameFontHighlight", colors.text)
    label:SetPoint("TOPLEFT", x, y - 5)
    label:SetText("Skin")
    local tabs, Select
    tabs, Select = Tabs(parent, {
        { "flat", "Flat", 60 },
        { "ellesmere", EllesmereUI and "EllesmereUI" or "EllesmereUI (not installed)", EllesmereUI and 96 or 170 },
        { "blizzard", "Blizzard", 76 },
    }, function(key)
        if key == ResolveSkin() or (key == "ellesmere" and not EllesmereUI) then
            Select(ResolveSkin(), true)
            return
        end
        addon.db.skin = key
        Select(key, true)
        print("|cff54c4ff" .. addonName .. "|r: the skin changes after a reload. Type /reload to apply it.")
        -- Settings windows sit in FULLSCREEN_DIALOG, above the popup's own DIALOG strata, and both
        -- open in the middle of the screen. Without this the popup is hidden behind the window.
        local dialog = StaticPopup_Show(popup)
        if dialog then
            dialog:SetFrameStrata("FULLSCREEN_DIALOG")
            dialog:Raise()
        end
    end, x + 40, y)
    Select(ResolveSkin(), true)
end

addon.Skin = {
    colors = colors, Apply = ApplySkin, Surface = Surface, Fill = Fill, TextColor = TextColor,
    Label = Label, Button = Button, Window = Window, Tabs = Tabs, Check = Check, List = List,
    SkinPicker = SkinPicker,
}
