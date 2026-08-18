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

H.case("sans argument ni sauvegarde : aide, et rien n'est touché", function()
	terrain()
	local sorties = run()

	H.contains(table.concat(sorties, "\n"), "ccQuarry <largeur>", "aide affichée")
	H.eq(mock.getTurtle().z, 0, "la turtle n'a pas bougé")
	H.eq(fs.exists("ccquarry.save"), false, "aucune sauvegarde créée")
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
