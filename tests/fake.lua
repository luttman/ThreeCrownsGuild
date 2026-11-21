-- Fake WoW frames for the tests, so the real Skin.lua can run. Every capitalized method is a no-op
-- that returns another fake frame. Use it like this (from the addon folder):
--   local fake = dofile("tests/fake.lua").new({ globals = env, onText = function(text) end })
--   env.CreateFrame = fake.CreateFrame
local M = {}

function M.new(options)
    options = options or {}
    local globals = options.globals or _G
    local frames = {}
    local function Fake()
        local frame = { scripts = {}, hooks = {}, shown = true }
        return setmetatable(frame, { __index = function(_, key)
            if not key:match("^%u") then return nil end
            local numbers = { GetStringWidth = 100, GetWidth = 100, GetHeight = 400, GetScrollOffset = 0,
                GetMaxScrollRange = 0, GetNumMessages = 0 }
            if numbers[key] then return function() return numbers[key] end end
            if key == "GetChecked" then return function() return true end end
            if key == "GetPoint" then return function() return "CENTER", nil, "CENTER", 0, 0 end end
            if key == "GetName" then return function(self) return self.name end end
            if key == "GetText" then return function(self) return self.text or "" end end
            if key == "SetText" then
                return function(self, text)
                    self.text = text
                    if options.onText then options.onText(text) end
                end
            end
            if key == "SetScript" then return function(self, name, fn) self.scripts[name] = fn end end
            if key == "HookScript" then return function(self, name, fn) self.hooks[name] = fn end end
            if key == "IsShown" or key == "IsVisible" then return function(self) return self.shown end end
            if key == "Show" then return function(self) self.shown = true end end
            if key == "Hide" then return function(self) self.shown = false end end
            if key == "SetShown" then return function(self, shown) self.shown = shown and true or false end end
            if key == "GetFrameLevel" then return function(self) return self.level or 1 end end
            if key == "SetFrameLevel" then return function(self, level) self.level = level end end
            return function() return Fake() end
        end })
    end

    local M2 = { frames = frames }
    function M2.CreateFrame(_, name, parent)
        local frame = Fake()
        frame.name, frame.parent = name, parent
        frame.level = ((parent and parent.level) or 0) + 1
        if name then globals[name] = frame end
        frames[#frames + 1] = frame
        return frame
    end

    -- A button must sit above its window's drag area, or the drag area takes the click.
    function M2.checkLevels(window, label)
        assert(window and window.drag, label .. ": no drag area")
        assert(window.drag:GetFrameLevel() > window:GetFrameLevel(), label .. ": the drag area is not above its window")
        for _, frame in ipairs(frames) do
            if frame.parent == window and frame ~= window.drag and frame.scripts.OnClick then
                assert(frame:GetFrameLevel() > window.drag:GetFrameLevel(), label .. ": a button is under the drag area")
            end
        end
    end
    return M2
end

return M
