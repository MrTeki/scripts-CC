-- ccFuel : niveau, budget de retour, et ravitaillement.
--
-- Remplace Refuel, CheckFuel et WaitForRefuel de ccQuarry, ainsi que refuel de
-- ccChopper et ccStairs.
--
-- Trois corrections :
--
--   1. "unlimited". turtle.getFuelLevel() renvoie cette CHAÎNE quand le serveur
--      désactive le carburant. ccQuarry la comparait directement à des nombres,
--      une dizaine de fois, et plantait donc au premier appel sur un tel
--      serveur. Ici le niveau est normalisé en math.huge, en un seul endroit.
--
--   2. Une seule formule de réserve. ccQuarry en avait trois, dupliquées huit
--      fois : (lastX+lastY+|lastZ|)*2, la même + targetX+targetY, et la même
--      + 1. Toutes fondées sur `last`, jamais sur la position courante.
--
--   3. Le ravitaillement au coffre unique. L'ancien code aspirait une pile,
--      échouait à la brûler, la RENDAIT aussitôt -- ce qui la remettait en
--      première position -- et la réaspirait. Boucle stérile, et le coffre
--      était en plus celui du butin.
--
-- Le correctif tient en une phrase : on RETIENT le rebut au lieu de le rendre
-- tout de suite. La turtle draine le début du coffre dans ses slots libres,
-- teste chaque pile, et ne restitue qu'à la fin, dans l'ordre d'aspiration,
-- si bien que le coffre retrouve son état initial.
--
-- Limite assumée : la turtle ne voit que les premières piles du coffre, autant
-- que de slots libres. C'est inhérent au coffre unique, `drop` remplissant
-- toujours par l'avant. Trois atténuations : le slot de carburant réservé
-- absorbe la variabilité (une pile de charbon vaut environ 5120), la liste de
-- rebut de ccInv réduit le volume déposé, et un ender chest drainé par un
-- système de tri garde l'avant libre.

local ccInv = require("ccInv")
local ccVec = require("ccVec")

local M = { _VERSION = 1 }

local ORIGIN = { x = 0, y = 0, z = 0 }

-- ---------------------------------------------------------------------------
-- Niveau
-- ---------------------------------------------------------------------------

--- Niveau de carburant, normalisé : math.huge quand il est illimité.
function M.level()
	local f = turtle.getFuelLevel()
	if f == "unlimited" then return math.huge end
	return f
end

function M.limit()
	local f = turtle.getFuelLimit()
	if f == "unlimited" then return math.huge end
	return f
end

function M.isUnlimited() return M.level() == math.huge end

--- Le slot sélectionné est-il du combustible ?
-- turtle.refuel(0) répond sans rien consommer. C'est ce qui rend inutile la
-- table fuelNames de ccQuarry, jamais lue, et qui de toute façon contenait des
-- noms d'affichage et non des identifiants de registre.
function M.isFuel()
	return turtle.refuel(0)
end

