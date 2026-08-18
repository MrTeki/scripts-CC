-- ccInv : inventaire du turtle, coffres, et mise au rebut.
--
-- Remplace getItemList (ccStairs), getTurtleInventory (ccFarm), findEmptySlot
-- (ccChopper, ccStairs), findItemSlotInTurtleInventory et clearTurtleInventory
-- (ccChopper), SearchEnderChest et Unload (ccQuarry).
--
-- PRINCIPE : la protection d'un slot dépend de ce qu'il CONTIENT, jamais de
-- son numéro.
--
-- La première version réservait les slots 1 et 16 en permanence. Quatre
-- défauts, tous issus de cette seule confusion :
--
--   * Un slot réservé laissé vide se remplissait en minant -- le jeu ne
--     protège rien -- puis n'était jamais vidé, puisque le vidage sautait les
--     slots réservés. Un slot perdu pour toute la session.
--   * Pire : avec du cobble dans le slot 1, le vidage protégeait le cobble et
--     jetait le carburant, qui se trouvait ailleurs. Exactement l'inverse de
--     l'intention.
--   * Les slots réservés étaient exclus du décompte des places libres, même
--     vides et inutilisés.
--   * Rien ne remettait jamais les choses à leur place.
--
-- Désormais : fuelSlot et chestSlot ne sont que des emplacements CANONIQUES,
-- où tidy range les choses. Ce qui est protégé au vidage, c'est le slot qui
-- contient réellement le coffre, plus ceux que l'appelant désigne.
--
-- ccInv ne sait pas reconnaître un combustible -- cela demande turtle.refuel(0),
-- qui appartient à ccFuel, lequel dépend déjà de ccInv. L'appelant fournit
-- donc l'ensemble des slots à préserver.

local M = { _VERSION = 1 }

local SIZE = 16
local MAX_STACK = 64

local DEFAULTS = {
	-- Emplacements canoniques : là où tidy range le carburant et le coffre.
	-- Ce ne sont PAS des slots interdits au butin.
	fuelSlot = 1,
	chestSlot = 16,

	-- Noms exacts reconnus comme coffre transportable.
	chestNames = {
		"EnderStorage:enderChest",
		"enderstorage:ender_storage",
		"enderstorage:ender_chest",
		"minecraft:ender_chest",
	},

	-- Motifs de repli, cherchés dans l'identifiant en minuscules. Une liste de
	-- noms exacts ne peut pas suivre les identifiants de tous les mods.
	-- Ne concerne QUE le coffre transportable, celui que la turtle emporte,
	-- pose, vide et reprend. Seuls les conteneurs qui gardent leur contenu
	-- quand on les casse sont éligibles.
	chestPatterns = {
		"ender_chest", "enderchest", "ender_storage", "enderstorage", "shulker_box",
	},

	-- Conteneurs FIXES, posés dans le monde et jamais cassés par la turtle.
	-- N'importe quel inventaire fait l'affaire, puisqu'on ne fait qu'y déposer.
	depotPatterns = { "chest", "barrel", "shulker", "hopper", "drawer", "crate" },

	trash = {},
}

local config

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

function M.reset(o)
	config = {}
	for k, v in pairs(DEFAULTS) do config[k] = v end
	for k, v in pairs(o or {}) do config[k] = v end
end

function M.configure(o)
	for k, v in pairs(o or {}) do config[k] = v end
end

function M.config() return config end

-- ---------------------------------------------------------------------------
-- Lecture
-- ---------------------------------------------------------------------------

function M.list()
	local out = {}
	for slot = 1, SIZE do out[slot] = turtle.getItemDetail(slot) end
	return out
end

function M.count(slot) return turtle.getItemCount(slot) end
function M.detail(slot) return turtle.getItemDetail(slot) end

--- Premier slot vide, ou nil. Tous les slots sont éligibles : aucun n'est
--- interdit au butin.
function M.firstFree()
	for slot = 1, SIZE do
		if turtle.getItemCount(slot) == 0 then return slot end
	end
	return nil
end

--- Nombre de slots vides. Un emplacement canonique inutilisé compte comme
--- libre : le refuser reviendrait à gaspiller un slot pour rien.
function M.freeCount()
	local n = 0
	for slot = 1, SIZE do
		if turtle.getItemCount(slot) == 0 then n = n + 1 end
	end
	return n
end

function M.find(name)
	for slot = 1, SIZE do
		local d = turtle.getItemDetail(slot)
		if d and d.name == name then return slot end
	end
	return nil
end

function M.findAny(names)
	for slot = 1, SIZE do
		local d = turtle.getItemDetail(slot)
		if d then
			for _, name in ipairs(names) do
				if d.name == name then return slot, name end
			end
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Rangement
-- ---------------------------------------------------------------------------

