-- Tests de ccInv.

local H = require("harness")
local mock = require("ccMock")
local ccInv = require("ccInv")

local ENDER = "enderstorage:ender_chest"

local function fresh(o)
	mock.install()
	ccInv.reset(o)
end

--- Remplit `n` slots de cobble à partir du slot 2.
local function fillSlots(n)
	for i = 2, 1 + n do mock.setSlot(i, "minecraft:cobblestone", 64) end
end

-- ---------------------------------------------------------------------------
-- Slots réservés
-- ---------------------------------------------------------------------------

H.case("un emplacement canonique laissé vide compte comme libre", function()
	-- L'ancienne version excluait les slots 1 et 16 du décompte, même vides et
	-- inutilisés : deux slots perdus pour rien.
	fresh()
	H.eq(ccInv.freeCount(), 16, "inventaire vide")
	H.eq(ccInv.firstFree(), 1, "le slot 1 est utilisable")

	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)
	H.eq(ccInv.freeCount(), 14, "deux slots occupés")

	fillSlots(14)
	H.eq(ccInv.freeCount(), 0, "inventaire plein")
end)

H.case("un emplacement canonique vide se fait occuper par le butin", function()
	-- Le jeu ne réserve rien : turtle.dig() range dans le premier slot libre.
	-- C'est précisément pourquoi la protection doit dépendre du CONTENU.
	fresh()
	mock.setBlock(1, 0, 0, "minecraft:stone")
	turtle.dig()

	H.eq(ccInv.count(1), 1, "le butin y atterrit")
	-- Et il en repart au vidage : aucun numéro de slot n'est protégé.
	H.eq(ccInv.lootCount(), 1, "compté comme du butin")
end)

H.case("lootCount ne compte ni le coffre ni les slots protégés", function()
	-- Remplace les seuils fondés sur le nombre de slots libres, qui
	-- dépendaient du nombre de slots réservés et devenaient faux dès qu'on y
	-- touchait.
	fresh()
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)
	mock.setSlot(3, "minecraft:diamond", 2)
	mock.setSlot(4, "minecraft:cobblestone", 64)

	H.eq(ccInv.lootCount(), 3, "sans protection : seul le coffre est exclu")
	H.eq(ccInv.lootCount({ [1] = true }), 2, "carburant protégé")
	H.eq(ccInv.lootCount({ [1] = true, [3] = true, [4] = true }), 0, "tout protégé")
end)

-- ---------------------------------------------------------------------------
-- Recherche
-- ---------------------------------------------------------------------------

H.case("find et findAny", function()
	fresh()
	mock.setSlot(3, "minecraft:diamond", 2)
	mock.setSlot(7, "minecraft:coal", 10)

	H.eq(ccInv.find("minecraft:diamond"), 3, "find")
	H.isNil(ccInv.find("minecraft:emerald"), "absent")

	local slot, name = ccInv.findAny({ "minecraft:emerald", "minecraft:coal" })
	H.eq(slot, 7, "findAny slot")
	H.eq(name, "minecraft:coal", "findAny nom")
end)

H.case("findChest renvoie nil quand le coffre a disparu", function()
	fresh()
	mock.setSlot(16, ENDER, 1)
	H.eq(ccInv.findChest(), 16, "coffre présent")

	-- SearchEnderChest gardait son index périmé : le script sélectionnait alors
	-- un slot arbitraire et posait du cobble à la place du coffre.
	mock.setSlot(16, nil)
	H.isNil(ccInv.findChest(), "coffre perdu")
end)

H.case("findChest reconnaît aussi l'ender chest vanilla", function()
	fresh()
	mock.setSlot(5, "minecraft:ender_chest", 1)
	-- Identifiant absent de la liste de ccQuarry.
	H.eq(ccInv.findChest(), 5, "vanilla")
end)

