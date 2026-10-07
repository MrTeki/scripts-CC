-- ccChopper par Teki
--
-- Ferme à arbres : plante, attend la pousse, abat, rapporte, et alimente au
-- passage un four à charbon de bois.
--
--   ccChopper              ferme sans fin ; reprend le travail en cours
--   ccChopper <n>          abat n arbres puis s'arrête
--   ccChopper del          oublie le travail en cours
--   ccChopper config       crée ou affiche les options
--   ccChopper update       met les APIs à jour
--
-- Conventions (voir README) : X / Y horizontaux, Z vertical, direction 0 = +X.
-- L'origine est la position de départ de la turtle, qui doit REGARDER LA CASE
-- DE PLANTATION. L'arbre pousse donc en (1, 0, 0).
--
-- Placement : un conteneur contre l'origine (derrière, sur un côté, au-dessus
-- ou en dessous), et pour le charbon de bois un four sur un autre côté.
-- Le conteneur sert à la fois de dépôt du butin, de réserve de saplings et de
-- source de carburant.
--
-- Deux principes propres à ce script, qui expliquent la forme du code :
--
--   1. On ne creuse QUE du bois et des feuilles. ccNav ne sait pas filtrer par
--      bloc -- son option `dig` est un booléen -- donc tous ses mouvements sont
--      appelés avec `dig = false` et la décision de casser reste ici. Sans
--      cela, un trajet raserait le décor, le coffre et le four.
--
--   2. L'abattage est RÉCURSIF, et chaque appel revient sur sa case d'appel.
--      La pile d'appels Lua est donc le chemin de retour, exact et gratuit.
--      L'ancienne version essayait de revenir en ligne droite à travers un
--      arbre à moitié coupé, avec une pile de positions qui n'était jamais
--      alimentée -- l'état « chopping » qui la remplissait n'existait pas.

-- ---------------------------------------------------------------------------
-- Amorce
-- ---------------------------------------------------------------------------
-- Un SEUL point d'entrée en dur : l'URL du dépôt. La logique vit dans ccBoot,
-- pour qu'une évolution du mécanisme ne demande pas de rééditer les scripts
-- déjà installés.

local REPO = "https://raw.githubusercontent.com/MrTeki/scripts-CC/main/"

-- Dépendances TRANSITIVES comprises : ccBoot n'installe que ce qui est listé.
-- ccUtil n'est pas utilisé ici, mais ccUi le requiert -- l'oublier faisait
-- planter le premier lancement sur une turtle neuve.
local NEEDS = {
	ccUtil = 1, ccVec = 1, ccNav = 1, ccInv = 1, ccConfig = 1,
	ccFuel = 2, ccSave = 1, ccUi = 1,
}

local args = { ... }

local function boot()
	package.path = "/apis/?.lua;apis/?.lua;" .. package.path

	if not fs.exists("apis/ccBoot.lua") and not pcall(require, "ccBoot") then
		if not http then
			error("apis/ccBoot.lua manquant et HTTP indisponible.\n"
				.. "Copier le dossier apis/ depuis " .. REPO, 0)
		end
		local res = http.get(REPO .. "apis/ccBoot.lua")
		if not res then error("Telechargement de ccBoot impossible : " .. REPO, 0) end
		local body = res.readAll()
		res.close()
		fs.makeDir("apis")
		local f = fs.open("apis/ccBoot.lua", "w")
		f.write(body)
		f.close()
	end

	local ok, result = require("ccBoot").ensure(REPO, NEEDS, { check = args[1] == "update" })
	if not ok then error(result, 0) end
	return result
end

local installed = boot()

if args[1] == "update" then
	if #installed == 0 then
		print("APIs deja a jour.")
	else
		print("APIs installees : " .. table.concat(installed, ", "))
	end
	return
end

local ccVec  = require("ccVec")
local ccNav  = require("ccNav")
local ccInv  = require("ccInv")
local ccFuel = require("ccFuel")
local ccSave = require("ccSave")
local ccUi   = require("ccUi")
local ccConfig = require("ccConfig")

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local SAVE_PATH = "ccchop.save"       -- même nom qu'avant : les anciennes
local SAVE_VERSION = 1                -- sauvegardes sont migrées, pas ignorées
local LOG_PATH = "ccchop.log"
local CONFIG_PATH = "ccchopper.cfg"

local DEFAULTS = {
	makeCharcoal = false,     -- alimenter un four avec une partie des bûches
	saplingReserve = 4,       -- en dessous, la canopée entière est rasée
	fertilize = true,         -- utiliser la poudre d'os sur les jeunes pousses

	growWait = 20,            -- secondes entre deux inspections d'une pousse
	fertilizeWait = 1,        -- idem, quand la poudre d'os vient d'être posée
	maxDepth = 96,            -- profondeur d'exploration depuis le tronc, en
	                          -- nombre de cases enchaînées
	maxHeight = 40,           -- plafond du trajet de secours, au-dessus de l'origine

	keepFuel = 64,            -- combustible gardé à bord ; le reste est du butin
	keepSaplings = 32,        -- saplings gardés à bord pour replanter
	spareSlots = 2,           -- marge de slots libres avant de rentrer vider
	fuelMargin = 128,         -- réserve en plus du retour : le chemin qui
	                          -- déroule la récursion est plus long que la
	                          -- distance à vol d'oiseau
	fuelTopUp = 2000,         -- niveau visé lors d'un ravitaillement

	-- Reconnaissance des blocs, par motif cherché dans l'identifiant. Une liste
	-- de noms exacts ne peut pas suivre les essences de tous les mods, et
	-- l'ancienne version codait « minecraft:oak_log » en dur à quatre endroits.
	woodPatterns    = { "_log", "_stem", "_wood", "_hyphae" },
	leafPatterns    = { "_leaves", "_wart_block" },
	saplingPatterns = { "_sapling", "_propagule" },

	-- Conteneurs FIXES acceptés comme dépôt, en repli quand l'API peripheral
	-- ne voit pas le bloc voisin.
	depotPatterns = { "chest", "barrel", "shulker", "hopper", "drawer", "crate", "backpack" },
	depotMinSlots = 27,

	-- Ce qui part par-dessus bord au lieu d'être rapporté. Les feuilles sont le
	-- gros du volume ramassé, et n'ont d'intérêt que pour les saplings qu'elles
	-- lâchent en tombant.
	trash = {
		"minecraft:oak_leaves",
		"minecraft:birch_leaves",
		"minecraft:spruce_leaves",
		"minecraft:jungle_leaves",
		"minecraft:acacia_leaves",
		"minecraft:dark_oak_leaves",
		"minecraft:mangrove_leaves",
		"minecraft:cherry_leaves",
	},
}

