-- ccSave : persistance d'état pour les scripts CC.
--
-- Remplace le motif copié dans ccQuarry, ccChopper, ccFarm et ccInventory :
--   savedFile = fs.open(path, "w")
--   savedFile.write(textutils.serialize({ [1] = curX, [2] = curY, ... }))
--
-- Trois problèmes de ce motif, tous corrigés ici :
--
--   1. Écriture non atomique. Un turtle détruit ou un chunk déchargé en pleine
--      écriture laisse un fichier tronqué. Au reboot, textutils.unserialize
--      renvoie nil, et l'accès savedValues[15] plante -- en boucle, puisque
--      startup relance le script. Ici on écrit dans un fichier temporaire, on
--      le relit pour vérifier qu'il est exploitable, et seulement alors on
--      remplace l'original. Une panne à n'importe quel instant laisse soit
--      l'ancienne sauvegarde intacte, soit la nouvelle complète.
--
--   2. Index numériques. savedValues[15] ne dit pas ce qu'il contient, et
--      insérer un champ décale tout. Ici les données sont une table libre à
--      clés nommées.
--
--   3. Pas de version. Tout changement de format casse les sauvegardes en
--      cours en silence. Ici l'enveloppe porte un numéro de version et read()
--      applique une chaîne de migrations.
--
-- Format sur disque :
--   { version = <n>, data = { ... } }
-- Un fichier sans enveloppe est traité comme la version 0, ce qui permet de
-- migrer les sauvegardes de l'ancien format.
--
-- Usage :
--   local store = ccSave.store("ccquarry.save", {
--       version = 1,
--       migrations = { [0] = function(old) return converti end },
--   })
--   store.write(etat)
--   local etat, err = store.read()

local M = { _VERSION = 1 }

local TMP = ".tmp"

-- ---------------------------------------------------------------------------
-- Interne
-- ---------------------------------------------------------------------------

--- Lit et désérialise un fichier. Retourne nil + raison si inexploitable.
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

--- Crée un accès à un fichier de sauvegarde.
-- @param path  chemin du fichier
-- @param opts  { version = <n cible, défaut 1>,
--                migrations = { [v] = function(data) end } }
--              migrations[v] transforme les données de la version v vers v+1.
-- @return une table exposant write, read, delete et exists
function M.store(path, opts)
	opts = opts or {}

	local version = opts.version or 1
	local migrations = opts.migrations or {}
	local tmpPath = path .. TMP

	local store = { path = path, version = version }

	--- Écrit `data` de façon atomique.
	-- @return true, ou false + raison
	function store.write(data)
		local ok, payload = pcall(textutils.serialize, { version = version, data = data })
		if not ok then return false, "sérialisation: " .. tostring(payload) end

		fs.delete(tmpPath)
		local handle, err = fs.open(tmpPath, "w")
		if not handle then return false, "ouverture: " .. tostring(err) end

		local written, werr = pcall(function()
			handle.write(payload)
			handle.flush()
		end)
		pcall(handle.close)
		if not written then
			fs.delete(tmpPath)
			return false, "écriture: " .. tostring(werr)
		end

		-- Relecture de contrôle. C'est ce qui garantit qu'on ne remplace jamais
		-- une sauvegarde valide par un fichier illisible. Le coût d'une lecture
		-- en plus est négligeable : on sauvegarde aux transitions d'état, pas à
		-- chaque bloc miné.
		local check = readRaw(tmpPath)
		if type(check) ~= "table" or check.version ~= version then
			fs.delete(tmpPath)
			return false, "vérification après écriture"
		end

		fs.delete(path)
		fs.move(tmpPath, path)
		return true
	end

	--- Lit la sauvegarde, en appliquant les migrations nécessaires.
	-- @return data, ou nil + raison
	function store.read()
		local raw, err = readRaw(path)
		if raw == nil then
			-- Fenêtre de panne entre le delete et le move de write() : le
			-- fichier principal a disparu, mais le temporaire est complet et
			-- déjà vérifié.
			local recovered = readRaw(tmpPath)
			if recovered == nil then return nil, err end
			fs.delete(path)
			fs.move(tmpPath, path)
			raw = recovered
		end

		local found, data
		if type(raw) == "table" and type(raw.version) == "number" and raw.data ~= nil then
			found, data = raw.version, raw.data
		else
			found, data = 0, raw     -- ancien format, sans enveloppe
		end

		if found > version then
			return nil, "sauvegarde en version " .. found
				.. ", ce script attend la version " .. version
		end

		while found < version do
			local step = migrations[found]
			if not step then
				return nil, "aucune migration de la version " .. found
					.. " vers " .. (found + 1)
			end
			local ok, result = pcall(step, data)
			if not ok then
				return nil, "migration " .. found .. ": " .. tostring(result)
			end
			data, found = result, found + 1
		end

		return data
	end

	--- Supprime la sauvegarde et son temporaire éventuel.
	function store.delete()
		fs.delete(path)
		fs.delete(tmpPath)
	end

	--- Vrai s'il existe quelque chose à reprendre (fichier principal ou temporaire).
	function store.exists()
		return fs.exists(path) or fs.exists(tmpPath)
	end

	return store
end

return M
