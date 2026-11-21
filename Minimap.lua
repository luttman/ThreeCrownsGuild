-- The minimap button. Left-click opens or closes the window, right-click opens the settings tab,
-- and you drag it around the edge of the minimap. The angle is saved in addon.db.minimapAngle.
-- ponytail: the button follows a round minimap. A square minimap needs a different formula.
local _, addon = ...

local LOGO = "Interface\\AddOns\\ThreeCrownsGuild\\Media\\Logo" -- Media/Logo.tga, the project logo
local atan2 = math.atan2 or math.atan
local minimapButton

local function Place()
    local angle = math.rad(addon.db.minimapAngle or 200)
    local radius = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function Drag()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    addon.db.minimapAngle = math.deg(atan2(cy / scale - my, cx / scale - mx))
    Place()
end

local function Create()
    -- minimapButton is set only at the end, so a failure part way means the next call tries again
    local button = CreateFrame("Button", "ThreeCrownsGuildMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:SetClampedToScreen(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    -- the round gold ring, a dark disc, and the icon, like other minimap buttons
    local ring = button:CreateTexture(nil, "OVERLAY")
    ring:SetSize(53, 53)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetPoint("TOPLEFT")
    local disc = button:CreateTexture(nil, "BACKGROUND")
    disc:SetSize(20, 20)
    disc:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    disc:SetPoint("TOPLEFT", 7, -5)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture(LOGO)
    icon:SetPoint("TOPLEFT", 6, -5)
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then addon.OpenSettings() else addon.Toggle() end
    end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", Drag)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("ThreeCrownsGuild")
        GameTooltip:AddLine("Left-click: open or close the window", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Right-click: settings", 0.5, 0.5, 0.5)
        GameTooltip:AddLine("Drag: move the button", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton = button
    Place()
end

function addon.RefreshMinimap()
    if not addon.db then return end
    if addon.GetSetting("minimapButton") then
        if not minimapButton then Create() end
        minimapButton:Show()
    elseif minimapButton then
        minimapButton:Hide()
    end
end
