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

H.case("les slots réservés sont exclus du décompte de places libres", function()
	fresh()
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)

	-- 16 slots, 2 réservés, 14 disponibles.
	H.eq(ccInv.freeCount(), 14, "au départ")
	H.eq(ccInv.reservedCount(), 2, "slots réservés")

	fillSlots(14)
	-- C'est ici que ccQuarry perdait des blocs : son seuil `items > 14` laissait
	-- deux slots, occupés par le carburant et le coffre, donc zéro de libre.
	H.eq(ccInv.freeCount(), 0, "inventaire plein")
end)

H.case("firstFree saute les slots réservés, sauf demande explicite", function()
	fresh()
	mock.setSlot(2, "minecraft:cobblestone", 64)

	H.eq(ccInv.firstFree(), 3, "slot 1 réservé, slot 2 occupé")
	H.eq(ccInv.firstFree(true), 1, "réservés inclus")
end)

H.case("isReserved", function()
	fresh()
	H.eq(ccInv.isReserved(1), true, "carburant")
	H.eq(ccInv.isReserved(16), true, "coffre")
	H.eq(ccInv.isReserved(8), false, "slot ordinaire")
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

H.case("moveTo transfère et vide le slot source", function()
	fresh()
	mock.setSlot(4, "minecraft:coal", 30)

	H.ok(ccInv.moveTo(4, 1), "transfert")
	H.eq(ccInv.count(4), 0, "source vidée")
	H.eq(ccInv.count(1), 30, "destination")
end)

H.case("moveTo échoue sans écraser quand la destination diffère", function()
	fresh()
	mock.setSlot(4, "minecraft:coal", 30)
	mock.setSlot(1, "minecraft:charcoal", 5)

	H.eq(ccInv.moveTo(4, 1), false, "refus")
	H.eq(ccInv.count(4), 30, "source intacte")
	H.eq(ccInv.count(1), 5, "destination intacte")
end)

-- ---------------------------------------------------------------------------
-- Rebut
-- ---------------------------------------------------------------------------

H.case("dumpTrash jette le rebut et épargne le reste", function()
	fresh({ trash = { "minecraft:cobblestone", "minecraft:dirt" } })
	mock.setSlot(1, "minecraft:coal", 64)          -- réservé
	mock.setSlot(16, ENDER, 1)                     -- réservé
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:diamond", 3)
	mock.setSlot(4, "minecraft:dirt", 40)
	mock.setSlot(5, "minecraft:iron_ore", 12)

	H.eq(ccInv.dumpTrash("forward"), 2, "deux slots vidés")
	H.eq(ccInv.count(2), 0, "cobble jeté")
	H.eq(ccInv.count(4), 0, "terre jetée")
	H.eq(ccInv.count(3), 3, "diamant conservé")
	H.eq(ccInv.count(5), 12, "minerai conservé")
	H.eq(ccInv.count(1), 64, "carburant conservé")
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

H.case("le rebut ne touche jamais le coffre, même hors slot réservé", function()
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

H.case("unload vide tout sauf les slots réservés et le coffre", function()
	fresh()
	mock.setChest(0, 0, -1, {}, 27)
	mock.setSlot(1, "minecraft:coal", 64)
	mock.setSlot(16, ENDER, 1)
	mock.setSlot(2, "minecraft:cobblestone", 64)
	mock.setSlot(3, "minecraft:diamond", 5)

	H.ok(ccInv.unload("down"), "vidage")
	H.eq(ccInv.count(2), 0, "cobble déposé")
	H.eq(ccInv.count(3), 0, "diamant déposé")
	H.eq(ccInv.count(1), 64, "carburant conservé")
	H.eq(ccInv.count(16), 1, "coffre conservé")
	H.eq(ccInv.freeCount(), 14, "tous les slots libres")
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
