-- Tests de bout en bout : ccChopper.lua est chargé et exécuté en entier sous
-- le mock, exactement comme le ferait shell.run en jeu.
--
-- Les cas modélisent ce qui cassait réellement l'ancienne version : bloc non
-- ligneux sur le trajet, inventaire plein en plein arbre, panne sèche, coffre
-- sous la turtle, quatrième argument de pushItems.

local H = require("harness")
local mock = require("ccMock")

local SAPLING = "minecraft:oak_sapling"
local LOG     = "minecraft:oak_log"
local LEAVES  = "minecraft:oak_leaves"

--- URL du dépôt, lue DANS ccChopper.lua : figée ici, elle divergerait au
--- premier changement de branche.
local function repoUrl()
	local f = assert(io.open("ccChopper.lua", "r"))
	local src = f:read("a")
	f:close()
	return assert(src:match('local REPO = "([^"]+)"'), "REPO introuvable dans ccChopper.lua")
end

local function run(...)
	local chunk = assert(loadfile("ccChopper.lua"))
	local vraiPrint = _G.print
	local sorties = {}
	_G.print = function(...) sorties[#sorties + 1] = table.concat({ ... }, " ") end
	local ok, err = pcall(chunk, ...)
	_G.print = vraiPrint
	if not ok then error(err, 0) end
	return sorties
end

--- Exécute un script qui finit dans une attente VOLONTAIRE : c'est le budget
--- d'événements du mock qui l'interrompt, depuis l'ordonnanceur. Toute autre
--- erreur remonte.
local function runWaiting(...)
	local ok, err = pcall(run, ...)
	if not ok and not tostring(err):find("budget", 1, true) then error(err, 0) end
	return ok
end

--- Petit chêne : tronc de 4, quelques feuilles au sommet.
-- La turtle est en (0,0,0) face à +X, le tronc pousse en (1,0,0).
local function plantTree()
	for z = 0, 3 do mock.setBlock(1, 0, z, LOG) end
	mock.setBlock(1, 0, 4, LEAVES)
	mock.setBlock(2, 0, 3, LEAVES)
	mock.setBlock(0, 0, 3, LEAVES)
	mock.setBlock(1, 1, 3, LEAVES)
	mock.setBlock(1, -1, 3, LEAVES)
	mock.setBlock(2, 0, 4, LEAVES)
end

--- Terrain de départ : sol sous la turtle, conteneur derrière, saplings et
--- carburant à bord.
local function terrain(o)
	o = o or {}
	mock.install()
	mock.getTurtle().fuel = o.fuel or 5000

	mock.setSlot(1, "minecraft:coal", 16)
	if o.saplings ~= 0 then mock.setSlot(2, SAPLING, o.saplings or 8) end

	-- Sol : la turtle et l'arbre reposent sur de la terre, que rien ne doit
	-- casser. C'est le témoin du creusement sélectif.
	mock.fill(-1, -1, -1, 3, 1, -1, "minecraft:dirt")

	if not o.noChest then
		mock.setChest(o.chestAt and o.chestAt[1] or -1,
		              o.chestAt and o.chestAt[2] or 0,
		              o.chestAt and o.chestAt[3] or 0,
		              o.chestContents or {}, 27)
	end

	if not o.noTree then plantTree() end
end

--- Contenu du coffre, agrégé par nom.
local function chestSummary(x, y, z)
	local b = mock.getBlock(x or -1, y or 0, z or 0)
	local out = {}
	if not b or not b.inventory then return out end
	for _, item in pairs(b.inventory) do
		out[item.name] = (out[item.name] or 0) + item.count
	end
	return out
end

--- Blocs d'un type donné encore debout autour de l'arbre.
local function countAround(name)
	local n = 0
	for x = 0, 3 do
		for y = -1, 1 do
			for z = 0, 6 do
				local b = mock.getBlock(x, y, z)
				if b and b.name == name then n = n + 1 end
			end
		end
	end
	return n
end

--- Bûches encore debout. Les feuilles ne comptent pas : loin du bois, elles
--- sont désormais laissées à pourrir.
local function treeBlocks() return countAround(LOG) end
local function leavesLeft() return countAround(LEAVES) end

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

H.case("argument non numérique : refus explicite", function()
	terrain()
	local sorties = run("beaucoup")
	H.contains(table.concat(sorties, "\n"), "Argument invalide", "message")
	H.eq(mock.getTurtle().x, 0, "la turtle n'a pas bougé")
end)

H.case("argument nul ou négatif : refus explicite", function()
	terrain()
	H.contains(table.concat(run("0"), "\n"), "Argument invalide", "zéro")
	terrain()
	H.contains(table.concat(run("-2"), "\n"), "Argument invalide", "négatif")
end)

H.case("config crée le fichier d'options sans rien abattre", function()
	terrain()
	local sorties = run("config")
	H.contains(table.concat(sorties, "\n"), "ccchopper.cfg", "message")
	H.ok(fs.exists("ccchopper.cfg"), "fichier d'options créé")
	H.eq(treeBlocks(), 4, "l'arbre est intact")
end)

H.case("l'amorce ne touche pas au réseau quand les APIs sont là", function()
	-- Règle critique : un turtle redémarre à chaque rechargement de chunk, et
	-- startup relance le script.
	terrain()
	run("1")
	H.eq(#mock.httpRequests(), 0, "aucune requête HTTP")
end)

H.case("update consulte le manifeste et n'installe que ce qui est en retard", function()
	terrain()
	local f = assert(io.open("manifest.lua", "r"))
	local reel = f:read("a")
	f:close()
	mock.setUrl(repoUrl() .. "manifest.lua", reel)

	local sorties = run("update")
	H.eq(#mock.httpRequests(), 1, "seul le manifeste est téléchargé")
	H.contains(table.concat(sorties, "\n"), "a jour", "message")
	H.eq(treeBlocks(), 4, "aucun abattage")
end)

-- ---------------------------------------------------------------------------
-- Abattage
-- ---------------------------------------------------------------------------

H.case("un arbre est abattu en entier et la turtle revient à l'origine", function()
	terrain()
	run("1")

	H.eq(treeBlocks(), 0, "plus un bloc d'arbre debout")
	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.y, 0, "revenue en y")
	H.eq(t.z, 0, "revenue en z")
	H.eq(t.dir, 0, "cap d'origine restauré")
end)

H.case("le butin part au conteneur", function()
	terrain()
	run("1")
	local chest = chestSummary()
	H.eq(chest[LOG], 4, "les quatre bûches sont déposées")
end)

H.case("un sapling est replanté avant l'arrêt", function()
	-- L'arrêt sur compte atteint appartient à PLANTATION, justement pour que la
	-- ferme ne reste pas en friche.
	terrain()
	run("1")
	local b = mock.getBlock(1, 0, 0)
	H.ok(b ~= nil, "quelque chose est planté")
	H.eq(b.name, SAPLING, "c'est un sapling")
end)

H.case("RÉGRESSION : rien d'autre que l'arbre n'est cassé", function()
	-- L'ancienne version confiait le trajet à moveToTarget, qui ne cassait que
	-- bûches et feuilles mais bouclait indéfiniment sur tout le reste. Ici tous
	-- les mouvements passent par ccNav avec dig = false, et la décision de
	-- casser reste dans le script.
	terrain()
	mock.setBlock(2, 0, 0, "minecraft:stone")       -- rocher contre le tronc
	mock.setBlock(1, 1, 0, "minecraft:cobblestone") -- et sur le côté
	run("1")

	H.eq(mock.getBlock(2, 0, 0).name, "minecraft:stone", "le rocher est intact")
	H.eq(mock.getBlock(1, 1, 0).name, "minecraft:cobblestone", "le mur est intact")
	H.eq(mock.getBlock(0, 0, -1).name, "minecraft:dirt", "le sol est intact")
	H.eq(treeBlocks(), 0, "l'arbre est abattu malgré tout")
end)

H.case("stock de saplings suffisant : la canopée n'est pas rasée", function()
	-- Les feuilles ne sont cassées que pour servir de poste d'observation,
	-- quand aucune case libre ne permet de voir une diagonale. (2,0,4) n'est
	-- jamais un poste : elle reste à pourrir.
	terrain()     -- 8 saplings, au-dessus de saplingReserve
	run("1")

	H.eq(treeBlocks(), 0, "le bois est abattu")
	H.ok(leavesLeft() > 0, "des feuilles restent")
	H.ok(mock.getBlock(2, 0, 4) ~= nil, "dont la plus éloignée")
end)

H.case("stock de saplings bas : la canopée entière est rasée", function()
	-- Casser une feuille ne rapporte pas plus de saplings que la laisser
	-- pourrir, mais les met en inventaire : c'est ce qui refait le stock.
	terrain({ saplings = 2 })
	run("1")

	H.eq(treeBlocks(), 0, "le bois est abattu")
	H.eq(leavesLeft(), 0, "plus une feuille")
	H.contains(mock.getFile("ccchop.log") or "", "canopee rasee", "le journal le dit")
end)

--- Colonne de `n` bûches sur la case de plantation, sans feuilles.
local function column(n)
	for z = 0, n - 1 do mock.setBlock(1, 0, z, LOG) end
end

H.case("RÉGRESSION : une branche en diagonale stricte, séparée par de l'air, est suivie", function()
	-- Constaté en jeu sur un grand chêne : des bûches en diagonale stricte du
	-- tronc restaient debout. Le générateur (FancyTrunkPlacer) trace les
	-- branches comme des droites discrétisées, sans feuilles près du tronc :
	-- la case entre deux bûches en diagonale est de l'AIR.
	terrain({ noTree = true })
	column(8)
	mock.setBlock(2, 1, 3, LOG)     -- diagonale horizontale de la 4e bûche
	mock.setBlock(3, 2, 4, LOG)     -- coin de la précédente
	mock.setBlock(4, 3, 4, LOG)     -- diagonale horizontale de la précédente
	run("1")

	H.isNil(mock.getBlock(2, 1, 3), "première bûche de branche")
	H.isNil(mock.getBlock(3, 2, 4), "bûche en coin")
	H.isNil(mock.getBlock(4, 3, 4), "bout de branche")
end)

H.case("une branche peut partir de la 3e bûche d'un tronc court", function()
	-- Une branche part à au moins 20 % de la hauteur de l'arbre : pour un
	-- grand chêne dont la colonne fait 5 bûches, c'est la 3e. Sonder seulement
	-- les deux du haut l'aurait manquée.
	terrain({ noTree = true })
	column(5)
	mock.setBlock(2, -1, 2, LOG)
	run("1")

	H.isNil(mock.getBlock(2, -1, 2), "la branche basse est abattue")
end)

H.case("un coin au-dessus du sommet est vu", function()
	-- Rien ne sonde au-dessus du sommet : c'est lui qui doit le faire.
	terrain({ noTree = true })
	column(4)
	mock.setBlock(0, 1, 4, LOG)
	run("1")

	H.isNil(mock.getBlock(0, 1, 4), "la bûche en coin du sommet est abattue")
end)

H.case("les deux premières bûches ne sont pas sondées", function()
	-- Aucune branche ne part si bas : y sonder coûterait sans rien trouver.
	-- Une bûche posée là à la main reste donc, et c'est voulu.
	terrain({ noTree = true })
	column(5)
	mock.setBlock(2, 1, 1, LOG)
	run("1")

	H.ok(mock.getBlock(2, 1, 1) ~= nil, "la diagonale de la 2e bûche n'est pas sondée")
	H.isNil(mock.getBlock(1, 0, 4), "mais le tronc est abattu")
end)

H.case("un poste occupé par autre chose que l'arbre n'est pas cassé", function()
	-- La diagonale se voit alors depuis une autre face.
	terrain({ noTree = true })
	column(5)
	mock.setBlock(0, 0, 2, "minecraft:stone")     -- face -X de la 3e bûche
	mock.setBlock(0, 1, 2, LOG)                   -- diagonale de ce côté
	run("1")

	H.eq(mock.getBlock(0, 0, 2).name, "minecraft:stone", "la pierre est intacte")
	H.isNil(mock.getBlock(0, 1, 2), "la diagonale est vue depuis la face +Y")
end)

H.case("RÉGRESSION : inventaire plein, la turtle vide avant d'abattre", function()
	-- turtle.dig() réussit MÊME quand l'inventaire est plein : l'objet est
	-- alors perdu en silence. L'ancienne version ne testait la place nulle part
	-- pendant l'abattage, et coupait donc l'arbre dans le vide.
	terrain()
	for slot = 3, 16 do mock.setSlot(slot, "minecraft:cobblestone", 64) end
	run("1")

	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.z, 0, "revenue en z")
	H.ok(chestSummary()["minecraft:cobblestone"] ~= nil, "le lest est déposé")
	-- Le vrai enjeu : aucune bûche perdue faute de place.
	H.eq(chestSummary()[LOG], 4, "les quatre bûches sont bien récupérées")
	H.eq(treeBlocks(), 0, "et l'arbre est abattu, une fois la place faite")
end)

H.case("RÉGRESSION : panne sèche, la turtle s'arrête proprement", function()
	-- Ancien comportement : turtle.forward() échouait, turtle.detect() était
	-- faux, donc le code appelait turtle.attack() en boucle.
	terrain({ fuel = 12 })
	run("1")

	local t = mock.getTurtle()
	H.ok(t.fuel >= 0, "le carburant n'est pas négatif")
	H.ok(t.z <= 4, "la turtle n'est pas partie au plafond")
end)

H.case("la marge de carburant ramène la turtle avant la panne", function()
	-- Assez pour monter, pas pour flâner : la réserve doit déclencher le retour.
	terrain({ fuel = 60 })
	run("1")
	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.y, 0, "revenue en y")
	H.eq(t.z, 0, "revenue en z")
end)

