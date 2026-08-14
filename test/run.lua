-- Lanceur de tests. Depuis la racine du depot :
--     lua test/run.lua
--
-- Les tests s'executent sous Lua 5.4 standard, hors Minecraft : ccMock fournit
-- fs, textutils, turtle, term et os.

local here = (arg and arg[0] or "test/run.lua"):match("^(.*)[/\\][^/\\]*$") or "."
package.path = table.concat({
	here .. "/../apis/?.lua",
	here .. "/?.lua",
	package.path,
}, ";")

-- Ajouter ici chaque nouveau fichier de test.
local MODULES = {
	"test_ccSave",
}

local H = require("harness")

for _, name in ipairs(MODULES) do
	require(name)
end

print(string.format("%d cas, %d module(s)\n", #H.cases, #MODULES))
os.exit(H.run() and 0 or 1)