H.case("findChest reconnaît un ender chest d'un mod imprévu", function()
	-- Une liste de noms exacts ne peut pas suivre les identifiants de tous les
	-- mods. En jeu, un ender chest non prévu n'était pas reconnu du tout, et
	-- le butin partait au sol.
	fresh()
	for _, name in ipairs({
		"enderchests:ender_chest",
		"SomeMod:EnderChest",
		"quark:pink_shulker_box",
		"minecraft:shulker_box",
	}) do
		mock.install()
		ccInv.reset()
		mock.setSlot(4, name, 1)
		H.eq(ccInv.findChest(), 4, name)
	end
end)

H.case("findChest ignore ce qui n'est pas un conteneur transportable", function()
	fresh()
	-- Un coffre ordinaire éparpillerait son contenu quand on le casse : il ne
	-- doit surtout pas servir au cycle poser / vider / reprendre.
	for _, name in ipairs({ "minecraft:chest", "minecraft:barrel", "minecraft:cobblestone" }) do
		mock.install()
		ccInv.reset()
		mock.setSlot(4, name, 1)
		H.isNil(ccInv.findChest(), name)
	end
end)

H.case("isDepot accepte tout inventaire fixe, isChest reste restrictif", function()
	fresh()
	-- Un conteneur fixe n'est jamais cassé par la turtle : n'importe quel
	-- inventaire convient. Le coffre transportable, lui, doit garder son
	-- contenu quand on le casse.
	for _, name in ipairs({ "minecraft:chest", "minecraft:trapped_chest",
		"minecraft:barrel", "minecraft:hopper", "storagedrawers:basicdrawers",
		"ironchest:iron_chest" }) do
		H.eq(ccInv.isDepot(name), true, "depot : " .. name)
		H.eq(ccInv.isChest(name), false, "pas transportable : " .. name)
	end

	H.eq(ccInv.isDepot("minecraft:stone"), false, "pierre")
	H.eq(ccInv.isDepot("minecraft:dirt"), false, "terre")
end)

H.case("depotAt interroge peripheral en priorité, et compte les slots", function()
	-- Plus fiable qu'une liste de noms : l'API dit si le bloc est un inventaire
	-- et de quelle taille, quel que soit le mod.
	fresh()
	mock.setChest(1, 0, 0, {}, 27)

	local found, name, slots = ccInv.depotAt("forward")
	H.eq(found, true, "coffre accepté")
	H.eq(name, "minecraft:chest", "nom remonté")
	H.eq(slots, 27, "taille remontée par peripheral")
end)

H.case("un petit tampon de machine est écarté par le seuil", function()
	-- Un four a 3 slots, un hopper 5 : ce sont des machines, pas du stockage.
	fresh()
	mock.setChest(1, 0, 0, {}, 5)
	mock.setBlock(1, 0, 0, { name = "minecraft:hopper", inventory = {}, size = 5 })

	local found, name, slots = ccInv.depotAt("forward")
	H.eq(found, false, "refusé malgré le nom présent dans depotPatterns")
	H.eq(slots, 5, "taille connue")
	H.eq(name, "minecraft:hopper", "nom remonté")
end)

H.case("le seuil est configurable", function()
	fresh({ depotMinSlots = 5 })
	mock.setBlock(1, 0, 0, { name = "minecraft:hopper", inventory = {}, size = 5 })
	H.eq(ccInv.depotAt("forward"), true, "accepté avec un seuil abaissé")
end)

H.case("un conteneur d'un mod inconnu est reconnu par sa taille", function()
	-- C'est tout l'intérêt : aucun motif de nom ne correspond, mais l'API
	-- peripheral tranche.
	fresh()
	mock.setBlock(1, 0, 0, { name = "somemod:magic_pouch", inventory = {}, size = 54 })

	H.eq(ccInv.isDepot("somemod:magic_pouch"), false, "aucun motif ne correspond")
	H.eq(ccInv.depotAt("forward"), true, "accepté par sa taille")
end)

