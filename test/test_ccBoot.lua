-- Tests de ccBoot. Chaque cas correspond à l'une des cinq règles de l'en-tête
-- du module, et plusieurs encodent l'échec de CCSuiteUpdater.

local H = require("harness")
local mock = require("ccMock")
local ccBoot = require("ccBoot")

local REPO = "https://raw.githubusercontent.com/MrTeki/scripts-CC/main/"

-- Noms fictifs : les vraies APIs sont chargeables depuis le disque de
-- développement, ce qui les rendrait déjà disponibles.
local A = "ccFictifA"
local B = "ccFictifB"

local function source(name, version)
	return "local M = { _VERSION = " .. version .. " }\n"
		.. "function M.hello() return '" .. name .. "' end\n"
		.. "return M\n"
end

local function manifest()
	return "return { version = 1, apis = {\n"
		.. "  " .. A .. " = { version = 1, path = 'apis/" .. A .. ".lua' },\n"
		.. "  " .. B .. " = { version = 1, path = 'apis/" .. B .. ".lua' },\n"
		.. "} }\n"
end

local function fresh()
	mock.install()
	package.loaded[A], package.loaded[B] = nil, nil
	mock.setUrl(REPO .. "manifest.lua", manifest())
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", source(A, 1))
	mock.setUrl(REPO .. "apis/" .. B .. ".lua", source(B, 1))
end

local function installedSource(name)
	return mock.getFile("apis/" .. name .. ".lua")
end

-- ---------------------------------------------------------------------------
-- Règle 1 : aucun accès réseau si tout est présent
-- ---------------------------------------------------------------------------

H.case("tout est à jour : AUCUNE requête réseau", function()
	-- La règle critique. Un turtle redémarre à chaque rechargement de chunk,
	-- et startup relance le script : télécharger à chaque démarrage ferait
	-- tomber les limites de débit.
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile("apis/" .. B .. ".lua", source(B, 1))

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1, [B] = 1 })
	H.ok(ok, "succès")
	H.eq(#installed, 0, "rien à installer")
	H.eq(#mock.httpRequests(), 0, "pas une seule requête, manifeste compris")
end)

H.case("une version supérieure à l'exigence suffit", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 7))

	H.ok(ccBoot.ensure(REPO, { [A] = 3 }), "succès")
	H.eq(#mock.httpRequests(), 0, "aucune requête")
end)

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

H.case("une API manquante est téléchargée et installée", function()
	fresh()

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1 })
	H.ok(ok, "succès")
	H.eq(installed[1], A, "installée")
	H.eq(installedSource(A), source(A, 1), "contenu écrit")

	local reqs = mock.httpRequests()
	H.eq(reqs[1], REPO .. "manifest.lua", "manifeste d'abord")
	H.eq(reqs[2], REPO .. "apis/" .. A .. ".lua", "puis l'API")
end)

H.case("une version trop ancienne est remplacée", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", source(A, 2))

	local ok, installed = ccBoot.ensure(REPO, { [A] = 2 })
	H.ok(ok, "succès")
	H.eq(installed[1], A, "remplacée")
	H.eq(installedSource(A), source(A, 2), "nouvelle version en place")
end)

H.case("le manifeste décide du chemin distant", function()
	-- L'indirection : déplacer un fichier se fait dans le dépôt, jamais en
	-- rééditant les scripts déployés.
	fresh()
	mock.setUrl(REPO .. "manifest.lua",
		"return { apis = { " .. A .. " = { path = 'ailleurs/autreNom.lua' } } }\n")
	mock.setUrl(REPO .. "ailleurs/autreNom.lua", source(A, 1))

	H.ok(ccBoot.ensure(REPO, { [A] = 1 }), "succès")
	H.eq(installedSource(A), source(A, 1), "installée depuis le chemin du manifeste")
end)

H.case("seules les APIs manquantes sont téléchargées", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1, [B] = 1 })
	H.ok(ok, "succès")
	H.eq(#installed, 1, "une seule installation")
	H.eq(installed[1], B, "la manquante")
end)

-- ---------------------------------------------------------------------------
-- Règle 2 : installation atomique
-- ---------------------------------------------------------------------------

H.case("un téléchargement tronqué ne casse pas l'installation existante", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	-- Le dépôt sert une version 2 syntaxiquement invalide.
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", "local M = { _VERSION = 2 }\nfunction M.")

	local ok, err = ccBoot.ensure(REPO, { [A] = 2 })
	H.eq(ok, false, "refus")
	H.contains(err, "syntaxe", "raison")
	H.eq(installedSource(A), source(A, 1), "l'ancienne version est intacte")
	H.eq(fs.exists("apis/" .. A .. ".lua.tmp"), false, "pas de temporaire résiduel")
end)

H.case("une réponse vide est refusée", function()
	fresh()
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", "")

	local ok, err = ccBoot.ensure(REPO, { [A] = 1 })
	H.eq(ok, false, "refus")
	H.contains(err, "vide", "raison")
	H.eq(fs.exists("apis/" .. A .. ".lua"), false, "rien n'a été écrit")
end)

