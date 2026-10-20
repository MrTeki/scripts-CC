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
	-- Champ planté partout : les graines en trop rentrent toutes au coffre.
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

-- Ordre de la spirale (tournée vers l'extérieur) : (0,1), (1,1), (1,0),
-- (1,-1), (0,-1)... Les tests qui dépendent de l'ordre s'y réfèrent.

local CARROTS = "minecraft:carrots"
local CARROT  = "minecraft:carrot"

local function carrots(age)
	return cropDef(CARROTS, age, { { name = CARROT, count = 3 } })
end

--- Culture de mod inconnue : seul le tag la désigne comme culture.
local function modCrop(name, age, drops)
	local def = cropDef(name, age, drops)
	def.tags = { ["minecraft:crops"] = true }
	return def
end

local function cellMem(sx, sy)
	return savedState().cells[sx .. "," .. sy]
end

H.case("ccFarmer : une case vide jamais vue cultivée reste vide", function()
	field()
	setCrop(0, 1, wheat(7))
	runWaiting()
	H.eq(getCrop(0, 1).state.age, 0, "case récoltée replantée")
	H.isNil(getCrop(1, 1), "case vide voisine : rien de semé")
	H.eq(chestSummary()[SEEDS], 1, "la graine en trop rentre au coffre")
	H.eq(cellMem(1, 1).kind, "empty", "case notée vide")
end)

H.case("ccFarmer : une case cultivée retrouvée vide est replantée avec SA graine", function()
	field()
	setCrop(0, 1, carrots(7))   -- premiere case : rapporte des carottes
	-- (1,1) a porté des carottes au passage précédent, elle est vide.
	writeState({ x = 0, y = 0, dir = 0, tours = 1, stats = {}, cells = {
		["1,1"] = { kind = "crop", block = CARROTS, seed = CARROT },
	} })
	runWaiting()
	H.eq(getCrop(1, 1).name, CARROTS, "replantée en carotte")
	H.eq(getCrop(1, 1).state.age, 0, "jeune pousse")
	H.eq(cellMem(1, 1).seed, CARROT, "mémoire conservée")
end)

H.case("ccFarmer : champ mixte, chaque case garde sa culture", function()
	field()
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(3)) end)
	setCrop(0, 1, carrots(7))
	setCrop(1, 1, wheat(7))
	setCrop(1, 0, carrots(7))
	runWaiting()
	H.eq(getCrop(0, 1).name, CARROTS, "carotte replantée en carotte")
	H.eq(getCrop(1, 1).name, WHEAT, "blé replanté en blé")
	H.eq(getCrop(1, 0).name, CARROTS, "carotte encore")
end)

H.case("ccFarmer : la mémoire suit un changement de culture", function()
	field()
	setCrop(0, 1, carrots(7))
	writeState({ x = 0, y = 0, dir = 0, tours = 1, stats = {}, cells = {
		["0,1"] = { kind = "crop", block = WHEAT, seed = SEEDS },
	} })
	runWaiting()
	H.eq(getCrop(0, 1).name, CARROTS, "replantée avec ce qui y poussait")
	H.eq(cellMem(0, 1).block, CARROTS, "mémoire mise à jour")
	H.eq(cellMem(0, 1).seed, CARROT, "nouvelle graine retenue")
end)

-- ---------------------------------------------------------------------------
-- Fruits, tiges, riz, tomates
-- ---------------------------------------------------------------------------

H.case("ccFarmer : melon cueilli, tige intacte, emplacement jamais semé", function()
	field()
	setCrop(0, 1, wheat(7))
	setCrop(1, 1, cropDef("minecraft:attached_melon_stem", nil, nil))
	setCrop(1, 0, cropDef("minecraft:melon", nil,
		{ { name = "minecraft:melon_slice", count = 5 } }))
	setCrop(1, -1, cropDef("minecraft:pumpkin_stem", 7, nil))
	runWaiting()

	H.eq(getCrop(1, 1).name, "minecraft:attached_melon_stem", "tige du melon intacte")
	H.eq(getCrop(1, -1).name, "minecraft:pumpkin_stem", "tige mûre intacte")
	H.isNil(getCrop(1, 0), "melon cueilli, rien replanté")
	H.eq(chestSummary()["minecraft:melon_slice"], 5, "tranches au coffre")
	H.eq(cellMem(1, 0).kind, "fruit", "emplacement de fruit retenu")
	H.eq(cellMem(1, 1).kind, "stem", "tige retenue")
end)

