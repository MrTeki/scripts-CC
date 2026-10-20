-- ccBoot : installe les APIs manquantes depuis le dépôt GitHub.
--
-- Remplace CCSuiteUpdater (2018), qui codait ONZE identifiants pastebin en
-- dur, dupliqués deux fois. Chaque mise à jour d'un script produisait un
-- nouvel identifiant, donc obligeait à rééditer l'updater : le mécanisme est
-- devenu ingérable dès la première évolution. Ici, un seul point d'entrée en
-- dur dans les scripts -- l'URL du dépôt -- et une URL GitHub raw est stable
-- par construction.
--
-- Cinq règles, dans l'ordre d'importance.
--
--   1. AUCUN accès réseau si tout est présent et à jour. C'est la règle
--      critique : un turtle redémarre à chaque rechargement de chunk, et
--      startup relance le script. Une carrière de trois heures peut rebooter
--      des dizaines de fois ; télécharger à chaque démarrage ferait tomber
--      les limites de débit et, pire, laisserait des fichiers à moitié écrits.
--
--   2. Installation ATOMIQUE, avec contrôle de syntaxe avant remplacement.
--      Un téléchargement tronqué ne doit jamais casser une installation qui
--      fonctionnait.
--
--   3. Échec DOUX. Si HTTP est indisponible mais que tout est déjà là, on
--      continue en silence. Sinon, message explicite nommant les APIs
--      manquantes et l'URL, pour installation manuelle.
--
--   4. Indirection par MANIFESTE : le dépôt décide où vivent les fichiers et
--      quelles versions font foi, pas les scripts déployés.
--
--   5. Rafraîchissement forcé sur demande explicite : `<script> update`.
--      Il porte sur TOUT ce qui peut être en retard : ccBoot lui-même, le
--      script, et les APIs -- celles que demande le script mis à jour, pas
--      seulement l'ancien. Sans cela, un script qui gagne une dépendance ne
--      pouvait être mis à jour qu'à la main, par `wget`.

local M = { _VERSION = 2 }

M.DIR = "apis"
M.MANIFEST = "manifest.lua"

-- ---------------------------------------------------------------------------
-- Interne
-- ---------------------------------------------------------------------------

--- Version déclarée dans une source, sans l'exécuter.
local function versionOfSource(src)
	return tonumber(src:match("_VERSION%s*=%s*(%d+)"))
end

--- Version d'un script, déclarée par `local VERSION = n`, ou nil.
function M.scriptVersion(src)
	return tonumber((src or ""):match("local%s+VERSION%s*=%s*(%d+)"))
end

--- Table NEEDS d'un script, lue sans l'exécuter : un script ne se charge pas
--- hors de son ordinateur, et l'exécuter lancerait le chantier.
-- @return { nom = version } ou nil
function M.needsOf(src)
	local block = (src or ""):match("local%s+NEEDS%s*=%s*(%b{})")
	if not block then return nil end
	local out = {}
	for name, v in block:gmatch("(cc%w+)%s*=%s*(%d+)") do out[name] = tonumber(v) end
	return out
end

local function readFile(path)
	local handle = fs.open(path, "r")
	if not handle then return nil end
	local content = handle.readAll()
	handle.close()
	return content
end

--- Version installée localement, ou nil.
-- On regarde d'abord le fichier attendu, puis, à défaut, si le module est
-- chargeable par un autre moyen : un dépôt de développement dans package.path,
-- ou un module installé ailleurs, sont des installations légitimes.
local function localVersion(name)
	local path = M.DIR .. "/" .. name .. ".lua"
	if fs.exists(path) then
		local src = readFile(path)
		return src and versionOfSource(src)
	end

	local ok, mod = pcall(require, name)
	if ok and type(mod) == "table" and type(mod._VERSION) == "number" then
		return mod._VERSION
	end
	return nil
end

local function available(name, minVersion)
	local v = localVersion(name)
	return v ~= nil and v >= minVersion