H.case("une URL injoignable est signalée avec le nom de l'API", function()
	fresh()
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", false)

	local ok, err = ccBoot.ensure(REPO, { [A] = 1 })
	H.eq(ok, false, "refus")
	H.contains(err, A, "l'API fautive est nommée")
end)

-- ---------------------------------------------------------------------------
-- Règle 3 : échec doux
-- ---------------------------------------------------------------------------

H.case("HTTP indisponible mais tout est présent : on continue", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.disableHttp()

	H.ok(ccBoot.ensure(REPO, { [A] = 1 }), "succès silencieux")
end)

H.case("HTTP indisponible et APIs manquantes : message exploitable", function()
	fresh()
	mock.disableHttp()

	local ok, err = ccBoot.ensure(REPO, { [A] = 1, [B] = 1 })
	H.eq(ok, false, "échec")
	H.contains(err, A, "première API nommée")
	H.contains(err, B, "seconde API nommée")
	H.contains(err, REPO, "URL donnée pour installation manuelle")
end)

H.case("manifeste injoignable : message clair, rien d'installé", function()
	fresh()
	mock.setUrl(REPO .. "manifest.lua", false)

	local ok, err = ccBoot.ensure(REPO, { [A] = 1 })
	H.eq(ok, false, "échec")
	H.contains(err, "manifeste", "raison")
	H.eq(fs.exists("apis/" .. A .. ".lua"), false, "rien d'installé")
end)

H.case("manifeste invalide : refus", function()
	fresh()
	mock.setUrl(REPO .. "manifest.lua", "ceci n'est pas du Lua {{{")

	local ok, err = ccBoot.ensure(REPO, { [A] = 1 })
	H.eq(ok, false, "échec")
	H.contains(err, "manifeste", "raison")
end)

H.case("le manifeste est évalué sans accès aux globales", function()
	-- C'est un fichier de données téléchargé : il ne doit pas pouvoir agir.
	fresh()
	mock.setUrl(REPO .. "manifest.lua", "fs.delete('apis') return { apis = {} }")

	local ok, err = ccBoot.manifest(REPO)
	H.isNil(ok, "évaluation refusée")
	H.contains(err, "manifeste", "raison")
end)

-- ---------------------------------------------------------------------------
-- Règle 5 : rafraîchissement forcé
-- ---------------------------------------------------------------------------

H.case("check installe ce que le dépôt propose en version plus récente", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile("apis/" .. B .. ".lua", source(B, 1))
	-- Le dépôt annonce une version 2 pour A seulement.
	mock.setUrl(REPO .. "manifest.lua", "return { apis = {\n"
		.. "  " .. A .. " = { version = 2, path = 'apis/" .. A .. ".lua' },\n"
		.. "  " .. B .. " = { version = 1, path = 'apis/" .. B .. ".lua' },\n"
		.. "} }\n")
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", source(A, 2))

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1, [B] = 1 }, { check = true })
	H.ok(ok, "succès")
	H.eq(#installed, 1, "une seule mise à jour")
	H.eq(installed[1], A, "celle qui était en retard")
	H.eq(installedSource(B), source(B, 1), "B n'a pas bougé")
end)

