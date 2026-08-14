-- ccSave : persistance d'etat pour les scripts CC.
--
-- Remplace le motif copie dans ccQuarry, ccChopper, ccFarm et ccInventory :
--   savedFile = fs.open(path, "w")
--   savedFile.write(textutils.serialize({ [1] = curX, [2] = curY, ... }))
--
-- Trois problemes de ce motif, tous corriges ici :
--
--   1. Ecriture non atomique. Un turtle detruit ou un chunk decharge en pleine
--      ecriture laisse un fichier tronque. Au reboot, textutils.unserialize
--      renvoie nil, et l'acces savedValues[15] plante -- en boucle, puisque
--      startup relance le script. Ici on ecrit dans un fichier temporaire, on
--      le relit pour verifier qu'il est exploitable, et seulement alors on
--      remplace l'original. Une panne a n'importe quel instant laisse soit
--      l'ancienne sauvegarde intacte, soit la nouvelle complete.
--
--   2. Index numeriques. savedValues[15] ne dit pas ce qu'il contient, et
--      inserer un champ decale tout. Ici les donnees sont un table libre a
--      cles nommees.
--
--   3. Pas de version. Tout changement de format casse les sauvegardes en
--      cours en silence. Ici l'enveloppe porte un numero de version et read()
--      applique une chaine de migrations.
--
-- Format sur disque :
--   { version = <n>, data = { ... } }
-- Un fichier sans enveloppe est traite comme la version 0, ce qui permet de
-- migrer les sauvegardes de l'ancien format.

local M = { _VERSION = 1 }

local TMP = ".tmp"

-- ---------------------------------------------------------------------------
-- Interne
-- ---------------------------------------------------------------------------

--- Lit et deserialise un fichier. Retourne nil + raison si inexploitable.
local function readRaw(path)
	if not fs.exists(path) then return nil, "absent" end

	local handle, err = fs.open(path, "r")
	if not handle then return nil, "ouverture: " .. tostring(err) end

	local ok, content = pcall(handle.readAll)
	pcall(handle.close)
	if not ok or content == nil or content == "" then return nil, "vide" end

	local value = textutils.unserialize(content)
	if value == nil then return nil, "corrompu" end
	return value
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

--- Ecrit `data` de facon atomique.
-- @param path  chemin du fichier de sauvegarde
-- @param data  table serialisable
-- @param opts  { version = <n> } (defaut 1)
-- @return true, ou false + raison
function M.write(path, data, opts)
	opts = opts or {}
	local version = opts.version or 1
	local tmp = path .. TMP

	local ok, payload = pcall(textutils.serialize, { version = version, data = data })
	if not ok then return false, "serialisation: " .. tostring(payload) end

	fs.delete(tmp)
	local handle, err = fs.open(tmp, "w")
	if not handle then return false, "ouverture: " .. tostring(err) end

	local written, werr = pcall(function()
		handle.write(payload)
		handle.flush()
	end)
	pcall(handle.close)
	if not written then
		fs.delete(tmp)
		return false, "ecriture: " .. tostring(werr)
	end

	-- Relecture de controle. C'est ce qui garantit qu'on ne remplace jamais une
	-- sauvegarde valide par un fichier illisible. Le cout d'une lecture en plus
	-- est negligeable : on sauvegarde aux transitions d'etat, pas a chaque bloc.
	local check = readRaw(tmp)
	if type(check) ~= "table" or check.version ~= version then
		fs.delete(tmp)
		return false, "verification apres ecriture"
	end

	fs.delete(path)
	fs.move(tmp, path)
	return true
end

--- Lit une sauvegarde, en appliquant les migrations necessaires.
-- @param path  chemin du fichier
-- @param opts  { version = <n cible>, migrations = { [v] = function(data) end } }
--              migrations[v] transforme les donnees de la version v vers v+1.
-- @return data, ou nil + raison
function M.read(path, opts)
	opts = opts or {}
	local target = opts.version or 1

	local raw, err = readRaw(path)
	if raw == nil then
		-- Fenetre de panne entre le delete et le move de write() : le fichier
		-- principal a disparu mais le temporaire, lui, est complet et verifie.
		local recovered = readRaw(path .. TMP)
		if recovered == nil then return nil, err end
		fs.delete(path)
		fs.move(path .. TMP, path)
		raw = recovered
	end

	local version, data
	if type(raw) == "table" and type(raw.version) == "number" and raw.data ~= nil then
		version, data = raw.version, raw.data
	else
		version, data = 0, raw     -- ancien format, sans enveloppe
	end

	if version > target then
		return nil, "sauvegarde en version " .. version
			.. ", ce script attend la version " .. target
	end

	local migrations = opts.migrations or {}
	while version < target do
		local step = migrations[version]
		if not step then
			return nil, "aucune migration de la version " .. version
				.. " vers " .. (version + 1)
		end
		local ok, result = pcall(step, data)
		if not ok then
			return nil, "migration " .. version .. ": " .. tostring(result)
		end
		data, version = result, version + 1
	end

	return data
end

--- Supprime la sauvegarde et son temporaire eventuel.
function M.delete(path)
	fs.delete(path)
	fs.delete(path .. TMP)
end

--- Vrai s'il existe quelque chose a reprendre (fichier principal ou temporaire).
function M.exists(path)
	return fs.exists(path) or fs.exists(path .. TMP)
end

return M
