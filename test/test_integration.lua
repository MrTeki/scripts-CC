-- Validation d'ensemble : les APIs que ccQuarry consommera, mises à l'épreuve
-- ensemble plutôt qu'isolément.
--
-- Chaque cas reproduit une situation que la carrière rencontrera vraiment :
-- descendre jusqu'à la limite de carburant et rentrer, faire un cycle complet
-- de vidage et de ravitaillement sur un coffre unique, reprendre après un
-- reboot, et encaisser des sollicitations d'interface et de réseau en plein
-- travail.

local H = require("harness")
local mock = require("ccMock")

local ccVec = require("ccVec")
local ccNav = require("ccNav")
local ccInv = require("ccInv")
local ccFuel = require("ccFuel")
local ccSave = require("ccSave")
local ccUi = require("ccUi")
local ccNet = require("ccNet")

local TRASH = { "minecraft:cobblestone", "minecraft:dirt", "minecraft:gravel" }
local ENDER = "enderstorage:ender_chest"

--- Met en place un chantier : monde de pierre, turtle à l'origine, APIs prêtes.
local function chantier(o)
	o = o or {}
	mock.install()
	mock.getTurtle().fuel = o.fuel or 1000

	-- Volume de pierre sous l'origine.
	local size = o.size or 3
	mock.fill(0, 0, -(o.depth or 6), size - 1, size - 1, -1, "minecraft:stone")

	ccNav.reset()
	ccInv.reset({ trash = o.trash })
	ccUi.reset()
	ccNet.reset()
	return ccSave.store("ccquarry.save", { version = 1 })
end

-- ---------------------------------------------------------------------------
-- Carburant et retour
-- ---------------------------------------------------------------------------

H.case("la garde carburant arrête la turtle à temps pour qu'elle puisse rentrer", function()
	local carburant = 20
	chantier({ fuel = carburant, depth = 30 })
	ccNav.setGuard(ccFuel.guard(ccNav.position))

	-- On s'éloigne jusqu'au refus.
	local raison
	repeat
		local ok, r = ccNav.forward()
		raison = r
	until not ok

	H.eq(raison, "denied", "arrêt par la garde, pas par la panne sèche")
	local atteint = ccNav.position().x
	H.ok(atteint > 0, "la turtle a bien progressé")
	H.eq(ccFuel.level(), carburant - atteint, "carburant dépensé")

	-- La garde est levée pour rentrer : elle raisonne sur la position courante
	-- et interdirait sinon les mouvements qui rapprochent justement du but.
    ccNav.setGuard(nil)
	H.ok(ccNav.goTo({ x = 0, y = 0, z = 0 }), "retour à l'origine")
	H.eq(ccNav.position().x, 0, "à l'origine")
	H.ok(ccFuel.level() >= 0, "carburant suffisant, sans marge d'erreur")
end)

H.case("sans lever la garde, le retour serait lui aussi refusé", function()
	-- Justifie l'existence de setGuard : c'est un piège réel, pas théorique.
	chantier({ fuel = 20, depth = 30 })
	ccNav.setGuard(ccFuel.guard(ccNav.position))
	repeat until not ccNav.forward()

	local ok, raison = ccNav.goTo({ x = 0, y = 0, z = 0 })
	H.eq(ok, false, "refus")
	H.eq(raison, "denied", "la garde bloque aussi le retour")
end)

-- ---------------------------------------------------------------------------
-- Cycle complet de service
-- ---------------------------------------------------------------------------