H.case("sans peripheral sur les blocs voisins, repli sur les motifs", function()
	-- Sur un turtle, left et right sont réservés aux upgrades : il n'est pas
	-- acquis qu'il voie ses voisins. Le repli doit rester fonctionnel.
	fresh()
	mock.setAdjacentPeripherals(false)

	mock.setBlock(1, 0, 0, { name = "minecraft:chest", inventory = {}, size = 27 })
	local found, name, slots = ccInv.depotAt("forward")
	H.eq(found, true, "reconnu par son nom")
	H.eq(name, "minecraft:chest", "nom remonté")
	H.isNil(slots, "taille inconnue par cette voie")

	mock.setBlock(1, 0, 0, { name = "somemod:magic_pouch", inventory = {}, size = 54 })
	H.eq(ccInv.depotAt("forward"), false, "nom inconnu, et pas de peripheral")
end)

H.case("depotAt inspecte au lieu de tenter un dépôt", function()
	-- turtle.drop() réussit AUSSI quand il n'y a rien en face : sans
	-- inspection, « déposer dans le coffre » et « perdre son butin au sol »
	-- sont indiscernables.
	fresh()
	H.eq(ccInv.depotAt("forward"), false, "rien devant")

	mock.setBlock(1, 0, 0, "minecraft:stone")
	H.eq(ccInv.depotAt("forward"), false, "un bloc plein n'est pas un dépôt")

	mock.setChest(1, 0, 0, {}, 27)
	local found, name = ccInv.depotAt("forward")
	H.eq(found, true, "coffre devant")
	H.eq(name, "minecraft:chest", "nom remonté")
end)

H.case("compact regroupe les piles partielles d'un même objet", function()
	-- Le butin miné atterrit dans le slot SÉLECTIONNÉ, et chaque opération
	-- déplace cette sélection : on se retrouve avec plusieurs piles partielles
	-- du même bloc, qui occupent des slots pour rien.
	fresh()
	mock.setSlot(2, "minecraft:cobblestone", 30)
	mock.setSlot(5, "minecraft:cobblestone", 20)
	mock.setSlot(9, "minecraft:cobblestone", 14)
	mock.setSlot(3, "minecraft:iron_ore", 4)

	H.eq(ccInv.freeCount(), 12, "quatre slots occupés au départ")
	ccInv.compact()

	H.eq(ccInv.count(2), 64, "les trois piles n'en font plus qu'une")
	H.eq(ccInv.count(5), 0, "slot libéré")
	H.eq(ccInv.count(9), 0, "slot libéré")
	H.eq(ccInv.count(3), 4, "le minerai n'a pas bougé")
	H.eq(ccInv.freeCount(), 14, "deux slots récupérés")
end)

H.case("compact déborde correctement au-delà d'une pile pleine", function()
	fresh()
	mock.setSlot(2, "minecraft:cobblestone", 50)
	mock.setSlot(4, "minecraft:cobblestone", 50)

	ccInv.compact()
	H.eq(ccInv.count(2), 64, "première pile pleine")
	H.eq(ccInv.count(4), 36, "le reste demeure")
	H.eq(ccInv.freeCount(), 14, "aucun slot perdu ni gagné")
end)

H.case("compact ne mélange jamais deux objets différents", function()
	fresh()
	mock.setSlot(2, "minecraft:coal", 10)
	mock.setSlot(3, "minecraft:charcoal", 10)

	ccInv.compact()
	H.eq(ccInv.count(2), 10, "charbon intact")
	H.eq(ccInv.count(3), 10, "charbon de bois intact")
end)

H.case("les opérations rendent la sélection telle qu'elles l'ont trouvée", function()
	-- Sans cela, dumpTrash laisse la sélection sur le dernier slot vidé, et
	-- tout ce qui est miné ensuite -- y compris pendant le trajet vers la
	-- cellule suivante, qui creuse devant lui -- y atterrit.
	fresh({ trash = { "minecraft:cobblestone" } })
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(5, "minecraft:cobblestone", 64)
	mock.setSlot(9, "minecraft:cobblestone", 64)
	mock.setSlot(11, "minecraft:iron_ore", 3)
	mock.setSlot(12, "minecraft:iron_ore", 3)
	mock.setChest(0, 0, -1, {}, 27)

	turtle.select(1)
	ccInv.dumpTrash("up")
	H.eq(turtle.getSelectedSlot(), 1, "après dumpTrash")

	ccInv.compact()
	H.eq(turtle.getSelectedSlot(), 1, "après compact")

	ccInv.moveToSlot(11, 7)
	H.eq(turtle.getSelectedSlot(), 1, "après moveToSlot")

	ccInv.unload("down", { protect = { [1] = true } })
	H.eq(turtle.getSelectedSlot(), 1, "après unload")
end)

