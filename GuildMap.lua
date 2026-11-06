local _, addon = ...
local secret = issecretvalue or function() return false end
local positions = {}
local worldPins, minimapPins = {}, {}
local freeWorldPins, freeMinimapPins = {}, {}
local POSITION_TTL = 30

local function validPoint(x, y)
    return not secret(x) and not secret(y) and x and y and x >= 0 and x <= 1 and y >= 0 and y <= 1
end

local function playerPosition()
    if not C_Map or IsInInstance() then return end
    local map = C_Map.GetBestMapForUnit("player")
    if secret(map) or not map then return end
    local point = C_Map.GetPlayerMapPosition(map, "player")
    if secret(point) or not point then return end
    local x, y = point:GetXY()
    if validPoint(x, y) and (x ~= 0 or y ~= 0) then return map, x, y end
end

function addon.MapPacket()
    local map, x, y = playerPosition()
    local _, class = UnitClass("player")
    if map and not secret(class) and class then
        return ("M;%s;%d;%d;%d"):format(class, map, math.floor(x * 100000 + 0.5), math.floor(y * 100000 + 0.5))
    end
end

function addon.ReceivePosition(sender, message)
    if message == "H" then positions[sender] = nil; return end
    local class, map, x, y = message:match("^M;([A-Z]+);(%d+);(%d+);(%d+)$")
    map, x, y = tonumber(map), tonumber(x), tonumber(y)
    if not (class and RAID_CLASS_COLORS[class] and map > 0 and map <= 100000 and x <= 100000 and y <= 100000) then return end
    positions[sender] = { class = class, map = map, x = x / 100000, y = y / 100000, seen = GetTime() }
end

local function placeDot(pins, pool, parent, name, class, x, y, anchor)
    local dot = pins[name]
    if not dot then
        dot = table.remove(pool)
        if not dot then
            dot = CreateFrame("Frame", nil, parent)
            dot:SetSize(8, 8)
            dot:EnableMouseMotion(true)
            dot:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.playerName)
                GameTooltip:Show()
            end)
            dot:SetScript("OnLeave", function() GameTooltip:Hide() end)
            dot.texture = dot:CreateTexture(nil, "OVERLAY")
            dot.texture:SetAllPoints()
            dot.texture:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
        end
        pins[name] = dot
    end
    dot.playerName = Ambiguate(name, "none")
    local color = RAID_CLASS_COLORS[class]
    dot.texture:SetVertexColor(color.r, color.g, color.b)
    dot:ClearAllPoints()
    dot:SetPoint("CENTER", parent, anchor, x, y)
    dot:Show()
    dot.placed = true
end

local function releaseUnused(pins, pool)
    for name, dot in pairs(pins) do
        if dot.placed then
            dot.placed = false
        else
            dot:Hide()
            pins[name] = nil
            pool[#pool + 1] = dot
        end
    end
end

function addon.ClearPositions()
    wipe(positions)
end

function addon.CountGuildPositions()
    local count, now = 0, GetTime()
    for _, position in pairs(positions) do
        if now - position.seen < POSITION_TTL then count = count + 1 end
    end
    return count
end

function addon.DrawPositions(visible, groupMembers)
    visible = visible and next(positions) ~= nil
    local mapFrame, mini = WorldMapFrame, Minimap
    local canvas = visible and C_Map and mapFrame and mapFrame.GetCanvas and mapFrame:IsShown() and mapFrame:GetCanvas()
    local viewedMap = canvas and mapFrame:GetMapID()
    local radius = visible and mini and mini:IsShown() and C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
    local continent, north, west, facing
    if radius and radius > 0 and C_Map and C_Map.GetWorldPosFromMapPos then
        local map, x, y = playerPosition()
        local point
        if map then continent, point = C_Map.GetWorldPosFromMapPos(map, CreateVector2D(x, y)) end
        if not secret(point) and point then north, west = point:GetXY() end
        if secret(continent) or secret(north) or secret(west) then north, west = nil, nil end
        if GetCVar("rotateMinimap") == "1" then facing = GetPlayerFacing() end
    end

    local now = GetTime()
    for name, p in pairs(positions) do
        if now - p.seen >= POSITION_TTL then
            positions[name] = nil
        elseif (canvas or north) and not groupMembers[name] then
            local peerContinent, worldPoint
            if (north or viewedMap ~= p.map) and C_Map.GetWorldPosFromMapPos then
                peerContinent, worldPoint = C_Map.GetWorldPosFromMapPos(p.map, CreateVector2D(p.x, p.y))
                if secret(peerContinent) or secret(worldPoint) then peerContinent, worldPoint = nil, nil end
            end
            if viewedMap then
                local x, y
                if viewedMap == p.map then
                    x, y = p.x, p.y
                elseif worldPoint and C_Map.GetMapPosFromWorldPos then
                    local map, point = C_Map.GetMapPosFromWorldPos(peerContinent, worldPoint, viewedMap)
                    if not secret(map) and not secret(point) and map == viewedMap and point then x, y = point:GetXY() end
                end
                if validPoint(x, y) then
                    placeDot(worldPins, freeWorldPins, canvas, name, p.class, x * canvas:GetWidth(), -y * canvas:GetHeight(), "TOPLEFT")
                end
            end
            if north and worldPoint and continent == peerContinent then
                local peerNorth, peerWest = worldPoint:GetXY()
                if not secret(peerNorth) and not secret(peerWest) then
                    local x, y = (west - peerWest) / radius, (peerNorth - north) / radius
                    if not secret(facing) and facing then
                        local cos, sin = math.cos(facing), math.sin(facing)
                        x, y = x * cos + y * sin, y * cos - x * sin
                    end
                    if x * x + y * y <= 0.9 ^ 2 then
                        placeDot(minimapPins, freeMinimapPins, mini, name, p.class, x * mini:GetWidth() / 2, y * mini:GetHeight() / 2, "CENTER")
                    end
                end
            end
        end
    end
    releaseUnused(worldPins, freeWorldPins)
    releaseUnused(minimapPins, freeMinimapPins)
end
