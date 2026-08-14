-- Tests de ccFuel, dont le ravitaillement au coffre unique.

local H = require("harness")
local mock = require("ccMock")
local ccInv = require("ccInv")
local ccFuel = require("ccFuel")

local ENDER = "enderstorage:ender_chest"

local function fresh(o)
	mock.install()
	ccInv.reset(o and o.inv or nil)
	if o and o.fuel ~= nil then mock.getTurtle().fuel = o.fuel end
	if o and o.unlimited then mock.getTurtle().unlimitedFuel = true end
end

--- Coffre sous la turtle, avec le contenu donné.
local function chestBelow(contents)
	mock.setChest(0, 0, -1, contents or {}, 27)
end

-- ---------------------------------------------------------------------------
-- Niveau
-- ---------------------------------------------------------------------------

H.case("le carburant illimité devient math.huge, jamais une chaîne", function()
	-- ccQuarry comparait directement "unlimited" à des nombres, une dizaine de
	-- fois : plantage immédiat sur un serveur sans carburant.
	fresh({ unlimited = true })

	H.eq(ccFuel.level(), math.huge, "niveau")
	H.eq(ccFuel.limit(), math.huge, "plafond")
	H.eq(ccFuel.isUnlimited(), true, "isUnlimited")
	H.ok(ccFuel.level() > 5000, "comparaison numérique possible")
end)

H.case("isFuel répond sans rien consommer", function()
	fresh({ fuel = 0 })
	mock.setSlot(3, "minecraft:coal", 10)
	turtle.select(3)

	H.eq(ccFuel.isFuel(), true, "charbon")
	H.eq(ccInv.count(3), 10, "aucun objet consommé")
	H.eq(ccFuel.level(), 0, "aucun carburant gagné")

	mock.setSlot(4, "minecraft:cobblestone", 10)
	turtle.select(4)
	H.eq(ccFuel.isFuel(), false, "cobble")
end)

H.case("burnUpTo s'arrête dès la cible atteinte", function()
	fresh({ fuel = 0 })
	mock.setSlot(1, "minecraft:coal", 10)     -- 80 par unité
	turtle.select(1)

	ccFuel.burnUpTo(200)
	H.ok(ccFuel.level() >= 200, "cible atteinte")
	H.eq(ccFuel.level(), 240, "trois charbons brûlés")
	H.eq(ccInv.count(1), 7, "le reste est conservé")
end)

-- ---------------------------------------------------------------------------
-- Budget
-- ---------------------------------------------------------------------------

H.case("costToHome et reserve", function()
	fresh()
	H.eq(ccFuel.costToHome({ x = 3, y = 5, z = -12 }), 20, "distance")
	H.eq(ccFuel.reserve({ x = 3, y = 5, z = -12 }, nil, 50), 70, "avec marge")
end)

H.case("la garde interdit de descendre sous la réserve", function()
	fresh({ fuel = 100 })
	local pos = { x = 40, y = 40, z = 0 }
	local guard = ccFuel.guard(function() return pos end, nil, 10)

	H.eq(guard(), true, "80 + 10 de réserve, 100 disponibles")
	mock.getTurtle().fuel = 85
	H.eq(guard(), false, "sous la réserve")
end)

H.case("la garde laisse tout passer en carburant illimité", function()
	fresh({ unlimited = true })
	local guard = ccFuel.guard(function() return { x = 9999, y = 9999, z = 0 } end)
	H.eq(guard(), true, "toujours autorisé")
end)

-- ---------------------------------------------------------------------------
-- Ravitaillement depuis l'inventaire
-- ---------------------------------------------------------------------------

H.case("refuelFromInventory brûle ce qu'il trouve", function()
	fresh({ fuel = 0 })
	mock.setSlot(4, "minecraft:cobblestone", 64)
	mock.setSlot(5, "minecraft:charcoal", 8)

	H.ok(ccFuel.refuelFromInventory(300), "ravitaillement")
	H.ok(ccFuel.level() >= 300, "cible atteinte")
	H.eq(ccInv.count(4), 64, "le cobble est intact")
end)

H.case("refuelFromInventory ne brûle pas le coffre", function()
	-- Un coffre en bois EST combustible : sans exclusion explicite, la turtle
	-- brûlerait son propre moyen de vidage.
	fresh({ fuel = 0 })
	mock.setSlot(16, ENDER, 1)
	mock.setSlot(4, "minecraft:coal", 2)

	ccFuel.refuelFromInventory(10000)
	H.eq(ccInv.count(16), 1, "coffre conservé")
end)

H.case("refuelFromInventory distingue rien-trouvé de pas-assez", function()
	fresh({ fuel = 0 })
	local ok, reason = ccFuel.refuelFromInventory(100)
	H.eq(ok, false, "échec")
	H.eq(reason, "no_fuel_found", "inventaire vide")

	mock.setSlot(4, "minecraft:stick", 1)     -- 5 unités
	ok, reason = ccFuel.refuelFromInventory(100)
	H.eq(ok, false, "échec")
	H.eq(reason, "not_enough_fuel", "insuffisant mais présent")
end)

-- ---------------------------------------------------------------------------
-- Ravitaillement au coffre unique
-- ---------------------------------------------------------------------------