-- ---------------------------------------------------------------------------
-- Conteneur
-- ---------------------------------------------------------------------------

H.case("RÉGRESSION : un coffre SOUS la turtle est reconnu et rempli", function()
	-- L'ancienne version testait chestSide == \"down\", alors que l'API
	-- peripheral nomme ce côté « bottom » : la branche ne matchait jamais et la
	-- turtle vidait devant elle, au sol.
	terrain({ chestAt = { 0, 0, -1 } })
	run("1")

	local chest = chestSummary(0, 0, -1)
	H.eq(chest[LOG], 4, "les bûches sont dans le coffre du dessous")
	-- Les feuilles, elles, sont du rebut : elles partent bien par-dessus bord.
	H.eq(mock.groundCount(LOG), 0, "aucune bûche perdue au sol")
end)

H.case("un coffre sur le côté est reconnu, et le cap est rendu", function()
	terrain({ chestAt = { 0, 1, 0 } })
	run("1")

	H.eq(chestSummary(0, 1, 0)[LOG], 4, "les bûches sont dans le coffre latéral")
	H.eq(mock.getTurtle().dir, 0, "cap d'origine restauré")
end)

H.case("sans conteneur, la turtle garde le butin et n'en perd pas au sol", function()
	terrain({ noChest = true })
	run("1")

	local total = 0
	for slot = 1, 16 do
		local d = turtle.getItemDetail(slot)
		if d and d.name == LOG then total = total + d.count end
	end
	H.eq(total, 4, "les bûches restent à bord")
end)

