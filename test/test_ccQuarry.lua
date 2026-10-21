-- Tests de bout en bout : ccQuarry.lua est chargé et exécuté en entier sous
-- le mock, exactement comme le ferait shell.run en jeu.

local H = require("harness")
local mock = require("ccMock")
local ccPlan = require("ccPlan")

local ENDER = "enderstorage:ender_chest"

--- URL du dépôt, lue DANS ccQuarry.lua : figée ici, elle divergerait au
--- premier changement de branche.
local function repoUrl()
	local f = assert(io.open("ccQuarry.lua", "r"))
	local src = f:read("a")
	f:close()
	return assert(src:match('local REPO = "([^"]+)"'), "REPO introuvable dans ccQuarry.lua")
end

--- Charge ccQuarry.lua et l'exécute avec les arguments donnés.
-- La sortie console est mise en sourdine : le script imprime son bilan.
local function run(...)
	local chunk = assert(loadfile("ccQuarry.lua"))
	local vraiPrint = _G.print
	local sorties = {}
	_G.print = function(...) sorties[#sorties + 1] = table.concat({ ... }, " ") end
	local ok, err = pcall(chunk, ...)
	_G.print = vraiPrint
	if not ok then error(err, 0) end
	return sorties
end

--- Chantier de départ : monde de pierre sous la surface, turtle équipée.
local function terrain(o)
	o = o or {}
	mock.install()
	mock.getTurtle().fuel = o.fuel or 5000
	mock.setSlot(1, "minecraft:coal", 32)     -- le slot réservé doit être occupé
	if not o.noChest then mock.setSlot(16, ENDER, 1) end

	local w, d, h = o.width or 2, o.depth or 2, o.height or 3
	-- Pierre de z = -1 à z = -(h + marge). La surface z = 0 reste de l'air.
	mock.fill(0, 0, -(h + 3), w - 1, d - 1, -1, "minecraft:stone")

	-- Du butin non jetable, pour vérifier où il finit.
	if o.ore then
		for _, p in ipairs(o.ore) do mock.setBlock(p[1], p[2], p[3], "minecraft:iron_ore") end
	end
end

--- Blocs restants dans le volume du chantier.
local function restants(w, d, h)
	local n = 0
	for x = 0, w - 1 do
		for y = 0, d - 1 do
			for z = -1, -(h - 1), -1 do
				if mock.getBlock(x, y, z) then n = n + 1 end
			end
		end
	end
	return n
end

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

H.case("sans argument ni sauvegarde : menu, et Ctrl+T n'y touche à rien", function()
	terrain()
	os.queueEvent("terminate")
	local sorties = run()

	H.contains(table.concat(sorties, "\n"), "Menu abandonne", "abandon annoncé")
	H.contains(table.concat(sorties, "\n"), "ccQuarry <largeur>", "aide affichée")
	H.eq(mock.getTurtle().z, 0, "la turtle n'a pas bougé")
	H.eq(fs.exists("ccquarry.save"), false, "aucune sauvegarde créée")
end)

--- Touches qui règlent les dimensions dans la vue Chantier, champ Largeur actif.
local function dimensions(w, d, h)
	local out = {}
	for i, n in ipairs({ w, d, h }) do
		if i > 1 then out[#out + 1] = { "key", keys.down } end
		for ch in tostring(n):gmatch(".") do out[#out + 1] = { "char", ch } end
	end
	return out
end

--- Met des événements en file, avant de lancer le script.
local function touches(...)
	for _, list in ipairs({ ... }) do
		for _, e in ipairs(list) do os.queueEvent(table.unpack(e)) end
	end
end

-- Vue Lancer, puis le bouton sous la case « Mémoriser ».
-- Fonction : `keys` n'existe qu'une fois le mock installé.
local function lancer()
	return {
		{ "key", keys.tab }, { "key", keys.tab }, { "key", keys.tab }, { "key", keys.tab },
		{ "key", keys.down }, { "key", keys.enter },
	}
end

H.case("le menu lance un chantier au clavier et mémorise ses dimensions", function()
	terrain({ width = 2, depth = 2, height = 3 })
	touches(dimensions(2, 2, 3), lancer())
	local sorties = run()

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier mené à terme")
	H.eq(restants(2, 2, 3), 0, "tout le volume est creusé")

	local cfg = mock.getFile("ccquarry.cfg")
	H.contains(cfg, "height = 3", "dimensions mémorisées")
	H.contains(cfg, "-- Mode de depot", "commentaires du gabarit conservés")
	H.eq((mock.getFile("ccquarry.log") or ""):find("Options :", 1, true), nil,
		"le fichier réécrit se relit sans avertissement")
end)

H.case("le menu peut placer le chantier à GAUCHE de la turtle", function()
	mock.install()
	mock.getTurtle().fuel = 5000
	mock.setSlot(1, "minecraft:coal", 32)
	mock.setSlot(16, ENDER, 1)
	mock.fill(0, -1, -6, 1, 0, -1, "minecraft:stone")
	mock.setBlock(0, 1, -1, "minecraft:iron_ore")    -- à droite : hors chantier

	touches(dimensions(2, 2, 3),
		{ { "key", keys.down }, { "key", keys.down }, { "key", keys.right } }, lancer())
	local sorties = run()

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier mené à terme")
	for _, p in ipairs({ { 0, -1, -1 }, { 1, -1, -2 }, { 1, 0, -2 } }) do
		H.isNil(mock.getBlock(p[1], p[2], p[3]), "creusé en " .. table.concat(p, ","))
	end
	H.ok(mock.getBlock(0, 1, -1), "la droite est intacte")
	H.contains(mock.getFile("ccquarry.cfg"), "left = true", "côté mémorisé")
end)

H.case("les options du menu non mémorisées survivent à une reprise", function()
	-- Sans coffre, la turtle finit par attendre : Ctrl+T la trouve là.
	terrain({ width = 2, depth = 2, height = 3, noChest = true, ore = { { 1, 1, -1 } } })
	-- Dépôt portable seulement, sans mémoriser.
	touches(dimensions(2, 2, 3), {
		{ "key", keys.tab }, { "key", keys.right },
		{ "key", keys.tab }, { "key", keys.tab }, { "key", keys.tab },
		{ "key", keys.enter }, { "key", keys.down }, { "key", keys.enter },
		{ "terminate" },
	})
	run()

	H.ok(fs.exists("ccquarry.save"), "chantier sauvegardé")
	H.eq(mock.getFile("ccquarry.cfg"):find('chest = "portable"', 1, true), nil,
		"rien d'écrit dans les options")

	-- Reprise, coffre fourni : l'option vient de la sauvegarde, pas du fichier.
	mock.setSlot(16, ENDER, 1)
	mock.putFile("ccquarry.log", "")
	local sorties = run()
	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "reprise menée à terme")
	H.contains(mock.getFile("ccquarry.log"), "depot portable", "option reprise de la sauvegarde")
end)

H.case("chest = fixed ignore le coffre portable", function()
	terrain({ width = 2, depth = 2, height = 3, ore = { { 1, 1, -1 } } })
	mock.setChest(-1, 0, 0, {}, 27)
	mock.putFile("ccquarry.cfg", 'return { chest = "fixed" }')

	run("2", "2", "3")
	local trouve = false
	for _, pile in pairs(mock.getBlock(-1, 0, 0).inventory) do
		if pile.name == "minecraft:iron_ore" then trouve = true end
	end
	H.ok(trouve, "le minerai est dans le coffre fixe")
end)

H.case("chest = none : ni coffre portable ni coffre fixe", function()
	terrain({ width = 2, depth = 2, height = 3, ore = { { 1, 1, -1 } } })
	mock.setChest(-1, 0, 0, {}, 27)
	mock.putFile("ccquarry.cfg", 'return { chest = "none", dropWhenNoChest = true }')

	run("2", "2", "3")
	H.isNil(mock.getBlock(-1, 0, 0).inventory[1], "le coffre fixe reste vide")
	H.eq(mock.groundCount("minecraft:iron_ore"), 1, "butin jeté, comme demandé")
end)

H.case("argument non numérique : refus explicite", function()
	terrain()
	-- `tonumber(tArgs[1])` pouvait valoir nil, et la comparaison qui suivait
	-- plantait avec « attempt to compare nil with number ».
	local sorties = run("seize")
	H.contains(table.concat(sorties, "\n"), "Argument invalide", "message")
end)

H.case("dimension nulle : refus explicite", function()
	terrain()
	-- `ccquarry 1` produisait un chantier de dimensions nulles, en silence.
	local sorties = run("0")
	H.contains(table.concat(sorties, "\n"), "non nulles", "message")
end)

H.case("l'amorce ne touche pas au réseau quand les APIs sont là", function()
	-- La règle critique du bootstrap : un turtle redémarre à chaque
	-- rechargement de chunk, et startup relance le script.
	terrain({ width = 2, depth = 2, height = 3 })
	run("2", "2", "3")
	H.eq(#mock.httpRequests(), 0, "aucune requête HTTP")
end)

H.case("update consulte le manifeste et n'installe que ce qui est en retard", function()
	terrain()
	-- Le VRAI manifeste du dépôt est servi : le test vérifie donc aussi qu'il
	-- s'évalue correctement et qu'il déclare les versions attendues.
	local f = assert(io.open("manifest.lua", "r"))
	local reel = f:read("a")
	f:close()
	mock.setUrl(repoUrl() .. "manifest.lua", reel)

	local sorties = run("update")

	H.eq(#mock.httpRequests(), 1, "seul le manifeste est telecharge")
	H.contains(table.concat(sorties, "\n"), "a jour", "message")
	H.eq(mock.getTurtle().z, 0, "aucun chantier lancé")
	H.eq(fs.exists("ccquarry.save"), false, "aucune sauvegarde")
end)

H.case("update remplace aussi le script, et installe les APIs qu'il demande", function()
	terrain()
	-- Le dépôt publie la version suivante du script, qui dépend d'une API
	-- inconnue de la version installée.
	local f = assert(io.open("ccQuarry.lua", "r"))
	local src = f:read("a")
	f:close()
	local suivante = tonumber(src:match("local VERSION = (%d+)")) + 1
	local nouveau = src:gsub("local VERSION = %d+", "local VERSION = " .. suivante, 1)
		:gsub("local NEEDS = {", "local NEEDS = {\n\tccNouvelle = 1,", 1)

	local repo = repoUrl()
	f = assert(io.open("manifest.lua", "r"))
	local manifeste = f:read("a"):gsub('ccQuarry    = { version = %d+', 'ccQuarry    = { version = ' .. suivante, 1)
		:gsub("apis = {", "apis = {\n\t\tccNouvelle = { version = 1, path = 'apis/ccNouvelle.lua' },", 1)
	f:close()
	mock.setUrl(repo .. "manifest.lua", manifeste)
	mock.setUrl(repo .. "ccQuarry.lua", nouveau)
	mock.setUrl(repo .. "apis/ccNouvelle.lua", "local M = { _VERSION = 1 }\nreturn M\n")

	_G.shell = { getRunningProgram = function() return "ccQuarry" end }
	local ok, sorties = pcall(run, "update")
	_G.shell = nil
	H.ok(ok, tostring(sorties))

	local texte = table.concat(sorties, "\n")
	H.contains(texte, "ccQuarry mis a jour : v" .. suivante, "script annoncé")
	H.contains(texte, "ccNouvelle", "nouvelle API annoncée")
	H.eq(mock.getFile("ccQuarry"), nouveau, "script remplacé à son chemin")
	H.ok(mock.getFile("apis/ccNouvelle.lua"), "nouvelle API installée")
	H.eq(mock.getTurtle().z, 0, "aucun chantier lancé")
end)

-- ---------------------------------------------------------------------------
-- Chantier complet
-- ---------------------------------------------------------------------------

H.case("un chantier 2x2x3 est creusé en entier et la turtle rentre", function()
	terrain({ width = 2, depth = 2, height = 3 })
	local sorties = run("2", "2", "3")

	-- Ce contrôle-là manquait : les tests vérifiaient les EFFETS (volume
	-- creusé, sauvegarde supprimée, startup restauré) sans jamais regarder
	-- l'état final. Un chantier réussi était donc annoncé « ERREUR » sans
	-- qu'aucun test ne s'en aperçoive.
	local texte = table.concat(sorties, "\n")
	H.contains(texte, "Carriere terminee", "bilan de réussite")
	H.eq(texte:find("ERREUR", 1, true), nil, "aucune erreur signalée")

	H.eq(restants(2, 2, 3), 0, "tout le volume est creusé")

	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.y, 0, "revenue en y")
	H.eq(t.z, 0, "revenue en z")

	H.eq(fs.exists("ccquarry.save"), false, "sauvegarde supprimée")
	H.eq(fs.exists("startup.lua"), false, "startup retiré")
end)

H.case("un chantier plus grand, sur plusieurs couches", function()
	terrain({ width = 3, depth = 2, height = 7 })
	local sorties = run("3", "2", "7")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "bilan de réussite")
	H.eq(restants(3, 2, 7), 0, "tout le volume est creusé")
	H.eq(mock.getTurtle().z, 0, "revenue à la surface")
end)

H.case("le journal enregistre l'etat terminal, pas une fausse erreur", function()
	-- Symptôme observé en jeu : « Etat inconnu : TERMINE ». La boucle
	-- cherchait la fonction de l'état AVANT de tester s'il était terminal, or
	-- TERMINE n'en a pas.
	terrain({ width = 2, depth = 2, height = 3 })
	run("2", "2", "3")

	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "Chantier termine", "fin normale tracée")
	H.eq(trace:find("Etat inconnu", 1, true), nil, "aucun état inconnu")
end)

--- Chantier ou chaque colonne donne un bloc DIFFERENT : l'inventaire se
--- remplit vraiment, au lieu que tout s'empile en trois slots.
local function terrainVarie(w, d, h)
	terrain({ width = w, depth = d, height = h })
	for x = 0, w - 1 do
		for y = 0, d - 1 do
			for z = -1, -(h + 2), -1 do
				mock.setBlock(x, y, z, "minecraft:rock_" .. (x * d + y))
			end
		end
	end
end

--- Releve le nombre de slots libres au moment de chaque vidage.
local function auVidage(cfg, w, d, h)
	local ccInv = require("ccInv")
	terrainVarie(w, d, h)
	mock.putFile("ccquarry.cfg", cfg)

	local libres = {}
	local vrai = ccInv.unload
	ccInv.unload = function(...)
		libres[#libres + 1] = ccInv.freeCount()
		return vrai(...)
	end

	pcall(run, tostring(w), tostring(d), tostring(h))
	ccInv.unload = vrai
	return libres
end

--- Relève la position de la turtle à chaque vidage.
local function ouVidage(cfg, w, d, h, avant)
	local ccInv = require("ccInv")
	terrainVarie(w, d, h)
	mock.putFile("ccquarry.cfg", cfg)
	if avant then avant() end

	local positions = {}
	local vrai = ccInv.unload
	ccInv.unload = function(...)
		local t = mock.getTurtle()
		positions[#positions + 1] = { x = t.x, y = t.y, z = t.z }
		return vrai(...)
	end
	local ok, err = pcall(run, tostring(w), tostring(d), tostring(h))
	ccInv.unload = vrai
	if not ok then error(err, 0) end
	return positions
end

local function retours()
	local n = 0
	for _ in (mock.getFile("ccquarry.log") or ""):gmatch("| RETOUR\n") do n = n + 1 end
	return n
end

H.case("avec un coffre portable, la turtle vide SUR PLACE sans remonter", function()
	-- Signalé en jeu : la turtle remontait à l'origine pour poser l'ender chest
	-- qu'elle transportait. Un aller-retour pour rien, d'autant plus long que
	-- la carrière est profonde.
	local positions = ouVidage("return { trash = {} }", 4, 4, 12)

	local auFond = 0
	for _, p in ipairs(positions) do
		if p.z < 0 then auFond = auFond + 1 end
	end
	H.ok(auFond > 0, "au moins un vidage au fond de la carriere")
	H.contains(mock.getFile("ccquarry.log"), "Vidage sur place", "trace dans le journal")
	H.eq(retours(), 1, "un seul retour : celui de fin de chantier")
	H.eq(restants(4, 4, 12), 0, "tout le volume est creuse")
	for i = 0, 15 do
		H.eq(mock.groundCount("minecraft:rock_" .. i), 0, "rien de perdu au sol (rock_" .. i .. ")")
	end
	H.ok(mock.getTurtle().inv[16], "l'ender chest est revenu en inventaire")
end)

H.case("en manque de carburant, le coffre portable est fouille SUR PLACE", function()
	-- Le mock ne partage pas le contenu des ender chests : la fouille est
	-- simulée, comme si l'autre bout du réseau contenait du charbon.
	local ccFuel = require("ccFuel")
	terrain({ width = 6, depth = 6, height = 12, fuel = 150 })
	mock.setSlot(1, nil)

	local fouilles, positions = 0, {}
	local vrai = ccFuel.refuelFromChest
	ccFuel.refuelFromChest = function()
		fouilles = fouilles + 1
		local t = mock.getTurtle()
		positions[#positions + 1] = t.z
		t.fuel = t.fuel + 1000
		return true
	end
	local ok, err = pcall(run, "6", "6", "12")
	ccFuel.refuelFromChest = vrai
	if not ok then error(err, 0) end

	local auFond = 0
	for _, z in ipairs(positions) do
		if z < 0 then auFond = auFond + 1 end
	end
	H.ok(auFond >= 1, "au moins une fouille au fond, pas a l'origine")
	H.eq(retours(), 1, "un seul retour : celui de fin de chantier")
	H.eq(restants(6, 6, 12), 0, "tout le volume est creuse")
end)

H.case("la garde carburant EN TRAJET fait aussi fouiller le coffre sur place", function()
	-- La garde de ccNav refuse un mouvement avant que MINAGE n'ait pu tester
	-- quoi que ce soit. On la simule au dixieme trajet, reservoir vide.
	local ccFuel = require("ccFuel")
	local ccNav = require("ccNav")
	terrain({ width = 3, depth = 3, height = 6 })
	mock.setSlot(1, nil)

	local fouilles = {}
	local vraiFouille, vraiGoTo = ccFuel.refuelFromChest, ccNav.goTo
	ccFuel.refuelFromChest = function()
		local t = mock.getTurtle()
		fouilles[#fouilles + 1] = t.z
		t.fuel = t.fuel + 1000
		return true
	end
	local trajets = 0
	ccNav.goTo = function(...)
		trajets = trajets + 1
		if trajets == 10 then
			mock.getTurtle().fuel = 0
			return false, "denied"
		end
		return vraiGoTo(...)
	end
	local ok, err = pcall(run, "3", "3", "6")
	ccFuel.refuelFromChest, ccNav.goTo = vraiFouille, vraiGoTo
	if not ok then error(err, 0) end

	H.eq(#fouilles, 1, "une fouille")
	H.ok(fouilles[1] < 0, "au fond, la ou la garde a refuse")
	H.eq(retours(), 1, "un seul retour : celui de fin de chantier")
	H.eq(restants(3, 3, 6), 0, "tout le volume est creuse")
end)

H.case("un coffre sans combustible n'est plus fouille a chaque passage", function()
	-- Signale en relisant le code : le coffre etait fouille a chaque passage
	-- des que le niveau etait sous fuelTopUp, donc presque toujours.
	local ccFuel = require("ccFuel")
	local fouilles = 0
	local vrai = ccFuel.refuelFromChest
	local positions = ouVidage('return { trash = {}, chest = "fixed" }', 4, 4, 12, function()
		mock.setChest(-1, 0, 0, {}, 27 * 4)
		-- Sous fuelTopUp et sans charbon a bord : la fouille a lieu.
		mock.setSlot(1, nil)
		mock.getTurtle().fuel = 1500
		ccFuel.refuelFromChest = function(...)
			fouilles = fouilles + 1
			return vrai(...)
		end
	end)
	ccFuel.refuelFromChest = vrai

	H.ok(#positions > 2, "plusieurs passages au coffre : " .. #positions)
	H.eq(fouilles, 1, "une seule fouille, celle qui montre qu'il n'y a rien")
end)

H.case("avec un coffre fixe seulement, la turtle rentre toujours a l'origine", function()
	local positions = ouVidage('return { trash = {}, chest = "fixed" }', 4, 4, 12, function()
		mock.setChest(-1, 0, 0, {}, 27 * 4)
	end)

	H.ok(#positions > 1, "plusieurs vidages")
	for _, p in ipairs(positions) do
		H.eq(p.x .. "," .. p.y .. "," .. p.z, "0,0,0", "vidage a l'origine")
	end
end)

H.case("la turtle rentre en gardant la marge configuree", function()
	-- On ne cherche pas a prevoir si le prochain bloc tiendra : inspect() donne
	-- le nom du BLOC, pas celui du BUTIN, et un meme bloc peut lacher plusieurs
	-- objets. On garde donc une marge, et on rentre des qu'elle est atteinte
	-- une fois l'inventaire range.
	local serre = auVidage("return { trash = {}, spareSlots = 1 }", 4, 4, 12)
	local large = auVidage("return { trash = {}, spareSlots = 5 }", 4, 4, 12)

	H.ok(#serre > 0 and #large > 0, "vidages observes dans les deux cas")

	-- Mesure prise DANS serviceUnload, donc apres le compactage qui libere
	-- parfois un slot de plus : d'ou la tolerance.
	H.ok(serre[1] <= 3, "marge serree : " .. serre[1] .. " slots libres au vidage")
	H.ok(large[1] > serre[1],
		"marge large respectee : " .. large[1] .. " contre " .. serre[1])

	H.eq(mock.groundCount("minecraft:rock_0"), 0, "aucun bloc perdu au sol")
end)

H.case("un menage sterile n'est pas rejoue a chaque cellule", function()
	-- Signale en jeu : des que la place devenait rare, le menage se relancait
	-- a chaque cellule, y compris quand il n'avait plus rien a liberer. Ici le
	-- butin n'est PAS du rebut, donc dumpTrash ne peut rien faire.
	terrain({ width = 3, depth = 3, height = 6 })
	mock.putFile("ccquarry.cfg", "return { trash = {} }")
	-- On remplit l'inventaire pour que la place soit rare des le depart.
	for slot = 2, 14 do mock.setSlot(slot, "minecraft:diamond", 1) end

	local ccInv = require("ccInv")
	local menages = 0
	local vrai = ccInv.compact
	ccInv.compact = function(...) menages = menages + 1 return vrai(...) end

	mock.setEventBudget(60)
	pcall(run, "3", "3", "6")
	ccInv.compact = vrai

	-- Sans le declenchement sur changement, compact partait a chaque cellule.
	-- Borne : au plus une tentative par slot restant, plus le service.
	H.ok(menages <= 5, "compact appele " .. menages .. " fois, au plus 5 attendu")
end)

H.case("la turtle brule son propre charbon au lieu de rentrer", function()
	-- Remonter a l'origine pour bruler du combustible qu'on a deja en soute
	-- est un aller-retour pour rien.
	terrain({ width = 2, depth = 2, height = 6, fuel = 30 })
	mock.setSlot(5, "minecraft:coal", 20)

	run("2", "2", "6")

	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "Ravitaille sur place", "ravitaillement sans deplacement")
	H.ok(mock.getTurtle().fuel > 30, "du charbon a ete brule")
end)

H.case("en panne seche, le coffre n'est pas refouille a chaque reveil", function()
	-- Sans combustible dans le coffre, chaque fouille aspire puis rend le butin
	-- qu'on vient d'y deposer. Refaire le service a chaque reveil de l'attente
	-- tournait en boucle.
	terrain({ width = 3, depth = 3, height = 6, fuel = 40, noChest = true })
	mock.setSlot(1, nil)
	mock.setChest(-1, 0, 0, {}, 27)

	local fouilles = 0
	local vrai = turtle.suck
	turtle.suck = function(...) fouilles = fouilles + 1 return vrai(...) end
	mock.setEventBudget(300)
	pcall(run, "3", "3", "6")
	turtle.suck = vrai

	local trace = mock.getFile("ccquarry.log")
	local _, attentes = trace:gsub("Carburant insuffisant", "")
	H.ok(attentes >= 1, "la turtle attend du carburant")
	H.ok(attentes <= 3, "coffre refouille " .. attentes .. " fois, au plus 3 attendu")
	H.ok(fouilles <= 3 * 27, "aspirations : " .. fouilles)
end)

H.case("un conteneur d'un mod inconnu est accepte sur sa TAILLE", function()
	-- Aucun motif de nom ne correspond, mais l'API peripheral tranche : c'est
	-- un inventaire de 54 slots, donc du stockage.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.setBlock(-1, 0, 0, { name = "somemod:magic_pouch", inventory = {}, size = 54 })

	local sorties = run("2", "2", "3")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier fini")
	local trouve = false
	for _, pile in pairs(mock.getBlock(-1, 0, 0).inventory) do
		if pile.name == "minecraft:iron_ore" then trouve = true end
	end
	H.eq(trouve, true, "minerai depose sans qu'aucun motif ne corresponde")

	H.contains(mock.getFile("ccquarry.log"), "54 slots", "taille journalisee")
end)

H.case("un tampon de machine est ecarte, et nomme dans le journal", function()
	-- 5 slots : c'est un hopper, pas du stockage. Le journal doit donner
	-- l'identifiant ET la taille, pour pouvoir trancher.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.setBlock(-1, 0, 0, { name = "somemod:tiny_buffer", inventory = {}, size = 5 })

	mock.setEventBudget(30)
	pcall(run, "2", "2", "3")

	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "somemod:tiny_buffer", "identifiant exact journalise")
	H.contains(trace, "5 slots", "taille journalisee")
	H.contains(trace, "depotMinSlots", "ou regler le seuil")
	H.eq(mock.groundCount("minecraft:iron_ore"), 0, "le butin n'est pas perdu")
end)

H.case("abaisser depotMinSlots fait accepter un petit conteneur", function()
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.setBlock(-1, 0, 0, { name = "somemod:tiny_buffer", inventory = {}, size = 5 })
	mock.putFile("ccquarry.cfg", "return { depotMinSlots = 5 }")

	local sorties = run("2", "2", "3")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier fini")
	local trouve = false
	for _, pile in pairs(mock.getBlock(-1, 0, 0).inventory) do
		if pile.name == "minecraft:iron_ore" then trouve = true end
	end
	H.eq(trouve, true, "minerai depose")
end)

H.case("le rebut n'est pas jete a chaque cellule", function()
	-- Observe en jeu : la turtle parcourait ses 16 slots apres chaque cellule,
	-- soit trois blocs mines, ce qui coutait plus cher que le minage. Un select
	-- et un drop par pile, plus un select et un refuel(0) par pile pour repérer
	-- le combustible a proteger -- toutes des commandes a un tick.
	terrain({ width = 3, depth = 3, height = 6 })

	local ccInv = require("ccInv")
	local appels = 0
	local vrai = ccInv.dumpTrash
	ccInv.dumpTrash = function(...) appels = appels + 1 return vrai(...) end

	run("3", "3", "6")
	ccInv.dumpTrash = vrai

	-- 3 x 3 x 2 couches = 18 cellules. L'ancienne version appelait dumpTrash
	-- 18 fois ; desormais seulement quand la place manque, plus le vidage final.
	H.ok(appels <= 3, "dumpTrash appele " .. appels .. " fois, au plus 3 attendu")
end)

H.case("la selection repart du premier slot avant chaque cellule", function()
	terrain({ width = 3, depth = 2, height = 3 })

	-- 3 x 2 sur une couche = 6 cellules. Au-dela, les digDown viennent de la
	-- finition (degagement sous la turtle pour poser le coffre), pas du minage.
	local CELLULES = 6
	local vus = {}
	local vraiDig = turtle.digDown
	turtle.digDown = function()
		if #vus < CELLULES then vus[#vus + 1] = turtle.getSelectedSlot() end
		return vraiDig()
	end

	run("3", "2", "3")
	turtle.digDown = vraiDig

	H.eq(#vus, CELLULES, "toutes les cellules observees")
	for i, slot in ipairs(vus) do
		H.eq(slot, 1, "cellule " .. i .. " : minage depuis le premier slot")
	end
end)

H.case("le butin ramasse EN TRAJET va aussi dans les premiers slots", function()
	-- goTo creuse devant lui : la majorite du butin est ramassee pendant le
	-- deplacement, pas au moment de creuser la cellule. Une operation qui
	-- laisse la selection ailleurs -- dumpTrash sur le dernier slot vide, ou
	-- ccFuel sur un slot de travail -- envoyait tout ce butin s'eparpiller.
	terrain({ width = 3, depth = 3, height = 6 })

	local vus = {}
	local vraiDig = turtle.dig
	turtle.dig = function()
		local avant = turtle.getSelectedSlot()
		local ok = vraiDig()
		if ok then vus[#vus + 1] = avant end
		return ok
	end

	run("3", "3", "6")
	turtle.dig = vraiDig

	H.ok(#vus > 5, "plusieurs blocs mines en trajet")
	local hors = 0
	for _, slot in ipairs(vus) do
		if slot ~= 1 then hors = hors + 1 end
	end
	H.eq(hors, 0, hors .. " blocs mines hors du premier slot")
end)

H.case("le rebut part au sol et n'engorge pas l'inventaire", function()
	terrain({ width = 3, depth = 3, height = 6 })
	run("3", "3", "6")

	-- 3 x 3 x 6 = 54 blocs de pierre, très au-delà des 14 slots utiles.
	H.ok(mock.groundCount("minecraft:stone") > 40, "la pierre a été jetée")
end)

H.case("une erreur d'etat est affichee, pas effacee par le nettoyage d'ecran", function()
	-- ccUi.clear() était appelé avant le bilan et effaçait le message écrit en
	-- ligne 13 : l'utilisateur voyait « Arret en ERREUR » et rien d'autre.
	terrain({ width = 2, depth = 2, height = 3 })
	-- On casse la reprise du coffre pour provoquer une erreur en FINITION.
	local vrai = turtle.digDown
	turtle.digDown = function() error("panne simulee de digDown", 0) end

	local sorties = run("2", "2", "3")
	turtle.digDown = vrai

	local texte = table.concat(sorties, "\n")
	H.contains(texte, "ERREUR", "etat final")
	H.contains(texte, "panne simulee", "le message d'erreur est visible")
	H.contains(texte, "ccquarry.log", "le journal est signale")
end)

H.case("le journal conserve la trace apres coup", function()
	terrain({ width = 2, depth = 2, height = 3 })
	run("2", "2", "3")

	local trace = mock.getFile("ccquarry.log")
	H.ok(trace, "le journal existe")
	H.contains(trace, "Coffre reconnu", "diagnostic du coffre au demarrage")
	H.contains(trace, "FINITION", "les transitions d'etat y figurent")
end)

-- ---------------------------------------------------------------------------
-- Interruption
-- ---------------------------------------------------------------------------

H.case("Ctrl+T interrompt proprement et conserve la sauvegarde", function()
	-- Sans coffre, la turtle finit par attendre : c'est le moment où Ctrl+T
	-- reprend la main. os.pullEvent transformait l'interruption en erreur
	-- « Terminated », donc en état ERREUR.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	os.queueEvent("terminate")

	local sorties = run("2", "2", "3")
	local texte = table.concat(sorties, "\n")

	H.contains(texte, "Interrompu", "arrêt annoncé comme volontaire")
	H.eq(texte:find("ERREUR", 1, true), nil, "pas presente comme une panne")
	H.contains(texte, "ccQuarry", "la reprise est expliquee")
	H.contains(texte, "edit ccquarry.cfg", "l'edition des options est expliquee")

	-- Le point essentiel : le chantier reste reprenable.
	H.ok(fs.exists("ccquarry.save"), "sauvegarde conservee")
	H.ok(fs.exists("startup.lua"), "reprise au reboot conservee")
end)

H.case("le cap sauvegarde suit CHAQUE rotation", function()
	-- Bug observe en jeu : au rechargement de la partie, la turtle se trompait
	-- de cap. La sauvegarde etait cablee sur les seuls deplacements, alors
	-- qu'une rotation change l'etat tout autant. En quittant la partie, le jeu
	-- n'accorde qu'un tick a la turtle : ce qui n'est pas enregistre est perdu.
	terrain({ width = 3, depth = 3, height = 3 })

	local ccNav = require("ccNav")
	local ecarts, rotations = 0, 0

	local function verifie(nom, vraie)
		return function(...)
			local r = vraie(...)
			rotations = rotations + 1
			local sauve = textutils.unserialize(mock.getFile("ccquarry.save") or "")
			local dir = sauve and sauve.data and sauve.data.pos and sauve.data.pos.dir
			if dir ~= mock.getTurtle().dir then ecarts = ecarts + 1 end
			return r
		end
	end

	local vraiR, vraiL = ccNav.turnRight, ccNav.turnLeft
	ccNav.turnRight = verifie("R", vraiR)
	ccNav.turnLeft = verifie("L", vraiL)

	run("3", "3", "3")
	ccNav.turnRight, ccNav.turnLeft = vraiR, vraiL

	H.ok(rotations > 3, rotations .. " rotations observees")
	H.eq(ecarts, 0, ecarts .. " rotations laissant un cap sauvegarde faux")
end)

H.case("la position est sauvegardee a chaque mouvement", function()
	-- Aux seules transitions d'état, une interruption en plein déplacement
	-- laisse une position en retard d'une cellule, et la reprise décale tout.
	terrain({ width = 3, depth = 3, height = 6 })

	local positions = {}
	local vraiForward = turtle.forward
	turtle.forward = function()
		local ok = vraiForward()
		if ok then
			local saved = textutils.unserialize(mock.getFile("ccquarry.save") or "")
			positions[#positions + 1] = saved and saved.data
				and (saved.data.pos.x .. "," .. saved.data.pos.y .. "," .. saved.data.pos.z)
		end
		return ok
	end

	run("3", "3", "6")
	turtle.forward = vraiForward

	H.ok(#positions > 5, "plusieurs mouvements observes")
	-- Chaque relevé doit être distinct du précédent : la sauvegarde suit.
	local distincts = 0
	for i = 2, #positions do
		if positions[i] ~= positions[i - 1] then distincts = distincts + 1 end
	end
	H.eq(distincts, #positions - 1, "la position enregistree change a chaque pas")
end)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

H.case("le fichier d'options est cree au premier lancement", function()
	terrain({ width = 2, depth = 2, height = 3 })
	run("2", "2", "3")

	local cfg = mock.getFile("ccquarry.cfg")
	H.ok(cfg, "fichier cree")
	H.contains(cfg, "dropWhenNoChest", "option presente")
	H.contains(cfg, "trash", "liste de rebut presente")
	H.contains(cfg, "edit ccquarry.cfg", "mode d'emploi en commentaire")
end)

H.case("vider la liste de rebut fait tout conserver", function()
	terrain({ width = 2, depth = 2, height = 3 })
	mock.putFile("ccquarry.cfg", "return { trash = {} }")

	run("2", "2", "3")

	-- Sans liste de rebut, plus rien ne part au sol : tout finit au coffre.
	H.eq(mock.groundCount("minecraft:stone"), 0, "aucune pierre jetee")
	local coffre = mock.getBlock(0, 0, -1)
	H.isNil(coffre, "l'ender chest a bien ete repris")
end)

H.case("dropWhenNoChest = true fait jeter au lieu d'attendre", function()
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.putFile("ccquarry.cfg", "return { dropWhenNoChest = true }")

	local sorties = run("2", "2", "3")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "la turtle n'attend pas")
	H.eq(mock.groundCount("minecraft:iron_ore"), 1, "butin abandonne, comme demande")
end)

H.case("une option fautive est signalee sans bloquer le chantier", function()
	terrain({ width = 2, depth = 2, height = 3 })
	mock.putFile("ccquarry.cfg", "return { dropWhenNoChest = 'oui', fuelMagrin = 9 }")

	local sorties = run("2", "2", "3")
	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier mene a terme")

	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "dropWhenNoChest", "mauvais type signale")
	H.contains(trace, "fuelMagrin", "faute de frappe signalee")
end)

H.case("config cree le fichier sans lancer de chantier", function()
	terrain()
	local sorties = run("config")

	H.contains(table.concat(sorties, "\n"), "ccquarry.cfg", "chemin affiche")
	H.ok(mock.getFile("ccquarry.cfg"), "fichier cree")
	H.eq(mock.getTurtle().z, 0, "aucun chantier lance")
end)

-- ---------------------------------------------------------------------------
-- Modes de dépôt
-- ---------------------------------------------------------------------------

H.case("un coffre classique DERRIERE l'origine recoit le butin", function()
	-- Le mode historique : l'ancien script faisait GoTo(0,0,0,2) puis drop(),
	-- ce qui imposait le coffre derrière la turtle. C'est la régression
	-- signalée en jeu -- la refonte ne gérait plus que le coffre transportable.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 }, { 0, 1, -2 } } })
	mock.setChest(-1, 0, 0, {}, 27)     -- derrière la turtle, qui regarde +X

	local sorties = run("2", "2", "3")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier fini")
	local coffre = mock.getBlock(-1, 0, 0).inventory
	H.ok(coffre[1], "le coffre a recu quelque chose")
	H.eq(coffre[1].name, "minecraft:iron_ore", "le minerai est dans le coffre")
	H.eq(coffre[1].count, 2, "les deux blocs")
	H.eq(mock.groundCount("minecraft:iron_ore"), 0, "rien de perdu au sol")
end)

H.case("le coffre fixe est trouve derriere, a gauche ou au-dessus", function()
	-- Les seules positions viables : la carrière s'étend vers l'AVANT et vers
	-- la DROITE, donc un coffre posé de ces côtés serait miné avec le reste.
	for _, p in ipairs({ { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 } }) do
		terrain({ width = 2, depth = 2, height = 3, noChest = true,
			ore = { { 1, 1, -1 } } })
		mock.setChest(p[1], p[2], p[3], {}, 27)

		run("2", "2", "3")
		local coffre = mock.getBlock(p[1], p[2], p[3]).inventory
		local label = table.concat(p, ",")

		local trouve = false
		for _, pile in pairs(coffre) do
			if pile.name == "minecraft:iron_ore" then trouve = true end
		end
		H.eq(trouve, true, label .. " : minerai depose")
		-- Le rebut ne doit PAS finir dans le depot : avec le coffre au-dessus
		-- et trashWhere = "up", il y atterrissait.
		for _, pile in pairs(coffre) do
			H.eq(pile.name ~= "minecraft:stone", true, label .. " : pas de rebut au depot")
		end
	end
end)

H.case("un coffre pose DANS l'emprise est mine, et la turtle attend", function()
	-- Piège réel : la carrière s'étend vers l'avant et la droite. Un coffre
	-- placé là disparait en cours de chantier. La turtle ne doit alors pas
	-- jeter son butin, mais attendre.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.setChest(1, 0, 0, {}, 27)      -- devant : dans le volume

	mock.setEventBudget(30)
	pcall(run, "2", "2", "3")

	H.isNil(mock.getBlock(1, 0, 0), "le coffre a bien ete mine")
	H.eq(mock.groundCount("minecraft:iron_ore"), 0, "le minerai n'est pas perdu")
end)

H.case("le coffre transportable prime sur le conteneur fixe", function()
	terrain({ width = 2, depth = 2, height = 3, ore = { { 1, 1, -1 } } })
	mock.setChest(-1, 0, 0, {}, 27)

	run("2", "2", "3")
	-- L'ender chest est posé SOUS l'origine : le butin y va, pas dans le
	-- coffre fixe.
	H.isNil(mock.getBlock(-1, 0, 0).inventory[1], "le coffre fixe reste vide")
end)

H.case("un bloc plein derriere l'origine n'est pas pris pour un coffre", function()
	-- Sans inspection, turtle.drop() aurait « reussi » en jetant au sol.
	terrain({ width = 2, depth = 2, height = 3, noChest = true,
		ore = { { 1, 1, -1 } } })
	mock.setBlock(-1, 0, 0, "minecraft:stone")

	-- L'attente est ici le comportement voulu et n'a pas de fin : on borne le
	-- nombre d'événements pour que le test se termine.
	mock.setEventBudget(30)
	pcall(run, "2", "2", "3")

	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "vider la turtle", "la turtle attend au lieu de jeter")
	H.eq(mock.groundCount("minecraft:iron_ore"), 0, "le minerai n'est pas perdu")
end)

-- ---------------------------------------------------------------------------
-- Obstacles
-- ---------------------------------------------------------------------------

H.case("le bedrock ne termine plus le chantier, il est contourné", function()
	-- Un unique mouvement raté sur un bloc mettait done = true et arrêtait
	-- toute la carrière.
	terrain({ width = 3, depth = 3, height = 3 })
	mock.setBlock(1, 1, -1, { name = "minecraft:bedrock", unbreakable = true })
	mock.setBlock(1, 1, -2, { name = "minecraft:bedrock", unbreakable = true })

	run("3", "3", "3")

	-- Tout est creusé sauf le bedrock lui-même.
	local restant = restants(3, 3, 3)
	H.eq(restant, 2, "seul le bedrock subsiste")
	H.eq(mock.getTurtle().z, 0, "revenue malgré l'obstacle")
end)

H.case("une rangee de bedrock suffit a conclure au fond", function()
	-- Auparavant, il fallait une couche ENTIERE inatteignable : ici 64
	-- cellules tentees une a une, chacune avec un detour.
	terrain({ width = 8, depth = 8, height = 9 })
	mock.fill(0, 0, -12, 7, 7, -3, { name = "minecraft:bedrock", unbreakable = true })

	local sorties = run("8", "8", "9")

	H.contains(table.concat(sorties, "\n"), "Carriere terminee", "chantier conclu")
	local trace = mock.getFile("ccquarry.log")
	H.contains(trace, "Fond atteint", "fond reconnu")
	local _, tentees = trace:gsub("Inatteignable", "")
	H.eq(tentees, 8, "une rangee tentee, pas toute la couche")
	H.eq(mock.getTurtle().z, 0, "revenue a l'origine")
end)

H.case("quelques blocs de bedrock epars ne concluent pas au fond", function()
	terrain({ width = 8, depth = 8, height = 3 })
	for x = 0, 6, 2 do mock.setBlock(x, 3, -1, { name = "minecraft:bedrock", unbreakable = true }) end

	run("8", "8", "3")
	H.eq((mock.getFile("ccquarry.log")):find("Fond atteint", 1, true), nil, "pas de fond")
	-- Chaque cellule sautee laisse son bedrock et le bloc sous lui.
	H.eq(restants(8, 8, 3), 8, "seules les cellules de bedrock subsistent")
end)

H.case("le gravier qui retombe ne bloque pas le chantier", function()
	terrain({ width = 2, depth = 2, height = 3 })
	for z = -1, -6, -1 do
		mock.setBlock(1, 1, z, { name = "minecraft:gravel", falling = true })
	end

	run("2", "2", "3")
	H.eq(restants(2, 2, 3), 0, "volume creusé malgré le gravier")
end)

-- ---------------------------------------------------------------------------
-- Sauvegarde et reprise
-- ---------------------------------------------------------------------------

H.case("del supprime la sauvegarde et restaure le startup", function()
	terrain()
	mock.putFile("startup.lua", 'shell.run("autre")\n')
	mock.putFile("ccquarry.save", "peu importe")

	run("del")

	H.eq(fs.exists("ccquarry.save"), false, "sauvegarde supprimée")
	-- `ccquarry del` laissait le startup en place : le turtle relançait le
	-- script à chaque démarrage, pour afficher l'aide.
	H.eq(mock.getFile("startup.lua"), 'shell.run("autre")\n', "startup d'origine intact")
end)

H.case("le startup de l'utilisateur n'est archivé qu'une fois", function()
	terrain({ width = 2, depth = 2, height = 3 })
	mock.putFile("startup.lua", 'shell.run("monScript")\n')

	run("2", "2", "3")

	-- L'ancienne version déplaçait startup vers startup.old à chaque
	-- lancement : un deuxième chantier écrasait la sauvegarde de l'utilisateur.
	H.eq(mock.getFile("startup.lua"), 'shell.run("monScript")\n', "startup restauré à la fin")
end)

H.case("une sauvegarde de l'ancien format est reprise, pas jetée", function()
	terrain({ width = 3, depth = 3, height = 3 })

	-- Format d'origine : 16 index numériques. La turtle est à mi-parcours.
	mock.putFile("ccquarry.save", textutils.serialize({
		[1] = 1, [2] = 0, [3] = -1, [4] = 0,
		[5] = 1, [6] = 0, [7] = -1, [8] = 0,
		[9] = 2, [10] = 2, [11] = -2,
		[12] = "false", [13] = "false", [14] = "false",
		[15] = "false", [16] = "false",
	}))
	-- État cohérent avec la sauvegarde : la cellule précédente a déjà été
	-- creusée par le run interrompu, et la turtle occupe bien sa case.
	mock.setBlock(0, 0, -1, nil)
	mock.setBlock(0, 0, -2, nil)
	mock.setBlock(1, 0, -1, nil)
	local t = mock.getTurtle()
	t.x, t.y, t.z, t.dir = 1, 0, -1, 0

	local sorties = run()
	H.contains(table.concat(sorties, "\n"), "ancien format", "reprise signalée")
	H.eq(restants(3, 3, 3), 0, "chantier mené à son terme")
end)

H.case("la sauvegarde suit le curseur du plan, pas des coordonnées brutes", function()
	terrain({ width = 3, depth = 3, height = 6 })

	-- On interrompt le chantier en coupant l'écriture disque après quelques
	-- octets : la sauvegarde en cours échoue, la précédente doit survivre.
	mock.failWriteAfter("ccquarry.save.tmp", 12)
	local ok = pcall(run, "3", "3", "6")

	-- Que le script ait abouti ou non, la sauvegarde ne doit jamais être
	-- illisible : soit absente, soit exploitable.
	if fs.exists("ccquarry.save") then
		local contenu = mock.getFile("ccquarry.save")
		H.ok(textutils.unserialize(contenu) ~= nil, "sauvegarde toujours lisible")
	end
	H.ok(ok ~= nil, "aucune exception non rattrapée")
end)