H.case("ccFarmer : fruit de mod reconnu à sa tige voisine", function()
	field()
	setCrop(0, 1, cropDef("mymod:attached_gourd_stem", nil, nil))
	setCrop(1, 1, cropDef("mymod:gourd", nil, { { name = "mymod:gourd", count = 1 } }))
	setCrop(-1, 0, cropDef("mymod:gourd", nil, { { name = "mymod:gourd", count = 1 } }))
	writeState({ x = 0, y = 0, dir = 0, tours = 1, stats = {}, cells = {
		["0,1"]  = { kind = "stem", block = "mymod:attached_gourd_stem" },
		["1,1"]  = { kind = "empty" },
		["-1,0"] = { kind = "empty" },
	} })
	runWaiting()
	H.isNil(getCrop(1, 1), "à côté d'une tige : cueilli")
	H.eq(getCrop(-1, 0).name, "mymod:gourd", "sans tige voisine : laissé")
end)

H.case("ccFarmer : riz, turtle surélevée, seules les panicules mûres sont coupées", function()
	-- Turtle en z = 0, panicules en z = -1, pied de riz dans l'eau en z = -2.
	field()
	local function rice(sx, sy, age)
		local x, y = at(sx, sy)
		mock.setBlock(x, y, -2, cropDef("farmersdelight:rice", 3, nil))
		mock.setBlock(x, y, -1, cropDef("farmersdelight:rice_panicles", age,
			{ { name = "farmersdelight:rice_panicle", count = 1 } }))
	end
	rice(0, 1, 3)
	rice(1, 1, 2)
	runWaiting()

	H.isNil(getCrop(0, 1), "panicule mûre coupée")
	H.eq(getCrop(1, 1).state.age, 2, "panicule verte laissée")
	local x, y = at(0, 1)
	H.eq(mock.getBlock(x, y, -2).name, "farmersdelight:rice", "le pied reste")
	H.eq(chestSummary()["farmersdelight:rice_panicle"], 1, "récolte au coffre")
end)

H.case("ccFarmer : tomates récoltées mûres, jeune plant jamais coupé", function()
	field()
	mock.addPlant("farmersdelight:tomato_seeds", "farmersdelight:budding_tomatoes")
	setCrop(0, 1, cropDef("farmersdelight:tomatoes", 3, {
		{ name = "farmersdelight:tomato", count = 2 },
		{ name = "farmersdelight:tomato_seeds", count = 1 },
	}))
	setCrop(1, 1, cropDef("farmersdelight:budding_tomatoes", 4, nil))
	runWaiting()
	H.eq(getCrop(0, 1).name, "farmersdelight:budding_tomatoes", "replantée en jeune plant")
	H.eq(getCrop(1, 1).state.age, 4, "jeune plant à l'âge max laissé")
	H.eq(chestSummary()["farmersdelight:tomato"], 2, "tomates au coffre")
end)

-- ---------------------------------------------------------------------------
-- Cultures inconnues : apprentissage
-- ---------------------------------------------------------------------------

H.case("ccFarmer : culture inconnue, âge et graine appris en récoltant", function()
	field()
	mock.addPlant("mymod:berry_seeds", "mymod:berries")
	-- Pas mûre : ne rend que sa graine.
	setCrop(0, 1, modCrop("mymod:berries", 2, { { name = "mymod:berry_seeds", count = 1 } }))
	-- Mûre : rend fruit et graine.
	setCrop(1, 1, modCrop("mymod:berries", 5, {
		{ name = "mymod:berry", count = 2 },
		{ name = "mymod:berry_seeds", count = 1 },
	}))
	-- Plus jeune que l'âge 5 une fois appris : laissée.
	setCrop(1, 0, modCrop("mymod:berries", 4, { { name = "mymod:berry_seeds", count = 1 } }))
	runWaiting()

	local L = savedState().learned["mymod:berries"]
	H.eq(L.known, true, "maturité connue")
	H.eq(L.max, 5, "âge appris sur la récolte à plusieurs objets")
	H.eq(L.seed, "mymod:berry_seeds", "graine apprise")
	H.eq(getCrop(0, 1).state.age, 0, "essai replanté")
	H.eq(getCrop(1, 1).state.age, 0, "récolte replantée")
	H.eq(getCrop(1, 0).state.age, 4, "culture plus jeune laissée")
	H.eq(chestSummary()["mymod:berry"], 2, "fruits au coffre")
end)