H.case("le rebut est retenu, pas rendu : le coffre n'est pas réaspiré en boucle", function()
	-- LE bug d'origine : la pile non combustible était rendue aussitôt, elle
	-- repartait en première position du coffre, et l'aspiration suivante
	-- ramenait le même objet. Ici trois piles de rebut précèdent le charbon.
	fresh({ fuel = 0 })
	chestBelow({
		{ name = "minecraft:cobblestone", count = 64 },
		{ name = "minecraft:dirt", count = 64 },
		{ name = "minecraft:gravel", count = 64 },
		{ name = "minecraft:coal", count = 5 },
	})

	H.ok(ccFuel.refuelFromChest("down", 300), "ravitaillement")
	H.ok(ccFuel.level() >= 300, "cible atteinte")
end)

H.case("le coffre retrouve son ordre, et les piles non examinées ne bougent pas", function()
	fresh({ fuel = 0 })
	chestBelow({
		{ name = "minecraft:cobblestone", count = 64 },
		{ name = "minecraft:dirt", count = 32 },
		{ name = "minecraft:coal", count = 4 },
		{ name = "minecraft:gravel", count = 17 },
	})

	H.ok(ccFuel.refuelFromChest("down", 200), "ravitaillement")

	local inv = mock.getBlock(0, 0, -1).inventory
	-- Le rebut est rendu dans l'ordre où il a été aspiré, donc aux mêmes places.
	H.eq(inv[1].name, "minecraft:cobblestone", "slot 1")
	H.eq(inv[1].count, 64, "slot 1 quantité")
	H.eq(inv[2].name, "minecraft:dirt", "slot 2")
	H.eq(inv[2].count, 32, "slot 2 quantité")
	-- Le charbon consommé laisse sa place vide : le coffre ne se compacte pas.
	H.isNil(inv[3], "slot 3 libéré par le charbon brûlé")
	-- Et le gravier, jamais aspiré, n'a pas bougé d'un pouce.
	H.eq(inv[4].name, "minecraft:gravel", "slot 4 intouché")
	H.eq(inv[4].count, 17, "slot 4 quantité")
end)

H.case("le reste de combustible part dans le slot réservé", function()
	fresh({ fuel = 0 })
	chestBelow({ { name = "minecraft:coal", count = 64 } })

	H.ok(ccFuel.refuelFromChest("down", 100), "ravitaillement")
	-- 100 / 80 = 2 charbons brûlés, 62 conservés en réserve.
	H.eq(ccInv.count(1), 62, "réserve dans le slot carburant")
	H.isNil(mock.getBlock(0, 0, -1).inventory[1], "le coffre a été vidé de sa pile")
end)

H.case("coffre sans combustible : no_fuel_found, contenu intact", function()
	fresh({ fuel = 0 })
	chestBelow({
		{ name = "minecraft:cobblestone", count = 64 },
		{ name = "minecraft:dirt", count = 10 },
	})

	local ok, reason = ccFuel.refuelFromChest("down", 500)
	H.eq(ok, false, "échec")
	H.eq(reason, "no_fuel_found", "raison")

	local inv = mock.getBlock(0, 0, -1).inventory
	H.eq(inv[1].name, "minecraft:cobblestone", "slot 1 restitué")
	H.eq(inv[2].count, 10, "slot 2 restitué")
	H.eq(ccInv.freeCount(), 14, "inventaire rendu")
end)

H.case("coffre vide : no_fuel_found immédiat", function()
	fresh({ fuel = 0 })
	chestBelow({})

	local ok, reason = ccFuel.refuelFromChest("down", 500)
	H.eq(ok, false, "échec")
	H.eq(reason, "no_fuel_found", "raison")
end)

H.case("combustible insuffisant : not_enough_fuel, et ce qui existe est brûlé", function()
	fresh({ fuel = 0 })
	chestBelow({ { name = "minecraft:stick", count = 2 } })     -- 10 unités

	local ok, reason = ccFuel.refuelFromChest("down", 500)
	H.eq(ok, false, "échec")
	H.eq(reason, "not_enough_fuel", "raison")
	H.eq(ccFuel.level(), 10, "tout a été brûlé")
end)

H.case("scratch borne le nombre de piles examinées", function()
	-- La limite assumée du coffre unique : au-delà des slots libres, la turtle
	-- ne voit pas plus loin.
	fresh({ fuel = 0 })
	local contents = {}
	for i = 1, 20 do contents[i] = { name = "minecraft:cobblestone", count = 64 } end
	contents[21] = { name = "minecraft:coal", count = 64 }
	chestBelow(contents)

	local ok, reason = ccFuel.refuelFromChest("down", 300, { scratch = 5 })
	H.eq(ok, false, "échec")
	H.eq(reason, "no_fuel_found", "le charbon est hors de portée")
	H.eq(mock.getBlock(0, 0, -1).inventory[1].name, "minecraft:cobblestone", "coffre restitué")
end)

H.case("carburant illimité : le coffre n'est même pas touché", function()
	fresh({ unlimited = true })
	chestBelow({ { name = "minecraft:coal", count = 64 } })

	H.ok(ccFuel.refuelFromChest("down", 500), "aucun besoin")
	H.eq(mock.getBlock(0, 0, -1).inventory[1].count, 64, "coffre intact")
end)
