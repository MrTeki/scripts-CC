-- ccUtil : petits utilitaires partagés par tous les scripts.
--
-- Regroupe des fonctions aujourd'hui dupliquées :
--   roundTo           ccQuarry.lua:72, ccInventory.lua:129 (identiques)
--   indexOf           ccChopper.lua:55, ccInventory.lua:157
--   recherche de périphérique
--                     ccQuarry.lua:39 (modem), ccChopper.lua:142, ccInventory.lua:493

local M = { _VERSION = 1 }

-- ---------------------------------------------------------------------------
-- Nombres
-- ---------------------------------------------------------------------------

--- Arrondit `num` à `n` décimales (0 par défaut).
function M.roundTo(num, n)
	local mult = 10 ^ (n or 0)
	return math.floor(num * mult + 0.5) / mult
end

--- Contraint `v` dans l'intervalle [min, max].
function M.clamp(v, min, max)
	if v < min then return min end
	if v > max then return max end
	return v
end

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

--- Index de `needle` dans `array`, ou nil.
-- Note : ccChopper.indexOf renvoyait `false` au lieu de nil. Les deux passent
-- un test de vérité, mais nil est la convention Lua et se compose avec `or`.
function M.indexOf(array, needle)
	for i, value in ipairs(array) do
		if value == needle then return i end
	end
	return nil
end

--- Vrai si `needle` est présent dans `array`.
function M.contains(array, needle)
	return M.indexOf(array, needle) ~= nil
end

--- Copie de surface d'une table.
function M.copy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

--- Nombre d'entrées d'une table, y compris à clés non numériques.
function M.count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

-- ---------------------------------------------------------------------------
-- Périphériques
-- ---------------------------------------------------------------------------

--- Premier périphérique du type demandé.
-- Remplace la boucle de ccQuarry.lua:39, qui parcourait tous les côtés en
-- gardant le DERNIER modem trouvé plutôt que le premier.
-- @return side, api  ou nil si absent
function M.findPeripheral(ptype)
	for _, side in ipairs(peripheral.getNames()) do
		if peripheral.getType(side) == ptype then
			return side, peripheral.wrap(side)
		end
	end
	return nil
end

--- Tous les côtés portant un périphérique du type demandé, dans l'ordre.
function M.findPeripherals(ptype)
	local out = {}
	for _, side in ipairs(peripheral.getNames()) do
		if peripheral.getType(side) == ptype then
			out[#out + 1] = side
		end
	end
	return out
end

return M