H.case("RÉGRESSION ccFarmer : culture mûre qui ne rend qu'un objet", function()
	-- ccFarm en concluait « pas mûre » et repoussait l'âge au-delà du maximum :
	-- la culture n'était plus jamais récoltée.
	field()
	mock.addPlant("mymod:root", "mymod:roots")
	setCrop(0, 1, modCrop("mymod:roots", 7, { { name = "mymod:root", count = 1 } }))
	runWaiting()
	local L = savedState().learned["mymod:roots"]
	H.eq(L.max, 7, "âge plafonné")
	H.eq(L.known, true, "retenu comme maturité")
	H.eq(L.seed, "mymod:root", "la récolte elle-même sert de graine")
end)

H.case("ccFarmer : culture inconnue sans croissance depuis le passage précédent", function()
	field()
	mock.addPlant("mymod:root", "mymod:roots")
	setCrop(0, 1, modCrop("mymod:roots", 4, { { name = "mymod:root", count = 1 } }))
	writeState({ x = 0, y = 0, dir = 0, tours = 1, stats = {},
		learned = { ["mymod:roots"] = { max = 6, known = false, seed = "mymod:root" } },
		cells = { ["0,1"] = { kind = "crop", block = "mymod:roots", seed = "mymod:root", age = 4 } } })
	runWaiting()
	local L = savedState().learned["mymod:roots"]
	H.eq(L.max, 4, "âge où la culture s'est arrêtée")
	H.eq(L.known, true, "maturité retenue")
	H.eq(getCrop(0, 1).state.age, 0, "récoltée et replantée")
end)

