-- Tests de bout en bout : ccStairs.lua est chargé et exécuté en entier sous
-- le mock, comme le ferait shell.run en jeu.
--
-- Le turtle part en (0, 0, 0) face à +X, dans la roche. La marche de l'étage
-- k est posée en (k, 0, -k).

local H = require("harness")
local mock = require("ccMock")

local STAIRS = "minecraft:oak_stairs"
local TORCH  = "minecraft:torch"

package.preload["cc.completion"] = function()
	return { choice = function() return {} end }
end

local function run(...)
	local chunk = assert(loadfile("ccStairs.lua"))
	local vraiRead, vraiWrite = _G.read, io.write
	_G.read = function() return "yes" end
	io.write = function() end
	local ok, err = pcall(chunk, ...)
	_G.read, io.write = vraiRead, vraiWrite
	if not ok then error(err, 0) end
end

local function screenText()
	local out = {}
	for y = 1, 13 do out[#out + 1] = mock.screenLine(y) end
	return table.concat(out, "\n")
end

--- Roche autour du chemin, le turtle dans une case vide.
local function setup(opts)
	mock.reset(opts)
	mock.fill(0, -1, -6, 6, 1, 3, "minecraft:stone")
	mock.setBlock(0, 0, 0, nil)
end

local function stairAt(k)
	local b = mock.getBlock(k, 0, -k)
	return b and b.name
end

H.case("ccStairs : 4 étages, marches et torche", function()
	setup()
	mock.setSlot(1, STAIRS, 4)
	mock.setSlot(2, TORCH, 2)
	run("4")
	for k = 1, 4 do H.eq(stairAt(k), STAIRS, "marche " .. k) end
	H.eq(mock.getBlock(4, 0, 0).name, TORCH, "torche de l'étage 4")
end)

H.case("ccStairs : le ravitaillement ne brûle pas les escaliers", function()
	setup({ fuel = 0 })
	mock.setSlot(1, STAIRS, 2)
	mock.setSlot(2, "minecraft:coal", 1)
	run("2")
	H.eq(stairAt(1), STAIRS, "marche 1")
	H.eq(stairAt(2), STAIRS, "marche 2")
	H.eq(mock.inventorySummary()[2] ~= "minecraft:coal x1", true, "charbon brûlé")
end)

H.case("ccStairs : bloc incassable, arrêt propre", function()
	setup()
	mock.setBlock(1, 0, -1, { name = "minecraft:bedrock", unbreakable = true })
	mock.setSlot(1, STAIRS, 1)
	run("1")
	H.contains(screenText(), "Can't dig down minecraft:bedrock", "message")
end)

H.case("ccStairs : carburant illimité", function()
	setup({ unlimitedFuel = true })
	mock.setSlot(1, STAIRS, 3)
	mock.setSlot(2, TORCH, 2)
	run("3")
	for k = 1, 3 do H.eq(stairAt(k), STAIRS, "marche " .. k) end
end)

H.case("ccStairs : mob sur le chemin", function()
	setup()
	mock.spawnEntity(1, 0, 0, 3)
	mock.setSlot(1, STAIRS, 1)
	run("1")
	H.eq(stairAt(1), STAIRS, "marche 1")
end)

H.case("ccStairs : gravier qui retombe", function()
	setup()
	mock.fill(2, 0, 1, 2, 0, 3, { name = "minecraft:gravel", falling = true })
	mock.setSlot(1, STAIRS, 2)
	run("2")
	H.eq(stairAt(2), STAIRS, "marche 2")
	H.isNil(mock.getBlock(2, 0, 1), "dégagement au-dessus")
end)

H.case("ccStairs : une torchflower n'est pas une torche", function()
	setup()
	mock.setSlot(1, STAIRS, 4)
	mock.setSlot(2, "minecraft:torchflower", 2)
	run("4")
	H.isNil(mock.getBlock(4, 0, 0), "rien posé au plafond")
end)

H.case("ccStairs : nombre d'étages invalide", function()
	for _, value in ipairs({ "abc", "0", "-2", "1.5" }) do
		setup()
		mock.setSlot(1, STAIRS, 4)
		run(value)
		H.contains(screenText(), "whole number", "message pour " .. value)
		H.eq(mock.getTurtle().x, 0, "pas bougé pour " .. value)
	end
end)
