-- Tests de bout en bout : ccFarmer.lua est chargé et exécuté en entier sous
-- le mock, comme le ferait shell.run en jeu.
--
-- Repère : ccFarmer a le sien (dir 0 = +y, dir 1 = +x). Le turtle du mock
-- part en dir 0 = +X, donc le y du script est le X du mock et son x le Y.
-- Verticale : turtle en z = 0, coffre et cultures en z = -1, terre labourée
-- en z = -2.

local H = require("harness")
local mock = require("ccMock")

local SAVE   = "ccfarmer.dat"
local WHEAT  = "minecraft:wheat"
local SEEDS  = "minecraft:wheat_seeds"
local RADIUS = 4

--- sleep tel qu'en jeu : un minuteur, et la main rendue à l'ordonnanceur.
--- Celui du mock avance l'horloge sans céder, ce qui figerait la boucle
--- d'affichage de ccFarmer dans parallel.
local function realSleep(s)
	local id = os.startTimer(s or 0)
	repeat
		local _, got = os.pullEvent("timer")
	until got == id
end

local function run(...)
	local chunk = assert(loadfile("ccFarmer.lua"))
	local vraiPrint, vraiSleep = _G.print, _G.sleep
	local sorties = {}
	_G.print = function(...) sorties[#sorties + 1] = table.concat({ ... }, " ") end
	_G.sleep = realSleep
	local ok, err = pcall(chunk, ...)
	_G.print, _G.sleep = vraiPrint, vraiSleep
	if not ok then error(err, 0) end
	return sorties
end

--- La ferme ne s'arrête jamais d'elle-même : c'est le budget d'événements du
--- mock qui l'interrompt pendant l'attente entre deux tournées.
local function runWaiting(...)
	local ok, err = pcall(run, ...)
	if not ok and not tostring(err):find("budget", 1, true) then error(err, 0) end
	return ok
end

--- Case du champ, en coordonnées du script -> coordonnées du mock.
local function at(sx, sy) return sy, sx end

local function cropDef(name, age, drops)
	return { name = name, state = { age = age }, drops = drops }
end

local function wheat(age, n)
	return cropDef(WHEAT, age, {
		{ name = WHEAT, count = n or 1 },
		{ name = SEEDS, count = 2 },
	})
end

local function setCrop(sx, sy, def)
	local x, y = at(sx, sy)
	mock.setBlock(x, y, -1, def)
end

local function getCrop(sx, sy)
	local x, y = at(sx, sy)
	return mock.getBlock(x, y, -1)
end

--- Champ 9x9 labouré, eau sous le coffre central, turtle sur le coffre.
local function field(o)
	o = o or {}
	mock.install()
	mock.getTurtle().fuel = o.fuel or 5000
	mock.fill(-RADIUS, -RADIUS, -2, RADIUS, RADIUS, -2, "minecraft:farmland")
	mock.setBlock(0, 0, -2, "minecraft:water")
	mock.setChest(0, 0, -1, o.chest or {}, o.chestSize or 27)
end

--- Chaque case du champ hors centre.
local function eachCell(fn)
	for sx = -RADIUS, RADIUS do
		for sy = -RADIUS, RADIUS do
			if sx ~= 0 or sy ~= 0 then fn(sx, sy) end
		end
	end
end

local function chestSummary()
	local b = mock.getBlock(0, 0, -1)
	local out = {}
	for _, item in pairs(b.inventory) do
		out[item.name] = (out[item.name] or 0) + item.count
	end
	return out
end

local function savedState()
	local content = mock.getFile(SAVE)
	return content and textutils.unserialize(content)
end

local function writeState(st)
	mock.putFile(SAVE, textutils.serialize(st))
end

local function replanted()
	local n = 0
	eachCell(function(sx, sy)
		local b = getCrop(sx, sy)
		if b and b.name == WHEAT and b.state.age == 0 then n = n + 1 end
	end)
	return n
end

-- ---------------------------------------------------------------------------
-- Récolte
-- ---------------------------------------------------------------------------

H.case("ccFarmer : cultures mûres récoltées et replantées, le reste intact", function()
	field()
	-- Champ planté partout : sinon les graines en trop partent sur les cases
	-- vides (cas testé à part).
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(3)) end)
	setCrop(1, 0, wheat(7))
	setCrop(-2, 3, wheat(7))
	setCrop(0, -1, wheat(3))
	setCrop(2, 2, "minecraft:stone")
	runWaiting()

	H.eq(getCrop(1, 0).state.age, 0, "mûr : replanté")
	H.eq(getCrop(-2, 3).state.age, 0, "mûr sur l'anneau extérieur : replanté")
	H.eq(getCrop(0, -1).state.age, 3, "immature : laissé tel quel")
	H.eq(getCrop(2, 2).name, "minecraft:stone", "bloc inconnu : jamais cassé")

	local chest = chestSummary()
	H.eq(chest[WHEAT], 2, "le blé est déposé")
	H.eq(chest[SEEDS], 2, "les graines restantes aussi")
	H.eq(chest["minecraft:stone"], nil, "pas de pierre")

	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue sur le coffre (X)")
	H.eq(t.y, 0, "revenue sur le coffre (Y)")
	H.eq(t.z, 0, "jamais descendue")
	H.eq(savedState().tours, 1, "une tournée comptée")
