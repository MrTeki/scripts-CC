-- ccQuarry par Teki
--
-- Creuse une carrière rectangulaire, avec reprise après reboot.
--
--   ccQuarry <largeur> <profondeur> <hauteur>   nouveau chantier
--   ccQuarry <taille>                           chantier cubique
--   ccQuarry                                    reprend le chantier en cours
--   ccQuarry del                                abandonne le chantier en cours
--
-- Hauteur positive : on creuse vers le BAS. Négative : vers le haut.
--
-- Conventions (voir README) : X / Y horizontaux, Z vertical, direction 0 = +X.
-- L'origine est la position de départ de la turtle, qui doit regarder dans la
-- direction de la largeur.
--
-- Trois façons de récupérer le butin, essayées dans cet ordre :
--   1. un coffre TRANSPORTABLE en inventaire (ender chest, shulker) : la
--      turtle le pose sous elle, le vide et le reprend ;
--   2. un conteneur FIXE contre l'origine. C'est le mode historique, avec un
--      coffre posé derrière la turtle. Le placer DERRIÈRE, À GAUCHE ou
--      AU-DESSUS : la carrière s'étend vers l'avant et vers la droite, donc un
--      coffre posé de ces côtés-là serait miné avec le reste ;
--   3. aucun des deux : la turtle attend qu'on vienne la vider.
-- Le conteneur fixe sert aussi de source de carburant.
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

-- Pointe sur la branche de refonte le temps des essais. À rebasculer sur
-- .../scripts-CC/main/ une fois refonte/apis-socle fusionnée.
-- (GitHub raw résout bien un nom de branche contenant un /.)
local REPO = "https://raw.githubusercontent.com/MrTeki/scripts-CC/refonte/apis-socle/"