end

local function fetch(url)
	if not http then return nil, "HTTP indisponible" end
	local res, err = http.get(url)
	if not res then return nil, tostring(err or "requete refusee") end
	local body = res.readAll()
	res.close()
	if not body or #body == 0 then return nil, "reponse vide" end
	return body
end

--- Télécharge et installe un fichier, sans jamais laisser l'existant cassé.
local function install(url, dest)
	local body, err = fetch(url)
	if not body then return false, err end

	-- Contrôle de syntaxe AVANT de toucher à l'existant.
	local chunk, lerr = load(body, "@" .. dest)
	if not chunk then return false, "syntaxe : " .. tostring(lerr) end

	local tmp = dest .. ".tmp"
	fs.delete(tmp)

	local handle = fs.open(tmp, "w")
	if not handle then return false, "ecriture impossible" end
	handle.write(body)
	handle.close()

	if not fs.exists(tmp) then return false, "fichier temporaire absent" end
	fs.delete(dest)
	fs.move(tmp, dest)
	return true
end

-- ---------------------------------------------------------------------------
-- API
-- ---------------------------------------------------------------------------

--- Récupère et évalue le manifeste du dépôt.
-- Évalué dans un environnement VIDE : c'est une table de données, pas du code
-- à qui l'on donne accès aux globales.
function M.manifest(repo)
	local body, err = fetch(repo .. M.MANIFEST)
	if not body then return nil, "manifeste : " .. err end

	local chunk, lerr = load(body, "@manifest", "t", {})
	if not chunk then return nil, "manifeste illisible : " .. tostring(lerr) end

	local ok, data = pcall(chunk)
	if not ok or type(data) ~= "table" then return nil, "manifeste invalide" end
	return data
end

