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

local M = { _VERSION = 2 }

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

-- ---------------------------------------------------------------------------
-- Écriture
-- ---------------------------------------------------------------------------
-- Un menu de démarrage doit pouvoir mémoriser ses choix sans trahir le
-- principe du gabarit : seules les VALEURS des options modifiées sont
-- remplacées, à leur place, et tout le reste du fichier -- commentaires,
-- ordre, mise en forme -- est conservé à l'identique.

--- Texte Lua d'une valeur. Les listes s'écrivent un élément par ligne, comme
--- dans le gabarit ; les tables à clés tiennent sur une ligne.
function M.serialize(value, indent)
	indent = indent or ""
	local kind = type(value)
	if kind == "string" then return ("%q"):format(value) end
	if kind ~= "table" then return tostring(value) end

	if #value > 0 or next(value) == nil then
		if #value == 0 then return "{}" end
		local lines = {}
		for _, v in ipairs(value) do
			lines[#lines + 1] = indent .. "    " .. M.serialize(v, indent .. "    ") .. ","
		end
		return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
	end

	local keys = {}
	for k in pairs(value) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. " = " .. M.serialize(value[k], indent)
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

--- Fin de la valeur qui commence en `pos` : table équilibrée, chaîne, ou
--- littéral simple (nombre, booléen).
local function valueEnd(content, pos)
	local c = content:sub(pos, pos)
	if c == "{" then
		local _, e = content:find("^%b{}", pos)
		return e
	elseif c == '"' or c == "'" then
		local i = pos + 1
		while i <= #content do
			local ch = content:sub(i, i)
			if ch == "\\" then
				i = i + 1
			elseif ch == c then
				return i
			end
			i = i + 1
		end
		return nil
	end
	local _, e = content:find("^[%w%.%-_]+", pos)
	return e
end

--- Remplace, ou ajoute, des options dans le fichier.
-- Une option absente est ajoutée avant l'accolade finale.
-- @param changes { clé = valeur }
-- @return true, ou false + raison
function M.set(path, changes)
	local content = readFile(path) or "return {\n}\n"

	local keys = {}
	for k in pairs(changes) do keys[#keys + 1] = k end
	table.sort(keys)

	for _, key in ipairs(keys) do
		-- La clé doit commencer une ligne : une mention dans un commentaire,
		-- précédé de « -- », ne correspond pas.
		local s, e, indent = ("\n" .. content):find("\n([ \t]*)" .. key .. "%s*=%s*")
		local stop = s and valueEnd(content, e)
		local text = M.serialize(changes[key], indent or "    ")
		if stop then
			-- `e` est compté dans le texte préfixé d'un saut de ligne.
			content = content:sub(1, e - 1) .. text .. content:sub(stop + 1)
		else
			local close = content:match("^.*()}")
			if not close then return false, "accolade finale introuvable" end
			local before = content:sub(1, close - 1)
			if not before:match("\n%s*$") then before = before .. "\n" end
			content = before .. "    " .. key .. " = " .. M.serialize(changes[key], "    ")
				.. ",\n" .. content:sub(close)
		end
	end

	local handle = fs.open(path, "w")
	if not handle then return false, "ecriture impossible" end
	handle.write(content)
	handle.close()
	return true
end

return M
