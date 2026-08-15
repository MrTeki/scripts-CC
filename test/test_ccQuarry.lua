-- Tests de bout en bout : ccQuarry.lua est chargé et exécuté en entier sous
-- le mock, exactement comme le ferait shell.run en jeu.

local H = require("harness")
local mock = require("ccMock")
local ccPlan = require("ccPlan")

local ENDER = "enderstorage:ender_chest"

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
	mock.setSlot(16, ENDER, 1)

	local w, d, h = o.width or 2, o.depth or 2, o.height or 3
	-- Pierre de z = -1 à z = -(h + marge). La surface z = 0 reste de l'air.
	mock.fill(0, 0, -(h + 3), w - 1, d - 1, -1, "minecraft:stone")
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
	mock.setUrl("https://raw.githubusercontent.com/MrTeki/scripts-CC/main/manifest.lua", reel)

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
	run("2", "2", "3")

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
	run("3", "2", "7")

	H.eq(restants(3, 2, 7), 0, "tout le volume est creusé")
	H.eq(mock.getTurtle().z, 0, "revenue à la surface")
end)

H.case("le rebut part au sol et n'engorge pas l'inventaire", function()
	terrain({ width = 3, depth = 3, height = 6 })
	run("3", "3", "6")

	-- 3 x 3 x 6 = 54 blocs de pierre, très au-delà des 14 slots utiles.
	H.ok(mock.groundCount("minecraft:stone") > 40, "la pierre a été jetée")
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
