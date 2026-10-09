-- Run from the addon directory: lua tests/forever_only.lua
local file = assert(io.open("ThreeCrownsGuild.lua", "r"))
local source = file:read("*a")
file:close()
local guard = assert(source:match("^(.-)%-%- ThreeCrownsGuild:"))
local compile = loadstring or load
local check = assert(compile(guard .. "\nreturn true"))

for _, version in ipairs({ 11509, 15999, 17000, 20506, 30400, 40400, 50500, 120100 }) do
    GetBuildInfo = function() return "", "", "", version end
    assert(check() == nil, "Unsupported client passed: " .. version)
    -- The whole addon must exit before touching any other WoW API.
    assert(compile(source))()
end
for _, version in ipairs({ 16000, 16001, 16002, 16999 }) do
    GetBuildInfo = function() return "", "", "", version end
    assert(check() == true, "Forever client rejected: " .. version)
end
print("Forever-only checks passed.")