H.case("cycle complet : miner, rentrer, vider, ravitailler, repartir", function()
	chantier({ fuel = 500, trash = TRASH })
	mock.setSlot(16, ENDER, 1)
	-- Le slot de carburant doit rester OCCUPÉ : le jeu ne le réserve pas, et
	-- le butin miné y atterrirait sinon, puisqu'il remplit le premier slot
	-- libre. C'est la configuration réelle de départ.
	mock.setSlot(1, "minecraft:coal", 2)
	local reserveAvant = ccInv.count(1)

	-- Le coffre unique contient du butin ancien et du charbon fourni par le
	-- joueur, derrière deux piles de rebut.
	local contenu = {
		{ name = "minecraft:cobblestone", count = 64 },
		{ name = "minecraft:dirt", count = 20 },
		{ name = "minecraft:coal", count = 10 },
	}

	-- Phase de minage : on descend, l'inventaire se remplit de pierre.
	for _ = 1, 5 do H.ok(ccNav.down(), "descente") end
	H.ok(ccInv.freeCount() < 16, "l'inventaire s'est rempli")
	H.eq(ccInv.count(1), reserveAvant, "le butin n'a pas pollué le slot carburant")
	local profondeur = ccNav.position().z

	-- Retour et service.
	ccNav.setGuard(nil)
	H.ok(ccNav.goTo({ x = 0, y = 0, z = 0 }), "retour")

	-- Le coffre se pose sous la turtle, dans le puits qu'elle vient de creuser.
	mock.setChest(0, 0, -1, contenu, 27)
	-- Le carburant est DÉSIGNÉ : aucun numéro de slot n'est protégé en soi.
	H.ok(ccInv.unload("down", { protect = ccFuel.protectSlots(64) }), "vidage")
	H.eq(ccInv.lootCount(ccFuel.protectSlots(64)), 0, "plus rien à déposer")
	H.ok(ccInv.count(1) > 0, "le carburant est resté")

	local avant = ccFuel.level()
	H.ok(ccFuel.refuelFromChest("down", avant + 200), "ravitaillement")
	H.ok(ccFuel.level() > avant, "carburant regagné")
	H.ok(ccInv.count(1) > reserveAvant, "le reste de charbon a grossi la réserve")

	-- Le rebut du coffre a été rendu à sa place.
	local coffre = mock.getBlock(0, 0, -1).inventory
	H.eq(coffre[1].name, "minecraft:cobblestone", "rebut restitué")
	H.eq(coffre[2].name, "minecraft:dirt", "rebut restitué")

	-- Reprise du travail là où on s'était arrêté.
	H.ok(ccNav.goTo({ x = 0, y = 0, z = profondeur }), "retour au front de taille")
	H.eq(ccNav.position().z, profondeur, "profondeur retrouvée")
end)

H.case("la liste de rebut évite au coffre de se remplir de cobble", function()
	chantier({ fuel = 500, trash = TRASH })
	mock.setChest(0, 0, 1, {}, 27)     -- coffre au-dessus, hors du chemin

	-- Butin typique : beaucoup de pierre, un peu de minerai.
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:dirt", 64)
	mock.setSlot(4, "minecraft:gravel", 64)
	mock.setSlot(5, "minecraft:diamond", 3)
	mock.setSlot(6, "minecraft:iron_ore", 9)

	H.ok(ccInv.unload("up", { trashWhere = "forward" }), "vidage")

	local coffre = mock.getBlock(0, 0, 1).inventory
	H.eq(coffre[1].name, "minecraft:diamond", "seul le butin utile est entreposé")
	H.eq(coffre[2].name, "minecraft:iron_ore", "et le minerai")
	H.isNil(coffre[3], "deux slots occupés au lieu de cinq")
	H.eq(mock.groundCount("minecraft:cobblestone"), 64, "le rebut est parti au sol")
end)

-- ---------------------------------------------------------------------------
-- Reprise après reboot
-- ---------------------------------------------------------------------------

H.case("reprise après reboot : la sauvegarde et le GPS se recoupent", function()
	local store = chantier({ fuel = 500 })
	mock.setGps(1000, 64, 2000)
	local origine = { x = 1000, y = 2000, z = 64 }

	-- Travail, puis sauvegarde de l'état.
	ccNav.goTo({ x = 2, y = 1, z = -3, dir = 1 })
	H.ok(store.write({
		curseur = 47,
		pos = ccNav.position(),
		origine = origine,
	}), "sauvegarde")

	-- Reboot : le script redémarre, ccNav repart de zéro et croit être à
	-- l'origine, alors que la turtle est au fond du puits.
	ccNav.reset()
	H.eq(ccNav.position().x, 0, "position perdue")

	local etat = store.read()
	H.eq(etat.curseur, 47, "curseur relu")

	-- Deux voies de recalage, qui doivent concorder.
	ccNav.setPosition(etat.pos)
	local parEstime = ccNav.position()

	ccNav.reset()
	H.ok(ccNav.calibrate(etat.origine), "recalage GPS")
	local parGps = ccNav.position()

	H.eq(parGps.x, parEstime.x, "x concordant")
	H.eq(parGps.y, parEstime.y, "y concordant")
	H.eq(parGps.z, parEstime.z, "z concordant")

	-- Le GPS ne donne pas le cap : il se retrouve par un sondage.
	H.eq(ccNav.gpsHeading(), 1, "cap retrouvé")
end)

