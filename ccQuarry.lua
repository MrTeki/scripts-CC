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
-- direction de la largeur. Le coffre se pose sous l'origine.
--
-- Slots réservés : 1 = carburant, 16 = coffre. Le jeu ne les protège pas :
-- il faut donc du carburant en slot 1 AU DÉPART, sinon le butin s'y installe.
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
	ccUtil = 1, ccVec = 1, ccPlan = 1, ccNav = 1, ccInv = 1,
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

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

local SAVE_PATH = "ccquarry.save"
local SAVE_VERSION = 1

local CONFIG = {
	fuelMargin = 64,        -- carburant gardé en plus du trajet de retour
	fuelTopUp = 2000,       -- visé lors d'un ravitaillement
	trashWhere = "up",      -- le rebut part dans la couche déjà creusée
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

-- États. Le nom de l'état EST l'état : les drapeaux done / needFuel /
-- needClearInventory de l'ancienne version, et les 64 combinaisons théoriques
-- qu'ils décrivaient, disparaissent.
local S = {
	CALIBRATE   = "CALIBRAGE",
	GO_TO_WORK  = "TRAJET",
	MINING      = "MINAGE",
	RETURN_HOME = "RETOUR",
	SERVICE     = "SERVICE",
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
	local e = { os.pullEvent() }
	local name = e[1]

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
				ccUi.log("Reprise")
			else
				ctx.resumeTo = ctx.state
				ctx.state = S.PAUSED
				ccUi.log("En pause")
			end

		elseif cmd == "refuel" then
			-- On ne ravitaille pas ici : on demande un retour au coffre.
			ctx.reason = "fuel"
			ctx.state = S.RETURN_HOME
			ccUi.log("Ravitaillement demande")

		elseif cmd == "abort" or cmd == "home" then
			ctx.reason = "abort"
			ctx.state = S.RETURN_HOME
			ccUi.log("Arret demande")
		end
	end
end

-- ---------------------------------------------------------------------------
-- États
-- ---------------------------------------------------------------------------

local function needsService()
	-- Un seul slot libre restant : le prochain bloc miné tomberait par terre.
	if ccInv.freeCount() <= 1 then return "inventory" end
	if ccFuel.level() <= ccFuel.reserve(ccNav.position(), nil, CONFIG.fuelMargin) then
		return "fuel"
	end
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
		ccUi.log("Recale par GPS")
	else
		ccUi.log("Pas de GPS, suivi a l'estime")
	end
	return S.GO_TO_WORK
end

STATES[S.GO_TO_WORK] = function()
	ccNav.setGuard(ccFuel.guard(ccNav.position, nil, CONFIG.fuelMargin))

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
		ctx.reason = "fuel"
		return S.RETURN_HOME
	end

	-- Cellule inatteignable : on la saute au lieu de terminer le chantier.
	-- L'ancienne version mettait done = true sur un unique mouvement raté.
	ctx.skips = ctx.skips + 1
	ctx.streak = ctx.streak + 1
	ccUi.log("Inatteignable : " .. tostring(block or reason))

	if ctx.streak >= ccPlan.perLayer(ctx.job) then
		-- Une couche entière inatteignable : c'est le fond.
		ccUi.log("Fond atteint")
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

	if cell.digUp then ccNav.dig("up") end
	if cell.digDown then ccNav.dig("down") end
	ccInv.dumpTrash(CONFIG.trashWhere)

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
		ccUi.log("Retour impossible : " .. tostring(reason))
		return S.FAILED
	end
	return ctx.reason == "done" and S.FINISHING or S.SERVICE
end

--- Pose le coffre sous la turtle, en dégageant la case si nécessaire.
local function placeChest()
	local ok, reason = ccInv.placeChest("down")
	if ok then return true end
	if reason == "no_chest" then return false, reason end

	ccNav.dig("down")
	return ccInv.placeChest("down")
end

STATES[S.SERVICE] = function()
	local withChest = placeChest()

	if withChest then
		local ok, reason = ccInv.unload("down", { trashWhere = CONFIG.trashWhere })
		if not ok then ccUi.log("Vidage : " .. tostring(reason)) end

		if ccFuel.level() < CONFIG.fuelTopUp then
			local fine, why = ccFuel.refuelFromChest("down", CONFIG.fuelTopUp)
			if not fine then ccUi.log("Carburant : " .. tostring(why)) end
		end
		ccInv.takeChest("down")
	else
		-- Sans coffre, on dépose devant soi et on attend du carburant à la main.
		ccInv.unload("forward", { trashWhere = CONFIG.trashWhere })
		ccFuel.refuelFromInventory(CONFIG.fuelTopUp)
	end

	if ctx.reason == "abort" then return S.FINISHING end

	-- Toujours à court après le service : on attend plutôt que de repartir
	-- pour tomber en panne au fond du trou.
	local besoin = ccFuel.reserve(ccPlan.cellAt(ctx.job, math.min(ctx.index, ccPlan.total(ctx.job))),
		nil, CONFIG.fuelMargin)
	if ccFuel.level() <= besoin then
		-- Attente réveillée aussi par un minuteur, pour que les commandes
		-- reçues entre-temps soient prises en compte.
		ccUi.log("En attente de carburant")
		local t = os.startTimer(5)
		repeat
			local e, id = os.pullEvent()
		until e == "turtle_inventory" or (e == "timer" and id == t)
		return S.SERVICE
	end

	ctx.reason = nil
	return S.GO_TO_WORK
end

STATES[S.PAUSED] = function()
	os.pullEvent()
	return S.PAUSED
end

STATES[S.FINISHING] = function()
	if ccInv.freeCount() < 14 then
		if placeChest() then
			ccInv.unload("down", { trashWhere = CONFIG.trashWhere })
			ccInv.takeChest("down")
		else
			ccInv.unload("forward", { trashWhere = CONFIG.trashWhere })
		end
	end
	store.delete()
	removeStartup()
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
	print("")
	print("Hauteur positive : on creuse vers le bas.")
	print("Slot 1 : carburant. Slot 16 : coffre.")
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

		local fn = STATES[ctx.state]
		if not fn then
			ccUi.log("Etat inconnu : " .. tostring(ctx.state))
			ctx.state = S.FAILED
		end

		if ctx.state == S.DONE or ctx.state == S.FAILED then
			ctx.stopped = true
			break
		end

		local before = ctx.state
		local ok, result = pcall(fn)
		if not ok then
			ccUi.log("Erreur : " .. tostring(result))
			ctx.state = S.FAILED
		else
			ctx.state = result
		end

		-- Pas de sauvegarde en état terminal : FINITION vient justement de
		-- supprimer le fichier, la réécrire le ressusciterait.
		if ctx.state ~= before and ctx.state ~= S.DONE and ctx.state ~= S.FAILED then
			ccUi.log(ctx.state)
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
ccNav.reset()
ccInv.reset({ trash = CONFIG.trash })
if not setup(args) then return end

setupUi()
setupNet()
ctx.drawTimer = os.startTimer(0.5)
save()

parallel.waitForAny(machine, events)

ccUi.clear()
if ctx.state == S.DONE then
	print("Carriere terminee.")
	if ctx.skips > 0 then print(ctx.skips .. " cellules inatteignables.") end
else
	print("Arret en etat " .. ctx.state .. ".")
end
