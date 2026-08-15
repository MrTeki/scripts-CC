-- ccInv : inventaire du turtle, slots réservés, et interaction avec le coffre.
--
-- Remplace getItemList (ccStairs), getTurtleInventory (ccFarm), findEmptySlot
-- (ccChopper, ccStairs), findItemSlotInTurtleInventory et clearTurtleInventory
-- (ccChopper), SearchEnderChest et Unload (ccQuarry).
--
-- Quatre corrections par rapport à l'existant :
--
--   1. Slots réservés déclarés. ccQuarry décidait de vider sur des constantes
--      magiques : `items > 14` pour partir vider, `items > 2` pour considérer
--      le vidage terminé. Or le carburant et le coffre occupent deux slots :
--      à 14 slots pleins il n'en restait aucun de libre, et les blocs minés
--      tombaient par terre. Et `items > 2` restait vrai dès qu'un troisième
--      objet non déposable traînait, ce qui bouclait dans `while
--      needClearInventory do Unload() end`.
--
--   2. Pose du coffre VÉRIFIÉE. ccQuarry faisait `turtle.placeUp()` sans
--      regarder le retour, puis marquait le coffre comme posé. Si la pose
--      échouait, tout l'inventaire partait au sol.
--
--   3. Coffre introuvable remis à nil. SearchEnderChest ne réinitialisait
--      jamais son index : un coffre perdu laissait le script sélectionner un
--      slot arbitraire, poser du cobble et jeter le butin dessus.
--
--   4. Dépôt à échecs bornés. `while turtle.getItemCount(i) > 0 and not
--      turtle.dropUp() do end` bouclait sans fin sur un coffre plein.
--
-- La liste de rebut est la nouveauté : jeter cobble, terre et gravier à la
-- volée divise le nombre de trajets de vidage, et donc la fréquence des
-- ravitaillements dans un coffre encombré.

local M = { _VERSION = 1 }

local SIZE = 16
local MAX_STACK = 64