local CONFIG_TEMPLATE = [==[
-- Options de ccChopper. Modifiable en jeu avec : edit ccchopper.cfg
-- Supprimer ce fichier le regenere avec les valeurs par defaut.

return {
    -- Alimenter un four voisin pour produire du charbon de bois. Le four doit
    -- etre contre la turtle, sur un autre cote que le conteneur : c'est le
    -- CONTENEUR qui l'alimente, la turtle ne fait que commander le transfert.
    makeCharcoal = false,

    -- Stock de saplings a bord, apres le service, en dessous duquel la
    -- canopee entiere est rasee. Casser une feuille ne rapporte pas plus de
    -- saplings que la laisser pourrir -- environ 1 sur 20 -- mais les met
    -- directement en inventaire. Un chene en rend environ 3 : le stock se
    -- reconstitue et ne tombe jamais a zero.
    saplingReserve = 4,

    -- Utiliser la poudre d'os sur les jeunes pousses, si la turtle en a.
    fertilize = true,

    -- Secondes entre deux inspections d'une pousse. L'ancienne version
    -- inspectait 20 fois par seconde et vidait une pile de poudre d'os en
    -- quelques secondes.
    growWait = 20,

    -- Pause apres une poudre d'os. Courte : une application ne fait pousser
    -- qu'environ une fois sur deux, inutile d'attendre la pousse naturelle
    -- tant qu'il en reste.
    fertilizeWait = 1,

    -- Garde-fou : profondeur d'exploration depuis le tronc, en nombre de
    -- cases enchainees. Ce n'est pas un total de blocs casses : un arbre de
    -- jungle en compte bien plus, mais aucune de ses cases n'est a 96 pas du
    -- tronc.
    maxDepth = 96,

    -- Plafond du trajet de secours, en hauteur au-dessus de l'origine. Sert
    -- quand la turtle doit rentrer apres un redemarrage, sans savoir par ou
    -- elle est arrivee : elle passe par au-dessus de la canopee.
    maxHeight = 40,

    -- Combustible et saplings gardes a bord lors d'un vidage, en nombre
    -- d'objets. Le surplus part au conteneur.
    keepFuel = 64,
    keepSaplings = 32,

    -- Slots laisses libres avant de rentrer vider. C'est une MARGE : entre
    -- deux verifications la turtle ramasse plusieurs blocs, et ce que
    -- l'inventaire ne peut plus accueillir est perdu en silence.
    spareSlots = 2,

    -- Carburant garde en reserve en plus du retour, et niveau vise lors d'un
    -- ravitaillement au conteneur.
    fuelMargin = 128,
    fuelTopUp = 2000,

    -- Reconnaissance des blocs, par motif cherche dans l'identifiant. Ajouter
    -- ici les essences d'un modpack : un motif suffit pour toute une famille.
    woodPatterns    = { "_log", "_stem", "_wood", "_hyphae" },
    leafPatterns    = { "_leaves", "_wart_block" },
    saplingPatterns = { "_sapling", "_propagule" },

    -- Conteneurs acceptes comme depot, en repli quand l'API peripheral ne voit
    -- pas le bloc voisin.
    depotPatterns = { "chest", "barrel", "shulker", "hopper", "drawer", "crate", "backpack" },
    depotMinSlots = 27,

    -- Jete a la volee au lieu d'etre rapporte. Vider la liste ( trash = {} )
    -- pour tout conserver.
    trash = {
        "minecraft:oak_leaves",
        "minecraft:birch_leaves",
        "minecraft:spruce_leaves",
        "minecraft:jungle_leaves",
        "minecraft:acacia_leaves",
        "minecraft:dark_oak_leaves",
        "minecraft:mangrove_leaves",
        "minecraft:cherry_leaves",
    },
}
]==]

local CONFIG = DEFAULTS

-- États. Le nom de l'état EST l'état : les drapeaux currentState / makeCharcoal
-- / needEmptying de l'ancienne version disparaissent.
local S = {
	CALIBRATE = "CALIBRAGE",
	TEND      = "PLANTATION",
	CHOP      = "ABATTAGE",
	RETURN    = "RETOUR",
	SERVICE   = "SERVICE",
	AWAIT     = "ATTENTE",
	PAUSED    = "PAUSE",
	DONE      = "TERMINE",
	FAILED    = "ERREUR",
}

-- La case de plantation : devant l'origine, au même niveau.
local TREE = { x = 1, y = 0, z = 0 }
local ORIGIN = { x = 0, y = 0, z = 0, dir = 0 }

local ctx = {
	state = S.CALIBRATE,
	reason = nil,
	trees = 0,           -- arbres abattus depuis le lancement
	target = nil,        -- nombre demandé, ou nil pour une ferme sans fin
	logs = 0,            -- blocs cassés sur le dernier arbre
	stopped = false,
	pending = {},        -- commandes en attente, jamais exécutées à la réception
}

local store

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

-- L'écran d'un turtle fait 13 lignes et se vide au premier nettoyage : un
-- message d'erreur qui n'existe que là est perdu au moment où il sert.
local function journal(msg)
	msg = tostring(msg)
	pcall(ccUi.log, msg)

	local handle = fs.open(LOG_PATH, "a")
	if not handle then return end
	handle.write(("[%.1f] %s | %s\n"):format(os.clock(), ctx.state or "?", msg))
	handle.close()
end

--- Attend un événement, en traitant Ctrl+T comme une demande d'arrêt propre.
local function waitEvent(filter)
	local event = { os.pullEventRaw(filter) }
	if event[1] == "terminate" then
		ctx.interrupted = true
		ctx.stopped = true
	end
	return table.unpack(event)
end

-- ---------------------------------------------------------------------------
-- Fichier de démarrage
-- ---------------------------------------------------------------------------

local STARTUP = 'shell.run("ccChopper")\n'

local function startupContent()
	if not fs.exists("startup.lua") then return nil end
	local f = fs.open("startup.lua", "r")
	local content = f.readAll()
	f.close()
	return content
end

local function installStartup()
	local current = startupContent()
	if current == STARTUP then return end

	if current then
		if not fs.exists("startup.old") then fs.move("startup.lua", "startup.old") end
		fs.delete("startup.lua")
	end

	local f = fs.open("startup.lua", "w")
	f.write(STARTUP)
	f.close()
end

local function removeStartup()
	-- On ne retire que le nôtre.
	if startupContent() == STARTUP then fs.delete("startup.lua") end
	if not fs.exists("startup.lua") and fs.exists("startup.old") then
		fs.move("startup.old", "startup.lua")
	end
end

-- ---------------------------------------------------------------------------
-- Sauvegarde
-- ---------------------------------------------------------------------------

-- Migration depuis le format d'origine : sept index numériques, positions en
-- X / Y / Z / direction majuscules. Seule la position a encore un sens ; la
-- pile de trajet qu'il stockait était toujours vide, faute d'un état qui
-- l'alimente.
local MIGRATIONS = {
	[0] = function(old)
		local p = old[1] or {}
		return {
			pos = ccVec.new(p.X or 0, p.Y or 0, p.Z or 0, p.direction or 0),
			state = S.RETURN,
			reason = "reprise",
		}
	end,
}

local function save()
	store.write({
		state = ctx.state,
		reason = ctx.reason,
		trees = ctx.trees,
		target = ctx.target,
		pos = ccNav.position(),
	})
end

-- ---------------------------------------------------------------------------
-- Reconnaissance des blocs
-- ---------------------------------------------------------------------------

local function matchesAny(name, patterns)
	if not name then return false end
	local lowered = name:lower()
	for _, p in ipairs(patterns or {}) do
		if lowered:find(p, 1, true) then return true end
	end
	return false
end

local function isWood(name) return matchesAny(name, CONFIG.woodPatterns) end
local function isLeaves(name) return matchesAny(name, CONFIG.leafPatterns) end
local function isSapling(name) return matchesAny(name, CONFIG.saplingPatterns) end

--- Ce bloc fait-il partie de l'arbre ? Ce qui en fait partie PEUT être cassé ;
--- c'est l'abattage qui décide si une feuille DOIT l'être.
local function isTree(name)
	return isWood(name) or isLeaves(name)
end

local INSPECTS = { forward = "inspect", up = "inspectUp", down = "inspectDown" }

--- Nom du bloc dans cette direction, ou nil.
local function blockAt(where)
	local seen, info = turtle[INSPECTS[where]]()
	if seen and info then return info.name end
	return nil
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------

local function setupUi()
	ccUi.reset({ logLines = 1 })
	ccUi.useMonitor()
	ccUi.addButton({ label = "CHARBON", y = 1, cmd = "charcoal", key = "c" })
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	ccUi.addButton({ label = "STOP", y = 3, cmd = "abort", key = "x" })
	ccUi.clear()
end

local function draw()
	local pos = ccNav.position()

	ccUi.line(1, "Ferme a arbres")
	ccUi.line(3, ("Arbres : %d%s")
		:format(ctx.trees, ctx.target and (" / " .. ctx.target) or ""))
	ccUi.line(4, ("Carburant : %s")
		:format(ccFuel.isUnlimited() and "illimite" or ccFuel.level()))
	ccUi.line(5, "Reserve : " .. ccFuel.reserve(pos, nil, CONFIG.fuelMargin))
	ccUi.line(6, "Position : " .. ccVec.tostring(pos))
	ccUi.line(7, "Slots libres : " .. ccInv.freeCount())
	ccUi.line(8, "Charbon de bois : " .. (CONFIG.makeCharcoal and "oui" or "non"))
	ccUi.line(9, "Etat : " .. ctx.state .. (ctx.reason and (" (" .. ctx.reason .. ")") or ""))
	ccUi.drawButtons()