H.case("une sauvegarde de l'ancien format ccQuarry est reprise", function()
	chantier()
	mock.putFile("ccquarry.save", textutils.serialize({
		[1] = 2, [2] = 1, [3] = -3, [4] = 1,
		[5] = 2, [6] = 1, [7] = -3, [8] = 1,
		[9] = 15, [10] = 15, [11] = -63,
		[12] = "true", [13] = "false", [14] = "false",
		[15] = "false", [16] = "false",
	}))

	local etat = ccSave.store("ccquarry.save", {
		version = 1,
		migrations = {
			[0] = function(old)
				return {
					pos = ccVec.new(old[1], old[2], old[3], old[4]),
					cible = ccVec.new(old[9], old[10], old[11]),
					termine = old[15] == "true",
				}
			end,
		},
	}).read()

	ccNav.setPosition(etat.pos)
	H.eq(ccNav.position().x, 2, "position reprise")
	H.eq(ccNav.position().dir, 1, "cap repris")
	H.eq(etat.termine, false, "drapeau redevenu booléen")
end)

-- ---------------------------------------------------------------------------
-- Interface et réseau pendant le travail
-- ---------------------------------------------------------------------------

H.case("ni l'interface ni le réseau ne touchent au turtle", function()
	-- La course de ccQuarry : catchTermEvents appelait Refuel() depuis la
	-- coroutine d'affichage, pendant que mainLoop pouvait être au milieu d'un
	-- vidage.
	chantier({ fuel = 500 })
	mock.addPeripheral("left", "modem")
	ccNet.open()

	ccUi.addButton({ label = "REFUEL", y = 1, cmd = "refuel" })
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	mock.setSlot(4, "minecraft:coal", 20)

	local t = mock.getTurtle()
	local avant = { x = t.x, y = t.y, z = t.z, dir = t.dir, fuel = t.fuel, coal = ccInv.count(4) }

	-- Sollicitations simultanées : clic, touche, et commandes réseau.
	H.eq(ccUi.dispatch("mouse_click", 1, 36, 1), "refuel", "clic REFUEL")
	H.eq(ccUi.dispatch("char", "p"), "pause", "touche PAUSE")
	mock.rednetInject(7, { method = "forward" }, "ccRemoteProtocol")
	mock.rednetInject(7, { method = "refuel" }, "ccRemoteProtocol")
	ccNet.poll()
	ccNet.poll()

	H.eq(t.x, avant.x, "position inchangée")
	H.eq(t.dir, avant.dir, "cap inchangé")
	H.eq(t.fuel, avant.fuel, "carburant inchangé")
	H.eq(ccInv.count(4), avant.coal, "charbon intact")
	H.eq(ccNet.pending(), 2, "les commandes attendent la machine à états")
end)

H.case("la télémétrie réseau expose l'état réel des autres APIs", function()
	chantier({ fuel = 500 })
	mock.addPeripheral("left", "modem")
	ccNet.open()
	ccNav.goTo({ x = 1, y = 2, z = -2 })

	ccNet.setTelemetry(function()
		local p = ccNav.position()
		return {
			etat = "MINAGE",
			pos = { x = p.x, y = p.y, z = p.z, dir = p.dir },
			reserve = ccFuel.reserve(p),
			slotsLibres = ccInv.freeCount(),
		}
	end)

	mock.rednetInject(7, "refresh", "ccRemoteProtocol")
	ccNet.poll()

	local sent = mock.rednetSent()
	local data = sent[#sent].message
	H.eq(data.etat, "MINAGE", "état")
	H.eq(data.pos.x, 1, "position x")
	H.eq(data.pos.z, -2, "position z")
	H.eq(data.reserve, 5, "réserve = distance de Manhattan au retour")
	H.eq(data.slotsLibres, ccInv.freeCount(), "slots libres")
	H.eq(type(data.fuelLevel), "number", "carburant numérique")
end)

H.case("l'affichage rend compte de la progression sans rien exécuter", function()
	chantier({ fuel = 500 })
	local t = mock.getTurtle()
	local avant = t.fuel

	ccUi.line(1, "Blocs restants : 1250")
	ccUi.bar({ x1 = 1, x2 = 20, y = 2, colorFull = colors.lime, colorEmpty = colors.gray,
		max = 3000, current = 1750, label = "" })
	ccUi.addButton({ label = "PAUSE", y = 3, cmd = "pause" })
	ccUi.drawButtons()
	ccUi.log("Minage ...")

	H.contains(mock.screenLine(1), "1250", "compteur affiché")
	H.contains(mock.screenLine(2), "1750/3000", "barre de progression")
	H.eq(mock.screenLine(13), "Minage ...", "journal")
	H.eq(t.fuel, avant, "aucun effet sur le turtle")
end)
