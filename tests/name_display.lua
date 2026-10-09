-- Run from the addon directory: lua tests/name_display.lua
local file = assert(io.open("ThreeCrownsGuild.lua", "r"))
local source = file:read("*a")
file:close()
local names = assert(source:match("local function nick%(name%)(.-)\nlocal function setNick"))
local rendering = assert(source:match("local function render%(rec%)(.-)\nrefreshChat ="))
local compile = loadstring or load
local db, nick, render = assert(compile(
    'local db = { nicks = {}, surname = true, tag = false }\n'
    .. 'local GREEN = ""\nlocal function classColor() return "" end\n'
    .. 'local function nick(name)' .. names
    .. '\nlocal function render(rec)' .. rendering
    .. '\nreturn db, nick, render'
))()

assert(nick("Anna Andersson") == "Anna Andersson")
assert(nick("Anna") == "Anna")
db.surname = false
assert(nick("Anna Andersson") == "Anna")
assert(nick("Åsa Öberg") == "Åsa")
db.nicks["Anna Andersson"] = "Ankan"
assert(nick("Anna Andersson") == "Anna(Ankan)")
assert(nick("Anna Svensson") == "Anna")
db.surname = true
assert(nick("Anna Andersson") == "Anna(Ankan)")
assert(render({ name = "Anna Andersson", msg = "Hej" })
    == "[TCG] |Hplayer:Anna Andersson|hAnna(Ankan)|h: Hej")
db.nicks["Anna Andersson"] = nil
assert(nick("Anna Andersson") == "Anna Andersson")
print("Name display checks passed.")