H.case("la sélection est rendue même quand l'opération échoue", function()
	fresh()
	local plein = {}
	for i = 1, 27 do plein[i] = { name = "minecraft:stone", count = 64 } end
	mock.setChest(0, 0, -1, plein, 27)
	mock.setSlot(4, "minecraft:diamond", 5)

	turtle.select(1)
	local ok = ccInv.unload("down")
	H.eq(ok, false, "vidage impossible, coffre plein")
	H.eq(turtle.getSelectedSlot(), 1, "sélection rendue malgré l'échec")
end)

H.case("selectForMining ramène la sélection au premier slot", function()
	fresh()
	turtle.select(9)
	H.eq(ccInv.selectForMining(), 1, "slot retenu")
	H.eq(turtle.getSelectedSlot(), 1, "sélection ramenée")
end)

H.case("selectForMining ne coûte rien si la sélection n'a pas bougé", function()
	-- select est une commande à un tick, getSelectedSlot est immédiat : on ne
	-- paie que lorsque c'est nécessaire.
	fresh()
	turtle.select(1)
	local selects = 0
	local vrai = turtle.select
	turtle.select = function(s) selects = selects + 1 return vrai(s) end

	ccInv.selectForMining()
	ccInv.selectForMining()
	turtle.select = vrai

	H.eq(selects, 0, "aucun select superflu")
end)

H.case("miner depuis le premier slot empile densément", function()
	-- Sans remise à zéro de la sélection, le butin atterrit là où la dernière
	-- opération l'avait laissée, et le même bloc se retrouve éparpillé.
	fresh()
	for z = 0, 5 do mock.setBlock(1, 0, z, "minecraft:stone") end

	for _ = 1, 6 do
		turtle.select(10)          -- comme après une opération quelconque
		ccInv.selectForMining()
		turtle.dig()
		mock.setBlock(1, 0, 0, "minecraft:stone")
	end

	H.eq(ccInv.count(1), 6, "tout dans le premier slot")
	H.eq(ccInv.freeCount(), 15, "un seul slot occupé")
end)

H.case("moveToSlot transfère et vide le slot source", function()
	fresh()
	mock.setSlot(4, "minecraft:coal", 30)

	H.ok(ccInv.moveToSlot(4, 1), "transfert")
	H.eq(ccInv.count(4), 0, "source vidée")
	H.eq(ccInv.count(1), 30, "destination")
end)

H.case("moveToSlot déplace l'occupant au lieu de renoncer", function()
	-- C'est ce qui permet au carburant de regagner son emplacement quand du
	-- butin l'a squatté. L'ancienne version se contentait d'échouer, et
	-- l'emplacement restait occupé pour toute la session.
	fresh()
	mock.setSlot(4, "minecraft:coal", 30)
	mock.setSlot(1, "minecraft:cobblestone", 5)

	H.ok(ccInv.moveToSlot(4, 1), "déplacement")
	H.eq(ccInv.count(1), 30, "le carburant a pris la place")
	H.eq(ccInv.find("minecraft:cobblestone") ~= nil, true, "le squatteur est ailleurs, pas détruit")
	H.eq(ccInv.count(4), 0, "source vidée")
end)

H.case("moveToSlot fusionne quand c'est le même objet", function()
	fresh()
	mock.setSlot(4, "minecraft:coal", 30)
	mock.setSlot(1, "minecraft:coal", 5)

	H.ok(ccInv.moveToSlot(4, 1), "fusion")
	H.eq(ccInv.count(1), 35, "piles regroupées")
	H.eq(ccInv.count(4), 0, "source vidée")
end)