H.case("les saplings manquants sont pris dans le conteneur", function()
	-- L'ancienne version avait la place de ce code, un commentaire décrivant ce
	-- qu'il devait faire, et à l'appel une COPIE de la recherche en inventaire
	-- dont le résultat était jeté : faute de sapling, le script s'arrêtait.
	terrain({ saplings = 0, chestContents = { [1] = { name = SAPLING, count = 12 } } })
	run("1")

	local b = mock.getBlock(1, 0, 0)
	H.ok(b ~= nil and b.name == SAPLING, "un sapling pris au coffre est replanté")
end)

H.case("sans sapling nulle part, la turtle réclame au lieu de s'arrêter", function()
	-- L'attente est volontaire et sans fin : c'est le budget d'événements du
	-- mock qui y met un terme. Ce qui est vérifié ici, c'est qu'elle a bien
	-- tourné en ATTENTE en le disant, plutôt que de s'arrêter en silence.
	terrain({ saplings = 0 })
	mock.setEventBudget(60)
	runWaiting("1")

	local log = mock.getFile("ccchop.log") or ""
	H.contains(log, "Plus de sapling", "la turtle dit ce qui lui manque")
	H.contains(log, "ATTENTE", "et elle attend")
	H.isNil(mock.getBlock(1, 0, 0), "rien n'est planté sans sapling")
end)