--- Garantit que les APIs demandées sont présentes dans une version suffisante.
-- @param repo   URL de base, terminée par /
-- @param needs  { nom = versionMinimale }
-- @param opts   { check = true }  consulter le manifeste et installer ce qui
--                                 est en retard sur le dépôt
--               { force = true }  tout retélécharger, sans comparer
--               { manifest = t }  manifeste déjà obtenu, pour ne pas le
--                                 retélécharger
-- @return true + liste des APIs installées, ou false + raison
function M.ensure(repo, needs, opts)
	opts = opts or {}

	local missing = {}
	for name, min in pairs(needs) do
		if not available(name, min) then missing[#missing + 1] = name end
	end
	table.sort(missing)

	-- Règle 1 : rien à faire, on ne touche pas au réseau.
	if #missing == 0 and not (opts.check or opts.force) then return true, {} end

	-- Règle 3 : échec doux et message exploitable.
	if not http then
		if #missing == 0 then return true, {} end
		return false, "APIs manquantes : " .. table.concat(missing, ", ")
			.. "\nHTTP indisponible. Copier le dossier " .. M.DIR
			.. "/ depuis " .. repo
	end

	local manifest, err = opts.manifest, nil
	if not manifest then
		manifest, err = M.manifest(repo)
		if not manifest then return false, err end
	end

	-- Cibles : ce qui manque, plus, en mode check, ce que le dépôt propose en
	-- version plus récente. `update` ne retélécharge donc pas tout à l'aveugle.
	local targets, seen = {}, {}
	for _, name in ipairs(missing) do
		targets[#targets + 1] = name
		seen[name] = true
	end

	if opts.check or opts.force then
		local names = {}
		for name in pairs(needs) do names[#names + 1] = name end
		table.sort(names)

		for _, name in ipairs(names) do
			if not seen[name] then
				local entry = (manifest.apis or {})[name]
				local remoteV = entry and entry.version
				local localV = localVersion(name)
				if opts.force or (remoteV and localV and remoteV > localV) then
					targets[#targets + 1] = name
					seen[name] = true
				end
			end
		end
	end

	local installed = {}
	if #targets > 0 then fs.makeDir(M.DIR) end
	for _, name in ipairs(targets) do
		local entry = (manifest.apis or {})[name]
		local remote = entry and entry.path or (M.DIR .. "/" .. name .. ".lua")

		local ok, ierr = install(repo .. remote, M.DIR .. "/" .. name .. ".lua")
		if not ok then
			return false, "installation de " .. name .. " : " .. ierr
		end
		package.loaded[name] = nil     -- forcer le rechargement
		installed[#installed + 1] = name
	end
	return true, installed
end

--- Met à jour ccBoot, le script et ses APIs : la commande `<script> update`.
--
-- Trois étapes, dans cet ordre :
--   1. ccBoot lui-même. La nouvelle version est rechargée et reprend la main,
--      pour que la suite profite de ses corrections ;
--   2. le script, réinstallé à son propre chemin si le manifeste en annonce
--      une version plus récente. Il ne prend effet qu'au prochain lancement :
--      le script en cours d'exécution est déjà en mémoire ;
--   3. les APIs, d'après les NEEDS du NOUVEAU script, relus dans sa source.
--      C'est ce qui rend la mise à jour complète en une seule commande : un
--      script qui gagne une dépendance la trouve installée à son relancement.
--
-- @param needs   NEEDS du script en cours
-- @param script  { name, version, path } ; sans `path`, le script n'est pas
--                touché (pas d'API shell, ou chemin inconnu)
-- @return true + rapport { boot = version?, script = version?, apis = {...} },
--         ou false + raison
function M.update(repo, needs, script, opts)
	opts = opts or {}
	script = script or {}
	local report = { apis = {} }

	if not http then return false, "HTTP indisponible" end
	local manifest, err = M.manifest(repo)
	if not manifest then return false, err end
	local apis = manifest.apis or {}

	-- 1. ccBoot. Le drapeau évite toute boucle si le dépôt annonçait une
	-- version que le fichier servi ne porte pas.
	local bootEntry = apis.ccBoot
	if not opts.bootDone and bootEntry and bootEntry.version and bootEntry.version > M._VERSION then
		fs.makeDir(M.DIR)
		local ok, ierr = install(repo .. (bootEntry.path or (M.DIR .. "/ccBoot.lua")), M.DIR .. "/ccBoot.lua")
		if not ok then return false, "installation de ccBoot : " .. ierr end
		-- Chargé depuis le fichier qu'on vient d'écrire, et non par require :
		-- package.path pourrait trouver un autre ccBoot avant celui-là.
		local chunk, lerr = load(readFile(M.DIR .. "/ccBoot.lua") or "", "@ccBoot")
		local loaded, fresh = false, nil
		if chunk then loaded, fresh = pcall(chunk) end
		if not loaded or type(fresh) ~= "table" or type(fresh.update) ~= "function" then
			return false, "ccBoot installe inutilisable : " .. tostring(lerr or fresh)
		end
		package.loaded.ccBoot = fresh
		local done, result = fresh.update(repo, needs, script, { bootDone = true })
		if done then result.boot = fresh._VERSION end
		return done, result
	end

	-- 2. Le script.
	local merged = {}
	for name, v in pairs(needs or {}) do merged[name] = v end

	local entry = script.name and (manifest.scripts or {})[script.name]
	if entry and script.path and entry.version and entry.version > (script.version or 0) then
		local ok, ierr = install(repo .. entry.path, script.path)
		if not ok then return false, "installation de " .. script.name .. " : " .. ierr end
		report.script = entry.version

		-- 3. Les besoins du nouveau script s'ajoutent aux anciens, à la plus
		-- haute version demandée.
		for name, v in pairs(M.needsOf(readFile(script.path)) or {}) do
			if not merged[name] or v > merged[name] then merged[name] = v end
		end
	end

	local ok, installed = M.ensure(repo, merged, { check = true, manifest = manifest })
	if not ok then return false, installed end
	report.apis = installed
	return true, report
end

return M
