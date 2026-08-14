-- Tests de ccUtil.

local H = require("harness")
local mock = require("ccMock")
local ccUtil = require("ccUtil")

H.case("roundTo", function()
	H.eq(ccUtil.roundTo(1.5), 2, "1.5")
	H.eq(ccUtil.roundTo(1.4), 1, "1.4")
	H.eq(ccUtil.roundTo(-1.5), -1, "-1.5")
	H.eq(ccUtil.roundTo(3.14159, 2), 3.14, "2 décimales")
	H.eq(ccUtil.roundTo(3.14159, 4), 3.1416, "4 décimales")
	H.eq(ccUtil.roundTo(10), 10, "entier")
end)

H.case("clamp", function()
	H.eq(ccUtil.clamp(5, 1, 10), 5, "dans l'intervalle")
	H.eq(ccUtil.clamp(-3, 1, 10), 1, "sous la borne")
	H.eq(ccUtil.clamp(42, 1, 10), 10, "au-dessus")
end)

H.case("indexOf renvoie nil quand absent, pas false", function()
	local arr = { "a", "b", "c" }
	H.eq(ccUtil.indexOf(arr, "a"), 1, "premier")
	H.eq(ccUtil.indexOf(arr, "c"), 3, "dernier")
	-- ccChopper.indexOf renvoyait false : les deux passent un test de vérité,
	-- mais nil est la convention Lua et se compose avec `or`.
	H.isNil(ccUtil.indexOf(arr, "z"), "absent")
	H.isNil(ccUtil.indexOf({}, "z"), "table vide")
end)

H.case("contains", function()
	H.eq(ccUtil.contains({ 1, 2, 3 }, 2), true, "présent")
	H.eq(ccUtil.contains({ 1, 2, 3 }, 9), false, "absent")
end)

H.case("copy est de surface et indépendante", function()
	local src = { a = 1, b = { imbrique = true } }
	local c = ccUtil.copy(src)
	c.a = 99
	H.eq(src.a, 1, "l'original n'est pas modifié")
	H.eq(c.b, src.b, "les tables imbriquées sont partagées (copie de surface)")
end)

H.case("count compte aussi les clés non numériques", function()
	H.eq(ccUtil.count({}), 0, "vide")
	H.eq(ccUtil.count({ 1, 2, 3 }), 3, "séquence")
	H.eq(ccUtil.count({ a = 1, b = 2 }), 2, "clés nommées")
	H.eq(ccUtil.count({ 1, 2, nom = "x" }), 3, "mixte")
end)

H.case("findPeripheral renvoie le PREMIER du type, pas le dernier", function()
	mock.install()
	mock.addPeripheral("top", "monitor")
	mock.addPeripheral("left", "modem")
	mock.addPeripheral("right", "modem")

	-- ccQuarry.lua:39 parcourait tous les côtés sans sortir de la boucle, et
	-- gardait donc le DERNIER modem trouvé.
	local side, api = ccUtil.findPeripheral("modem")
	H.eq(side, "left", "côté")
	H.ok(api, "api enveloppée")
end)

H.case("findPeripheral renvoie nil quand le type est absent", function()
	mock.install()
	mock.addPeripheral("top", "monitor")

	H.isNil(ccUtil.findPeripheral("modem"), "aucun modem")
end)

H.case("findPeripherals liste tous les côtés, dans l'ordre", function()
	mock.install()
	mock.addPeripheral("left", "modem")
	mock.addPeripheral("top", "monitor")
	mock.addPeripheral("right", "modem")

	local sides = ccUtil.findPeripherals("modem")
	H.eq(#sides, 2, "nombre")
	H.eq(sides[1], "left", "premier")
	H.eq(sides[2], "right", "second")
	H.eq(#ccUtil.findPeripherals("drive"), 0, "type absent")
end)