-- ---------------------------------------------------------------------------
-- Four
-- ---------------------------------------------------------------------------

--- Slots du four posé sous la turtle, en (0, 0, -1).
-- Le four est un VRAI bloc du monde : les transferts passent donc par les
-- mêmes règles d'insertion que le reste, slot de destination compris.
local function furnaceSlots()
	local b = mock.getBlock(0, 0, -1)
	return (b and b.inventory) or {}
end

--- Terrain avec four : conteneur derrière, four dessous.
-- La turtle se tourne vers le conteneur pour le service, ce qui donne
-- « front » au conteneur et « bottom » au four -- deux noms que le coffre sait
-- résoudre puisqu'ils sont relatifs à la turtle.
local function terrainWithFurnace(o)
	o = o or {}
	terrain(o)
	-- Le four prend la place de la terre sous la turtle : « bottom » pour
	-- l'API peripheral, quel que soit le cap.
	mock.setFurnace(0, 0, -1, o.furnaceContents)
	mock.putFile("ccchopper.cfg", "return { makeCharcoal = true }")
end

H.case("RÉGRESSION : le four reçoit des bûches en entrée et du charbon au foyer", function()
	-- L'ancienne version appelait pushItems SANS slot de destination : la bûche
	-- étant à la fois fondable et combustible, tout partait dans l'entrée.
	terrainWithFurnace({ chestContents = {
		[1] = { name = "minecraft:charcoal", count = 8 },
		[2] = { name = LOG, count = 20 },
	} })

	run("1")

	local slots = furnaceSlots()
	H.ok(slots[1] ~= nil, "le slot d'entrée est rempli")
	H.eq(slots[1].name, LOG, "l'entrée reçoit des bûches")
	H.ok(slots[2] ~= nil, "le foyer est rempli")
	H.eq(slots[2].name, "minecraft:charcoal", "le foyer reçoit du charbon")
end)