local DEFAULTS = {
	fuelSlot = 1,      -- jamais vidé
	chestSlot = 16,    -- jamais vidé

	-- Noms exacts reconnus comme coffre transportable.
	chestNames = {
		"EnderStorage:enderChest",
		"enderstorage:ender_storage",
		"enderstorage:ender_chest",
		"minecraft:ender_chest",
	},

	-- Motifs de repli, cherchés dans l'identifiant en minuscules. Une liste de
	-- noms exacts ne peut pas suivre les identifiants de tous les mods : c'est
	-- ce qui faisait qu'un ender chest non prévu n'était pas reconnu du tout.
	--
	-- Ne concerne QUE le coffre transportable, celui que la turtle emporte,
	-- pose, vide et reprend. Seuls les conteneurs qui gardent leur contenu
	-- quand on les casse sont éligibles : un coffre ordinaire éparpillerait
	-- tout à la reprise.
	chestPatterns = {
		"ender_chest",
		"enderchest",
		"ender_storage",
		"enderstorage",
		"shulker_box",
	},

	-- Conteneurs FIXES, posés dans le monde et jamais cassés par la turtle.
	-- N'importe quel inventaire fait l'affaire, puisqu'on ne fait qu'y déposer.
	depotPatterns = {
		"chest",
		"barrel",
		"shulker",
		"hopper",
		"drawer",
		"crate",
	},

	-- Rebut : jeté à la volée plutôt que rapporté. Vide par défaut, c'est à
	-- l'appelant d'assumer la perte.
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
-- Lecture de l'inventaire
-- ---------------------------------------------------------------------------

--- Contenu des 16 slots. Les slots vides valent nil.
function M.list()
	local out = {}
	for slot = 1, SIZE do out[slot] = turtle.getItemDetail(slot) end
	return out
end

function M.count(slot) return turtle.getItemCount(slot) end

function M.detail(slot) return turtle.getItemDetail(slot) end

function M.isReserved(slot)
	return slot == config.fuelSlot or slot == config.chestSlot
end

--- Premier slot libre.
-- @param includeReserved  si vrai, les slots réservés sont éligibles
function M.firstFree(includeReserved)
	for slot = 1, SIZE do
		if (includeReserved or not M.isReserved(slot)) and turtle.getItemCount(slot) == 0 then
			return slot
		end
	end
	return nil
end

--- Nombre de slots libres, hors slots réservés.
function M.freeCount()
	local n = 0
	for slot = 1, SIZE do
		if not M.isReserved(slot) and turtle.getItemCount(slot) == 0 then n = n + 1 end
	end
	return n
end

--- Nombre de slots réservés effectivement immobilisés.
function M.reservedCount()
	return config.fuelSlot == config.chestSlot and 1 or 2
end

--- Slot contenant `name`, ou nil.
function M.find(name)
	for slot = 1, SIZE do
		local d = turtle.getItemDetail(slot)
		if d and d.name == name then return slot end
	end
	return nil
end

--- Premier slot contenant l'un des noms donnés.
-- @return slot, nom  ou nil
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

--- Déplace le contenu de `from` vers `to`. Retourne true si tout a été déplacé.
function M.moveTo(from, to)
	if from == to then return true end
	local n = turtle.getItemCount(from)
	if n == 0 then return true end
	turtle.select(from)
	turtle.transferTo(to, n)
	return turtle.getItemCount(from) == 0
end

-- ---------------------------------------------------------------------------
-- Rebut
-- ---------------------------------------------------------------------------

function M.isTrash(name)
	if not name then return false end
	for _, t in ipairs(config.trash) do
		if t == name then return true end
	end
	return false
end

--- Jette tout le rebut par-dessus bord.
-- Les slots réservés sont épargnés, ainsi que le coffre s'il est en main.
-- @param where  "forward" (défaut), "up" ou "down"
-- @return nombre de slots vidés
local DROPS = { forward = "drop", up = "dropUp", down = "dropDown" }

function M.dumpTrash(where)
	local fn = DROPS[where or "forward"]
	local chest = M.findChest()
	local emptied = 0

	for slot = 1, SIZE do
		if not M.isReserved(slot) and slot ~= chest then
			local d = turtle.getItemDetail(slot)
			if d and M.isTrash(d.name) then
				turtle.select(slot)
				if turtle[fn]() then emptied = emptied + 1 end
			end
		end
	end
	return emptied
end

-- ---------------------------------------------------------------------------
-- Coffre
-- ---------------------------------------------------------------------------

--- Ce nom désigne-t-il un coffre transportable ?
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
-- Contrairement à SearchEnderChest, retourne bien nil quand il n'y en a pas,
-- au lieu de conserver un index périmé.
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
local INSPECTS = { forward = "inspect", up = "inspectUp", down = "inspectDown" }

--- Ce nom désigne-t-il un conteneur fixe, où l'on peut déposer ?
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
-- @return present, nom du bloc
function M.depotAt(where)
	local seen, info = turtle[INSPECTS[where or "forward"]]()
	if not seen or not info then return false end
	return M.isDepot(info.name), info.name
end

--- Pose le coffre, en vérifiant que la pose a réussi.
-- @return true, ou false + raison
function M.placeChest(where)
	local slot = M.findChest()
	if not slot then return false, "no_chest" end

	turtle.select(slot)
	if not turtle[PLACES[where or "down"]]() then
		return false, "place_failed"
	end
	return true
end

--- Reprend le coffre posé.
-- @return true, ou false + raison
function M.takeChest(where)
	local free = M.firstFree(true)
	if not free then return false, "inventory_full" end

	turtle.select(free)
	if not turtle[DIGS[where or "down"]]() then
		return false, "dig_failed"
	end
	-- Range le coffre dans son slot réservé s'il est libre.
	if free ~= config.chestSlot and turtle.getItemCount(config.chestSlot) == 0 then
		M.moveTo(free, config.chestSlot)
	end
	return true
end

--- Dépose le slot courant dans le conteneur visé.
-- Échecs bornés : un coffre plein renvoie "container_full" au lieu de boucler.
-- @return true, ou false + raison
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

--- Aspire depuis le conteneur visé vers le slot donné.
-- @return true, ou false + raison
function M.suckFrom(where, slot, count)
	turtle.select(slot)
	if not turtle[SUCKS[where or "down"]](count) then
		return false, "empty"
	end
	return true
end

--- Vide l'inventaire dans le conteneur visé.
-- Épargne les slots réservés, le coffre lui-même, et tout nom listé dans
-- `keep`. Le rebut est jeté au sol plutôt que déposé, s'il en reste.
-- @param opts  { keep = { noms }, trashWhere = "forward" }
-- @return true, ou false + raison + slot fautif
function M.unload(where, opts)
	opts = opts or {}
	local chest = M.findChest()

	local keep = {}
	for _, name in ipairs(opts.keep or {}) do keep[name] = true end

	for slot = 1, SIZE do
		if not M.isReserved(slot) and slot ~= chest then
			local d = turtle.getItemDetail(slot)
			if d and not keep[d.name] then
				if M.isTrash(d.name) then
					turtle.select(slot)
					turtle[DROPS[opts.trashWhere or "forward"]]()
				else
					local ok, reason = M.dropTo(where, slot)
					if not ok then return false, reason, slot end
				end
			end
		end
	end
	return true
end

M.reset()

return M