end)

H.case("ccFarmer : la spirale couvre les 80 cases, sans rien perdre", function()
	field()
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(7)) end)
	runWaiting()

	H.eq(replanted(), 80, "toutes les cases replantées")
	H.eq(chestSummary()[WHEAT], 80, "80 blés au coffre")
	H.eq(#mock.groundItems(), 0, "rien n'est tombé au sol")
end)

H.case("ccFarmer : les cases vides reçoivent la dernière graine récoltée", function()
	field()
	setCrop(1, 0, wheat(7))   -- première case de la spirale
	setCrop(1, 1, wheat(3))
	runWaiting()

	-- 1 blé + 2 graines, une replantée sur place : il reste UNE graine, pour
	-- la première case vide rencontrée ensuite.
	local planted = 0
	eachCell(function(sx, sy)
		local b = getCrop(sx, sy)
		if b and b.state.age == 0 then planted = planted + 1 end
	end)
	H.eq(planted, 2, "case récoltée + une case vide")
	H.eq(chestSummary()[SEEDS], nil, "plus de graine en trop")
	H.eq(getCrop(1, 1).state.age, 3, "la culture immature n'est pas touchée")
end)

H.case("ccFarmer : betterave mûre à l'âge 3", function()
	field()
	setCrop(1, 0, cropDef("minecraft:beetroots", 3, {
		{ name = "minecraft:beetroot", count = 1 },
		{ name = "minecraft:beetroot_seeds", count = 2 },
	}))
	runWaiting()
	local b = getCrop(1, 0)
	H.eq(b.name, "minecraft:beetroots", "replantée en betterave")
	H.eq(b.state.age, 0, "jeune pousse")
end)

H.case("ccFarmer : inventaire plein, aller-retour au coffre en pleine tournée", function()
	-- 64 blés par case : l'inventaire déborde bien avant la fin du champ.
	field({ chestSize = 200 })
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(7, 64)) end)
	runWaiting()

	H.eq(replanted(), 80, "toutes les cases replantées")
	H.eq(chestSummary()[WHEAT], 80 * 64, "tout le blé au coffre")
	H.eq(#mock.groundItems(), 0, "rien n'est tombé au sol")
end)

-- ---------------------------------------------------------------------------
-- Carburant
-- ---------------------------------------------------------------------------

H.case("ccFarmer : recharge au coffre avant de partir", function()
	field({ fuel = 50, chest = {
		[1] = { name = "minecraft:dirt", count = 10 },
		[5] = { name = "minecraft:coal", count = 32 },
	} })
	setCrop(1, 0, wheat(7))
	runWaiting()

	-- 50 + 12 * 80 = 1010 >= 1000 : douze charbons, pas un de plus.
	H.eq(chestSummary()["minecraft:coal"], 20, "douze charbons brûlés, le reste rendu")
	H.eq(mock.inventorySummary()[1], false, "aucun charbon gardé à bord")
	H.ok(mock.getTurtle().fuel > 900, "plein fait, tournée payée")
	H.eq(getCrop(1, 0).state.age, 0, "la tournée a eu lieu")
end)

H.case("RÉGRESSION ccFarmer : coffre plein, fuel hors du slot 1", function()
	-- L'ancienne version ne trouvait pas de slot libre pour dégager le slot 1
	-- et attendait du fuel indéfiniment, alors qu'il y en avait.
	field({ fuel = 50, chestSize = 3, chest = {
		[1] = { name = WHEAT, count = 64 },
		[2] = { name = "minecraft:dirt", count = 64 },
		[3] = { name = "minecraft:coal", count = 16 },
	} })
	runWaiting()

	H.ok(mock.getTurtle().fuel >= 200, "recharge faite")
	local chest = chestSummary()
	H.eq(chest[WHEAT], 64, "le blé est rendu au coffre")
	H.eq(chest["minecraft:dirt"], 64, "la terre n'a pas bougé")
	H.eq(#mock.groundItems(), 0, "rien n'est tombé au sol")
end)

H.case("ccFarmer : sans fuel au coffre, attend sans partir", function()
	field({ fuel = 50 })
	setCrop(1, 0, wheat(7))
	runWaiting()
	H.eq(getCrop(1, 0).state.age, 7, "aucune tournée")
	local t = mock.getTurtle()
	H.eq(t.x + t.y, 0, "restée sur le coffre")
end)

-- ---------------------------------------------------------------------------
-- Reprise après redémarrage
-- ---------------------------------------------------------------------------

H.case("ccFarmer : reprise d'une tournée là où elle s'était arrêtée", function()
	field()
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(7)) end)
	writeState({ x = 0, y = 0, dir = 0, inTour = true, idx = 79, outward = true,
		tours = 0, stats = {} })
	runWaiting()

	H.eq(replanted(), 2, "seules les deux dernières cases sont traitées")
	H.eq(savedState().inTour, false, "tournée terminée")