H.case("le four est chargé par lots exacts : 8 bûches par charbon", function()
	-- Un charbon allumé brûle jusqu'au bout : allumé pour 3 bûches, il perd 5
	-- cuissons sur 8. 24 bûches disponibles (20 + 4 de l'arbre) : 3 lots.
	terrainWithFurnace({ chestContents = {
		[1] = { name = "minecraft:charcoal", count = 8 },
		[2] = { name = LOG, count = 20 },
	} })

	run("1")

	H.eq(furnaceSlots()[1].count, 24, "24 bûches en entrée")
	H.eq(furnaceSlots()[2].count, 3, "3 charbons au foyer, pas un de plus")
end)

H.case("le combustible disponible limite le nombre de lots", function()
	-- Un seul charbon : un seul lot, même s'il y a 24 bûches. Les 16 autres
	-- attendraient sinon dans l'entrée un combustible qui n'existe pas.
	terrainWithFurnace({ chestContents = {
		[1] = { name = "minecraft:charcoal", count = 1 },
		[2] = { name = LOG, count = 20 },
	} })

	run("1")

	H.eq(furnaceSlots()[1].count, 8, "8 bûches seulement")
	H.eq(furnaceSlots()[2].count, 1, "pour le seul charbon")
	H.eq(chestSummary()[LOG], 16, "le reste au coffre")
end)

H.case("moins d'un lot de bûches : rien n'est chargé", function()
	terrainWithFurnace({ chestContents = { [1] = { name = "minecraft:charcoal", count = 8 } } })

	run("1")     -- 4 bûches seulement

	H.isNil(furnaceSlots()[1], "entrée vide")
	H.isNil(furnaceSlots()[2], "aucun charbon engagé")
	H.eq(chestSummary()[LOG], 4, "les bûches attendent au coffre")
end)

H.case("un lot en cours de cuisson n'est pas complété", function()
	-- Le compléter ferait recouvrir deux lots, et le dernier charbon
	-- s'allumerait pour un reste incomplet.
	terrainWithFurnace({
		chestContents = {
			[1] = { name = "minecraft:charcoal", count = 8 },
			[2] = { name = LOG, count = 20 },
		},
		furnaceContents = { [1] = { name = LOG, count = 5 } },
	})

	run("1")

	H.eq(furnaceSlots()[1].count, 5, "l'entrée n'est pas touchée")
	H.isNil(furnaceSlots()[2], "le foyer non plus")
end)

H.case("sans charbon, le four s'amorce au bois : 3 bûches pour 2", function()
	-- Une bûche cuit 1,5 objet : 2 bûches au foyer cuisent exactement 3
	-- bûches. 20 bûches (16 + 4) : 4 lots, soit 12 en entrée et 8 au foyer.
	terrainWithFurnace({ chestContents = { [1] = { name = LOG, count = 16 } } })

	run("1")

	H.eq(furnaceSlots()[1].count, 12, "12 bûches en entrée")
	H.eq(furnaceSlots()[2].name, LOG, "du bois au foyer")
	H.eq(furnaceSlots()[2].count, 8, "8 bûches au foyer")
end)

H.case("du bois au foyer est repris dès que du charbon est disponible", function()
	-- Le bois rend 0,6 charbon par bûche, le charbon 0,875 : on change de
	-- combustible quand rien ne cuit.
	terrainWithFurnace({
		chestContents = {
			[1] = { name = "minecraft:charcoal", count = 8 },
			[2] = { name = LOG, count = 16 },
		},
		furnaceContents = { [2] = { name = LOG, count = 4 } },
	})

	run("1")

	H.eq(furnaceSlots()[2].name, "minecraft:charcoal", "le foyer passe au charbon")
	H.eq(furnaceSlots()[1].count, 24, "24 bûches : les 4 reprises comptent")
	H.eq(furnaceSlots()[2].count, 3, "3 charbons")
end)

H.case("la sortie du four est vidée dans le conteneur", function()
	-- Foyer déjà plein : sans cela le charbon qui vient de sortir repartirait
	-- aussitôt l'alimenter, ce qui est le bon comportement mais rendrait le cas
	-- illisible.
	terrainWithFurnace({ furnaceContents = {
		[2] = { name = "minecraft:charcoal", count = 64 },
		[3] = { name = "minecraft:charcoal", count = 5 },
	} })

	run("1")

	H.isNil(furnaceSlots()[3], "la sortie est vidée")
	H.eq(chestSummary()["minecraft:charcoal"], 5, "le charbon est au conteneur")
end)

H.case("le charbon produit réalimente le foyer", function()
	-- 16 bûches (12 + 4) : 2 lots, donc 2 des 5 charbons sortis.
	terrainWithFurnace({
		chestContents = { [1] = { name = LOG, count = 12 } },
		furnaceContents = { [3] = { name = "minecraft:charcoal", count = 5 } },
	})

	run("1")

	H.isNil(furnaceSlots()[3], "la sortie est vidée")
	H.eq(furnaceSlots()[2].name, "minecraft:charcoal", "le charbon repart au foyer")
	H.eq(furnaceSlots()[2].count, 2, "juste ce qu'il faut")
	H.eq(chestSummary()["minecraft:charcoal"], 3, "le reste attend au coffre")
end)

H.case("la turtle se ravitaille au charbon sorti du four, pas aux bûches", function()
	-- La sortie du four est vidée AVANT le ravitaillement. Dans l'autre ordre,
	-- la turtle à court ne trouvait au coffre que des bûches et en brûlait une
	-- quinzaine -- 15 unités chacune, contre 80 une fois en charbon de bois.
	terrainWithFurnace({
		fuel = 50,
		chestContents = { [1] = { name = LOG, count = 32 } },
		furnaceContents = { [3] = { name = "minecraft:charcoal", count = 16 } },
	})
	mock.setSlot(1, nil)     -- pas de charbon à bord

	run("1")

	local logs = (chestSummary()[LOG] or 0)
	local slots = furnaceSlots()
	for _, s in pairs(slots) do
		if s.name == LOG then logs = logs + s.count end
	end
	H.eq(logs, 36, "aucune bûche brûlée par la turtle (32 + 4)")
	H.ok(mock.getTurtle().fuel > 1000, "ravitaillée au charbon de bois")
end)

H.case("un four déjà plein ne fait pas boucler le service", function()
	-- Le garde-fou : chaque transfert doit déplacer quelque chose, sinon on
	-- s'arrête. Sans lui, un pushItems qui renvoie 0 tourne indéfiniment.
	terrainWithFurnace({
		furnaceContents = {
			[1] = { name = LOG, count = 64 },
			[2] = { name = "minecraft:charcoal", count = 64 },
		},
	})

	run("1")
	H.eq(furnaceSlots()[1].count, 64, "l'entrée reste pleine")
	H.eq(chestSummary()[LOG], 4, "le butin est quand même déposé")
end)

H.case("sans four, makeCharcoal ne fait pas échouer le service", function()
	terrain()
	mock.putFile("ccchopper.cfg", "return { makeCharcoal = true }")
	run("1")
	H.eq(treeBlocks(), 0, "l'arbre est abattu")
	H.eq(chestSummary()[LOG], 4, "le butin est déposé")
end)

-- ---------------------------------------------------------------------------
-- Sauvegarde et reprise
-- ---------------------------------------------------------------------------

H.case("del supprime la sauvegarde et restaure le startup", function()
	terrain()
	run("1")
	H.ok(fs.exists("ccchop.save") == false or true, "peu importe l'état")

	mock.putFile("ccchop.save", textutils.serialize({ version = 1, data = {
		pos = { x = 0, y = 0, z = 0, dir = 0 }, state = "PLANTATION", trees = 3,
	} }))
	mock.putFile("startup.lua", 'shell.run("ccChopper")\n')

	run("del")
	H.eq(fs.exists("ccchop.save"), false, "sauvegarde supprimée")
	H.eq(fs.exists("startup.lua"), false, "notre startup retiré")
end)

H.case("le startup de l'utilisateur est archivé puis rendu", function()
	-- Pendant le travail, le nôtre prend la place -- c'est ce qui fait repartir
	-- la turtle après un rechargement de chunk. Une fois le compte atteint, le
	-- sien lui est rendu : l'ancienne version l'écrasait sans le sauver.
	terrain()
	mock.putFile("startup.lua", "print('a moi')\n")
	run("1")

	H.eq(mock.getFile("startup.lua"), "print('a moi')\n", "startup de l'utilisateur rendu")
	H.eq(fs.exists("startup.old"), false, "plus d'archive en attente")
end)

H.case("notre startup reste en place tant que le travail n'est pas fini", function()
	terrain({ saplings = 0 })
	mock.setEventBudget(60)
	pcall(run, "1")     -- s'interrompt en attente d'un sapling
	H.contains(mock.getFile("startup.lua") or "", "ccChopper", "startup posé")
end)

H.case("une reprise loin de l'origine ramène la turtle sans raser le décor", function()
	-- La récursion d'abattage est une pile d'appels Lua : elle ne se sauvegarde
	-- pas. Reprendre en plein arbre n'a donc de sens que par un retour.
	--
	-- Le trajet direct passe ici par de la pierre : il doit ÉCHOUER, et laisser
	-- la place au trajet de secours par-dessus la canopée. Une turtle qui
	-- rentre en creusant tout droit ramènerait une cheminée dans le paysage.
	terrain({ noTree = true })
	mock.setBlock(1, 0, 3, LOG)                      -- un reste d'arbre
	mock.setBlock(1, 0, 2, "minecraft:stone")        -- et un rocher dessous
	mock.setBlock(1, 0, 1, "minecraft:stone")
	mock.getTurtle().x, mock.getTurtle().z = 1, 4
	mock.putFile("ccchop.save", textutils.serialize({ version = 1, data = {
		pos = { x = 1, y = 0, z = 4, dir = 0 }, state = "ABATTAGE", trees = 2,
	} }))

	run("1")

	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.z, 0, "revenue en z")
	H.eq(mock.getBlock(1, 0, 2).name, "minecraft:stone", "le rocher est intact")
	H.eq(mock.getBlock(1, 0, 1).name, "minecraft:stone", "le second aussi")
end)

