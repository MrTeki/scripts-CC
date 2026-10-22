-- Tests de ccCapa : lecture des noms de loot capacitors et machine conseillée.

local H = require("harness")

local function load()
	local chunk = assert(loadfile("ccCapa.lua"))
	return chunk("--lib")
end

local C = load()
local LOOT = "enderio:loot_capacitor"

local function near(a, b, what)
	H.ok(math.abs(a - b) < 1e-6, (what or "") .. " : " .. tostring(a) .. " ~= " .. tostring(b))
end

H.case("ccCapa : capacitors craftables a niveau fixe", function()
	H.eq(C.parse("enderio:basic_capacitor", "Basic Capacitor").base, 1, "basic")
	H.eq(C.parse("enderio:double_layer_capacitor", "x").base, 2, "double")
	H.eq(C.parse("enderio:octadic_capacitor", "x").base, 3, "octadic")
	H.isNil(C.parse("enderio:basic_capacitor_bank", "Basic Capacitor Bank"), "pas une banque")
end)

H.case("ccCapa : Enhanced en qualite ET en base", function()
	local info = C.parse(LOOT, "Enhanced Hungry Enhanced Capacitor")
	near(info.base, 2, "base Enhanced [1.5, 2.5[")
	near(info.mods.energy_use, 3.25, "qualite Enhanced [3, 3.5[")
end)

H.case("ccCapa : bases courte et longue", function()
	near(C.parse(LOOT, "Nice Hot Capacitor").base, 1.25, "Capacitor")
	near(C.parse(LOOT, "Good Efficient Capacitor Dud").base, 0.75, "Dud")
	near(C.parse(LOOT, "Wonder Capacitor").base, 3, "sans bonus")
	H.eq(next(C.parse(LOOT, "Wonder Capacitor").mods), nil, "aucun bonus")
end)

H.case("ccCapa : nom sous forme de cles de traduction", function()
	local info = C.parse(LOOT, "enderio.capacitor.loot.modifier.premium "
		.. "enderio.capacitor.loot.type.burning_energy_generation "
		.. "enderio.capacitor.loot.base.impossible")
	near(info.base, 3.75, "base")
	near(info.mods.burning_energy_generation, 3.75, "bonus")
end)

H.case("ccCapa : nom inconnu (renomme a l'enclume)", function()
	H.isNil(C.parse(LOOT, "Mon super capa"), "renomme")
	H.isNil(C.parse(LOOT, "Shiny Hungry Capacitor"), "qualite inconnue")
end)

H.case("ccCapa : Hungry va au traitement, Hot au Stirling", function()
	local a = C.assess(C.parse(LOOT, "Premium Hungry Enhanced Capacitor"))
	H.eq(a.role, "traitement", "Hungry")
	near(a.stats.speed, 3.75 ^ 2, "vitesse = m²")
	H.ok(a.ratio > 1, "meilleur qu'un Octadic")

	local h = C.assess(C.parse(LOOT, "Premium Hot Enhanced Capacitor"))
	H.eq(h.role, "stirling", "Hot")
	near(h.stats.power, 3.75, "production = m")
end)

H.case("ccCapa : un faible bonus Hot sur une forte base reste au traitement", function()
	-- Production x1.25 au Stirling, mais vitesse x9 en machine grâce à la base.
	local a = C.assess(C.parse(LOOT, "Simple Hot Wonder Capacitor"))
	H.eq(a.role, "traitement", "role")
	near(a.ratio, 1, "autant qu'un Octadic")
end)

H.case("ccCapa : rapport classe du meilleur au moins bon", function()
	local lines = C.report({
		{ item = LOOT, displayName = "Nice Hungry Capacitor", count = 1, where = "chest:1" },
		{ item = LOOT, displayName = "Premium Hungry Wonder Capacitor", count = 1, where = "chest:2" },
		{ item = LOOT, displayName = "Good Hot Enhanced Capacitor", count = 2, where = "chest:3" },
		{ item = LOOT, displayName = "Truc", count = 1, where = "chest:4" },
	})
	local text = table.concat(lines, "\n")
	local best = text:find("Premium Hungry Wonder", 1, true)
	local worse = text:find("Nice Hungry Capacitor", 1, true)
	H.ok(best and worse and best < worse, "ordre")
	H.contains(text, "Stirling Generator", "groupe Stirling")
	H.contains(text, "Good Hot Enhanced Capacitor x2", "quantite")
	H.contains(text, "Non reconnus", "inconnus listes")
	H.contains(text, "chest:2", "emplacement")
end)

H.case("ccCapa : scan des inventaires voisins", function()
	local oldP, oldT = _G.peripheral, _G.turtle
	local chest = {
		list = function() return {
			[1] = { name = LOOT, count = 1 },
			[2] = { name = "minecraft:dirt", count = 64 },
			[5] = { name = "enderio:octadic_capacitor", count = 3 },
		} end,
		getItemDetail = function(slot)
			local names = { [1] = "Good Hungry Capacitor", [5] = "Octadic Capacitor" }
			local ids = { [1] = LOOT, [5] = "enderio:octadic_capacitor" }
			return { name = ids[slot], displayName = names[slot], count = slot == 5 and 3 or 1 }
		end,
	}
	_G.turtle = nil
	_G.peripheral = {
		getNames = function() return { "left", "monitor_0" } end,
		hasType = function(side, t) return side == "left" and t == "inventory" end,
		wrap = function(side) return side == "left" and chest or nil end,
	}
	local ok, found = pcall(C.scan)
	_G.peripheral, _G.turtle = oldP, oldT
	assert(ok, found)
	H.eq(#found, 2, "deux capacitors, pas la terre")
	local where = {}
	for _, e in ipairs(found) do where[e.where] = e end
	H.eq(where["left:1"].displayName, "Good Hungry Capacitor", "loot")
	H.eq(where["left:5"].count, 3, "octadic x3")
end)