end)

H.case("ccFarmer : un redémarrage pendant l'attente ne relance pas de tournée", function()
	-- Une turtle redémarre à chaque rechargement du chunk : sans échéance
	-- sauvegardée, chaque rechargement déclenchait une tournée.
	field()
	setCrop(1, 0, wheat(7))
	writeState({ x = 0, y = 0, dir = 0, inTour = false, idx = 1, outward = true,
		tours = 3, stats = {}, nextTourAt = os.epoch("utc") + 60 * 60 * 1000 })
	runWaiting()
	H.eq(getCrop(1, 0).state.age, 7, "attente respectée")
end)

H.case("ccFarmer : premier lancement, tournée immédiate", function()
	field()
	setCrop(1, 0, wheat(7))
	runWaiting()
	H.ok(savedState().nextTourAt ~= nil, "prochaine échéance posée")
	H.eq(getCrop(1, 0).state.age, 0, "tournée faite tout de suite")
end)

-- ---------------------------------------------------------------------------
-- Interface et démarrage
-- ---------------------------------------------------------------------------

H.case("ccFarmer : la touche t lance une tournée sans attendre", function()
	field()
	os.queueEvent("char", "t")
	runWaiting()
	H.eq(savedState().tours, 2, "tournée initiale + tournée demandée")
end)

H.case("ccFarmer : clic sur Tournee (écran couleur)", function()
	field()
	-- Barre du bas : " Pause " en 1-7, " Tournee " en 9-17.
	os.queueEvent("mouse_click", 1, 12, 13)
	runWaiting()
	H.eq(savedState().tours, 2, "tournée demandée par clic")
end)

H.case("ccFarmer : startup posé au lancement, retiré par Quitter", function()
	field()
	mock.putFile("startup.lua", "print('a moi')\n")
	os.queueEvent("char", "q")
	local sorties = run()

	H.contains(table.concat(sorties, "\n"), "arrete", "message d'arrêt")
	H.eq(mock.getFile("startup.lua"), "print('a moi')\n", "startup de l'utilisateur rendu")
	H.eq(fs.exists("startup.old"), false, "plus d'archive")
	H.ok(fs.exists(SAVE), "état conservé pour une reprise manuelle")
end)

H.case("ccFarmer : startup en place tant que la ferme tourne", function()
	field()
	runWaiting()
	H.contains(mock.getFile("startup.lua") or "", "ccFarmer", "reprise auto installée")
end)

H.case("ccFarmer : del oublie l'état et le startup", function()
	field()
	writeState({ x = 0, y = 0, dir = 0, tours = 5, stats = {} })
	mock.putFile("startup.lua", 'shell.run("ccFarmer")\n')
	run("del")
	H.eq(fs.exists(SAVE), false, "sauvegarde supprimée")
	H.eq(fs.exists("startup.lua"), false, "startup retiré")
	H.eq(mock.getTurtle().x, 0, "la turtle n'a pas bougé")
end)

H.case("ccFarmer : écran noir et blanc, raccourci en négatif", function()
	field()
	mock.setColour(false)
	runWaiting()

	H.eq(mock.screenLine(13), " Pause   Tournee   Quitter", "boutons sans crochets")
	local WHITE, BLACK = colors.white, colors.black
	H.eq(mock.screenBg(2, 13), BLACK, "P en négatif")
	H.eq(mock.screenBg(3, 13), WHITE, "le reste du bouton en blanc")
	H.eq(mock.screenBg(10, 13), BLACK, "T en négatif")
	H.eq(mock.screenBg(20, 13), BLACK, "Q en négatif")
end)

H.case("ccFarmer : écran couleur, boutons colorés sans négatif", function()
	field()
	runWaiting()
	H.eq(mock.screenBg(2, 13), colors.orange, "Pause en orange")
	H.eq(mock.screenBg(10, 13), colors.lime, "Tournee en vert")
	H.eq(mock.screenBg(20, 13), colors.red, "Quitter en rouge")
end)