--- Restitue la sélection d'entrée.
--
-- PROPRIÉTÉ des opérations d'inventaire de ce module : elles rendent la
-- sélection telle qu'elles l'ont trouvée. CC range le butin dans le slot
-- SÉLECTIONNÉ en priorité ; une opération qui laisse la sélection sur le
-- dernier slot qu'elle a vidé casse donc l'empilement dense du minage suivant,
-- y compris celui du trajet vers la cellule d'après.
--
-- getSelectedSlot est immédiat, select coûte un tick : on ne paie que si la
-- sélection a réellement bougé.
local function restoreSelection(entry)
	if turtle.getSelectedSlot() ~= entry then turtle.select(entry) end
end

--- Regroupe les piles partielles d'un même objet.
--
-- Le butin miné atterrit dans le slot SÉLECTIONNÉ, et chaque opération
-- (dépôt, ravitaillement, pose de coffre) déplace cette sélection. Sans
-- regroupement, on se retrouve avec plusieurs piles partielles du même bloc,
-- qui occupent des slots pour rien et déclenchent un vidage prématuré.
-- @return nombre de transferts effectués
function M.compact()
	local entry = turtle.getSelectedSlot()
	local moves = 0
	for target = 1, SIZE - 1 do
		local d = turtle.getItemDetail(target)
		if d and d.count < MAX_STACK then
			for source = target + 1, SIZE do
				local s = turtle.getItemDetail(source)
				if s and s.name == d.name then
					turtle.select(source)
					turtle.transferTo(target)
					moves = moves + 1
					d = turtle.getItemDetail(target)
					if not d or d.count >= MAX_STACK then break end
				end
			end
		end
	end
	restoreSelection(entry)
	return moves
end

--- Ramène la sélection sur le premier slot, avant de miner.
--
-- CC range le butin dans le slot SÉLECTIONNÉ en priorité, puis balaie à partir
-- du début. Repartir toujours du même slot bas garantit donc un empilement
-- dense. Sans cela, la sélection héritée de la dernière opération éparpille
-- des piles partielles du même bloc un peu partout.
--
-- getSelectedSlot est immédiat, select coûte un tick : on ne le paie que si la
-- sélection a réellement bougé.
function M.selectForMining(slot)
	slot = slot or 1
	if turtle.getSelectedSlot() ~= slot then turtle.select(slot) end
	return slot
end

--- Déplace le contenu de `from` vers `to`, en libérant `to` si nécessaire.
-- @return true, ou false + raison
function M.moveToSlot(from, to)
	if from == to then return true end
	if turtle.getItemCount(from) == 0 then return true end
	local entry = turtle.getSelectedSlot()

	local dest = turtle.getItemDetail(to)
	if dest then
		local src = turtle.getItemDetail(from)
		if not (src and dest.name == src.name) then
			-- Occupé par autre chose : on l'évacue vers un slot libre.
			local spare = M.firstFree()
			if not spare then return false, "inventory_full" end
			turtle.select(to)
			turtle.transferTo(spare)
			if turtle.getItemCount(to) > 0 then
				restoreSelection(entry)
				return false, "transfer_failed"
			end
		end
	end

	turtle.select(from)
	turtle.transferTo(to)
	local moved = turtle.getItemCount(from) == 0
	restoreSelection(entry)
	return moved
end

--- Range le coffre et le carburant à leurs emplacements canoniques.
-- @param fuelSlot  slot contenant le carburant à préserver (fourni par ccFuel)
-- @return true
function M.tidy(fuelSlot)
	M.compact()

	local chest = M.findChest()
	if chest then M.moveToSlot(chest, config.chestSlot) end

	-- Relu APRÈS le déplacement du coffre, qui a pu tout décaler.
	if fuelSlot and turtle.getItemCount(fuelSlot) > 0 then
		M.moveToSlot(fuelSlot, config.fuelSlot)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Coffres
-- ---------------------------------------------------------------------------

function M.isChest(name)
	if not name then return false end
	for _, exact in ipairs(config.chestNames) do
		if name == exact then return true end
	end
	local lowered = name:lower()
	for _, pattern in ipairs(config.chestPatterns or {}) do
		if lowered:find(pattern, 1, true) then return true end
	end
	return false
end

--- Slot contenant le coffre transportable, ou nil.
function M.findChest()
	for slot = 1, SIZE do
		local d = turtle.getItemDetail(slot)
		if d and M.isChest(d.name) then return slot end
	end
	return nil
end

local PLACES   = { forward = "place",   up = "placeUp",   down = "placeDown" }
local DIGS     = { forward = "dig",     up = "digUp",     down = "digDown" }
local SUCKS    = { forward = "suck",    up = "suckUp",    down = "suckDown" }
local DROPS    = { forward = "drop",    up = "dropUp",    down = "dropDown" }
local INSPECTS = { forward = "inspect", up = "inspectUp", down = "inspectDown" }

function M.isDepot(name)
	if not name then return false end
	local lowered = name:lower()
	for _, pattern in ipairs(config.depotPatterns or {}) do
		if lowered:find(pattern, 1, true) then return true end
	end
	return false
