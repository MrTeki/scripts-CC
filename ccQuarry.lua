-- ccQuarry par Teki
--
-- Creuse une carrière rectangulaire, avec reprise après reboot.
--
--   ccQuarry                                    menu de démarrage, ou reprise
--   ccQuarry <largeur> <profondeur> <hauteur>   nouveau chantier, sans menu
--   ccQuarry <taille>                           chantier cubique
--   ccQuarry del                                abandonne le chantier en cours
--
-- Sans argument ni chantier en cours, un menu règle dimensions, sens, côté,
-- dépôt, carburant et liste de rebut, au clavier sur toute turtle et aussi à
-- la souris sur une turtle avancée.
--
-- Hauteur positive : on creuse vers le BAS. Négative : vers le haut.
--
-- Conventions (voir README) : X / Y horizontaux, Z vertical, direction 0 = +X.
-- L'origine est la position de départ de la turtle, qui doit regarder dans la
-- direction de la largeur. La profondeur s'étend à sa droite, ou à sa gauche
-- si le menu le demande.
--
-- Trois façons de récupérer le butin, essayées dans cet ordre :
--   1. un coffre TRANSPORTABLE en inventaire (ender chest, shulker) : la
--      turtle le pose, le vide et le reprend LÀ OÙ ELLE EST, sans remonter
--      à l'origine ;
--   2. un conteneur FIXE contre l'origine. C'est le mode historique, avec un
--      coffre posé derrière la turtle. Le placer DERRIÈRE, AU-DESSUS, ou du
--      côté opposé au chantier : la carrière s'étend vers l'avant et vers la
--      droite (ou la gauche), donc un coffre posé là serait miné avec le reste ;
--   3. aucun des deux : la turtle attend qu'on vienne la vider.
-- Le conteneur fixe sert aussi de source de carburant. L'option `chest`
-- restreint ces modes à un seul, ou à aucun.
--
-- Aucun slot n'est interdit au butin. Les slots 1 et 16 sont seulement les
-- emplacements où la turtle RANGE le carburant et le coffre : ce qui est
-- épargné lors d'un vidage dépend de ce que le slot contient, pas de son
-- numéro. Un slot d'emplacement laissé vide sert donc normalement.
--
-- Ce script ne contient plus que ce qui lui est propre : la machine à états,
-- l'interface et les arguments. Le reste vit dans les APIs partagées.

-- ---------------------------------------------------------------------------
-- Amorce
-- ---------------------------------------------------------------------------
-- Un SEUL point d'entrée en dur : l'URL du dépôt. Mettre à jour une API se
-- fait en publiant le dépôt, jamais en rééditant les scripts déployés.
-- CCSuiteUpdater codait onze identifiants pastebin en dur et devenait
-- ingérable dès la première mise à jour ; une URL GitHub raw est stable.
--
-- Le reste de la logique vit dans ccBoot, pour qu'une évolution du mécanisme
-- ne demande pas de rééditer les six scripts installés.

local REPO = "https://raw.githubusercontent.com/MrTeki/scripts-CC/main/"

-- Version du script, comparée à celle du manifeste par `update`. À incrémenter,
-- ici ET dans manifest.lua, à chaque publication qui doit atteindre les turtles.
local VERSION = 3

-- Version minimale de ccBoot : la première qui sait mettre à jour le script.
local BOOT = 2

local NEEDS = {
	ccUtil = 1, ccVec = 1, ccPlan = 2, ccNav = 1, ccInv = 2, ccConfig = 2,
	ccFuel = 1, ccSave = 1, ccUi = 1, ccNet = 1, ccMenu = 1,
}

local args = { ... }

local function fetchBoot()
	if not http then
		error("apis/ccBoot.lua manquant ou trop ancien, et HTTP indisponible.\n"
			.. "Copier le dossier apis/ depuis " .. REPO, 0)
	end
	local res = http.get(REPO .. "apis/ccBoot.lua")
	if not res then error("Telechargement de ccBoot impossible : " .. REPO, 0) end
	local body = res.readAll()
	res.close()
	-- Contrôle de syntaxe avant d'écraser : un ccBoot tronqué bloquerait tous
	-- les scripts de l'ordinateur.
	if not body or #body == 0 or not load(body, "@ccBoot") then
		error("ccBoot telecharge illisible : " .. REPO, 0)
	end
	fs.makeDir("apis")
	local f = fs.open("apis/ccBoot.lua", "w")
	f.write(body)
	f.close()
	package.loaded.ccBoot = nil
end

local function boot()
	package.path = "/apis/?.lua;apis/?.lua;" .. package.path

	-- Un ccBoot absent, ou trop ancien pour connaître `update`, est remplacé.
	-- Le réseau n'est touché qu'à ce moment-là, une seule fois.
	local found, existing = pcall(require, "ccBoot")
	if not found or type(existing) ~= "table" or (existing._VERSION or 1) < BOOT then
		fetchBoot()
	end

	local ok, result = require("ccBoot").ensure(REPO, NEEDS)
	if not ok then error(result, 0) end
end

boot()

if args[1] == "update" then
	-- ccBoot, le script lui-même, puis les APIs que demande le NOUVEAU script.
	local path = shell and shell.getRunningProgram and shell.getRunningProgram()
	local ok, report = require("ccBoot").update(REPO, NEEDS,
		{ name = "ccQuarry", version = VERSION, path = path })
	if not ok then error(report, 0) end

	if report.boot then print("ccBoot mis a jour : v" .. report.boot) end
	if report.script then
		print("ccQuarry mis a jour : v" .. report.script .. ", relancer pour l'utiliser")
	end
	if #report.apis > 0 then print("APIs installees : " .. table.concat(report.apis, ", ")) end
	if not report.boot and not report.script and #report.apis == 0 then
		print("Tout est deja a jour.")
	end
	return
end