H.case("ccFarmer : un objet posé par erreur pendant l'apprentissage est repris", function()
	field()
	mock.addPlant("mymod:sprout", "mymod:sprouts")
	-- « apple » passe avant « sprout » : il est essayé en premier, et posé
	-- comme un bloc ordinaire.
	setCrop(0, 1, modCrop("mymod:sprouts", 7, {
		{ name = "mymod:apple", count = 1 },
		{ name = "mymod:sprout", count = 1 },
	}))
	runWaiting()
	H.eq(getCrop(0, 1).name, "mymod:sprouts", "la bonne graine est plantée")
	H.eq(savedState().learned["mymod:sprouts"].seed, "mymod:sprout", "graine retenue")
	H.eq(chestSummary()["mymod:apple"], 1, "la pomme est revenue au coffre")
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

-- ---------------------------------------------------------------------------
-- Reprise après un arrêt en plein mouvement
-- ---------------------------------------------------------------------------
-- Le chunk peut être déchargé entre un mouvement et la sauvegarde qui le
-- suit : la sauvegarde a alors un mouvement de retard. Avant le correctif,
-- la turtle finissait arrêtée à côté du coffre, « Coffre introuvable ».

--- Place la turtle du mock en (sx, sy) du script, cap `dir` du script (les
--- caps des deux repères ont la même numérotation).
local function putTurtle(sx, sy, dir)
	local t = mock.getTurtle()
	t.x, t.y = at(sx, sy)
	t.dir = dir
end

local function onChest()
	local t = mock.getTurtle()
	return t.x == 0 and t.y == 0 and t.z == 0
end

local function pendingState(x, y, dir, pending)
	writeState({ x = x, y = y, dir = dir, tours = 0, stats = {}, pending = pending })
end

H.case("RÉGRESSION ccFarmer : pas fait mais pas sauvegardé, le fuel tranche", function()
	field()
	setCrop(0, 1, wheat(7))
	-- Partie de (0,1) vers le coffre : le pas a eu lieu, la sauvegarde non.
	putTurtle(0, 0, 2)
	mock.getTurtle().fuel = 4999
	pendingState(0, 1, 2, { kind = "move", fuel = 5000 })
	runWaiting()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(savedState().tours, 1, "la tournée a eu lieu")
	H.eq(getCrop(0, 1).state.age, 0, "blé récolté")
	H.isNil(savedState().pending, "plus de mouvement en suspens")
end)

H.case("ccFarmer : pas annoncé mais pas fait, rien à corriger", function()
	field()
	putTurtle(0, 1, 2)
	pendingState(0, 1, 2, { kind = "move", fuel = 5000 })
	runWaiting()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(savedState().tours, 1, "la tournée a eu lieu")
end)

H.case("RÉGRESSION ccFarmer : quart de tour fait mais pas sauvegardé", function()
	field()
	putTurtle(0, 1, 1)
	pendingState(0, 1, 0, { kind = "turn", to = 1 })
	runWaiting()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(savedState().tours, 1, "la tournée a eu lieu")
end)

H.case("ccFarmer : quart de tour annoncé mais pas fait, essai puis correction", function()
	-- La première hypothèse (tour fait) est fausse : la turtle ne trouve pas
	-- le coffre, revient à son point de départ et essaie l'autre.
	field()
	eachCell(function(sx, sy) setCrop(sx, sy, wheat(3)) end)
	putTurtle(0, 1, 0)
	pendingState(0, 1, 0, { kind = "turn", to = 1 })
	runWaiting()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(savedState().tours, 1, "la tournée a eu lieu")
	H.eq(replanted(), 0, "rien d'immature n'a été coupé pendant l'essai")
end)

H.case("ccFarmer : fuel illimité, le pas incertain est vérifié au coffre", function()
	field()
	local t = mock.getTurtle()
	t.unlimitedFuel = true
	putTurtle(0, 1, 2)   -- le pas n'a PAS eu lieu
	pendingState(0, 1, 2, { kind = "move", fuel = "unlimited" })
	runWaiting()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(savedState().tours, 1, "la tournée a eu lieu")
end)

H.case("ccFarmer : position introuvable, la turtle s'arrête et le dit", function()
	field()
	mock.setBlock(0, 0, -1, nil)   -- plus de coffre : aucune hypothèse ne tient
	putTurtle(0, 1, 0)
	pendingState(0, 1, 0, { kind = "turn", to = 1 })
	runWaiting()
	local screen = {}
	for y = 1, 13 do screen[#screen + 1] = mock.screenLine(y) end
	H.contains(table.concat(screen, "\n"), "Position perdue", "alerte affichée")
	H.contains(table.concat(screen, "\n"), "recal", "remède indiqué")
	H.eq(savedState().tours, 0, "aucune tournée à l'aveugle")
end)

H.case("ccFarmer : recal remet la position à zéro et garde la mémoire", function()
	field()
	writeState({ x = 3, y = -2, dir = 1, tours = 4, stats = { [WHEAT] = 10 },
		inTour = true, idx = 12, pending = { kind = "turn", to = 2 },
		cells = { ["0,1"] = { kind = "crop", block = WHEAT, seed = SEEDS } } })
	run("recal")
	local st = savedState()
	H.eq(st.x, 0, "x") H.eq(st.y, 0, "y") H.eq(st.dir, 0, "cap")
	H.isNil(st.pending, "plus de mouvement en suspens")
	H.eq(st.inTour, false, "tournée abandonnée")
	H.eq(st.tours, 4, "compteur conservé")
	H.eq(st.cells["0,1"].seed, SEEDS, "mémoire du champ conservée")
	H.eq(mock.getTurtle().x, 0, "la turtle n'a pas bougé")
end)

H.case("RÉGRESSION ccFarmer : position décalée en tournée, le coffre n'est jamais miné", function()
	-- La turtle se croit en (1,-1), elle est en (1,0) : décalée d'une case.
	-- La case suivante (0,-1) l'amène en réalité AU-DESSUS du coffre. Sa
	-- mémoire y voyait un emplacement de fruit à côté d'une tige : l'ancienne
	-- version prenait le coffre pour un fruit et le minait.
	field({ chest = { [1] = { name = "minecraft:coal", count = 5 } } })
	setCrop(-1, -1, wheat(7))
	putTurtle(1, 0, 3)
	writeState({ x = 1, y = -1, dir = 3, tours = 0, stats = {},
		inTour = true, idx = 5, outward = true,
		cells = {
			["0,-1"] = { kind = "empty" },
			["1,-1"] = { kind = "stem", block = "minecraft:melon_stem" },
		} })
	runWaiting()

	local chest = mock.getBlock(0, 0, -1)
	H.ok(chest and chest.inventory, "le coffre est toujours là")
	H.eq(savedState().recals, 1, "recalage compté")
	H.ok(onChest(), "revenue sur le coffre en fin de tournée")
	H.eq(getCrop(-1, -1).state.age, 0, "la case suivante est la bonne")
end)

H.case("RÉGRESSION ccFarmer : une tige non attachée ne fait pas d'un bloc un fruit", function()
	field()
	setCrop(0, 1, cropDef("minecraft:melon_stem", 7, nil))
	setCrop(1, 1, "minecraft:torch")
	writeState({ x = 0, y = 0, dir = 0, tours = 1, stats = {}, cells = {
		["0,1"] = { kind = "stem", block = "minecraft:melon_stem" },
		["1,1"] = { kind = "empty" },
	} })
	runWaiting()
	H.eq(getCrop(1, 1).name, "minecraft:torch", "torche laissée en place")
end)

-- ---------------------------------------------------------------------------
-- Position décalée : vérification au coffre, recherche, journal
-- ---------------------------------------------------------------------------

local LOG, LOG_OLD = "ccfarmer.log", "ccfarmer.old"

local function wall(sx, sy)
	local x, y = at(sx, sy)
	mock.setBlock(x, y, 0, "minecraft:stone")
end

H.case("RÉGRESSION ccFarmer : décalée hors du champ contre un mur, elle se recale", function()
	-- Le cas rapporté : sauvegarde en (0,4) cap +x, case 53/80, turtle en
	-- réalité en (0,5) sur la bordure, un mur devant. L'ancienne version
	-- réessayait ce pas indéfiniment.
	field()
	wall(1, 5)
	setCrop(2, 4, wheat(7))
	putTurtle(0, 5, 1)
	writeState({ x = 0, y = 4, dir = 1, tours = 50, stats = {},
		inTour = true, idx = 53, outward = true, recals = 2 })
	runWaiting()

	local st = savedState()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(st.recals, 3, "recalage compté")
	H.eq(st.tours, 51, "tournée terminée")
	H.eq(getCrop(2, 4).state.age, 0, "la suite de la tournée est au bon endroit")
	H.contains(mock.getFile(LOG_OLD) or "", "recalage", "incident gardé au journal")
end)

H.case("ccFarmer : un vrai obstacle fait sauter la case, sans se croire perdue", function()
	field()
	wall(1, 1)                   -- deuxième case de la spirale
	setCrop(1, 0, wheat(7))      -- troisième case
	runWaiting()

	local st = savedState()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(st.tours, 1, "tournée terminée")
	H.isNil(st.recals, "aucun recalage : la position était bonne")
	H.eq(getCrop(1, 0).state.age, 0, "les autres cases sont faites")
	H.contains(mock.getFile(LOG_OLD) or "", "inaccessible", "case sautée au journal")
end)

H.case("ccFarmer : monde revenu en arrière, détecté au fuel et corrigé", function()
	-- La sauvegarde a vu le fuel à 4000 ; le monde rechargé dit 5000 : la
	-- turtle est revenue à un état plus ancien, ici une case avant le coffre.
	field()
	putTurtle(0, 1, 2)
	writeState({ x = 0, y = 0, dir = 2, tours = 3, stats = {}, fuel = 4000 })
	runWaiting()

	local st = savedState()
	H.ok(onChest(), "revenue sur le coffre")
	H.eq(st.recals, 1, "recalée")
	H.eq(st.tours, 4, "la tournée a eu lieu")
	H.contains(mock.getFile(LOG_OLD) or "", "arriere", "cause au journal")
end)

H.case("ccFarmer : sans incident, le journal est vidé au coffre", function()
	field()
	setCrop(0, 1, wheat(7))
	runWaiting()
	H.eq(fs.exists(LOG), false, "journal vidé")
	H.eq(fs.exists(LOG_OLD), false, "rien à garder")
end)