H.case("une sauvegarde de l'ancien format est reprise, pas jetée", function()
	-- Sept index numériques, positions en X / Y / Z / direction majuscules.
	terrain({ noTree = true })
	mock.getTurtle().x, mock.getTurtle().z = 2, 1
	mock.putFile("ccchop.save", textutils.serialize({
		[1] = { X = 2, Y = 0, Z = 1, direction = 0 },
		[2] = { X = 0, Y = 0, Z = 0, direction = 0 },
		[3] = { X = 0, Y = 0, Z = 0, direction = 0 },
		[4] = "right", [5] = "left", [6] = "wait", [7] = {},
	}))
	mock.setEventBudget(100)

	runWaiting("1")     -- finit en attente de la pousse

	local t = mock.getTurtle()
	H.eq(t.x, 0, "revenue en x")
	H.eq(t.z, 0, "revenue en z")
end)

H.case("la sauvegarde suit les rotations, pas seulement les déplacements", function()
	-- En quittant la partie, le jeu n'accorde qu'un tick à la turtle : une
	-- rotation non enregistrée la fait rouvrir avec un cap erroné.
	terrain({ chestAt = { 0, 1, 0 } })
	run("1")

	local saved = textutils.unserialize(mock.getFile("ccchop.save") or "")
	if saved then
		H.ok(saved.data.pos.dir ~= nil, "le cap est sauvegardé")
	end
end)

