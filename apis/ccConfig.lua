-- ccConfig : options d'un script, dans un fichier Lua éditable en jeu.
--
-- Les scripts du dépôt portent tous des réglages en dur : la liste de rebut de
-- ccQuarry, fuelPriority et les listes de blocs de ccChopper, isStairs et
-- isTorch de ccStairs, isSeed de ccFarm. Les changer demande de rééditer le
-- script sur chaque ordinateur, et l'édition est perdue à la mise à jour
-- suivante.
--
-- Le fichier est du Lua, comme manifest.lua, et se modifie en jeu avec
-- `edit <fichier>`.
--
-- Deux principes :
--
--   * Le gabarit COMMENTÉ n'est écrit qu'une fois, à la création. Le fichier
--     n'est jamais réécrit ensuite : les commentaires et la mise en forme de
--     l'utilisateur survivent, ce qu'une sérialisation automatique ne
--     permettrait pas.
--
--   * Une option mal saisie ne casse rien. Le type attendu est déduit de la
--     valeur par défaut ; toute divergence est signalée et la valeur par
--     défaut conservée. Un fichier illisible ne bloque pas le script.

local M = { _VERSION = 1 }

--- Copie profonde, pour qu'un défaut de type table ne soit jamais partagé
--- entre l'appelant et la configuration retournée.
local function deepCopy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = deepCopy(v) end
	return out
end

local function readFile(path)
	local handle = fs.open(path, "r")
	if not handle then return nil end
	local content = handle.readAll()
	handle.close()
	return content
end

--- Écrit le gabarit s'il n'existe pas déjà.
-- @return true si le fichier vient d'être créé
function M.install(path, template)
	if fs.exists(path) then return false end
	local handle = fs.open(path, "w")
	if not handle then return false end
	handle.write(template)
	handle.close()
	return true
end

--- Charge les options.
-- @param path      chemin du fichier
-- @param defaults  table des valeurs par défaut ; les types en sont déduits
-- @param template  contenu commenté écrit à la création (optionnel)
-- @return config, avertissements, cree
function M.load(path, defaults, template)
	local config = deepCopy(defaults)
	local warnings = {}
	local created = false

	if template then created = M.install(path, template) end
	if not fs.exists(path) then return config, warnings, created end

	local content = readFile(path)
	if not content or content == "" then
		warnings[#warnings + 1] = "fichier vide, valeurs par defaut"
		return config, warnings, created
	end

	-- Évalué dans un environnement VIDE : c'est un fichier de données, il n'a
	-- pas à pouvoir agir sur l'ordinateur.
	local chunk, lerr = load(content, "@" .. path, "t", {})
	if not chunk then
		warnings[#warnings + 1] = "illisible (" .. tostring(lerr) .. "), valeurs par defaut"
		return config, warnings, created
	end

	local ok, loaded = pcall(chunk)
	if not ok or type(loaded) ~= "table" then
		warnings[#warnings + 1] = "ne renvoie pas une table, valeurs par defaut"
		return config, warnings, created
	end

	for key, value in pairs(loaded) do
		local expected = defaults[key]
		if expected == nil then
			warnings[#warnings + 1] = "option inconnue : " .. tostring(key)
		elseif type(value) ~= type(expected) then
			warnings[#warnings + 1] = ("option %s : %s attendu, %s trouve")
				:format(tostring(key), type(expected), type(value))
		else
			config[key] = value
		end
	end

	return config, warnings, created
end

return M