local NEEDS = {
	ccUtil = 1, ccVec = 1, ccPlan = 1, ccNav = 1, ccInv = 1, ccConfig = 1,
	ccFuel = 1, ccSave = 1, ccUi = 1, ccNet = 1,
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

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local SAVE_PATH = "ccquarry.save"
local SAVE_VERSION = 1
local LOG_PATH = "ccquarry.log"

local CONFIG_PATH = "ccquarry.cfg"

-- Valeurs par défaut. Le fichier ccquarry.cfg les remplace au cas par cas, et
-- leur TYPE sert à valider ce qui y est saisi.
local DEFAULTS = {
	fuelMargin = 64,          -- carburant gardé en plus du trajet de retour
	fuelTopUp = 2000,         -- visé lors d'un ravitaillement
	trashWhere = "up",        -- le rebut part dans la couche déjà creusée
	dropWhenNoChest = false,  -- sans coffre : attendre, plutôt que jeter
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

	local handle = fs.open(LOG_PATH, "a")
	if not handle then return end
	handle.write(("[%.1f] %s | %s\n"):format(os.clock(), ctx.state or "?", msg))
	handle.close()
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
	ccUi.addButton({ label = "STOP", y = 3, cmd = "abort", key = "x" })
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
		return S.MINING
	end

	if reason == "no_fuel" or reason == "denied" then
		-- La garde refuse le mouvement AVANT que MINAGE ne puisse tester quoi
		-- que ce soit : c'est donc ici, et pas seulement dans needsService,
		-- qu'il faut envisager de brûler ce qu'on transporte.
		if refuelOnSite() then return S.GO_TO_WORK end
		ctx.reason = "fuel"
		return S.RETURN_HOME
	end

	-- Cellule inatteignable : on la saute au lieu de terminer le chantier.
	-- L'ancienne version mettait done = true sur un unique mouvement raté.
	ctx.skips = ctx.skips + 1
	ctx.streak = ctx.streak + 1
	journal("Inatteignable : " .. tostring(block or reason))

	if ctx.streak >= ccPlan.perLayer(ctx.job) then
		-- Une couche entière inatteignable : c'est le fond.
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

local function serviceUnload(refuel)
	-- Rangement AVANT le vidage : le coffre et le carburant retrouvent leurs
	-- emplacements, et les piles partielles sont regroupées. Sans cela, du
	-- butin ayant squatté l'emplacement du carburant s'y installait pour de
	-- bon, puisque l'ancienne version protégeait le slot 1 quel qu'en soit le
	-- contenu -- au point de jeter le vrai carburant, qui était ailleurs.
	tidyInventory()

	if placeChest() then
		local ok, reason, slot = ccInv.unload("down", { trashWhere = trashAwayFrom("down"), protect = protectedSlots() })
		if not ok then
			journal("Vidage : " .. tostring(reason) .. " (slot " .. tostring(slot) .. ")")
		end

		if refuel and ccFuel.level() < CONFIG.fuelTopUp then
			-- Le moins cher d abord : ce qu on transporte deja.
			ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
			local fine, why = ccFuel.refuelFromChest("down", CONFIG.fuelTopUp)
			if not fine then journal("Carburant : " .. tostring(why)) end
		end

		local taken, why = ccInv.takeChest("down")
		if not taken then journal("Reprise du coffre : " .. tostring(why)) end
		tidyInventory()     -- le ravitaillement a pu disperser le combustible
		return "chest"
	end

	local where = findDepot()
	if where then
		local ok, reason, slot = ccInv.unload(where, { trashWhere = trashAwayFrom(where), protect = protectedSlots() })
		if not ok then
			journal("Vidage : " .. tostring(reason) .. " (slot " .. tostring(slot) .. ")")
		end

		-- Le conteneur fixe sert aussi de source de carburant : c'est là qu'on
		-- vient déposer du charbon pour la turtle.
		if refuel and ccFuel.level() < CONFIG.fuelTopUp then
			-- Le moins cher d abord : ce qu on transporte deja.
			ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
			local fine, why = ccFuel.refuelFromChest(where, CONFIG.fuelTopUp)
			if not fine then journal("Carburant : " .. tostring(why)) end
		end
		tidyInventory()
		return "depot"
	end

	return nil
end

STATES[S.SERVICE] = function()
	if not serviceUnload(true) then
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

	local cell = ccPlan.cellAt(ctx.job, math.min(ctx.index, ccPlan.total(ctx.job)))
	if ccFuel.level() <= ccFuel.reserve(cell, nil, CONFIG.fuelMargin) then
		journal("Carburant insuffisant : en fournir a la turtle")
		ctx.afterWait = S.SERVICE
		return S.AWAIT_HUMAN
	end

	ctx.reason = nil
	return S.GO_TO_WORK
end

--- Attend une intervention humaine. C'est le comportement par DÉFAUT sans
-- coffre reconnu : le butin d'une carrière ne doit pas partir au sol sans que
-- ce soit demandé. Le réveil se fait sur un changement d'inventaire, et sur un
-- minuteur pour que les commandes reçues entre-temps soient traitées.
STATES[S.AWAIT_HUMAN] = function()
	local timer = os.startTimer(5)
	repeat
		local event, id = waitEvent()
		if ctx.stopped then return S.AWAIT_HUMAN end
	until event == "turtle_inventory" or (event == "timer" and id == timer)

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
	print("ccQuarry <largeur> <profondeur> <hauteur>")
	print("ccQuarry <taille>      chantier cubique")
	print("ccQuarry               reprend le chantier en cours")
	print("ccQuarry del           abandonne le chantier en cours")
	print("ccQuarry config        cree ou affiche les options")
	print("ccQuarry update        met les APIs a jour")
	print("")
	print("Hauteur positive : on creuse vers le bas.")
	print("Slot 1 : carburant. Slot 16 : coffre.")
	print("Options : edit " .. CONFIG_PATH)
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

	-- Reprise
	if #args == 0 then
		local saved, err = store.read()
		if not saved then
			if err ~= "absent" then print("Sauvegarde illisible : " .. tostring(err)) end
			usage()
			return false
		end

		ctx.job = ccPlan.new(saved.job)
		ctx.origin = saved.origin
		ctx.skips = saved.skips or 0

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

local chestSlot = ccInv.findChest()
if chestSlot then
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