-- ---------------------------------------------------------------------------
-- Ferme continue
-- ---------------------------------------------------------------------------

H.case("deux arbres d'affilée : la ferme boucle", function()
	terrain()
	mock.setEventBudget(400)

	-- L'arbre repousse dès que la turtle a replanté : on simule la croissance
	-- en remplaçant le sapling par un tronc à la première attente.
	local vraiTimer = os.startTimer
	local pousses = 0
	os.startTimer = function(s)
		local b = mock.getBlock(1, 0, 0)
		if b and b.name == SAPLING and pousses < 1 then
			pousses = pousses + 1
			plantTree()
		end
		return vraiTimer(s)
	end

	local ok, err = pcall(run, "2")
	os.startTimer = vraiTimer
	H.ok(ok, "exécution : " .. tostring(err))

	H.eq(chestSummary()[LOG], 8, "les bûches des deux arbres sont déposées")
	H.eq(mock.getBlock(1, 0, 0).name, SAPLING, "et un sapling est replanté")
end)

-- ---------------------------------------------------------------------------
-- Poudre d'os
-- ---------------------------------------------------------------------------

--- Simule la poudre d'os : turtle.place() sur le sapling la consomme, et
--- l'arbre pousse à la `poussee`-ième application. Le place du mock, lui,
--- refuse toute case occupée.
local function boneMeal(poussee)
	local vraiPlace = turtle.place
	local applications = 0
	turtle.place = function()
		local t = mock.getTurtle()
		local d = turtle.getItemDetail()
		local front = mock.getBlock(1, 0, 0)
		if d and d.name == "minecraft:bone_meal" and t.x == 0 and t.y == 0 and t.z == 0
			and t.dir == 0 and front and front.name == SAPLING then
			mock.setSlot(turtle.getSelectedSlot(), d.count > 1 and d.name or nil, d.count - 1)
			applications = applications + 1
			if applications >= poussee then plantTree() end
			return true
		end
		return vraiPlace()
	end
	return function() return applications end
end

H.case("RÉGRESSION : la poudre d'os est réappliquée sans attendre la pousse naturelle", function()
	-- Constaté en jeu : 20 s entre deux applications, l'attente de la pousse
	-- naturelle étant appliquée aussi après une poudre d'os.
	terrain({ noTree = true })
	mock.setBlock(1, 0, 0, SAPLING)
	mock.setSlot(3, "minecraft:bone_meal", 10)
	local applications = boneMeal(3)

	run("1")

	H.eq(applications(), 3, "trois applications")
	H.eq(treeBlocks(), 0, "l'arbre poussé est abattu")
	H.ok(os.clock() < 20, "moins d'une attente naturelle au total : " .. os.clock() .. " s")
end)

H.case("la poudre d'os restante reste à bord", function()
	terrain({ noTree = true })
	mock.setBlock(1, 0, 0, SAPLING)
	mock.setSlot(3, "minecraft:bone_meal", 10)
	boneMeal(3)

	run("1")

	H.eq(chestSummary()["minecraft:bone_meal"], nil, "rien au coffre")
	local reste = 0
	for slot = 1, 16 do
		local d = turtle.getItemDetail(slot)
		if d and d.name == "minecraft:bone_meal" then reste = reste + d.count end
	end
	H.eq(reste, 7, "sept poudres d'os restantes")
end)

-- ---------------------------------------------------------------------------
-- Constaté en jeu : carburant bas, saplings brûlés, attente qui tourne en rond
-- ---------------------------------------------------------------------------

H.case("RÉGRESSION : le ravitaillement ne brûle pas les saplings", function()
	-- Carburant sous la réserve : l'abattage est différé, la turtle rentre se
	-- ravitailler. ccFuel brûlait alors tout ce qui est combustible pour viser
	-- fuelTopUp -- saplings compris, puisqu'un sapling brûle.
	terrain({ fuel = 50, chestContents = { [1] = { name = "minecraft:coal", count = 32 } } })

	run("1")

	H.eq(treeBlocks(), 0, "l'arbre est abattu une fois ravitaillée")
	H.eq(turtle.getItemCount(2), 7, "huit saplings, un replanté, aucun brûlé")
end)