end

-- ---------------------------------------------------------------------------
-- Commandes
-- ---------------------------------------------------------------------------

-- Les commandes sont COLLECTÉES ici et CONSOMMÉES entre deux transitions.
-- L'ancienne version basculait makeCharcoal depuis la coroutine d'événements,
-- en pleine opération de la boucle principale.
local function collect()
	local e = { waitEvent() }
	if ctx.stopped then return end

	local name = e[1]
	if name == "char" or name == "mouse_click" or name == "monitor_touch" then
		local cmd = ccUi.dispatch(table.unpack(e))
		if cmd then ctx.pending[#ctx.pending + 1] = cmd end
		draw()
	elseif name == "timer" and e[2] == ctx.drawTimer then
		ctx.drawTimer = os.startTimer(0.5)
		draw()
	end
end

local function applyCommands()
	while #ctx.pending > 0 do
		local cmd = table.remove(ctx.pending, 1)

		if cmd == "charcoal" then
			CONFIG.makeCharcoal = not CONFIG.makeCharcoal
			journal("Charbon de bois : " .. (CONFIG.makeCharcoal and "active" or "desactive"))

		elseif cmd == "pause" or cmd == "resume" then
			if ctx.state == S.PAUSED then
				ctx.state = ctx.resumeTo or S.TEND
				journal("Reprise")
			else
				ctx.resumeTo = ctx.state
				ctx.state = S.PAUSED
				journal("En pause")
			end

		elseif cmd == "abort" then
			ctx.reason = "abort"
			ctx.abort = true
			ctx.state = S.RETURN
			journal("Arret demande")
		end
	end
end

-- ---------------------------------------------------------------------------
-- Carte des cases examinées
-- ---------------------------------------------------------------------------
-- Remise à zéro à chaque arbre. Les diagonales de deux bûches voisines se
-- recouvrent largement : une case déjà vue n'est pas réinspectée.
--
--   ctx.seen[c]    = nom du bloc, ou false pour de l'air (état COURANT)
--   ctx.wasWood[c] = true si la case portait du bois quand on l'a vue

local function cellKey(c) return c.x .. "," .. c.y .. "," .. c.z end

--- Case visée par une direction, depuis la position courante.
local function cellAt(where)
	local p = ccNav.position()
	if where == "up" then return { x = p.x, y = p.y, z = p.z + 1 } end
	if where == "down" then return { x = p.x, y = p.y, z = p.z - 1 } end
	local dx, dy = ccVec.delta(p.dir)
	return { x = p.x + dx, y = p.y + dy, z = p.z }
end

--- Inspecte et retient.
local function look(where)
	local name = blockAt(where)
	if ctx.seen then
		local k = cellKey(cellAt(where))
		ctx.seen[k] = name or false
		if isWood(name) then ctx.wasWood[k] = true end
	end
	return name
end

local function distance(a, b)
	return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

local function adjacent(a, b) return distance(a, b) == 1 end

-- ---------------------------------------------------------------------------
-- Mouvement filtré
-- ---------------------------------------------------------------------------
-- Toutes les primitives de déplacement passent par ici avec `dig = false`, et
-- ne cassent que ce que isTree() reconnaît. C'est la seule façon d'obtenir un
-- creusement sélectif avec ccNav, dont l'option `dig` est un booléen.

--- Dégage la case si elle appartient à l'arbre.
-- @return true si la case est libre à la sortie
local function clearTree(where)
	for _ = 1, 8 do
		local name = blockAt(where)
		if not name then return true end
		if not isTree(name) then return false end
		-- maxDig = 1 : un seul coup, puis on ré-inspecte. ccNav.dig() sans
		-- borne creuserait aussi ce qui retombe derrière, sans le regarder.
		if not ccNav.dig(where, { maxDig = 1 }) then return false end
		ctx.logs = ctx.logs + 1
	end
	if blockAt(where) ~= nil then return false end
	if ctx.seen then ctx.seen[cellKey(cellAt(where))] = false end
	return true
end

local MOVES = { forward = ccNav.forward, up = ccNav.up, down = ccNav.down }

--- Un pas, en ne cassant que l'arbre.
-- @return true, ou false + raison
local function stepTo(where)
	clearTree(where)
	return MOVES[where]({ dig = false })
end

--- Cap à prendre pour aller de `from` à la case adjacente `to`.
local function headingTo(from, to)
	if to.x > from.x then return 0 end
	if to.y > from.y then return 1 end
	if to.x < from.x then return 2 end
	if to.y < from.y then return 3 end
	return nil
end

--- Revient sur `prev`, adjacente par construction puisqu'on en vient.
--
-- On ne se sert PAS de ccNav.back() : la case d'où l'on vient est derrière
-- nous seulement si le cap n'a pas bougé, et l'exploration des quatre côtés le
-- fait justement tourner. Recalculer le cap depuis les deux positions est
-- exact quoi qu'il se soit passé entre-temps.
local function stepBackTo(prev)
	local cur = ccNav.position()
	local where
	if prev.z > cur.z then where = "up"
	elseif prev.z < cur.z then where = "down"
	else
		local dir = headingTo(cur, prev)
		if not dir then
			if prev.dir then ccNav.turnTo(prev.dir) end
			return true          -- déjà sur place
		end
		ccNav.turnTo(dir)
		where = "forward"
	end

	local ok, reason = stepTo(where)
	if prev.dir then ccNav.turnTo(prev.dir) end
	if not ok then
		-- La case d'où l'on vient s'est refermée : sable tombé, bloc posé par
		-- un tiers. On ne peut plus dérouler la récursion, le trajet de
		-- secours prendra le relais.
		ctx.lost = true
		journal("Retour d'un pas impossible : " .. tostring(reason))
	end
	return ok
end

-- ---------------------------------------------------------------------------
-- Abattage
-- ---------------------------------------------------------------------------

--- Faut-il interrompre l'abattage en cours ?
--
-- Vérifié à CHAQUE nœud de la récursion. L'ancienne version ne testait ni la
-- place ni le carburant pendant l'abattage, et les deux manques ont des
-- conséquences distinctes :
--
--   * Inventaire plein. turtle.dig() réussit QUAND MÊME -- il renvoie true et
--     l'objet est perdu en silence. L'arbre était donc coupé dans le vide,
--     sans que rien ne le signale.
--   * Panne sèche en pleine canopée. Le mouvement échouait, turtle.detect()
--     était faux, et l'ancien code appelait turtle.attack() en boucle.
--
-- La garde de ccFuel n'est délibérément PAS installée sur ccNav ici : elle
-- refuserait aussi les mouvements qui déroulent la récursion, c'est-à-dire
-- ceux qui ramènent justement vers l'origine.
local function chopStop()
	if ctx.stopped or ctx.abort then return "abort" end
	if ctx.lost then return "perdu" end
	if ccInv.freeCount() <= CONFIG.spareSlots then return "inventaire" end
	if ccFuel.level() <= ccFuel.reserve(ccNav.position(), nil, CONFIG.fuelMargin) then
		return "carburant"
	end
	return nil
end

--- S'oriente vers la case adjacente `c`.
-- @return la direction à utiliser : "forward", "up" ou "down"
local function aim(c)
	local p = ccNav.position()
	if c.z > p.z then return "up" end
	if c.z < p.z then return "down" end
	ccNav.turnTo(headingTo(p, c))
	return "forward"
end

-- ---------------------------------------------------------------------------
-- Abattage
-- ---------------------------------------------------------------------------
-- Tracé déduit du générateur du jeu (FancyTrunkPlacer, Minecraft 1.21.1) :
--
--   * le tronc est une colonne droite ;
--   * chaque branche part DE L'INTÉRIEUR de cette colonne, à au moins 20 % de
--     la hauteur de l'arbre (trimBranches), et monte en ligne droite vers une
--     boule de feuillage ;
--   * une branche est une droite discrétisée : à chaque pas l'axe principal
--     avance de 1 et chacun des deux autres de 0 ou 1. Deux bûches
--     consécutives peuvent donc ne se toucher que par une arête, voire par un
--     coin ;
--   * les feuilles ne sont qu'au BOUT des branches : près du tronc, la case
--     entre deux bûches en diagonale est de l'air.
--
-- D'où le tracé : explorer les six faces de chaque bûche, puis sonder ses
-- diagonales en se postant dans les cases libres voisines -- sans rien
-- casser, sauf une feuille quand aucune case libre ne permet de voir.
-- Sonder à travers les feuilles seules ne suffisait pas : c'est l'air qui
-- sépare les bûches en diagonale.

local chopHere

--- Entre dans la case adjacente indiquée, l'abat, puis revient.
local function enter(where, depth, isLog)
	if not clearTree(where) then return true end
	local from = ccNav.position()
	if not MOVES[where]({ dig = false }) then return true end
	chopHere(depth + 1, isLog)
	return stepBackTo(from)
end

--- Inspecte, depuis la position courante, toutes les cibles encore inconnues
--- qui lui sont adjacentes, et abat le bois trouvé.
-- @return false s'il faut interrompre l'abattage
local function inspectAround(targets, depth)
	for _, t in ipairs(targets) do
		if ctx.seen[cellKey(t)] == nil and adjacent(t, ccNav.position()) then
			if chopStop() then return false end
			local where = aim(t)
			if isWood(look(where)) then
				if not enter(where, depth, true) then return false end
			end
		end
	end
	return true
end

--- Diagonales à examiner autour de la bûche courante.
--
-- Colonne du tronc : rien sous la 3e bûche. Une branche part à au moins 20 %
-- de la hauteur de l'arbre, ce qui pour le plus petit grand chêne qui en porte
-- donne déjà la 3e bûche ; les deux premières n'en portent jamais. Au-dessus,
-- seules les 4 diagonales HORIZONTALES : les diagonales verticales et les coins
-- d'une bûche de la colonne sont les diagonales horizontales de ses voisines
-- du dessus et du dessous, qui les sondent elles-mêmes. Le sommet fait
-- exception : rien ne sonde au-dessus de lui.
--
-- Branche : une branche s'éloigne de la colonne et ne descend jamais. Sur
-- chaque axe horizontal, le pas suivant est donc 0 ou le signe déjà pris -- les
-- deux sens tant que la branche ne s'est pas encore écartée sur cet axe -- et
-- sur la verticale, 0 ou +1.
local function diagonalTargets()
	local p = ccNav.position()
	local out = {}
	local function add(dx, dy, dz)
		local axes = (dx ~= 0 and 1 or 0) + (dy ~= 0 and 1 or 0) + (dz ~= 0 and 1 or 0)
		if axes >= 2 then out[#out + 1] = { x = p.x + dx, y = p.y + dy, z = p.z + dz } end
	end

	if p.x == TREE.x and p.y == TREE.y then
		if p.z - TREE.z < 2 then return out end
		for _, dx in ipairs({ -1, 1 }) do
			for _, dy in ipairs({ -1, 1 }) do add(dx, dy, 0) end
		end
		if not ctx.wasWood[cellKey({ x = p.x, y = p.y, z = p.z + 1 })] then
			for dx = -1, 1 do
				for dy = -1, 1 do add(dx, dy, 1) end
			end
		end
		return out
	end

	local function steps(v, axis)
		if v > axis then return { 0, 1 } end
		if v < axis then return { -1, 0 } end
		return { -1, 0, 1 }
	end
	for _, dx in ipairs(steps(p.x, TREE.x)) do
		for _, dy in ipairs(steps(p.y, TREE.y)) do
			add(dx, dy, 0)
			add(dx, dy, 1)
		end
	end
	return out
end

-- Postes d'observation : les faces de la bûche, dans l'ordre qui minimise les
-- visites pour les cas courants.
local POSTS = {
	{ 1, 0, 0 }, { -1, 0, 0 }, { 0, 0, 1 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, -1 },
}

--- Sonde les diagonales de la bûche courante, et abat le bois trouvé.
--
-- Une cible voisine d'une face est vue depuis cette face. Un coin est à deux
-- pas : on le voit depuis une case libre voisine à la fois du poste et du coin
-- -- un « saut ». Les postes libres passent d'abord ; une feuille n'est cassée
-- pour servir de poste que s'il reste quelque chose à voir.
-- @return false s'il faut interrompre l'abattage
local function probe(targets, depth)
	if #targets == 0 then return true end
	-- Sans cap : le revenir sur la bûche suffit, l'appelant restaure le cap
	-- dont il a besoin. Le restaurer ici coûtait deux rotations par poste.
	local p = ccNav.position()
	local home = { x = p.x, y = p.y, z = p.z }

	local function unknownNear(near, maxDist)
		for _, t in ipairs(targets) do
			if ctx.seen[cellKey(t)] == nil and distance(t, near) <= maxDist then return true end
		end
		return false
	end

	--- Depuis le poste courant, saute vers une case libre voisine d'un coin
	--- encore inconnu, l'inspecte, et revient.
	local function hops()
		local p = ccNav.position()
		local at = { x = p.x, y = p.y, z = p.z }
		for _, t in ipairs(targets) do
			if ctx.seen[cellKey(t)] == nil and distance(t, at) == 2 then
				for _, q in ipairs(targets) do
					if ctx.seen[cellKey(q)] == false and adjacent(q, at) and adjacent(q, t) then
						local ok = true
						if MOVES[aim(q)]({ dig = false }) then
							ok = inspectAround(targets, depth)
							if not stepBackTo(at) then ok = false end
						end
						if not ok then return false end
						break
					end
				end
			end
		end
		return true
	end

	for pass = 1, 2 do
		for _, o in ipairs(POSTS) do
			if not unknownNear(home, 3) then return true end
			if chopStop() then return false end

			local post = { x = home.x + o[1], y = home.y + o[2], z = home.z + o[3] }
			local state = ctx.seen[cellKey(post)]
			local usable = state == false or (pass == 2 and state and isLeaves(state))

			if usable and unknownNear(post, 2) then
				local where = aim(post)
				if clearTree(where) and MOVES[where]({ dig = false }) then
					local ok = inspectAround(targets, depth) and hops()
					if not stepBackTo(home) or not ok then return false end
				end
			end
		end
	end
	return true
end

--- Abat l'arbre à partir de la case courante, qui vient d'être vidée.
--
-- Chaque descente revient sur sa case d'appel avant de rendre la main : la
-- pile d'appels Lua EST le chemin de retour. En sortie, la turtle est donc
-- revenue exactement là où elle est entrée, cap compris.
--
-- Les feuilles ne sont suivies qu'en mode rasage (ctx.shave), pour refaire le
-- stock de saplings ; sinon elles pourrissent seules une fois le bois abattu.
chopHere = function(depth, isLog)
	if depth > CONFIG.maxDepth then return end

	-- La position de retour est relevée à CHAQUE descente, et non une fois pour
	-- toutes à l'entrée de la fonction : l'exploration des quatre côtés fait
	-- tourner la turtle, donc le cap à restaurer change d'un côté à l'autre.
	-- @return false s'il faut interrompre l'abattage
	local function into(where)
		if chopStop() then return false end
		local name = look(where)
		local log = isWood(name)
		if not log and not (ctx.shave and isLeaves(name)) then return true end
		return enter(where, depth, log)
	end

	if not into("up") then return end
	if not into("down") then return end

	-- Les quatre côtés : trois rotations suffisent. La quatrième ne ferait
	-- que ramener le cap de départ, ce que stepBackTo fait de toute façon en
	-- rendant la main à l'appelant.
	for side = 1, 4 do
		if not into("forward") then return end
		if chopStop() then return end
		if side < 4 then ccNav.turnRight() end
	end

	if isLog then probe(diagonalTargets(), depth) end
end

--- Ramasse ce qui traîne autour, sans vider un conteneur voisin.
--
-- Les saplings et bâtons lâchés par les feuilles tombent au sol : turtle.dig()
-- ne les met en inventaire que s'ils viennent du bloc cassé. La garde sur
-- detect() est ce qui évite d'aspirer le contenu du coffre.
local function gatherDrops()
	local entry = turtle.getSelectedSlot()
	for _, where in ipairs({ "forward", "up", "down" }) do
		if blockAt(where) == nil then
			local fn = ({ forward = turtle.suck, up = turtle.suckUp, down = turtle.suckDown })[where]
			for _ = 1, 8 do
				if not fn() then break end
			end
		end
	end
	if turtle.getSelectedSlot() ~= entry then turtle.select(entry) end
end

-- ---------------------------------------------------------------------------
-- Conteneur et four
-- ---------------------------------------------------------------------------

--- Côté portant un périphérique dont le type correspond à l'un des motifs.
-- @return côté (nom de l'API peripheral), type
local function sideMatching(patterns)
	if type(peripheral) ~= "table" then return nil end
	local ok, names = pcall(peripheral.getNames)
	if not ok or type(names) ~= "table" then return nil end

	for _, side in ipairs(names) do
		local fine, kind = pcall(peripheral.getType, side)
		if fine and type(kind) == "string" and matchesAny(kind, patterns) then
			return side, kind
		end
	end
	return nil
end

--- Cherche un conteneur autour de l'origine, et s'oriente vers lui.
--
-- Les quatre côtés, le dessus et le dessous sont examinés : n'importe quelle
-- position convient. L'ancienne version imposait un côté sans le dire, et son
-- test `chestSide == "down"` ne matchait jamais -- l'API peripheral nomme ce
-- côté « bottom ». Avec un coffre en dessous, la turtle vidait donc DEVANT
-- elle, au sol.
--
-- Le conteneur trouvé est MÉMORISÉ, cap compris, et vérifié en premier au
-- service suivant. Sans cela, chaque service refaisait le tour complet ; et
-- comme une attente relance un service toutes les quelques secondes, la
-- turtle tournait sur elle-même sans fin en attendant qu'on la serve.
-- @return "forward", "up", "down", ou nil
local function findDepot()
	local known = ctx.depot
	if known then
		if known.dir then ccNav.turnTo(known.dir) end
		if ccInv.depotAt(known.where) then return known.where end
		ctx.depot = nil
	end

	local function remember(where)
		ctx.depot = { where = where, dir = where == "forward" and ccNav.position().dir or nil }
		return where
	end

	local seen = {}

	local function describe(name, slots)
		return name .. (slots and (" (" .. slots .. " slots)") or " (nom seul)")
	end

	for _ = 1, 4 do
		local found, name, slots = ccInv.depotAt("forward")
		if found then return remember("forward") end
		if name then seen[#seen + 1] = describe(name, slots) end
		ccNav.turnRight()
	end

	for _, where in ipairs({ "up", "down" }) do
		local found, name, slots = ccInv.depotAt(where)
		if found then return remember(where) end
		if name then seen[#seen + 1] = describe(name, slots) end
	end

	if #seen > 0 then
		journal("Aucun depot reconnu parmi : " .. table.concat(seen, ", "))
		journal("Voir depotMinSlots et depotPatterns dans " .. CONFIG_PATH)
	end
	return nil
end

-- Nom de périphérique correspondant à une direction du turtle.
local SIDES = { forward = "front", up = "top", down = "bottom" }

-- ---------------------------------------------------------------------------
-- Four
-- ---------------------------------------------------------------------------
-- C'est le CONTENEUR qui alimente le four -- pushItems avec un slot de
-- destination explicite. Une turtle ne peut pas viser un slot précis d'un
-- voisin : turtle.drop() laisse le four choisir, et une bûche est à la fois
-- fondable et combustible. Elle ne peut pas non plus y « puiser » le charbon
-- produit : par le côté, un four n'expose que son foyer (SLOTS_FOR_SIDES), si
-- bien qu'un turtle.suck() lui volerait son combustible.
--
-- Slots d'un four, vus par l'API peripheral : 1 entrée, 2 foyer, 3 sortie.

-- Combustibles du four, en cuissons par objet : durée de combustion du jeu
-- divisée par les 200 ticks d'une cuisson. Charbon : 1600 ticks, soit 8. Bois :
-- 300 ticks, soit 1,5. Dans l'ordre de préférence -- un charbon de bois au
-- foyer rend 0,875 charbon par bûche, une bûche au foyer seulement 0,6. Le bois
-- ne sert qu'à amorcer, tant qu'il n'y a encore aucun charbon.
local FURNACE_FUELS = {
	{ name = "charbon de bois", smelts = 8, match = function(n) return n == "minecraft:charcoal" end },
	{ name = "charbon", smelts = 8, match = function(n) return n == "minecraft:coal" end },
	{ name = "bois", smelts = 1.5, wood = true, match = function(n) return isWood(n) end },
}

local function fuelKind(name)
	for _, kind in ipairs(FURNACE_FUELS) do
		if name and kind.match(name) then return kind end
	end
	return nil
end

--- Plus petit lot sans perte : `fuel` objets de combustible cuisent exactement
--- `input` bûches. 8 bûches pour 1 charbon, 3 bûches pour 2 bûches de bois.
local function lotFor(kind)
	local fuel = 1
	while kind.smelts * fuel ~= math.floor(kind.smelts * fuel) do fuel = fuel + 1 end
	return kind.smelts * fuel, fuel
end

--- Ouvre le conteneur et le four, vus depuis la turtle.
-- @return { chest, chestSide, furnace, furnaceSide }, ou nil + raison
local function openFurnace(depotWhere)
	local furnaceSide = sideMatching({ "furnace", "smelter", "kiln" })
	if not furnaceSide then return nil, "aucun four" end

	local chestSide = SIDES[depotWhere]
	if not chestSide then return nil, "depot inaccessible" end

	local okChest, chest = pcall(peripheral.wrap, chestSide)
	local okFurnace, furnace = pcall(peripheral.wrap, furnaceSide)
	if not okChest or not chest or not okFurnace or not furnace then
		return nil, "peripherique illisible"
	end
	return { chest = chest, chestSide = chestSide, furnace = furnace, furnaceSide = furnaceSide }
end

--- Vide la sortie du four dans le conteneur.
--
-- Fait AVANT le ravitaillement de la turtle : le charbon de bois produit depuis
-- le dernier service est ainsi disponible pour elle, et elle n'a jamais à
-- brûler de bûches tant qu'il en reste.
local function collectFurnace(dev)
	for _ = 1, 8 do
		local ok, moved = pcall(dev.furnace.pushItems, dev.chestSide, 3)
		if not ok or not moved or moved == 0 then break end
	end
end

--- Objets du conteneur satisfaisant `accept` : total, et liste des slots.
local function inChest(dev, accept)
	local ok, list = pcall(dev.chest.list)
	local total, slots = 0, {}
	if not ok or type(list) ~= "table" then return 0, slots end
	for slot, item in pairs(list) do
		if item and item.name and accept(item.name) then
			total = total + item.count
			slots[#slots + 1] = slot
		end
	end
	table.sort(slots)
	return total, slots
end

--- Pousse exactement `count` objets acceptés vers un slot du four.
-- @return nombre réellement déplacé
local function pushCount(dev, accept, toSlot, count)
	local moved = 0
	local _, slots = inChest(dev, accept)
	for _, slot in ipairs(slots) do
		if moved >= count then break end
		local ok, n = pcall(dev.chest.pushItems, dev.furnaceSide, slot, count - moved, toSlot)
		if ok and n then moved = moved + n end
	end
	return moved
end

--- Rend au conteneur `count` objets d'un slot du four.
local function pullBack(dev, fromSlot, count)
	if count > 0 then pcall(dev.furnace.pushItems, dev.chestSide, fromSlot, count) end
end

--- Charge le four par lots exacts, pour qu'aucun combustible ne brûle à vide.
--
-- Un combustible allumé brûle jusqu'au bout, qu'il reste ou non quelque chose
-- à cuire : un charbon allumé pour 3 bûches perd 5 cuissons sur 8. On ne
-- charge donc qu'un four dont l'ENTRÉE est vide -- le lot précédent est alors
-- entièrement cuit et rien ne brûle plus -- et uniquement par multiples du lot
-- exact : 8 bûches par charbon, 3 bûches par paire de bûches de bois. Les
-- bûches qui ne remplissent pas un lot attendent le service suivant.
--
-- Un combustible qui n'est pas encore allumé, lui, ne se perd pas : il attend
-- dans le foyer et compte pour le lot suivant.
-- @return true, ou false + raison
local function feedFurnace(dev)
	local okIn, input = pcall(dev.furnace.getItemDetail, 1)
	local okFuel, fuel = pcall(dev.furnace.getItemDetail, 2)
	if not okIn or not okFuel then return false, "four illisible" end
	if input then return true end          -- lot en cours de cuisson

	-- Le combustible préféré disponible.
	local preferred
	for _, kind in ipairs(FURNACE_FUELS) do
		if inChest(dev, kind.match) > 0 then preferred = kind break end
	end

	local kind = fuel and fuelKind(fuel.name)
	if fuel and not kind then return false, "foyer occupe par " .. tostring(fuel.name) end

	-- Du bois au foyer alors que du charbon est disponible : on le reprend,
	-- rien ne cuisant, pour charger le combustible le plus rentable.
	if kind and preferred and kind ~= preferred and preferred.smelts > kind.smelts then
		pullBack(dev, 2, fuel.count)
		fuel, kind = nil, nil
	end
	kind = kind or preferred
	if not kind then return true end       -- rien à brûler

	local lotIn, lotFuel = lotFor(kind)
	local logs = inChest(dev, isWood)
	local spare = inChest(dev, kind.match)
	local present = fuel and fuel.count or 0

	-- Plus grand nombre de lots que permettent le stock et la place (64 par
	-- slot). Pour le bois, entrée et foyer puisent dans le même stock.
	local lots = 0
	for k = math.floor(64 / lotIn), 1, -1 do
		local needFuel = math.max(0, k * lotFuel - present)
		local enough
		if kind.wood then
			enough = k * lotIn + needFuel <= logs
		else
			enough = k * lotIn <= logs and needFuel <= spare
		end
		if enough and present + needFuel <= 64 then lots = k break end
	end
	if lots == 0 then return true end      -- pas encore de quoi faire un lot

	local wantFuel = math.max(0, lots * lotFuel - present)
	local gotFuel = pushCount(dev, kind.match, 2, wantFuel)
	if gotFuel < wantFuel then
		-- Moins de combustible que prévu : on réduit le nombre de lots. Le
		-- combustible en trop n'est pas allumé, il attend le lot suivant.
		lots = math.floor((present + gotFuel) / lotFuel)
	end
	if lots == 0 then return true end

	local wantIn = lots * lotIn
	local gotIn = pushCount(dev, isWood, 1, wantIn)
	local exact = math.floor(gotIn / lotIn) * lotIn
	pullBack(dev, 1, gotIn - exact)        -- jamais de lot incomplet en cuisson
	return true
end

-- ---------------------------------------------------------------------------
-- Inventaire
-- ---------------------------------------------------------------------------

--- Slots à ne pas vider : de quoi garder du combustible, des saplings et de
--- l'engrais.
--
-- On n'utilise PAS ccFuel.protectSlots ici, et c'est le piège propre à ce
-- script : dans une ferme à bois, le butin EST du combustible. La bûche brûle,
-- donc turtle.refuel(0) répond oui, donc protectSlots la garde -- et la récolte
-- ne serait jamais déposée. Le bois est explicitement exclu : s'il faut du
-- carburant, refuelFromInventory le brûlera, ce qui est un choix délibéré et
-- pas un effet de bord du vidage.
local function protectedSlots()
	local set, fuel, saplings = {}, 0, 0

	for _, slot in ipairs(ccFuel.fuelSlots()) do
		if fuel >= CONFIG.keepFuel then break end
		local d = ccInv.detail(slot)
		if d and not isWood(d.name) then
			set[slot] = true
			fuel = fuel + d.count
		end
	end

	for slot = 1, 16 do
		if saplings >= CONFIG.keepSaplings then break end
		local d = ccInv.detail(slot)
		if d and isSapling(d.name) then
			set[slot] = true
			saplings = saplings + d.count
		end
	end

	-- L'engrais n'est ni du butin ni du combustible : il sert ici.
	local bone = ccInv.find("minecraft:bone_meal")
	if bone then set[bone] = true end

	ccInv.selectForMining()
	return set
end

--- Slot de combustible à ranger à l'emplacement canonique. Même raison qu'au
--- dessus : ccFuel.bestFuelSlot() élirait une pile de bûches.
local function fuelSlotForTidy()
	local best, count = nil, 0
	for _, slot in ipairs(ccFuel.fuelSlots()) do
		local d = ccInv.detail(slot)
		if d and not isWood(d.name) and d.count > count then
			best, count = slot, d.count
		end
	end
	ccInv.selectForMining()
	return best
end

--- Nombre de saplings à bord.
local function saplingCount()
	local n = 0
	for slot = 1, 16 do
		local d = ccInv.detail(slot)
		if d and isSapling(d.name) then n = n + d.count end
	end
	return n
end

--- Slot contenant un sapling, ou nil.
local function findSapling()
	for slot = 1, 16 do
		local d = ccInv.detail(slot)
		if d and isSapling(d.name) then return slot end
	end
	return nil
end

--- Prend des saplings dans le conteneur, quand il n'en reste plus à bord.
--
-- L'ancienne version avait la place de ce code, un commentaire décrivant ce
-- qu'il devait faire, et à l'endroit de l'appel une COPIE de la recherche en
-- inventaire, dont le résultat était jeté. Faute de sapling, le script
-- s'arrêtait au lieu d'aller en chercher.
local function fetchSaplings(where)
	local before = ccInv.freeCount()
	if before == 0 then return false end

	for _ = 1, 4 do
		local slot = ccInv.firstFree()
		if not slot then break end
		if not ccInv.suckFrom(where, slot) then break end

		local d = ccInv.detail(slot)
		if d and isSapling(d.name) then return true end
		-- Ce n'est pas un sapling : on le rend et on s'arrête là. Insister
		-- viderait le conteneur pile par pile dans la turtle.
		ccInv.dropTo(where, slot)
		break
	end
	return false
end

--- Ravitaillement au service, en deux étages.
--
-- Le combustible « propre » -- charbon, bâtons -- est brûlé jusqu'à
-- fuelTopUp. Le bois ne l'est que pour atteindre le plancher qui permet
-- d'abattre l'arbre suivant : c'est la récolte, pas une réserve. Les saplings
-- ne le sont jamais.
--
-- Constaté en jeu : sans filtre, ccFuel brûlait tout ce qui est combustible
-- pour viser fuelTopUp, saplings compris. La turtle se retrouvait sans rien à
-- replanter, et attendait qu'on lui en rende.
-- @param where  direction du conteneur, ou nil sans conteneur
local function refuel(where)
	local function clean(name) return not isSapling(name) and not isWood(name) end
	local function any(name) return not isSapling(name) end

	if ccFuel.level() < CONFIG.fuelTopUp then
		ccFuel.refuelFromInventory(CONFIG.fuelTopUp, { accept = clean })
		if where then ccFuel.refuelFromChest(where, CONFIG.fuelTopUp, { accept = clean }) end
	end

	local floor = 2 * CONFIG.fuelMargin
	if ccFuel.level() < floor then
		ccFuel.refuelFromInventory(floor, { accept = any })
		if where then ccFuel.refuelFromChest(where, floor, { accept = any }) end
	end
	ccInv.selectForMining()
end

-- ---------------------------------------------------------------------------
-- États
-- ---------------------------------------------------------------------------

local STATES = {}

STATES[S.CALIBRATE] = function()
	-- Le suivi de position est à l'estime : rien à recaler, mais on vérifie que
	-- la turtle est bien chez elle avant de repartir.
	local pos = ccNav.position()
	if pos.x ~= 0 or pos.y ~= 0 or pos.z ~= 0 then
		journal("Reprise loin de l'origine : " .. ccVec.tostring(pos))
		return S.RETURN
	end
	ccNav.turnTo(0)
	return S.TEND
end

--- Inspecte la case de plantation, et agit selon ce qui s'y trouve.
--
-- Cet état ne s'exécute QU'À l'origine, ce qui en fait le bon endroit pour
-- décider de l'arrêt : la turtle y est déjà rentrée et vidée. C'est aussi
-- pourquoi le compte d'arbres est vérifié APRÈS la plantation, et non avant --
-- sinon `ccChopper 1` laissait la ferme en friche derrière lui.
STATES[S.TEND] = function()
	ccNav.turnTo(0)

	local name = blockAt("forward")

	if name == nil then
		-- Case libre : on plante avant toute autre décision.
		local slot = findSapling()
		if not slot then
			ctx.reason = "saplings"
			return S.RETURN
		end
		turtle.select(slot)
		local placed = turtle.place()
		ccInv.selectForMining()
		if not placed then
			journal("Plantation impossible : sol inadapte ?")
			ctx.afterWait = S.TEND
			return S.AWAIT
		end
		name = blockAt("forward")
	end

	if ctx.target and ctx.trees >= ctx.target then
		journal(("Compte atteint : %d arbre(s)"):format(ctx.trees))
		return S.DONE
	end

	if isWood(name) then
		return S.CHOP
	end

	if isSapling(name) then
		local fertilized = false
		if CONFIG.fertilize then
			local bone = ccInv.find("minecraft:bone_meal")
			if bone then
				turtle.select(bone)
				fertilized = turtle.place()
				ccInv.selectForMining()
			end
		end

		-- Attente sur MINUTEUR, pas en boucle serrée. L'ancienne version
		-- tournait à vide 20 fois par seconde -- sleep(0) -- et reposait de la
		-- poudre d'os à chaque tour.
		--
		-- Deux durées. Une poudre d'os ne fait pousser qu'environ une fois sur
		-- deux : tant qu'il en reste et qu'elle prend, on réessaie vite. La
		-- longue attente est réservée à la pousse naturelle -- l'appliquer
		-- aussi après une poudre d'os donnait 20 s entre deux applications.
		--
		-- L'attente est aussi le seul moment où ce script est disponible pour
		-- l'utilisateur : les événements sont donc traduits en commandes ici,
		-- et consommés par applyCommands au tour suivant.
		local timer = os.startTimer(fertilized and CONFIG.fertilizeWait or CONFIG.growWait)
		while true do
			local e = { waitEvent() }
			if ctx.stopped then return S.TEND end
			if e[1] == "timer" and e[2] == timer then break end
			if e[1] == "char" or e[1] == "mouse_click" or e[1] == "monitor_touch" then
				local cmd = ccUi.dispatch(table.unpack(e))
				if cmd then
					ctx.pending[#ctx.pending + 1] = cmd
					break
				end
			end
		end
		return S.TEND
	end

	-- Autre chose devant : ni bois, ni pousse, ni air.
	journal("Bloc inattendu devant l'origine : " .. tostring(name))
	ctx.afterWait = S.TEND
	return S.AWAIT
end

STATES[S.CHOP] = function()
	ctx.lost = false
	ctx.logs = 0
	ccInv.selectForMining()

	-- Vérifié AVANT le premier coup, et pas seulement dans la récursion : le
	-- tronc est cassé par cet état lui-même, et turtle.dig() réussit même quand
	-- l'inventaire est plein -- l'objet est alors perdu en silence.
	local blocked = chopStop()
	if blocked then
		ctx.reason = blocked
		journal("Abattage differe : " .. blocked)
		return S.RETURN
	end

	-- Stock de saplings bas : on rase la canopée de cet arbre-là pour le
	-- refaire. Sinon on la laisse pourrir, ce qui divise le temps d'abattage.
	ctx.shave = saplingCount() < CONFIG.saplingReserve
	ctx.seen, ctx.wasWood = {}, {}

	local base = ccNav.position()

	if not clearTree("forward") then
		journal("Tronc inaccessible")
		return S.RETURN
	end
	if not ccNav.forward({ dig = false }) then
		journal("Entree dans le tronc impossible")
		return S.RETURN
	end

	chopHere(1, true)
	stepBackTo(base)
	ctx.seen, ctx.wasWood = nil, nil

	local stop = chopStop()
	ctx.trees = ctx.trees + 1
	journal(("Arbre abattu : %d blocs%s%s")
		:format(ctx.logs, ctx.shave and ", canopee rasee" or "",
		        stop and (", interrompu (" .. stop .. ")") or ""))

	ctx.reason = stop or "arbre"
	return S.RETURN
end

STATES[S.RETURN] = function()
	-- Rappel : aucune garde de carburant n'est installée sur ccNav (voir
	-- chopStop). Elle raisonne sur la position courante, donc au moment précis
	-- où la réserve est atteinte, elle interdirait AUSSI les mouvements qui
	-- rapprochent de l'origine -- c'est-à-dire ceux de cet état.
	if ccVec.equals(ccNav.position(), ORIGIN) then
		ccNav.turnTo(0)
		return S.SERVICE
	end

	-- Trajet direct, en ne cassant que l'arbre. Suffit dans le cas courant :
	-- on est dans le fût que l'on vient de vider.
	local ok = ccNav.goTo(ORIGIN, { dig = false })
	if ok then return S.SERVICE end

	-- Trajet de secours : par-dessus la canopée. C'est la seule route fiable
	-- après un redémarrage, quand le chemin d'aller est perdu.
	--
	-- On monte d'un cran à la fois, en retentant le trajet horizontal après
	-- chaque pas plutôt qu'en visant d'emblée le plafond : sortir du feuillage
	-- suffit presque toujours, et grimper 40 blocs coûterait 80 mouvements pour
	-- rien.
	journal("Retour direct impossible, passage par au-dessus")
	while ccNav.position().z < CONFIG.maxHeight do
		if not stepTo("up") then break end
		if ccNav.goTo({ x = 0, y = 0, z = ccNav.position().z }, { dig = false }) then
			break
		end
	end

	if ccNav.position().x ~= 0 or ccNav.position().y ~= 0 then
		journal("Trajet de secours bloque")
		return S.FAILED
	end

	while ccNav.position().z > 0 do
		if not stepTo("down") then
			journal("Descente sur l'origine bloquee")
			return S.FAILED
		end
	end

	ccNav.turnTo(0)
	return S.SERVICE
end

STATES[S.SERVICE] = function()
	gatherDrops()
	ccInv.tidy(fuelSlotForTidy())

	local where = findDepot()

	if where then
		local protect = protectedSlots()
		local ok, why, slot = ccInv.unload(where, {
			trashWhere = (where == "up") and "down" or "up",
			protect = protect,
		})
		if not ok then journal("Vidage : " .. tostring(why) .. " (slot " .. tostring(slot) .. ")") end

		-- Sortie du four AVANT le ravitaillement : le charbon de bois produit
		-- depuis le dernier service est alors à portée de la turtle, qui n'a
		-- pas à brûler de bûches tant qu'il en reste.
		local furnace
		if CONFIG.makeCharcoal then
			local why
			furnace, why = openFurnace(where)
			if furnace then collectFurnace(furnace) else journal("Four : " .. why) end
		end

		refuel(where)

		-- refuelFromChest garde à bord le reste d'une pile entamée : c'est
		-- voulu pour du charbon, mais l'étage « bois » aspire alors une pile
		-- de bûches, en brûle une ou deux, et rapporte le reste dans la
		-- turtle. La récolte quittait le coffre à chaque service. Le bois
		-- n'étant jamais protégé, un second vidage le rend.
		if ccInv.lootCount(protectedSlots()) > 0 then
			ccInv.unload(where, {
				trashWhere = (where == "up") and "down" or "up",
				protect = protectedSlots(),
			})
		end

		if not findSapling() then fetchSaplings(where) end

		if furnace then
			local fine, reason = feedFurnace(furnace)
			if not fine then journal("Four : " .. tostring(reason)) end
		end

		ccInv.tidy(fuelSlotForTidy())
	else
		-- Sans conteneur, on jette au moins le rebut : sans cela l'inventaire
		-- se remplit de feuilles et la turtle s'arrête au bout d'un arbre.
		ccInv.dumpTrash("up", { protect = protectedSlots() })
		refuel(nil)
	end

	ccNav.turnTo(0)

	if ctx.abort or ctx.stopped then return S.DONE end

	-- L'arrêt sur compte atteint appartient à PLANTATION, qui replante d'abord.
	-- On ne repart QUE si les conditions du retour sont levées.
	if ccInv.freeCount() <= CONFIG.spareSlots then
		journal("Inventaire plein : vider la turtle ou lui donner un conteneur")
		ctx.afterWait = S.SERVICE
		return S.AWAIT
	end
	-- Un sapling n'est exigé que si la case de plantation est VIDE. Un arbre
	-- adulte qui attend d'être abattu n'en demande pas : l'exiger bloquait la
	-- turtle en attente devant l'arbre même qui allait lui en fournir.
	if blockAt("forward") == nil and not findSapling() then
		journal("Plus de sapling : en mettre dans le conteneur")
		ctx.afterWait = S.SERVICE
		return S.AWAIT
	end
	if ccFuel.level() <= ccFuel.reserve(TREE, nil, CONFIG.fuelMargin) then
		journal("Carburant insuffisant : en fournir a la turtle")
		ctx.afterWait = S.SERVICE
		return S.AWAIT
	end

	ctx.reason = nil
	ctx.awaitDelay = nil
	return S.TEND
end

--- Attend une intervention humaine. Réveil sur changement d'inventaire, et sur
--- minuteur pour revérifier le conteneur, où l'utilisateur a pu déposer ce
--- qui manque sans que la turtle en soit avertie.
--
-- Le délai double à chaque réveil sans effet, de 5 s jusqu'à une minute : une
-- attente qui dure n'a pas à relancer un service complet toutes les 5 s. Une
-- intervention directe sur l'inventaire le remet à zéro.
STATES[S.AWAIT] = function()
	ctx.awaitDelay = math.min((ctx.awaitDelay or 2.5) * 2, 60)
	local timer = os.startTimer(ctx.awaitDelay)
	local event, id
	repeat
		event, id = waitEvent()
		if ctx.stopped then return S.AWAIT end
	until event == "turtle_inventory" or (event == "timer" and id == timer)

	if event == "turtle_inventory" then ctx.awaitDelay = nil end

	return ctx.afterWait or S.SERVICE
end

STATES[S.PAUSED] = function()
	waitEvent()
	return S.PAUSED
end

-- ---------------------------------------------------------------------------
-- Démarrage
-- ---------------------------------------------------------------------------

local function usage()
	print("ccChopper           ferme sans fin")
	print("ccChopper <n>       abat n arbres puis s'arrete")
	print("ccChopper del       oublie le travail en cours")
	print("ccChopper config    cree ou affiche les options")
	print("ccChopper update    met les APIs a jour")
	print("")
	print("La turtle doit REGARDER la case de plantation,")
	print("avec un conteneur contre elle (et un four pour le charbon).")
	print("Options : edit " .. CONFIG_PATH)
end

local function setup(a)
	store = ccSave.store(SAVE_PATH, { version = SAVE_VERSION, migrations = MIGRATIONS })

	if a[1] == "del" then
		store.delete()
		removeStartup()
		print("Travail en cours oublie.")
		return false
	end

	if a[1] == "config" then
		local _, warnings, created = ccConfig.load(CONFIG_PATH, DEFAULTS, CONFIG_TEMPLATE)
		print(created and ("Options creees : " .. CONFIG_PATH)
			or ("Options existantes : " .. CONFIG_PATH))
		for _, w in ipairs(warnings) do print("  " .. w) end
		print("Modifier avec : edit " .. CONFIG_PATH)
		return false
	end

	if a[1] ~= nil then
		local n = tonumber(a[1])
		if not n or n <= 0 or n ~= math.floor(n) then
			print("Argument invalide : " .. tostring(a[1]))
			usage()
			return false
		end
		ctx.target = n
	end

	-- Reprise : la position est restaurée, l'état repart par un retour à
	-- l'origine. La récursion d'abattage ne se sauvegarde pas -- c'est une
	-- pile d'appels Lua -- donc reprendre en plein arbre n'a pas de sens.
	local saved = store.read()
	if saved and saved.pos then
		ccNav.setPosition(saved.pos)
		ctx.trees = saved.trees or 0
		if ctx.target == nil then ctx.target = saved.target end
		ctx.state = S.CALIBRATE
		if saved.state == S.CHOP or saved.state == S.RETURN then
			journal("Reprise en " .. tostring(saved.state) .. " : retour a l'origine")
		end
	end

	installStartup()
	return true
end

-- ---------------------------------------------------------------------------
-- Boucle principale
-- ---------------------------------------------------------------------------

local function machine()
	while not ctx.stopped do
		applyCommands()

		if ctx.state == S.DONE or ctx.state == S.FAILED then
			ctx.stopped = true
			break
		end

		local fn = STATES[ctx.state]
		if not fn then
			ctx.error = "etat inconnu : " .. tostring(ctx.state)
			journal(ctx.error)
			ctx.state = S.FAILED
			ctx.stopped = true
			break
		end

		local before = ctx.state
		local ok, result = pcall(fn)
		if not ok then
			ctx.error = tostring(result)
			journal("Erreur en " .. before .. " : " .. ctx.error)
			ctx.state = S.FAILED
		elseif result == nil then
			ctx.error = "l'etat " .. before .. " n'a renvoye aucun etat suivant"
			journal(ctx.error)
			ctx.state = S.FAILED
		else
			ctx.state = result
		end

		if ctx.state ~= before and ctx.state ~= S.DONE and ctx.state ~= S.FAILED then
			journal(ctx.state)
			save()
		end
		draw()
	end
end

local function events()
	while not ctx.stopped do
		collect()
		draw()
	end
end

-- L'ordre compte : ccNav.reset() remet la position à l'origine, il doit donc
-- précéder setup(), qui la restaure depuis la sauvegarde. Les options sont
-- lues avant tout le reste : elles décident de ce qui est reconnu comme bois,
-- donc de ce que la turtle casse dès le premier mouvement.
local configWarnings, configCreated
CONFIG, configWarnings, configCreated = ccConfig.load(CONFIG_PATH, DEFAULTS, CONFIG_TEMPLATE)

ccNav.reset()
ccInv.reset({
	trash = CONFIG.trash,
	depotMinSlots = CONFIG.depotMinSlots,
	depotPatterns = CONFIG.depotPatterns,
})
if not setup(args) then return end

-- Sauvegarde à CHAQUE changement d'état suivi -- déplacement ET rotation. En
-- quittant la partie, le jeu n'accorde qu'un tick à la turtle : si elle vient
-- de pivoter sans que ce soit enregistré, elle rouvre avec un cap erroné.
ccNav.configure({ onChange = function() save() end })

setupUi()
ctx.drawTimer = os.startTimer(0.5)

if configCreated then journal("Options creees : " .. CONFIG_PATH) end
for _, w in ipairs(configWarnings) do journal("Options : " .. w) end
journal(("Rasage sous %d saplings, charbon : %s")
	:format(CONFIG.saplingReserve,
	        CONFIG.makeCharcoal and "oui" or "non"))

save()

parallel.waitForAny(machine, events)

ccUi.clear()
if ctx.interrupted then
	save()
	journal("Interrompu par Ctrl+T")
	print("Interrompu. Le travail est sauvegarde.")
	print("")
	print("  edit " .. CONFIG_PATH .. "   modifier les options")
	print("  ccChopper           reprendre")
	print("  ccChopper del       oublier")

elseif ctx.state == S.DONE then
	store.delete()
	removeStartup()
	print(("Termine : %d arbre(s) abattu(s)."):format(ctx.trees))
else
	print("Arret en etat " .. ctx.state .. ".")
	if ctx.error then print(ctx.error) end
	print("Journal complet : edit " .. LOG_PATH)
end