--- Slots contenant du combustible, dans l'ordre.
-- ccInv ne peut pas répondre à cette question : reconnaître un combustible
-- demande turtle.refuel(0), et ccFuel dépend déjà de ccInv.
function M.fuelSlots()
	local out = {}
	for slot = 1, 16 do
		if turtle.getItemCount(slot) > 0 then
			turtle.select(slot)
			if M.isFuel() then out[#out + 1] = slot end
		end
	end
	return out
end

--- Slot de combustible le plus fourni, ou nil.
function M.bestFuelSlot()
	local best, count = nil, 0
	for _, slot in ipairs(M.fuelSlots()) do
		local n = turtle.getItemCount(slot)
		if n > count then best, count = slot, n end
	end
	return best
end

--- Slots à préserver lors d'un vidage, pour garder `keep` unités de
--- combustible. Le reste part au coffre : le charbon est aussi du butin, et
--- tout garder reviendrait à ne jamais le déposer.
-- @return { [slot] = true }, total conservé
function M.protectSlots(keep)
	keep = keep or 64
	local set, total = {}, 0
	for _, slot in ipairs(M.fuelSlots()) do
		if total >= keep then break end
		set[slot] = true
		total = total + turtle.getItemCount(slot)
	end
	return set, total
end

--- Brûle depuis le slot sélectionné jusqu'à atteindre `target`.
-- @return nombre d'objets restant dans le slot
function M.burnUpTo(target)
	while M.level() < target and turtle.getItemCount() > 0 do
		-- Garde-fou : jamais de boucle muette si refuel se met à échouer.
		if not turtle.refuel(1) then break end
	end
	return turtle.getItemCount()
end

-- ---------------------------------------------------------------------------
-- Budget
-- ---------------------------------------------------------------------------

--- Coût en carburant pour rejoindre `origin` depuis `pos`, rotations exclues.
function M.costToHome(pos, origin)
	return ccVec.manhattan(pos, origin or ORIGIN)
end

--- Carburant à ne jamais dépenser en minage : de quoi rentrer, plus une marge.
function M.reserve(pos, origin, margin)
	return M.costToHome(pos, origin) + (margin or 0)
end

--- Garde à brancher sur ccNav.configure({ canMove = ... }).
-- Conservatrice : elle raisonne sur la position courante, donc refuse un peu
-- tôt lorsque le mouvement rapproche justement de l'origine. C'est le sens de
-- l'erreur qu'on veut.
-- @param getPos  fonction renvoyant la position courante (ccNav.position)
function M.guard(getPos, origin, margin)
	return function()
		if M.isUnlimited() then return true end
		return M.level() > M.reserve(getPos(), origin, margin)
	end
end

-- ---------------------------------------------------------------------------
-- Ravitaillement
-- ---------------------------------------------------------------------------

--- Brûle le combustible déjà présent dans l'inventaire.
-- Le coffre transportable est épargné : un coffre en bois est combustible.
-- @return true, ou false + "not_enough_fuel" | "no_fuel_found"
function M.refuelFromInventory(target)
	local chest = ccInv.findChest()
	local found = false

	for slot = 1, 16 do
		if M.level() >= target then break end
		if slot ~= chest and turtle.getItemCount(slot) > 0 then
			turtle.select(slot)
			if M.isFuel() then
				found = true
				M.burnUpTo(target)
			end
		end
	end

	if M.level() >= target then return true end
	return false, found and "not_enough_fuel" or "no_fuel_found"
end

--- Ravitaille depuis le conteneur visé, sans en altérer le contenu.
--
-- L'appelant a déjà posé le coffre et vidé le butin. Le contenu du coffre est
-- restitué dans son ordre d'origine : les piles non combustibles sont retenues
-- le temps du parcours, puis rendues dans l'ordre où elles ont été aspirées.
--
-- @param where   "forward", "up" ou "down"
-- @param target  niveau de carburant visé
-- @param opts    { scratch = nombre de piles à examiner au plus }
-- @return true, ou false + "chest_full" | "not_enough_fuel" | "no_fuel_found"
function M.refuelFromChest(where, target, opts)
	opts = opts or {}
	local scratch = opts.scratch or ccInv.freeCount()
	local fuelSlot = ccInv.config().fuelSlot

	local borrowed = {}     -- slots empruntés, DANS L'ORDRE D'ASPIRATION
	local kept = {}         -- slots de combustible conservé
	local sawFuel = false

	while M.level() < target and #borrowed < scratch do
		local slot = ccInv.firstFree()
		if not slot then break end
		if not ccInv.suckFrom(where, slot) then break end   -- coffre épuisé

		if M.isFuel() then
			sawFuel = true
			M.burnUpTo(target)
			if turtle.getItemCount(slot) > 0 then
				-- Reste de combustible : on le garde plutôt que de le rendre.
				-- Le rangement à l'emplacement canonique attend la fin : y
				-- toucher maintenant DÉPLACERAIT une pile empruntée, et la
				-- restitution rendrait alors le mauvais slot.
				kept[#kept + 1] = slot
			end
		else
			-- LE point de la correction : le rebut est RETENU. L'ancien code le
			-- rendait ici même, il repartait en première position du coffre, et
			-- l'aspiration suivante ramenait le même objet.
			borrowed[#borrowed + 1] = slot
		end
	end

	for i = 1, #borrowed do
		local ok, reason = ccInv.dropTo(where, borrowed[i])
		if not ok then return false, reason end
	end

	-- Le rebut est rendu : plus aucun indice à préserver, on peut ranger.
	for _, slot in ipairs(kept) do ccInv.moveToSlot(slot, fuelSlot) end

	if M.level() >= target then return true end
	return false, sawFuel and "not_enough_fuel" or "no_fuel_found"
end

return M