end

--- Y a-t-il un conteneur fixe dans cette direction ?
-- On INSPECTE au lieu de tenter un dépôt : turtle.drop() réussit aussi quand
-- il n'y a rien en face, en faisant simplement tomber l'objet au sol. Sans
-- cette vérification, « déposer dans le coffre » et « perdre son butin » sont
-- indiscernables.
function M.depotAt(where)
	local seen, info = turtle[INSPECTS[where or "forward"]]()
	if not seen or not info then return false end
	return M.isDepot(info.name), info.name
end

--- Pose le coffre, en vérifiant que la pose a réussi.
function M.placeChest(where)
	local slot = M.findChest()
	if not slot then return false, "no_chest" end

	turtle.select(slot)
	if not turtle[PLACES[where or "down"]]() then
		return false, "place_failed"
	end
	return true
end

--- Reprend le coffre posé et le range à son emplacement canonique.
function M.takeChest(where)
	local free = M.firstFree()
	if not free then return false, "inventory_full" end

	turtle.select(free)
	if not turtle[DIGS[where or "down"]]() then
		return false, "dig_failed"
	end

	local chest = M.findChest()
	if chest then M.moveToSlot(chest, config.chestSlot) end
	return true
end

--- Dépose le contenu d'un slot dans le conteneur visé.
-- Échecs bornés : un coffre plein renvoie "container_full" au lieu de boucler.
function M.dropTo(where, slot, tries)
	local fn = DROPS[where or "down"]
	turtle.select(slot)

	for _ = 1, (tries or 4) do
		if turtle.getItemCount(slot) == 0 then return true end
		if not turtle[fn]() then return false, "container_full" end
	end

	if turtle.getItemCount(slot) > 0 then return false, "container_full" end
	return true
end

function M.suckFrom(where, slot, count)
	turtle.select(slot)
	if not turtle[SUCKS[where or "down"]](count) then
		return false, "empty"
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Rebut et vidage
-- ---------------------------------------------------------------------------

function M.isTrash(name)
	if not name then return false end
	for _, t in ipairs(config.trash) do
		if t == name then return true end
	end
	return false
end

--- Slots à ne jamais vider : celui du coffre, plus ceux que l'appelant
--- désigne. Rien n'est protégé pour son seul numéro.
local function protectedSet(protect)
	local set = {}
	for slot in pairs(protect or {}) do set[slot] = true end
	local chest = M.findChest()
	if chest then set[chest] = true end
	return set
end

--- Nombre de slots contenant du BUTIN : ni le coffre, ni les slots protégés.
--
-- Remplace les seuils fondés sur le nombre de slots libres, qui dépendaient du
-- nombre de slots réservés et devenaient faux dès qu'on y touchait. « Reste-t-il
-- quelque chose à déposer ? » est la vraie question, et elle ne dépend d'aucun
-- décompte magique.
function M.lootCount(protect)
	local keep = protectedSet(protect)
	local n = 0
	for slot = 1, SIZE do
		if not keep[slot] and turtle.getItemCount(slot) > 0 then n = n + 1 end
	end
	return n
end

--- Jette le rebut par-dessus bord.
-- @param where  "forward" (défaut), "up" ou "down"
-- @param opts   { protect = { [slot] = true } }
-- @return nombre de slots vidés
function M.dumpTrash(where, opts)
	local fn = DROPS[where or "forward"]
	local keep = protectedSet(opts and opts.protect)
	local entry = turtle.getSelectedSlot()
	local emptied = 0

	for slot = 1, SIZE do
		if not keep[slot] then
			local d = turtle.getItemDetail(slot)
			if d and M.isTrash(d.name) then
				turtle.select(slot)
				if turtle[fn]() then emptied = emptied + 1 end
			end
		end
	end

	restoreSelection(entry)
	return emptied
end

--- Vide l'inventaire dans le conteneur visé.
-- Le rebut est jeté plutôt que déposé. Sont épargnés : le coffre, les slots
-- de `protect`, et tout nom listé dans `keep`.
-- @param opts { protect = { [slot] = true }, keep = { noms }, trashWhere = ... }
-- @return true, ou false + raison + slot fautif
function M.unload(where, opts)
	opts = opts or {}
	local protectedSlots = protectedSet(opts.protect)
	local entry = turtle.getSelectedSlot()

	local keepNames = {}
	for _, name in ipairs(opts.keep or {}) do keepNames[name] = true end

	for slot = 1, SIZE do
		if not protectedSlots[slot] then
			local d = turtle.getItemDetail(slot)
			if d and not keepNames[d.name] then
				if M.isTrash(d.name) then
					turtle.select(slot)
					turtle[DROPS[opts.trashWhere or "forward"]]()
				else
					local ok, reason = M.dropTo(where, slot)
					if not ok then
						restoreSelection(entry)
						return false, reason, slot
					end
				end
			end
		end
	end

	restoreSelection(entry)
	return true
end

M.reset()

return M