H.case("check sans nouveauté ne télécharge que le manifeste", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile("apis/" .. B .. ".lua", source(B, 1))

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1, [B] = 1 }, { check = true })
	H.ok(ok, "succès")
	H.eq(#installed, 0, "rien à installer")
	H.eq(#mock.httpRequests(), 1, "une seule requête, le manifeste")
end)

H.case("force retélécharge même ce qui est à jour", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.setUrl(REPO .. "apis/" .. A .. ".lua", source(A, 1) .. "-- revision\n")

	local ok, installed = ccBoot.ensure(REPO, { [A] = 1 }, { force = true })
	H.ok(ok, "succès")
	H.eq(#installed, 1, "réinstallée")
	H.contains(installedSource(A), "revision", "contenu rafraîchi")
end)

-- ---------------------------------------------------------------------------
-- update : ccBoot, le script, puis les APIs du nouveau script
-- ---------------------------------------------------------------------------

local SCRIPT = "monScript"

local function scriptSource(version, needs)
	return "-- script de test\nlocal REPO = 'x'\nlocal VERSION = " .. version .. "\n"
		.. "local NEEDS = {\n\t" .. needs .. "\n}\nprint('script v" .. version .. "')\n"
end

local function manifestWithScript(scriptVersion, bootVersion)
	return "return { apis = {\n"
		.. "  " .. A .. " = { version = 1, path = 'apis/" .. A .. ".lua' },\n"
		.. "  " .. B .. " = { version = 1, path = 'apis/" .. B .. ".lua' },\n"
		.. (bootVersion and ("  ccBoot = { version = " .. bootVersion .. ", path = 'apis/ccBoot.lua' },\n") or "")
		.. "}, scripts = {\n"
		.. "  " .. SCRIPT .. " = { version = " .. scriptVersion .. ", path = '" .. SCRIPT .. ".lua' },\n"
		.. "} }\n"
end

H.case("scriptVersion et needsOf lisent la source sans l'executer", function()
	local src = scriptSource(3, A .. " = 2, " .. B .. " = 1,")
	H.eq(ccBoot.scriptVersion(src), 3, "version")
	H.eq(ccBoot.scriptVersion("local SAVE_VERSION = 9"), nil, "pas une autre constante")
	local needs = ccBoot.needsOf(src)
	H.eq(needs[A], 2, "premiere dependance")
	H.eq(needs[B], 1, "seconde dependance")
	H.isNil(ccBoot.needsOf("print('rien')"), "pas de NEEDS")
end)

H.case("update reinstalle le script plus recent et les APIs qu'il demande", function()
	-- Le cas qui imposait un wget a la main : la nouvelle version du script
	-- depend d'une API que l'ancienne ne connaissait pas.
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile(SCRIPT, scriptSource(1, A .. " = 1,"))
	mock.setUrl(REPO .. "manifest.lua", manifestWithScript(2))
	mock.setUrl(REPO .. SCRIPT .. ".lua", scriptSource(2, A .. " = 1, " .. B .. " = 1,"))

	local ok, report = ccBoot.update(REPO, { [A] = 1 }, { name = SCRIPT, version = 1, path = SCRIPT })
	H.ok(ok, "succes")
	H.eq(report.script, 2, "script mis a jour")
	H.eq(mock.getFile(SCRIPT), scriptSource(2, A .. " = 1, " .. B .. " = 1,"), "ecrit a son chemin")
	H.eq(table.concat(report.apis, ","), B, "la nouvelle dependance est installee")
	H.eq(installedSource(B), source(B, 1), "contenu de la nouvelle API")
	H.eq(mock.httpRequests()[1], REPO .. "manifest.lua", "manifeste d'abord")
	local manifests = 0
	for _, url in ipairs(mock.httpRequests()) do
		if url == REPO .. "manifest.lua" then manifests = manifests + 1 end
	end
	H.eq(manifests, 1, "le manifeste n'est telecharge qu'une fois")
end)

H.case("update ne touche pas a un script deja a jour", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile(SCRIPT, scriptSource(2, A .. " = 1,"))
	mock.setUrl(REPO .. "manifest.lua", manifestWithScript(2))

	local ok, report = ccBoot.update(REPO, { [A] = 1 }, { name = SCRIPT, version = 2, path = SCRIPT })
	H.ok(ok, "succes")
	H.isNil(report.script, "pas de mise a jour")
	H.eq(#report.apis, 0, "aucune API")
	H.eq(#mock.httpRequests(), 1, "seul le manifeste")
end)

H.case("update sans chemin de script : seules les APIs sont traitees", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.setUrl(REPO .. "manifest.lua", manifestWithScript(5))

	local ok, report = ccBoot.update(REPO, { [A] = 1 }, { name = SCRIPT, version = 1 })
	H.ok(ok, "succes")
	H.isNil(report.script, "script ignore")
	H.eq(fs.exists(SCRIPT), false, "rien d'ecrit")
end)

H.case("un script telecharge illisible laisse l'ancien en place", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.putFile(SCRIPT, scriptSource(1, A .. " = 1,"))
	mock.setUrl(REPO .. "manifest.lua", manifestWithScript(2))
	mock.setUrl(REPO .. SCRIPT .. ".lua", "local VERSION = 2\nfunction (")

	local ok, err = ccBoot.update(REPO, { [A] = 1 }, { name = SCRIPT, version = 1, path = SCRIPT })
	H.eq(ok, false, "refus")
	H.contains(err, SCRIPT, "script nomme")
	H.eq(mock.getFile(SCRIPT), scriptSource(1, A .. " = 1,"), "ancien script intact")
end)

H.case("update installe d'abord un ccBoot plus recent, qui reprend la main", function()
	fresh()
	mock.putFile("apis/" .. A .. ".lua", source(A, 1))
	mock.setUrl(REPO .. "manifest.lua", manifestWithScript(1, ccBoot._VERSION + 1))
	-- Le ccBoot servi est le vrai, a la version annoncee : il doit etre
	-- installe, recharge, et poursuivre la mise a jour sans boucler.
	local f = assert(io.open("apis/ccBoot.lua", "r"))
	local real = f:read("a")
	f:close()
	local served = real:gsub("_VERSION = %d+", "_VERSION = " .. (ccBoot._VERSION + 1), 1)
	mock.setUrl(REPO .. "apis/ccBoot.lua", served)

	local loaded = package.loaded.ccBoot
	local ok, report = ccBoot.update(REPO, { [A] = 1 }, { name = SCRIPT, version = 1 })
	package.loaded.ccBoot = loaded
	H.ok(ok, "succes : " .. tostring(report))
	H.eq(report.boot, ccBoot._VERSION + 1, "ccBoot mis a jour")
	H.eq(mock.getFile("apis/ccBoot.lua"), served, "ecrit sur le disque")
end)