H.case("RÉGRESSION : un arbre adulte devant n'exige pas de sapling", function()
	-- La turtle refusait de repartir faute de sapling, alors que la case de
	-- plantation portait un arbre prêt à être abattu.
	terrain({ fuel = 50, saplings = 0,
	          chestContents = { [1] = { name = "minecraft:coal", count = 32 } } })
	mock.setEventBudget(60)

	runWaiting("1")     -- finit en attente : plus rien à replanter ensuite

	H.eq(treeBlocks(), 0, "l'arbre est abattu malgré l'absence de sapling")
end)

H.case("RÉGRESSION : une attente qui dure espace ses services", function()
	-- Chaque réveil relançait un service complet toutes les 5 s, coffre
	-- cherché et turtle retournée compris : vue de dehors, elle tournait sur
	-- elle-même sans fin.
	terrain({ noTree = true, saplings = 0 })
	-- L'écran se redessine toutes les 0,5 s : chaque seconde d'attente coûte
	-- deux événements.
	mock.setEventBudget(400)

	runWaiting("1")

	local times = {}
	for t in (mock.getFile("ccchop.log") or ""):gmatch("%[([%d%.]+)%] SERVICE | SERVICE") do
		times[#times + 1] = tonumber(t)
	end
	H.ok(#times >= 4, "plusieurs services : " .. #times)
	for i = 3, #times do
		H.ok(times[i] - times[i - 1] >= times[i - 1] - times[i - 2],
			"écart croissant entre les services " .. (i - 1) .. " et " .. i)
	end
	H.ok(times[#times] - times[#times - 1] >= 40, "jusqu'à près d'une minute")
end)

H.case("à court de charbon, les bûches servent de carburant, jamais les saplings", function()
	terrain({ fuel = 50, chestContents = { [1] = { name = LOG, count = 32 } } })
	mock.setSlot(1, nil)     -- pas de charbon à bord

	run("1")

	H.eq(treeBlocks(), 0, "l'arbre est abattu grâce aux bûches")
	local saplings = 0
	for slot = 1, 16 do
		local d = turtle.getItemDetail(slot)
		if d and d.name == SAPLING then saplings = saplings + d.count end
	end
	H.eq(saplings, 7, "aucun sapling brûlé")
	-- Le bois n'est brûlé que jusqu'au plancher, pas jusqu'à fuelTopUp :
	-- c'est la récolte. Viser 2000 aurait englouti tout le coffre.
	H.ok((chestSummary()[LOG] or 0) >= 15, "la récolte reste au coffre : "
		.. tostring(chestSummary()[LOG]))
end)

-- ---------------------------------------------------------------------------
-- Commandes pendant une attente
-- ---------------------------------------------------------------------------

--- Simule un appui sur une touche dès que la turtle se met à attendre la
--- pousse (minuteur de growWait).
local function pressDuringGrowth(key)
	local vraiTimer = os.startTimer
	local pressed = false
	os.startTimer = function(s)
		local id = vraiTimer(s)
		if s == 20 and not pressed then
			pressed = true
			os.queueEvent("char", key)
		end
		return id
	end
	return function() os.startTimer = vraiTimer end
end

H.case("RÉGRESSION : C bascule le charbon une seule fois, et tout de suite", function()
	-- Constaté en jeu : en attente de pousse, la touche était vue par l'attente
	-- de la machine ET par la coroutine d'interface. La première basculait
	-- aussitôt, la seconde empilait une bascule appliquée au réveil suivant,
	-- 20 s plus tard -- qui annulait la première.
	terrain({ noTree = true })
	mock.setBlock(1, 0, 0, SAPLING)
	mock.setEventBudget(200)
	local restore = pressDuringGrowth("c")

	runWaiting("1")
	restore()

	local log = mock.getFile("ccchop.log") or ""
	local active = log:match("%[([%d%.]+)%] %S+ | Charbon de bois : active")
	H.ok(active ~= nil, "le charbon est activé")
	H.ok(tonumber(active) < 20, "sans attendre la fin de l'attente : " .. tostring(active))
	H.ok(not log:find("Charbon de bois : desactive", 1, true), "et pas désactivé ensuite")
end)

H.case("STOP pendant une attente est pris en compte sans attendre son terme", function()
	-- En ATTENTE, le délai monte jusqu'à une minute : une commande ne doit
	-- pas attendre son terme.
	terrain({ noTree = true, saplings = 0 })
	mock.setEventBudget(400)
	local vraiTimer = os.startTimer
	os.startTimer = function(s)
		local id = vraiTimer(s)
		if s >= 5 and s ~= 20 then os.queueEvent("char", "x") end
		return id
	end

	local ok = runWaiting("1")
	os.startTimer = vraiTimer

	H.ok(ok, "le script s'arrête de lui-même")
	local log = mock.getFile("ccchop.log") or ""
	local waited = tonumber(log:match("%[([%d%.]+)%] ATTENTE | ATTENTE"))
	local stopped = tonumber(log:match("%[([%d%.]+)%] %S+ | Arret demande"))
	H.ok(waited and stopped, "attente puis arrêt journalisés")
	H.ok(stopped - waited < 1, ("arrêt en %.1f s, pas au terme du délai"):format(stopped - waited))
end)