H.case("moveToSlot échoue proprement sans place où évacuer", function()
	fresh()
	for slot = 1, 16 do mock.setSlot(slot, "minecraft:cobblestone", 64) end
	mock.setSlot(4, "minecraft:coal", 30)

	local ok, reason = ccInv.moveToSlot(4, 1)
	H.eq(ok, false, "échec")
	H.eq(reason, "inventory_full", "raison")
	H.eq(ccInv.count(4), 30, "source intacte")
end)

-- ---------------------------------------------------------------------------
-- Rebut
-- ---------------------------------------------------------------------------

H.case("dumpTrash jette le rebut et épargne le reste", function()
	fresh({ trash = { "minecraft:cobblestone", "minecraft:dirt" } })
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:diamond", 3)
	mock.setSlot(4, "minecraft:dirt", 40)
	mock.setSlot(5, "minecraft:iron_ore", 12)

	H.eq(ccInv.dumpTrash("forward"), 2, "deux slots vidés")
	H.eq(ccInv.count(2), 0, "cobble jeté")
	H.eq(ccInv.count(4), 0, "terre jetée")
	H.eq(ccInv.count(3), 3, "diamant conservé")
	H.eq(ccInv.count(5), 12, "minerai conservé")
	H.eq(ccInv.count(1), 64, "carburant conservé : le rebut ne le concerne pas")
	H.eq(ccInv.count(16), 1, "coffre conservé")

	H.eq(mock.groundCount("minecraft:cobblestone"), 64, "cobble au sol")
	H.eq(mock.groundCount("minecraft:dirt"), 40, "terre au sol")
end)

H.case("liste de rebut vide : rien n'est jeté", function()
	fresh()
	mock.setSlot(2, "minecraft:cobblestone", 64)

	H.eq(ccInv.dumpTrash(), 0, "aucun slot vidé")
	H.eq(ccInv.count(2), 64, "cobble conservé")
end)

H.case("le rebut ne touche jamais le coffre, où qu il soit", function()
	fresh({ trash = { "minecraft:cobblestone" } })
	mock.setSlot(5, ENDER, 1)
	mock.setSlot(2, "minecraft:cobblestone", 64)

	ccInv.dumpTrash()
	H.eq(ccInv.count(5), 1, "coffre conservé")
end)

-- ---------------------------------------------------------------------------
-- Coffre
-- ---------------------------------------------------------------------------

H.case("placeChest vérifie que la pose a réussi", function()
	fresh()
	mock.setSlot(16, ENDER, 1)
	-- La case visée est déjà occupée : la pose doit échouer proprement.
	-- ccQuarry marquait enderChestPlaced sans regarder le retour, puis jetait
	-- tout l'inventaire dans le vide.
	mock.setBlock(0, 0, -1, "minecraft:stone")

	local ok, reason = ccInv.placeChest("down")
	H.eq(ok, false, "échec")
	H.eq(reason, "place_failed", "raison")
	H.eq(ccInv.count(16), 1, "le coffre est toujours en main")
end)

H.case("placeChest sans coffre : no_chest", function()
	fresh()
	local ok, reason = ccInv.placeChest("down")
	H.eq(ok, false, "échec")
	H.eq(reason, "no_chest", "raison")
end)

H.case("placeChest puis takeChest, le coffre revient dans son slot réservé", function()
	fresh()
	mock.setSlot(5, ENDER, 1)

	H.ok(ccInv.placeChest("down"), "pose")
	H.eq(ccInv.count(5), 0, "sorti de l'inventaire")
	H.ok(mock.getBlock(0, 0, -1), "coffre dans le monde")

	H.ok(ccInv.takeChest("down"), "reprise")
	H.eq(ccInv.count(16), 1, "rangé dans le slot réservé")
	H.isNil(mock.getBlock(0, 0, -1), "retiré du monde")
end)