local ccUtil = require("ccUtil")
local ccVec  = require("ccVec")
local ccPlan = require("ccPlan")
local ccNav  = require("ccNav")
local ccInv  = require("ccInv")
local ccFuel = require("ccFuel")
local ccSave = require("ccSave")
local ccUi   = require("ccUi")
local ccNet  = require("ccNet")
local ccConfig = require("ccConfig")
local ccMenu = require("ccMenu")

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local SAVE_PATH = "ccquarry.save"
local SAVE_VERSION = 1
local LOG_PATH = "ccquarry.log"
-- Au-delà, le journal passe en .old (l'ancien .old est effacé). Sans plafond,
-- il remplissait le disque du turtle (1 Mo) au bout de quelques heures de
-- chantier, et l'écriture suivante tuait le script sur « Out of space ».
local LOG_MAX = 64 * 1024

local CONFIG_PATH = "ccquarry.cfg"

-- Valeurs par défaut. Le fichier ccquarry.cfg les remplace au cas par cas, et
-- leur TYPE sert à valider ce qui y est saisi.
local DEFAULTS = {
	fuelMargin = 64,          -- carburant gardé en plus du trajet de retour
	fuelTopUp = 2000,         -- visé lors d'un ravitaillement
	trashWhere = "up",        -- le rebut part dans la couche déjà creusée
	dropWhenNoChest = false,  -- sans coffre : attendre, plutôt que jeter
	chest = "auto",           -- dépôt : "auto", "portable", "fixed" ou "none"
	chestItem = "",           -- objet accepté comme coffre portable, en plus des motifs
	chestSlot = 16,           -- où la turtle range le coffre portable
	fuelSlot = 1,             -- où elle range le carburant
	keepFuel = 64,            -- combustible gardé au vidage ; le reste est du butin
	spareSlots = 2,           -- marge de slots libres avant de rentrer vider

	-- Taille minimale d'un inventaire pour servir de dépôt, quand l'API
	-- peripheral peut la donner. 27 = capacité d'un coffre vanilla.
	depotMinSlots = 27,

	-- Conteneurs FIXES : repli par motif, quand peripheral ne voit pas le bloc.
	depotPatterns = { "chest", "barrel", "shulker", "hopper", "drawer", "crate", "backpack" },

	-- Conteneurs TRANSPORTABLES acceptés. Plus restrictif : la turtle les
	-- casse pour les reprendre, donc ils doivent garder leur contenu.
	chestPatterns = { "ender_chest", "enderchest", "ender_storage", "enderstorage", "shulker_box" },

	trash = {
		"minecraft:cobblestone",
		"minecraft:stone",
		"minecraft:dirt",
		"minecraft:gravel",
		"minecraft:granite",
		"minecraft:diorite",
		"minecraft:andesite",
		"minecraft:tuff",
		"minecraft:deepslate",
		"minecraft:cobbled_deepslate",
		"minecraft:netherrack",
	},

	-- Dimensions proposées par le menu : celles du dernier chantier mémorisé.
	lastJob = { width = 16, depth = 16, height = 32, down = true, left = false },
}

-- Options qu'un chantier lancé depuis le menu fixe pour toute sa durée. Elles
-- sont copiées dans la sauvegarde : une reprise après reboot relit le fichier
-- d'options, qui ne les contient pas forcément.
local JOB_OPTIONS = {
	"chest", "chestItem", "chestSlot", "fuelSlot", "dropWhenNoChest",
	"keepFuel", "fuelMargin", "fuelTopUp", "trashWhere", "trash",
}

-- Écrit tel quel à la première exécution, puis jamais réécrit : les
-- modifications et les commentaires de l'utilisateur survivent aux
-- lancements suivants.
local CONFIG_TEMPLATE = [==[
-- Options de ccQuarry. Modifiable en jeu avec : edit ccquarry.cfg
-- Supprimer ce fichier le regenere avec les valeurs par defaut.

return {
    -- Que faire quand aucun coffre n'est disponible a l'origine, ni
    -- transportable (ender chest, shulker) ni fixe (coffre pose derriere) ?
    --   false : la turtle ATTEND qu'on vienne la vider. Rien n'est perdu,
    --           mais elle peut attendre longtemps sans que vous le sachiez.
    --   true  : elle depose le butin au sol et continue. Perte assumee.
    dropWhenNoChest = false,

    -- Mode de depot :
    --   "auto"     : coffre portable s'il y en a un, sinon conteneur fixe ;
    --   "portable" : seulement le coffre portable (ender chest, shulker) ;
    --   "fixed"    : seulement le conteneur pose contre l'origine ;
    --   "none"     : aucun depot, voir dropWhenNoChest.
    chest = "auto",

    -- Objet accepte comme coffre portable en plus de chestPatterns. Le menu le
    -- remplit quand on designe le slot d'un conteneur non reconnu.
    chestItem = "",

    -- Slots ou la turtle RANGE le coffre portable et le carburant. Ce ne sont
    -- pas des slots interdits au butin.
    chestSlot = 16,
    fuelSlot = 1,

    -- Blocs jetes a la volee au lieu d'etre rapportes. C'est le meilleur
    -- levier pour espacer les allers-retours de vidage : sans cette liste,
    -- une carriere passe son temps a rentrer.
    -- Vider la liste ( trash = {} ) pour tout conserver.
    trash = {
        "minecraft:cobblestone",
        "minecraft:stone",
        "minecraft:dirt",
        "minecraft:gravel",
        "minecraft:granite",
        "minecraft:diorite",
        "minecraft:andesite",
        "minecraft:tuff",
        "minecraft:deepslate",
        "minecraft:cobbled_deepslate",
        "minecraft:netherrack",
    },

    -- Ou part le rebut : "up", "down" ou "forward".
    -- "up" l'envoie dans la couche deja creusee, hors du chemin.
    trashWhere = "up",

    -- Taille minimale d'un inventaire pour servir de depot. L'API peripheral
    -- dit si un bloc voisin est un inventaire et combien de slots il a, ce
    -- qu'aucune liste de noms ne peut suivre d'un mod a l'autre. Le seuil
    -- ecarte les machines, qui n'ont qu'un petit tampon -- un four en a 3, un
    -- hopper 5 -- la ou un coffre vanilla en a 27.
    depotMinSlots = 27,

    -- REPLI par motif, utilise seulement quand l'API peripheral ne voit pas le
    -- bloc voisin. Si votre conteneur n'est reconnu par aucune des deux voies,
    -- le journal indique son identifiant exact : ajoutez un motif ici.
    depotPatterns = { "chest", "barrel", "shulker", "hopper", "drawer", "crate", "backpack" },

    -- Conteneurs TRANSPORTABLES acceptes, que la turtle pose puis reprend.
    -- Plus restrictif : elle les CASSE, donc ils doivent garder leur contenu.
    -- Un coffre ordinaire eparpillerait tout.
    chestPatterns = { "ender_chest", "enderchest", "ender_storage", "enderstorage", "shulker_box" },

    -- Combustible garde lors d'un vidage, en nombre d'objets. Le surplus part
    -- au coffre : le charbon est aussi du butin, tout garder reviendrait a ne
    -- jamais le deposer.
    keepFuel = 64,

    -- Slots laisses libres avant de rentrer vider. C'est une MARGE, pas du
    -- gaspillage : entre deux verifications la turtle ramasse au moins trois
    -- blocs, et davantage dans du gravier. Ce que l'inventaire ne peut plus
    -- accueillir est perdu en silence, turtle.dig() ne signalant rien.
    -- Monter a 3 si vous constatez des pertes ; descendre a 1 pour remplir au
    -- maximum, au risque d'en perdre.
    spareSlots = 2,

    -- Carburant garde en reserve en plus du trajet de retour.
    fuelMargin = 64,

    -- Niveau vise lors d'un ravitaillement au coffre.
    fuelTopUp = 2000,

    -- Dimensions proposees par le menu de demarrage. Il les met a jour quand
    -- on coche « Memoriser ».
    lastJob = { width = 16, depth = 16, height = 32, down = true, left = false },
}
]==]

local CONFIG = DEFAULTS

-- États. Le nom de l'état EST l'état : les drapeaux done / needFuel /
-- needClearInventory de l'ancienne version, et les 64 combinaisons théoriques
-- qu'ils décrivaient, disparaissent.
local S = {
	CALIBRATE   = "CALIBRAGE",
	GO_TO_WORK  = "TRAJET",
	MINING      = "MINAGE",
	RETURN_HOME = "RETOUR",
	SERVICE     = "SERVICE",
	AWAIT_HUMAN = "ATTENTE",
	AWAIT_FUEL  = "CARBURANT",
	PAUSED      = "PAUSE",
	FINISHING   = "FINITION",
	DONE        = "TERMINE",
	FAILED      = "ERREUR",
}

local ctx = {
	job = nil,
	index = 1,
	state = S.CALIBRATE,
	reason = nil,        -- pourquoi on rentre : "fuel", "inventory", "done", "abort"
	origin = nil,        -- position monde de l'origine, pour le GPS
	skips = 0,           -- cellules inatteignables sautées
	streak = 0,          -- sauts consécutifs, pour détecter le fond
	stopped = false,
	pending = {},        -- commandes en attente, jamais exécutées à la réception
	options = nil,       -- options choisies au menu, gardées dans la sauvegarde
}

local store

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

-- L'écran d'un turtle fait 13 lignes et se vide au premier nettoyage : un
-- message d'erreur qui n'existe que là est perdu au moment où il sert. Tout
-- passe donc aussi par un fichier, relisible après coup avec `edit ccquarry.log`.
local function journal(msg)
	msg = tostring(msg)
	pcall(ccUi.log, msg)

	-- Le journal est un confort : rien de ce qui l'empêche d'écrire (disque
	-- plein compris) ne doit arrêter le chantier.
	pcall(function()
		if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > LOG_MAX then
			fs.delete(LOG_PATH .. ".old")
			fs.move(LOG_PATH, LOG_PATH .. ".old")
		end
		local handle = fs.open(LOG_PATH, "a")
		if not handle then return end
		pcall(handle.write, ("[%.1f] %s | %s\n"):format(os.clock(), ctx.state or "?", msg))
		handle.close()
	end)
end

--- Attend un événement, en traitant Ctrl+T comme une demande d'arrêt propre.
--
-- os.pullEvent transforme l'interruption en erreur « Terminated » : selon la
-- coroutine où elle tombe, le script mourait sur une erreur Lua brute ou
-- basculait en ERREUR. Or Ctrl+T est le seul moyen de reprendre la main pour
-- modifier les options, et c'est une manoeuvre normale, pas une panne.
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

local STARTUP = 'shell.run("ccQuarry")\n'

local function startupContent()
	if not fs.exists("startup.lua") then return nil end
	local f = fs.open("startup.lua", "r")
	local content = f.readAll()
	f.close()
	return content
end

local function installStartup()
	-- Écrit localement : l'ancienne version faisait un `pastebin get` à chaque
	-- lancement, sans vérifier le résultat. Sans HTTP ou sans pastebin, il n'y
	-- avait donc pas de fichier startup, donc pas de reprise après un
	-- rechargement de chunk -- soit exactement ce à quoi il servait.
	local current = startupContent()
	if current == STARTUP then return end     -- déjà le nôtre

	if current then
		-- L'ancienne version archivait à CHAQUE lancement : au deuxième
		-- chantier, le startup de l'utilisateur était écrasé par le nôtre.
		if not fs.exists("startup.old") then fs.move("startup.lua", "startup.old") end
		fs.delete("startup.lua")
	end

	local f = fs.open("startup.lua", "w")
	f.write(STARTUP)
	f.close()
end

local function removeStartup()
	-- On ne retire que le nôtre : `ccquarry del` supprimait le fichier sans
	-- regarder, y compris le startup de l'utilisateur.
	if startupContent() == STARTUP then fs.delete("startup.lua") end
	if not fs.exists("startup.lua") and fs.exists("startup.old") then
		fs.move("startup.old", "startup.lua")
	end
end

-- ---------------------------------------------------------------------------
-- Sauvegarde
-- ---------------------------------------------------------------------------

-- Migration depuis le format d'origine : 16 index numériques, drapeaux en
-- chaînes. On ne récupère que ce qui a encore un sens, la position et la
-- cible ; le curseur est recalculé à partir de la position.
local MIGRATIONS = {
	[0] = function(old)
		return {
			legacy = true,
			pos = ccVec.new(old[1], old[2], old[3], old[4]),
			job = {
				width = (old[9] or 0) + 1,
				depth = (old[10] or 0) + 1,
				height = math.abs(old[11] or 0) + 1,
				down = (old[11] or 0) <= 0,
			},
		}
	end,
}

local function save()
	if not ctx.job then return end
	store.write({
		job = ctx.job,
		index = ctx.index,
		state = ctx.state,
		reason = ctx.reason,
		origin = ctx.origin,
		skips = ctx.skips,
		options = ctx.options,
		pos = ccNav.position(),
	})
end

-- ---------------------------------------------------------------------------
-- Interface
-- ---------------------------------------------------------------------------

local function setupUi()
	ccUi.reset({ logLines = 1 })
	ccUi.useMonitor()
	ccUi.addButton({ label = "REFUEL", y = 1, cmd = "refuel" })
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	-- Pas de touche explicite : la première lettre, S, est celle que
	-- l'écran met en évidence. L'ancien raccourci, x, n'apparaissait pas dans
	-- le libellé ; ccUi surlignait donc le S, qui ne faisait rien.
	ccUi.addButton({ label = "STOP", y = 3, cmd = "abort" })
	ccUi.clear()
end

local function draw()
	if not ctx.job then return end
	local job, width = ctx.job, ccUi.size()
	local pos = ccNav.position()
	local total = ccPlan.total(job)

	ccUi.line(1, ("Carriere %dx%dx%d"):format(job.width, job.depth, job.height))

	ccUi.bar({
		x1 = 1, x2 = math.min(width - 8, 30), y = 2,
		colorFull = colors.lime, colorEmpty = colors.gray,
		max = total, current = math.min(ctx.index - 1, total), label = "",
	})

	-- Exact, et non plus estimé : plus de blocsLeftInCurLvl.
	ccUi.line(3, "Blocs restants : " .. ccPlan.remainingBlocks(job, ctx.index))
	ccUi.line(4, ("Carburant : %s / %s")
		:format(ccFuel.isUnlimited() and "illimite" or ccFuel.level(),
		        ccFuel.isUnlimited() and "illimite" or ccFuel.limit()))
	ccUi.line(5, "Reserve : " .. ccFuel.reserve(pos, nil, CONFIG.fuelMargin))
	ccUi.line(6, "Position : " .. ccVec.tostring(pos))
	ccUi.line(7, ("Cellule : %d / %d  (couche %d)")
		:format(math.min(ctx.index, total), total, ccPlan.cellAt(job, math.min(ctx.index, total)).layer + 1))
	ccUi.line(8, "Slots libres : " .. ccInv.freeCount())
	ccUi.line(9, "Etat : " .. ctx.state .. (ctx.reason and (" (" .. ctx.reason .. ")") or ""))
	if ctx.skips > 0 then
		ccUi.line(10, "Cellules inatteignables : " .. ctx.skips)
	end
end

-- ---------------------------------------------------------------------------
-- Réseau
-- ---------------------------------------------------------------------------

local function setupNet()
	ccNet.reset()
	if not ccNet.open() then return end

	ccNet.setTelemetry(function()
		local pos = ccNav.position()
		return {
			script = "ccQuarry",
			etat = ctx.state,
			raison = ctx.reason,
			job = ctx.job,
			index = ctx.index,
			total = ctx.job and ccPlan.total(ctx.job) or 0,
			progression = ctx.job and ccPlan.progress(ctx.job, ctx.index) or 0,
			blocsRestants = ctx.job and ccPlan.remainingBlocks(ctx.job, ctx.index) or 0,
			pos = { x = pos.x, y = pos.y, z = pos.z, dir = pos.dir },
			slotsLibres = ccInv.freeCount(),
			sautees = ctx.skips,
		}
	end)
end

-- ---------------------------------------------------------------------------
-- Commandes
-- ---------------------------------------------------------------------------

-- Les commandes sont COLLECTÉES ici et CONSOMMÉES entre deux transitions.
-- L'ancienne version appelait Refuel() directement depuis la coroutine
-- d'affichage, en pleine opération de la boucle principale.
local function drainRemote()
	local remote = ccNet.popCommand()
	while remote do
		ctx.pending[#ctx.pending + 1] = remote.name
		remote = ccNet.popCommand()
	end
end

local function collect()
	local e = { waitEvent() }
	local name = e[1]
	if ctx.stopped then return end

	if name == "char" or name == "mouse_click" or name == "monitor_touch" then
		local cmd = ccUi.dispatch(table.unpack(e))
		if cmd then ctx.pending[#ctx.pending + 1] = cmd end
		draw()

	elseif name == "rednet_message" then
		-- handleMessage et non poll : l'événement vient d'être consommé ici,
		-- rednet.receive ne le reverrait jamais.
		ccNet.handleMessage(e[2], e[3], e[4])
		drainRemote()

	elseif name == "timer" and e[2] == ctx.drawTimer then
		ctx.drawTimer = os.startTimer(0.5)
		draw()
	end
end

local function applyCommands()
	while #ctx.pending > 0 do
		local cmd = table.remove(ctx.pending, 1)

		if cmd == "pause" or cmd == "resume" then
			if ctx.state == S.PAUSED then
				ctx.state = ctx.resumeTo or S.MINING
				journal("Reprise")
			else
				ctx.resumeTo = ctx.state
				ctx.state = S.PAUSED
				journal("En pause")
			end

		elseif cmd == "refuel" then
			-- On ne ravitaille pas ici : on demande un retour au coffre.
			ctx.reason = "fuel"
			ctx.state = S.RETURN_HOME
			journal("Ravitaillement demande")

		elseif cmd == "abort" or cmd == "home" then
			ctx.reason = "abort"
			ctx.state = S.RETURN_HOME
			journal("Arret demande")
		end
	end
end

-- ---------------------------------------------------------------------------
-- États
-- ---------------------------------------------------------------------------

--- Slots à ne pas vider : de quoi garder du combustible. Le coffre est
--- protégé par ccInv lui-même, qui sait le reconnaître.
local function protectedSlots()
	return (ccFuel.protectSlots(CONFIG.keepFuel))
end

--- Range l'inventaire : piles partielles regroupées, coffre et carburant
--- remis à leurs emplacements canoniques.
local function tidyInventory()
	ccInv.tidy(ccFuel.bestFuelSlot())
end

--- Tente de couvrir la réserve avec le combustible déjà en soute, sans bouger.
--
-- Remonter à l'origine pour brûler du charbon qu'on transporte est un
-- aller-retour pour rien -- et la carrière en produit justement.
-- @return true si la réserve est de nouveau couverte
local function refuelOnSite()
	local function covered()
		return ccFuel.level() > ccFuel.reserve(ccNav.position(), nil, CONFIG.fuelMargin)
	end
	if covered() then return true end

	ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
	if not covered() then return false end

	journal("Ravitaille sur place")
	return true
end

local function needsService()
	-- Le ménage n'a lieu QUE lorsque la place vient à manquer.
	--
	-- Le faire à chaque cellule coûtait bien plus cher que le minage lui-même :
	-- dumpTrash paie un select et un drop par pile, et protectedSlots un select
	-- plus un refuel(0) par pile occupée -- toutes des commandes à un tick.
	-- Avec dix slots pleins, cela faisait une vingtaine de ticks de ménage pour
	-- trois blocs minés.
	--
	-- Et ce n'est pas seulement moins cher : la liste de rebut n'a qu'un but,
	-- éviter le trajet de retour. Il suffit donc de la vider juste avant que
	-- l'inventaire ne force ce trajet. getItemCount étant immédiat, le test
	-- ci-dessous, lui, ne coûte rien.
	--
	-- Et il est déclenché sur un CHANGEMENT, pas sur un niveau. Sur le niveau,
	-- il se relançait à chaque cellule dès que la place devenait rare, y
	-- compris quand il n'y avait plus rien à libérer -- butin absent de la
	-- liste de rebut, ou piles déjà compactées. Tant que la place ne diminue
	-- pas, refaire le ménage ne peut rien libérer de plus : on ne le relance
	-- donc que si un slot de plus a été occupé depuis la dernière fois, ce qui
	-- borne les tentatives stériles à une par slot.
	local free = ccInv.freeCount()

	if free <= CONFIG.spareSlots and free < (ctx.lastTidy or math.huge) then
		ccInv.compact()
		if #CONFIG.trash > 0 then
			ccInv.dumpTrash(CONFIG.trashWhere, { protect = protectedSlots() })
		end
		free = ccInv.freeCount()
		ctx.lastTidy = free
	end

	-- Tout est rangé et il ne reste que la marge : on rentre.
	--
	-- On ne cherche PAS à prévoir si le prochain bloc tiendra. turtle.inspect()
	-- donne le nom du BLOC, pas celui du BUTIN : la pierre lâche du cobble, le
	-- gravier lâche du gravier ou du silex, et un même bloc peut lâcher
	-- plusieurs objets différents. Aucune prévision fiable n'est possible.
	--
	-- On garde donc une marge. Entre deux passages ici, la turtle ramasse au
	-- moins trois blocs -- creusement en haut, en bas, et devant elle en
	-- avançant -- et davantage si elle traverse du gravier. Sans marge, ce que
	-- l'inventaire ne peut plus accueillir est perdu EN SILENCE : turtle.dig()
	-- renvoie true même quand l'objet tombe au sol faute de place.
	if free <= CONFIG.spareSlots then return "inventory" end

	if not refuelOnSite() then return "fuel" end
	return nil
end

local STATES = {}

-- Défini plus bas, avec les autres fonctions de vidage.
local serviceOnSite

local BEDROCK = "minecraft:bedrock"

--- Cellules de bedrock consécutives au-delà desquelles le fond est atteint.
--
-- Sans cette règle, seule une couche ENTIÈRE inatteignable concluait : sur un
-- 16x16, 256 cellules tentées une à une, chacune avec un détour par le
-- dessus. Or le bedrock n'a rien au-delà. Une rangée complète suffit : dans
-- la couche de bedrock irrégulière, une rangée de 16 bedrocks d'affilée est
-- rare (moins de 3 % à 80 % de bedrock, un millième à 60 %), et ce qu'on y
-- perdrait se limite à quelques blocs au ras du fond. Au moins 8, pour qu'un
-- chantier étroit ne s'arrête pas sur deux ou trois blocs malchanceux.
local function bedrockFloor(job)
	return math.min(ccPlan.perLayer(job), math.max(job.width, job.depth, 8))
end

STATES[S.CALIBRATE] = function()
	-- Le GPS, s'il est disponible, rend la reprise fiable : la position suivie
	-- peut être en retard d'un bloc après un reboot en plein mouvement.
	local world = ccNav.gpsPosition()
	if world then
		if not ctx.origin then
			-- Premier lancement : l'origine du chantier est ici.
			ctx.origin = world
		end
		ccNav.calibrate(ctx.origin)

		local heading = ccNav.gpsHeading()
		if heading then ccNav.setPosition({ x = ccNav.position().x, y = ccNav.position().y,
			z = ccNav.position().z, dir = heading }) end
		journal("Recale par GPS")
	else
		journal("Pas de GPS, suivi a l'estime")
	end
	return S.GO_TO_WORK
end

STATES[S.GO_TO_WORK] = function()
	ccNav.setGuard(ccFuel.guard(ccNav.position, nil, CONFIG.fuelMargin))

	-- goTo creuse devant lui : la MAJORITÉ du butin est ramassée pendant le
	-- trajet, pas au moment de creuser la cellule. La sélection doit donc être
	-- remise ici aussi. Les opérations de ccInv sont transparentes, mais celles
	-- de ccFuel laissent volontairement la sélection sur un slot de travail,
	-- puisque isFuel() lit le slot sélectionné.
	ccInv.selectForMining()

	if ctx.index > ccPlan.total(ctx.job) then
		ctx.reason = "done"
		return S.RETURN_HOME
	end

	local cell = ccPlan.cellAt(ctx.job, ctx.index)
	local ok, reason, block = ccNav.goTo(cell)

	if not ok and reason ~= "no_fuel" and reason ~= "denied" then
		-- Contournement par la couche du dessus, déjà creusée : sans cela, une
		-- cellule inatteignable bloque aussi TOUTES celles qui la suivent dans
		-- le serpentin, puisque le trajet passe par elle.
		local detour = { x = cell.x, y = cell.y, z = cell.z + (ctx.job.down and 1 or -1) }
		if ccNav.goTo(detour) then
			ok, reason, block = ccNav.goTo(cell)
		end
	end

	if ok then
		ctx.streak = 0
		ctx.bedrock = 0
		return S.MINING
	end

	if reason == "no_fuel" or reason == "denied" then
		-- La garde refuse le mouvement AVANT que MINAGE ne puisse tester quoi
		-- que ce soit : c'est donc ici, et pas seulement dans needsService,
		-- qu'il faut envisager de brûler ce qu'on transporte.
		if refuelOnSite() then return S.GO_TO_WORK end
		-- Puis le coffre portable, posé là où l'on est : la garde se
		-- déclenche aussi en plein trajet, pas seulement au fond.
		if serviceOnSite() then return S.GO_TO_WORK end
		ctx.reason = "fuel"
		return S.RETURN_HOME
	end

	-- Cellule inatteignable : on la saute au lieu de terminer le chantier.
	-- L'ancienne version mettait done = true sur un unique mouvement raté.
	ctx.skips = ctx.skips + 1
	ctx.streak = ctx.streak + 1
	ctx.bedrock = (block == BEDROCK) and (ctx.bedrock or 0) + 1 or 0
	journal("Inatteignable : " .. tostring(block or reason))

	if ctx.streak >= ccPlan.perLayer(ctx.job) or ctx.bedrock >= bedrockFloor(ctx.job) then
		-- Une couche entière inatteignable, ou une rangée de bedrock : c'est
		-- le fond.
		journal("Fond atteint")
		ctx.reason = "done"
		return S.RETURN_HOME
	end

	ctx.index = ctx.index + 1
	return S.GO_TO_WORK
end

STATES[S.MINING] = function()
	local cell = ccPlan.cellAt(ctx.job, ctx.index)
	local pos = ccNav.position()
	if pos.x ~= cell.x or pos.y ~= cell.y or pos.z ~= cell.z then
		return S.GO_TO_WORK
	end

	-- Avant de creuser : la sélection repart du premier slot, pour que le butin
	-- s'empile densément au lieu d'atterrir là où la dernière opération avait
	-- laissé la sélection.
	ccInv.selectForMining()

	if cell.digUp then ccNav.dig("up") end
	if cell.digDown then ccNav.dig("down") end

	ctx.index = ctx.index + 1

	local need = needsService()
	-- Avec un coffre portable, le vidage se fait là où l'on est : remonter à
	-- l'origine pour poser un coffre qu'on transporte est un aller-retour
	-- pour rien, d'autant plus long que la carrière est profonde.
	if need and serviceOnSite() then need = nil end
	if need then
		ctx.reason = need
		return S.RETURN_HOME
	end

	if ctx.index > ccPlan.total(ctx.job) then
		ctx.reason = "done"
		return S.RETURN_HOME
	end
	return S.GO_TO_WORK
end

STATES[S.RETURN_HOME] = function()
	-- La garde est levée : elle raisonne sur la position courante, donc au
	-- moment précis où la réserve est atteinte, elle interdirait AUSSI les
	-- mouvements qui rapprochent de l'origine.
	ccNav.setGuard(nil)

	local ok, reason = ccNav.goTo({ x = 0, y = 0, z = 0, dir = 0 })
	if not ok then
		journal("Retour impossible : " .. tostring(reason))
		return S.FAILED
	end
	return ctx.reason == "done" and S.FINISHING or S.SERVICE
end

--- Pose le coffre sous la turtle, en dégageant la case si nécessaire.
local function placeChest()
	local ok, reason = ccInv.placeChest("down")
	if ok then return true end

	if reason == "no_chest" then
		journal("Aucun coffre reconnu en inventaire")
		return false, reason
	end

	-- La case sous la turtle n'est pas libre : on la dégage et on réessaie.
	ccNav.dig("down")
	ok, reason = ccInv.placeChest("down")
	if not ok then journal("Pose du coffre impossible : " .. tostring(reason)) end
	return ok
end

--- Cherche un conteneur fixe autour de l'origine.
--
-- C'est le mode de dépôt historique, qu'il fallait rétablir : un coffre posé
-- contre la turtle à son point de départ. L'ancien script faisait
-- `GoTo(0,0,0,2)` puis `turtle.drop()`, ce qui imposait de le placer DERRIÈRE
-- l'origine, sans que ce soit écrit nulle part. Ici les quatre côtés et le
-- dessus sont examinés, donc n'importe quelle position convient.
--
-- La turtle finit face au conteneur quand il est horizontal.
-- @return "forward", "up" ou nil
local function findDepot()
	-- Les blocs examinés et rejetés sont journalisés, avec leur taille quand
	-- l'API peripheral la donne : sans cette trace, un conteneur non reconnu
	-- ne laisse aucune indication de ce qu'il faut déclarer.
	local seen = {}

	local function describe(name, slots)
		return name .. (slots and (" (" .. slots .. " slots)") or " (nom seul)")
	end

	for _ = 1, 4 do
		local found, name, slots = ccInv.depotAt("forward")
		if found then
			journal("Depot fixe : " .. describe(name, slots))
			return "forward"
		end
		if name then seen[#seen + 1] = describe(name, slots) end
		ccNav.turnRight()
	end

	local above, name, slots = ccInv.depotAt("up")
	if above then
		journal("Depot fixe au-dessus : " .. describe(name, slots))
		return "up"
	end
	if name then seen[#seen + 1] = describe(name, slots) end

	if #seen > 0 then
		journal("Aucun depot reconnu parmi : " .. table.concat(seen, ", "))
		journal("Voir depotMinSlots et depotPatterns dans " .. CONFIG_PATH)
	end
	return nil
end

--- Trace le contenu de l'inventaire, pour comprendre après coup ce qui a été
--- gardé, jeté ou déposé.
local function journalInventory()
	local parts = {}
	for slot = 1, 16 do
		local d = ccInv.detail(slot)
		if d then parts[#parts + 1] = slot .. ":" .. d.name .. "x" .. d.count end
	end
	journal("Inventaire " .. (#parts == 0 and "vide" or table.concat(parts, " ")))
end

--- Vide l'inventaire par le meilleur moyen disponible, et ravitaille au passage.
-- Trois modes, dans l'ordre de préférence :
--   1. coffre transportable, posé puis repris ;
--   2. conteneur fixe autour de l'origine ;
--   3. rien -- l'appelant décide alors d'attendre ou de jeter.
-- @return "chest", "depot" ou nil
--- Direction où jeter le rebut pendant un vidage.
-- Jamais celle du conteneur : sinon le rebut y atterrit au lieu d'être jeté,
-- ce qui annule tout l'intérêt de la liste. Le cas se présente dès que le
-- dépôt fixe est au-dessus, la direction par défaut du rebut.
local function trashAwayFrom(where)
	if CONFIG.trashWhere ~= where then return CONFIG.trashWhere end
	return where == "up" and "down" or "up"
end

--- Vide l'inventaire dans le coffre portable déjà posé, ravitaille si
--- demandé, puis reprend le coffre.
-- @return true si le coffre a été repris
--- Ravitaille depuis le conteneur visé, après avoir brûlé ce qu'on porte.
--
-- Retient si le conteneur contenait du combustible : un coffre qui ne reçoit
-- que du butin n'en aura pas davantage au passage suivant, et le fouiller
-- coûte une aspiration, un test et un dépôt par pile examinée.
local function refuelFromContainer(where)
	if ccFuel.level() >= CONFIG.fuelTopUp then return end
	-- Le moins cher d abord : ce qu on transporte deja.
	ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
	if ccFuel.level() >= CONFIG.fuelTopUp then return end

	local fine, why = ccFuel.refuelFromChest(where, CONFIG.fuelTopUp)
	ctx.chestFuel = fine or why ~= "no_fuel_found"
	if not fine then journal("Carburant : " .. tostring(why)) end
end

local function unloadIntoChest(where, refuel)
	local ok, reason, slot = ccInv.unload(where, { trashWhere = trashAwayFrom(where), protect = protectedSlots() })
	if not ok then
		journal("Vidage : " .. tostring(reason) .. " (slot " .. tostring(slot) .. ")")
	end

	if refuel then refuelFromContainer(where) end

	local taken, why = ccInv.takeChest(where)
	if not taken then journal("Reprise du coffre : " .. tostring(why)) end
	tidyInventory()     -- le ravitaillement a pu disperser le combustible
	return taken
end

--- Service sur place, au fond de la carrière, avec le coffre portable.
--
-- Le coffre n'est posé que dans une case VIDE, sous la turtle puis au-dessus :
-- jamais rien n'est creusé pour lui faire de la place. Sous elle, c'est soit
-- la couche qu'elle vient de creuser, soit le fond du chantier, et la pose
-- échoue alors sans dommage ; au-dessus, c'est la couche précédente.
--
-- Le coffre n'est fouillé pour du carburant que si la réserve n'est plus
-- couverte : il contient le butin, et le fouiller à chaque vidage reviendrait
-- à en aspirer puis rendre une partie pour rien.
-- @return true si la turtle peut reprendre le travail sans rentrer
serviceOnSite = function()
	if CONFIG.chest == "fixed" or CONFIG.chest == "none" then return false end
	if not ccInv.findChest() then return false end

	tidyInventory()
	local low = not refuelOnSite()
	for _, where in ipairs({ "down", "up" }) do
		if ccInv.placeChest(where) then
			journal("Vidage sur place")
			local taken = unloadIntoChest(where, low)
			ctx.lastTidy = nil
			-- Coffre resté en place : on rentre, le service à l'origine
			-- prendra le relais avec ce qu'il trouvera.
			if not taken then return false end
			return ccInv.freeCount() > CONFIG.spareSlots and refuelOnSite()
		end
	end
	return false
end

local function serviceUnload(refuel)
	-- Rangement AVANT le vidage : le coffre et le carburant retrouvent leurs
	-- emplacements, et les piles partielles sont regroupées. Sans cela, du
	-- butin ayant squatté l'emplacement du carburant s'y installait pour de
	-- bon, puisque l'ancienne version protégeait le slot 1 quel qu'en soit le
	-- contenu -- au point de jeter le vrai carburant, qui était ailleurs.
	tidyInventory()

	local mode = CONFIG.chest
	local portable = mode ~= "fixed" and mode ~= "none"
	local fixed = mode ~= "portable" and mode ~= "none"

	if portable and placeChest() then
		unloadIntoChest("down", refuel)
		return "chest"
	end

	local where = fixed and findDepot()
	if where then
		local ok, reason, slot = ccInv.unload(where, { trashWhere = trashAwayFrom(where), protect = protectedSlots() })
		if not ok then
			journal("Vidage : " .. tostring(reason) .. " (slot " .. tostring(slot) .. ")")
		end

		-- Le conteneur fixe sert aussi de source de carburant : c'est là qu'on
		-- vient déposer du charbon pour la turtle.
		if refuel then refuelFromContainer(where) end
		tidyInventory()
		return "depot"
	end

	return nil
end

--- Assez de carburant pour retourner à la prochaine cellule, et en revenir ?
local function fuelForWork()
	local cell = ccPlan.cellAt(ctx.job, math.min(ctx.index, ccPlan.total(ctx.job)))
	return ccFuel.level() > ccFuel.reserve(cell, nil, CONFIG.fuelMargin)
end

local FUEL_CHEST_RETRY = 60   -- secondes entre deux fouilles du coffre
local WAIT_MARK = "ccquarry_wait"

STATES[S.SERVICE] = function()
	-- Le coffre n'est fouillé pour du carburant que s'il peut en contenir, ou
	-- si la turtle en a réellement besoin. Auparavant, il l'était à CHAQUE
	-- passage dès que le niveau était sous fuelTopUp, donc presque toujours :
	-- avec un coffre qui ne reçoit que du butin, des dizaines d'opérations
	-- pour rien. La première fouille d'une session tranche la question.
	local refuel = ctx.reason == "fuel" or ctx.chestFuel ~= false or not fuelForWork()
	if not serviceUnload(refuel) then
		-- Aucun moyen de dépôt : on brûle ce qu'on a, on jette le rebut, et le
		-- reste du service dépend d'un humain. Le butin, lui, reste à bord.
		journal("Aucun conteneur a l'origine : le butin reste a bord")
		ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
		ccInv.dumpTrash(CONFIG.trashWhere, { protect = protectedSlots() })
		if CONFIG.dropWhenNoChest then
			ccInv.unload("forward", { trashWhere = trashAwayFrom("forward"), protect = protectedSlots() })
		end
	end

	-- L'inventaire vient d'être remanié : le prochain ménage doit pouvoir
	-- se déclencher, quel que soit l'état d'avant le retour.
	ctx.lastTidy = nil

	if ctx.reason == "abort" then return S.FINISHING end

	-- On ne repart QUE si les deux conditions du retour sont levées. Repartir
	-- sans place ou sans carburant, c'est retomber en panne au fond du trou.
	if ccInv.freeCount() <= 1 then
		journal("Inventaire plein : vider la turtle ou lui donner un coffre")
		ctx.afterWait = S.SERVICE
		return S.AWAIT_HUMAN
	end

	if not fuelForWork() then
		journal("Carburant insuffisant : en fournir a la turtle")
		-- Le coffre vient d'être fouillé : on ne le refouillera qu'à
		-- l'échéance. Le refaire à chaque réveil, c'était aspirer puis rendre
		-- le butin qu'on venait d'y déposer, en boucle -- refuelFromChest ne
		-- peut pas savoir où est le combustible sans tout sortir.
		ctx.chestRetryAt = os.clock() + FUEL_CHEST_RETRY
		ctx.afterWait = S.AWAIT_FUEL
		return S.AWAIT_HUMAN
	end

	ctx.reason = nil
	return S.GO_TO_WORK
end

--- Attente de carburant. Ce qu'on donne à la turtle est brûlé à chaque
-- réveil ; le coffre, lui, n'est refouillé qu'à l'échéance, ou sur la
-- commande REFUEL.
STATES[S.AWAIT_FUEL] = function()
	ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
	if fuelForWork() then
		journal("Carburant fourni, reprise")
		tidyInventory()
		ctx.reason = nil
		return S.GO_TO_WORK
	end
	if os.clock() >= (ctx.chestRetryAt or 0) then return S.SERVICE end
	ctx.afterWait = S.AWAIT_FUEL
	return S.AWAIT_HUMAN
end

--- Attend une intervention humaine. C'est le comportement par DÉFAUT sans
-- coffre reconnu : le butin d'une carrière ne doit pas partir au sol sans que
-- ce soit demandé. Le réveil se fait sur un changement d'inventaire, et sur un
-- minuteur pour que les commandes reçues entre-temps soient traitées.
STATES[S.AWAIT_HUMAN] = function()
	-- Les turtle_inventory déjà en file viennent des propres manipulations de
	-- la turtle juste avant l'attente : s'y réveiller relançait aussitôt
	-- l'état demandeur, sans que personne n'ait rien donné. Seuls comptent
	-- ceux qui suivent ce marqueur.
	os.queueEvent(WAIT_MARK)
	local armed = false
	local timer = os.startTimer(5)
	repeat
		local event, id = waitEvent()
		if ctx.stopped then return S.AWAIT_HUMAN end
		if event == WAIT_MARK then armed = true end
	until (armed and event == "turtle_inventory") or (event == "timer" and id == timer)

	-- La décision de repartir appartient à l'état qui a demandé l'attente :
	-- lui seul connaît les conditions à revérifier.
	return ctx.afterWait or S.SERVICE
end

STATES[S.PAUSED] = function()
	waitEvent()
	return S.PAUSED
end

STATES[S.FINISHING] = function()
	journalInventory()

	if ccInv.lootCount(protectedSlots()) > 0 then
		-- Pas de ravitaillement ici : le chantier est fini.
		if not serviceUnload(false) then
			if CONFIG.dropWhenNoChest then
				ccInv.unload("forward", { trashWhere = trashAwayFrom("forward"), protect = protectedSlots() })
			else
				-- Le chantier est fini mais la turtle tient encore du butin :
				-- elle attend qu'on la vide plutôt que de l'abandonner au sol.
				ccInv.dumpTrash(CONFIG.trashWhere, { protect = protectedSlots() })
				if ccInv.lootCount(protectedSlots()) > 0 then
					journal("Chantier fini : vider la turtle pour qu'elle s'arrete")
					ctx.afterWait = S.FINISHING
					return S.AWAIT_HUMAN
				end
			end
		end
		journalInventory()
	end

	store.delete()
	removeStartup()
	journal("Chantier termine")
	return S.DONE
end

-- ---------------------------------------------------------------------------
-- Démarrage
-- ---------------------------------------------------------------------------

local function usage()
	print("ccQuarry               menu, ou reprise du chantier")
	print("ccQuarry <largeur> <profondeur> <hauteur>")
	print("ccQuarry <taille>      chantier cubique")
	print("ccQuarry del           abandonne le chantier en cours")
	print("ccQuarry config        cree ou affiche les options")
	print("ccQuarry update        met le script et les APIs a jour")
	print("")
	print("Hauteur positive : on creuse vers le bas.")
	print("Options : edit " .. CONFIG_PATH)
end

-- ---------------------------------------------------------------------------
-- Menu de démarrage
-- ---------------------------------------------------------------------------

local MINECRAFT = "minecraft:"

local function shortName(name)
	if name:sub(1, #MINECRAFT) == MINECRAFT then return name:sub(#MINECRAFT + 1) end
	return name
end

local function copyList(list)
	local out = {}
	for i, v in ipairs(list or {}) do out[i] = v end
	return out
end

--- Carburant que demandera le chantier, en mouvements : une cellule par
--- mouvement, plus un aller-retour par couche et la marge. Approché, et
--- annoncé comme tel.
local function fuelEstimate(v)
	local job = ccPlan.new({ width = v.width, depth = v.depth, height = v.height })
	return ccPlan.total(job) + ccPlan.layers(job) * (v.width + v.depth) + v.height + v.fuelMargin
end

local SLOT_OPTIONS = {}
for slot = 1, 16 do SLOT_OPTIONS[slot] = { slot, tostring(slot) } end

--- Décrit le menu de démarrage de ccQuarry.
-- L'inventaire est lu à l'ouverture puis à chaque turtle_inventory, et non à
-- chaque image : un appel turtle par slot et par touche pressée serait du
-- gaspillage.
local function menuSpec()
	local last = CONFIG.lastJob or DEFAULTS.lastJob
	local values = {
		width = last.width or 16, depth = last.depth or 16, height = last.height or 32,
		down = last.down ~= false, left = last.left == true,
		chest = CONFIG.chest, chestSlot = CONFIG.chestSlot, fuelSlot = CONFIG.fuelSlot,
		dropWhenNoChest = CONFIG.dropWhenNoChest,
		keepFuel = CONFIG.keepFuel, fuelMargin = CONFIG.fuelMargin, fuelTopUp = CONFIG.fuelTopUp,
		trashWhere = CONFIG.trashWhere, trash = copyList(CONFIG.trash),
		remember = true,
	}

	local inv = {}
	local function refresh()
		for slot = 1, 16 do inv[slot] = ccInv.detail(slot) end
	end
	refresh()

	local function inInventory(name)
		for slot = 1, 16 do
			if inv[slot] and inv[slot].name == name then return true end
		end
		return false
	end

	--- Coffre portable retenu : celui du slot désigné s'il est reconnu (ou
	--- imposé en mode portable), sinon le premier reconnu.
	local function chestOf(v)
		local d = inv[v.chestSlot]
		if d and (ccInv.isChest(d.name) or v.chest == "portable") then return v.chestSlot, d end
		for slot = 1, 16 do
			if inv[slot] and ccInv.isChest(inv[slot].name) then return slot, inv[slot] end
		end
		return nil
	end

	local function trashItems(v)
		local names = {}
		local fuel = inv[v.fuelSlot]
		for slot = 1, 16 do
			local d = inv[slot]
			if d and not ccInv.isChest(d.name) and slot ~= v.chestSlot
				and not (fuel and d.name == fuel.name) then
				names[#names + 1] = d.name
			end
		end
		for _, name in ipairs(DEFAULTS.trash) do names[#names + 1] = name end
		return names
	end

	local whereNames = { up = "le haut", down = "le bas", forward = "devant" }

	local views = {
		{ title = "Chantier",
			fields = {
				{ kind = "number", key = "width", label = "Largeur", min = 1, max = 256,
					hint = "Devant la turtle" },
				{ kind = "number", key = "depth", label = "Profondeur", min = 1, max = 256,
					hint = "Sur le cote choisi" },
				{ kind = "number", key = "height", label = "Hauteur", min = 1, max = 384,
					hint = "Blocs a creuser" },
				{ kind = "choice", key = "down", label = "Sens", options = {
					{ true, "Bas", "Creuse sous la turtle" },
					{ false, "Haut", "Creuse au-dessus" } } },
				{ kind = "choice", key = "left", label = "Cote", options = {
					{ false, "Droite", "Chantier a droite de la turtle" },
					{ true, "Gauche", "Chantier a gauche de la turtle" } } },
			},
			after = function(v)
				local job = ccPlan.new({ width = v.width, depth = v.depth, height = v.height })
				return {
					("%d blocs, %d couches"):format(ccPlan.blocks(job), ccPlan.layers(job)),
					"Carburant estime ~" .. fuelEstimate(v),
				}
			end,
		},
		{ title = "Depot",
			fields = {
				{ kind = "choice", key = "chest", label = "Coffre", options = {
					{ "auto", "Auto", "Portable si present, sinon fixe" },
					{ "portable", "Portable", "Pose et reprend le coffre" },
					{ "fixed", "Fixe", "Coffre contre l'origine" },
					{ "none", "Aucun", "Pas de depot" } } },
				{ kind = "choice", key = "chestSlot", label = "Slot coffre", options = SLOT_OPTIONS,
					hint = "Ou ranger le coffre portable" },
				{ kind = "choice", key = "dropWhenNoChest", label = "Sans coffre", options = {
					{ false, "Attendre", "Attend qu'on vienne vider" },
					{ true, "Jeter", "Depose au sol, perte assumee" } } },
			},
			after = function(v)
				if v.chest == "none" then return { "Le butin reste a bord" } end
				local lines = {}
				if v.chest ~= "fixed" then
					local slot, d = chestOf(v)
					if not slot then
						lines[#lines + 1] = { "Aucun coffre portable", v.chest == "portable" and colors.red or colors.orange }
					elseif ccInv.isChest(d.name) then
						lines[#lines + 1] = { ("Slot %d : %s"):format(slot, shortName(d.name)), colors.lime }
					else
						lines[#lines + 1] = { ("Slot %d : %s"):format(slot, shortName(d.name)), colors.orange }
						lines[#lines + 1] = { "Doit garder son contenu !", colors.orange }
					end
				end
				if v.chest ~= "portable" then
					lines[#lines + 1] = "Fixe : derriere, dessus ou a "
						.. (v.left and "droite" or "gauche")
				end
				return lines
			end,
		},
		{ title = "Carbu",
			fields = {
				{ kind = "choice", key = "fuelSlot", label = "Slot fuel", options = SLOT_OPTIONS,
					hint = "Ou ranger le carburant" },
				{ kind = "number", key = "keepFuel", label = "Garder", min = 0, max = 1024, step = 16,
					hint = "Combustible garde au vidage" },
				{ kind = "number", key = "fuelMargin", label = "Marge", min = 0, max = 10000, step = 16,
					hint = "En plus du trajet de retour" },
				{ kind = "number", key = "fuelTopUp", label = "Recharge", min = 0, max = 100000, step = 500,
					hint = "Niveau vise au coffre" },
			},
			after = function(v)
				local d = inv[v.fuelSlot]
				local level = ccFuel.isUnlimited() and "illimite"
					or (ccFuel.level() .. " / " .. ccFuel.limit())
				return {
					d and ("Slot %d : %s x%d"):format(v.fuelSlot, shortName(d.name), d.count)
						or { ("Slot %d vide"):format(v.fuelSlot), colors.orange },
					"Niveau " .. level,
				}
			end,
		},
		{ title = "Rebut",
			header = function(v)
				return ("Coche = jete, %d jetes"):format(#v.trash)
			end,
			fields = {
				{ kind = "choice", key = "trashWhere", label = "Jeter vers", options = {
					{ "up", "Haut", "Dans la couche deja creusee" },
					{ "down", "Bas", "Sous la turtle" },
					{ "forward", "Devant", "Devant la turtle" } } },
				{ kind = "set", key = "trash", items = trashItems, display = shortName,
					tag = function(name) return inInventory(name) and "inv" or nil end,
					hint = function(_, name) return name end,
					add = "+ Saisir un nom", prefix = MINECRAFT },
			},
		},
		{ title = "Lancer",
			before = function(v)
				local lines = {
					("%dx%dx%d vers le %s, a %s"):format(v.width, v.depth, v.height,
						v.down and "bas" or "haut", v.left and "gauche" or "droite"),
				}
				local need = fuelEstimate(v)
				if ccFuel.isUnlimited() then
					lines[#lines + 1] = "Carburant illimite"
				elseif ccFuel.level() >= need then
					lines[#lines + 1] = { "Carburant suffisant (~" .. need .. ")", colors.lime }
				else
					lines[#lines + 1] = { ("Carburant ~%d, niveau %d"):format(need, ccFuel.level()), colors.orange }
				end
				local depot = ({ auto = "auto", portable = "portable", fixed = "fixe", none = "aucun" })[v.chest]
				lines[#lines + 1] = "Depot : " .. depot
				lines[#lines + 1] = ("Rebut : %d, vers %s"):format(#v.trash, whereNames[v.trashWhere] or v.trashWhere)
				return lines
			end,
			fields = {
				{ kind = "check", key = "remember", label = "Memoriser les options",
					hint = "Ecrites dans " .. CONFIG_PATH },
				{ kind = "button", label = "Lancer le chantier", action = "submit",
					hint = "Entree pour demarrer" },
			},
		},
	}

	return {
		values = values,
		views = views,
		refresh = refresh,
		validate = function(v)
			if v.chest ~= "fixed" and v.chest ~= "none" and v.chestSlot == v.fuelSlot then
				return "Coffre et carburant sur le meme slot"
			end
			return nil
		end,
	}, chestOf
end

--- Affiche le menu et en tire le chantier et ses options.
-- @return job, options  ou nil si l'utilisateur a abandonné
local function startMenu()
	local spec, chestOf = menuSpec()
	local v = ccMenu.new(spec):run()
	if not v then return nil end

	local options = {}
	for _, key in ipairs(JOB_OPTIONS) do
		if v[key] ~= nil then options[key] = v[key] end
	end

	-- Un conteneur non reconnu, désigné par son slot en mode portable, est
	-- accepté sous son nom exact : il sera reconnu où qu'il soit rangé.
	options.chestItem = ""
	if v.chest == "portable" then
		local slot, d = chestOf(v)
		if slot and not ccInv.isChest(d.name) then options.chestItem = d.name end
	end

	if v.remember then
		local changes = { lastJob = { width = v.width, depth = v.depth, height = v.height,
			down = v.down, left = v.left } }
		for k, val in pairs(options) do changes[k] = val end
		local ok, err = ccConfig.set(CONFIG_PATH, changes)
		if not ok then print("Options non memorisees : " .. tostring(err)) end
	end

	local job = ccPlan.new({ width = v.width, depth = v.depth, height = v.height,
		down = v.down, left = v.left })
	return job, options
end

--- Applique au chantier ses propres options, par-dessus le fichier.
local function applyOptions(options)
	for k, v in pairs(options or {}) do CONFIG[k] = v end
end

--- Transmet à ccInv ce qui dépend des options : rebut, emplacements, et
--- coffre désigné à la main.
local function configureInventory()
	local names = copyList(ccInv.config().chestNames)
	if CONFIG.chestItem ~= "" then names[#names + 1] = CONFIG.chestItem end
	ccInv.configure({
		trash = CONFIG.trash,
		chestSlot = CONFIG.chestSlot,
		fuelSlot = CONFIG.fuelSlot,
		chestNames = names,
	})
end

--- Construit le chantier à partir des arguments, ou le reprend.
-- @return true si un chantier est prêt
local function setup(args)
	store = ccSave.store(SAVE_PATH, { version = SAVE_VERSION, migrations = MIGRATIONS })

	if args[1] == "del" then
		store.delete()
		removeStartup()
		print("Chantier abandonne.")
		return false
	end

	if args[1] == "config" then
		local _, warnings, created = ccConfig.load(CONFIG_PATH, DEFAULTS, CONFIG_TEMPLATE)
		print(created and ("Options creees : " .. CONFIG_PATH)
			or ("Options existantes : " .. CONFIG_PATH))
		for _, w in ipairs(warnings) do print("  " .. w) end
		print("Modifier avec : edit " .. CONFIG_PATH)
		return false
	end

	-- Reprise, ou menu quand il n'y a rien à reprendre
	if #args == 0 then
		local saved, err = store.read()
		if not saved then
			if err ~= "absent" then
				-- Une sauvegarde illisible n'est pas écrasée par un nouveau
				-- chantier sans que l'utilisateur l'ait demandé.
				print("Sauvegarde illisible : " .. tostring(err))
				usage()
				return false
			end
			local job, options = startMenu()
			if not job then
				print("Menu abandonne.")
				usage()
				return false
			end
			ctx.job, ctx.options, ctx.index = job, options, 1
			applyOptions(options)
			installStartup()
			return true
		end

		ctx.job = ccPlan.new(saved.job)
		ctx.origin = saved.origin
		ctx.skips = saved.skips or 0
		ctx.options = saved.options
		applyOptions(saved.options)

		if saved.legacy then
			-- L'ancien format ne stockait pas de curseur : on le retrouve à
			-- partir de la position, ou on repart du début de la couche.
			ccNav.setPosition(saved.pos)
			ctx.index = ccPlan.indexOf(ctx.job, saved.pos) or 1
			print("Sauvegarde de l'ancien format reprise, cellule " .. ctx.index)
		else
			ccNav.setPosition(saved.pos)
			ctx.index = saved.index
			ctx.reason = saved.reason
		end
		return true
	end

	-- Nouveau chantier
	local nums = {}
	for i = 1, #args do
		nums[i] = tonumber(args[i])
		if not nums[i] then
			print("Argument invalide : " .. tostring(args[i]))
			usage()
			return false
		end
	end

	local w, d, h
	if #args == 1 then
		w, d, h = math.abs(nums[1]), math.abs(nums[1]), nums[1]
	elseif #args == 3 then
		w, d, h = nums[1], nums[2], nums[3]
	else
		usage()
		return false
	end

	if w <= 0 or d <= 0 or h == 0 then
		print("Les dimensions doivent etre non nulles.")
		usage()
		return false
	end

	ctx.job = ccPlan.new({ width = w, depth = d, height = math.abs(h), down = h > 0 })
	ctx.index = 1
	installStartup()
	return true
end

-- ---------------------------------------------------------------------------
-- Boucle principale
-- ---------------------------------------------------------------------------

local function machine()
	while not ctx.stopped do
		applyCommands()

		-- Les états terminaux se testent AVANT de chercher leur fonction :
		-- ils n'en ont pas. Dans l'autre ordre, atteindre TERMINE produisait
		-- « Etat inconnu : TERMINE » et transformait un chantier réussi en
		-- échec.
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
			-- Un état qui ne renvoie rien laisserait ctx.state à nil, et le
			-- tour suivant échouerait sur « Etat inconnu : nil », sans dire
			-- lequel des neuf états est fautif.
			ctx.error = "l'etat " .. before .. " n'a renvoye aucun etat suivant"
			journal(ctx.error)
			ctx.state = S.FAILED
		else
			ctx.state = result
		end

		-- Pas de sauvegarde en état terminal : FINITION vient justement de
		-- supprimer le fichier, la réécrire le ressusciterait.
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
-- précéder setup(), qui la restaure depuis la sauvegarde.
-- Les options sont lues AVANT tout le reste : elles décident du rebut, donc de
-- ce que la turtle garde dès le premier bloc miné.
local configWarnings, configCreated
CONFIG, configWarnings, configCreated = ccConfig.load(CONFIG_PATH, DEFAULTS, CONFIG_TEMPLATE)

ccNav.reset()
ccInv.reset({
	trash = CONFIG.trash,
	depotMinSlots = CONFIG.depotMinSlots,
	depotPatterns = CONFIG.depotPatterns,
	chestPatterns = CONFIG.chestPatterns,
})
if not setup(args) then return end
-- Après setup : le menu ou la sauvegarde ont pu changer les options.
configureInventory()

-- Sauvegarde à CHAQUE changement d'état suivi -- déplacement ET rotation --
-- et pas seulement aux transitions de la machine.
--
-- Sans cela, la reprise repart d'un point faux et tout le chantier se décale.
-- Le cas de la rotation est le plus vicieux : en quittant la partie, le jeu
-- n'accorde qu'un tick à la turtle pour finir son itération. Si elle vient de
-- pivoter sans que ce soit enregistré, elle rouvre la partie avec un cap
-- erroné, et rien dans son état ne permet de s'en apercevoir.
--
-- Avec un GPS le recalage corrigerait la position, mais pas le cap sans un
-- déplacement d'essai -- et on ne peut de toute façon pas compter sur le GPS.
ccNav.configure({ onChange = function() save() end })

setupUi()
setupNet()
ctx.drawTimer = os.startTimer(0.5)

-- Diagnostic de départ : le coffre non reconnu est le piège le plus probable,
-- puisque son identifiant dépend du mod installé.
if configCreated then journal("Options creees : " .. CONFIG_PATH) end
for _, w in ipairs(configWarnings) do journal("Options : " .. w) end
journal(("Rebut : %d entrees, sans coffre : %s")
	:format(#CONFIG.trash, CONFIG.dropWhenNoChest and "jeter" or "attendre"))
journal(("Chantier %dx%dx%d, %s, a %s, depot %s"):format(ctx.job.width, ctx.job.depth,
	ctx.job.height, ctx.job.down and "bas" or "haut", ctx.job.left and "gauche" or "droite", CONFIG.chest))

local chestSlot = ccInv.findChest()
if CONFIG.chest == "fixed" or CONFIG.chest == "none" then
	journal("Coffre portable ignore (mode " .. CONFIG.chest .. ")")
elseif chestSlot then
	journal("Coffre reconnu slot " .. chestSlot .. " : " .. ccInv.detail(chestSlot).name)
else
	journal("AUCUN coffre reconnu -- la turtle attendra un vidage manuel")
end
-- Trace systématique : sans elle, un coffre non reconnu ne laisse aucune
-- indication de l'identifiant qu'il aurait fallu accepter.
journalInventory()

save()

parallel.waitForAny(machine, events)

ccUi.clear()
if ctx.interrupted then
	save()
	journal("Interrompu par Ctrl+T")
	print("Interrompu. Le chantier est sauvegarde.")
	print("")
	print("  edit " .. CONFIG_PATH .. "   modifier les options")
	print("  ccQuarry            reprendre")
	print("  ccQuarry del        abandonner")

elseif ctx.state == S.DONE then
	print("Carriere terminee.")
	if ctx.skips > 0 then print(ctx.skips .. " cellules inatteignables.") end
else
	-- Le message d'erreur est réaffiché APRÈS le nettoyage de l'écran : sinon
	-- il disparaît exactement au moment où il sert.
	print("Arret en etat " .. ctx.state .. ".")
	if ctx.error then print(ctx.error) end
	print("Journal complet : edit " .. LOG_PATH)
end