H.case("dropTo sur un coffre plein : container_full, sans boucler", function()
	-- `while getItemCount(i) > 0 and not dropUp() do end` bouclait sans fin.
	fresh()
	local plein = {}
	for i = 1, 27 do plein[i] = { name = "minecraft:stone", count = 64 } end
	mock.setChest(0, 0, -1, plein, 27)
	mock.setSlot(2, "minecraft:cobblestone", 64)

	local ok, reason = ccInv.dropTo("down", 2)
	H.eq(ok, false, "échec")
	H.eq(reason, "container_full", "raison")
	H.eq(ccInv.count(2), 64, "rien n'a été déposé")
end)

H.case("unload épargne le coffre et les slots désignés, rien d'autre", function()
	fresh()
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:diamond", 5)

	H.ok(ccInv.unload("down", { protect = { [1] = true } }), "vidage")
	H.eq(ccInv.count(2), 0, "cobble déposé")
	H.eq(ccInv.count(3), 0, "diamant déposé")
	H.eq(ccInv.count(1), 64, "carburant conservé, parce que DÉSIGNÉ")
	H.eq(ccInv.count(16), 1, "coffre conservé, reconnu par ccInv")
	H.eq(ccInv.lootCount({ [1] = true }), 0, "plus rien à déposer")
end)

H.case("sans désignation, le carburant part au coffre comme le reste", function()
	-- Le point de bascule : le slot 1 n'est plus sacré. C'est ce qui permet
	-- au butin qui l'a squatté d'en repartir -- et ce qui impose à ccQuarry de
	-- désigner explicitement le combustible à garder.
	fresh()
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(1, "minecraft:coal", 64)

	H.ok(ccInv.unload("down"), "vidage")
	H.eq(ccInv.count(1), 0, "slot 1 vidé, faute d'être désigné")
end)

H.case("du butin ayant squatté l'emplacement du carburant en repart", function()
	-- Le symptôme observé en jeu : un slot canonique laissé vide se remplit en
	-- minant, puis n'était JAMAIS vidé. Un slot perdu pour toute la session.
	fresh()
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(1, "minecraft:cobblestone", 64)   -- squatte l'emplacement
	mock.setSlot(5, "minecraft:coal", 32)          -- le vrai carburant

	-- ccQuarry désigne le slot qui contient RÉELLEMENT du combustible.
	H.ok(ccInv.unload("down", { protect = { [5] = true } }), "vidage")
	H.eq(ccInv.count(1), 0, "le cobble squatteur est parti")
	H.eq(ccInv.count(5), 32, "le carburant est resté")
end)

H.case("unload jette le rebut au lieu de l'entreposer", function()
	fresh({ trash = { "minecraft:cobblestone" } })
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:diamond", 5)

	H.ok(ccInv.unload("down"), "vidage")
	H.eq(mock.groundCount("minecraft:cobblestone"), 64, "cobble au sol")
	local coffre = mock.getBlock(0, 0, -1).inventory
	H.eq(coffre[1].name, "minecraft:diamond", "seul le diamant est entreposé")
	H.isNil(coffre[2], "rien d'autre dans le coffre")
end)

H.case("unload respecte la liste keep", function()
	fresh()
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:torch", 20)

	H.ok(ccInv.unload("down", { keep = { "minecraft:torch" } }), "vidage")
	H.eq(ccInv.count(3), 20, "torches conservées")
	H.eq(ccInv.count(2), 0, "cobble déposé")
end)

H.case("unload remonte le slot fautif quand le coffre déborde", function()
	fresh()
	local presque = {}
	for i = 1, 27 do presque[i] = { name = "minecraft:stone", count = 64 } end
	mock.setChest(0, 0, -1, presque, 27)
	mock.setSlot(4, "minecraft:diamond", 5)

	local ok, reason, slot = ccInv.unload("down")
	H.eq(ok, false, "échec")
	H.eq(reason, "container_full", "raison")
	H.eq(slot, 4, "slot fautif")
end)
