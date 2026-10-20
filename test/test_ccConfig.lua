-- Tests de ccConfig.

local H = require("harness")
local mock = require("ccMock")
local ccConfig = require("ccConfig")

local PATH = "test.cfg"

local DEFAULTS = {
	dropWhenNoChest = false,
	trashWhere = "up",
	fuelMargin = 64,
	trash = { "minecraft:cobblestone", "minecraft:dirt" },
}

local TEMPLATE = "-- commentaire d'origine\nreturn {\n  fuelMargin = 64,\n}\n"

local function fresh() mock.install() end

-- ---------------------------------------------------------------------------
-- Création
-- ---------------------------------------------------------------------------

H.case("le gabarit est ecrit a la creation, avec ses commentaires", function()
	fresh()
	local config, warnings, created = ccConfig.load(PATH, DEFAULTS, TEMPLATE)

	H.eq(created, true, "cree")
	H.eq(#warnings, 0, "aucun avertissement")
	H.eq(mock.getFile(PATH), TEMPLATE, "gabarit ecrit tel quel")
	H.eq(config.fuelMargin, 64, "valeur du gabarit")
end)

H.case("le fichier n'est jamais reecrit ensuite", function()
	-- Une serialisation automatique detruirait les commentaires et la mise en
	-- forme de l'utilisateur a chaque lancement.
	fresh()
	ccConfig.load(PATH, DEFAULTS, TEMPLATE)
	mock.putFile(PATH, "-- mes notes a moi\nreturn { fuelMargin = 200 }\n")

	local config, _, created = ccConfig.load(PATH, DEFAULTS, TEMPLATE)
	H.eq(created, false, "pas recree")
	H.eq(config.fuelMargin, 200, "valeur de l'utilisateur")
	H.contains(mock.getFile(PATH), "mes notes a moi", "commentaires preserves")
end)

H.case("sans gabarit, aucun fichier n'est cree", function()
	fresh()
	local config = ccConfig.load(PATH, DEFAULTS)
	H.eq(fs.exists(PATH), false, "aucun fichier")
	H.eq(config.fuelMargin, 64, "valeurs par defaut")
end)

-- ---------------------------------------------------------------------------
-- Fusion
-- ---------------------------------------------------------------------------

H.case("les options saisies remplacent les defauts, une par une", function()
	fresh()
	mock.putFile(PATH, "return { dropWhenNoChest = true, fuelMargin = 500 }")

	local config = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.dropWhenNoChest, true, "remplacee")
	H.eq(config.fuelMargin, 500, "remplacee")
	H.eq(config.trashWhere, "up", "non citee : defaut conserve")
	H.eq(#config.trash, 2, "non citee : defaut conserve")
end)

H.case("une liste vide est respectee, pas remplacee par le defaut", function()
	-- Vider la liste de rebut est un choix legitime : tout conserver.
	fresh()
	mock.putFile(PATH, "return { trash = {} }")

	local config = ccConfig.load(PATH, DEFAULTS)
	H.eq(#config.trash, 0, "liste vide respectee")
end)

H.case("les defauts de type table ne sont pas partages", function()
	fresh()
	local a = ccConfig.load(PATH, DEFAULTS)
	table.insert(a.trash, "minecraft:sand")

	local b = ccConfig.load(PATH, DEFAULTS)
	H.eq(#b.trash, 2, "second chargement intact")
	H.eq(#DEFAULTS.trash, 2, "table des defauts intacte")
end)

-- ---------------------------------------------------------------------------
-- Saisie fautive
-- ---------------------------------------------------------------------------

H.case("un mauvais type est signale et le defaut conserve", function()
	fresh()
	mock.putFile(PATH, "return { dropWhenNoChest = 'oui', fuelMargin = 500 }")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.dropWhenNoChest, false, "defaut conserve")
	H.eq(config.fuelMargin, 500, "les options valides passent quand meme")
	H.eq(#warnings, 1, "un avertissement")
	H.contains(warnings[1], "dropWhenNoChest", "option nommee")
	H.contains(warnings[1], "boolean", "type attendu")
end)

H.case("une option inconnue est signalee, sans rien casser", function()
	fresh()
	mock.putFile(PATH, "return { fuelMagrin = 500 }")     -- faute de frappe

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.fuelMargin, 64, "defaut conserve")
	H.eq(#warnings, 1, "un avertissement")
	H.contains(warnings[1], "fuelMagrin", "la faute est nommee")
end)

H.case("un fichier illisible ne bloque pas le script", function()
	fresh()
	mock.putFile(PATH, "return { ceci n'est pas du Lua")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.fuelMargin, 64, "valeurs par defaut")
	H.eq(#warnings, 1, "un avertissement")
	H.contains(warnings[1], "illisible", "raison")
end)

H.case("un fichier qui ne renvoie pas de table est refuse", function()
	fresh()
	mock.putFile(PATH, "return 42")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.fuelMargin, 64, "valeurs par defaut")
	H.contains(warnings[1], "table", "raison")
end)

H.case("le fichier est evalue sans acces aux globales", function()
	-- C'est un fichier de donnees : il n'a pas a pouvoir agir sur l'ordinateur.
	fresh()
	mock.putFile(PATH, "fs.delete('apis') return { fuelMargin = 1 }")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(config.fuelMargin, 64, "valeurs par defaut")
	H.eq(#warnings, 1, "refuse")
end)

-- ---------------------------------------------------------------------------
-- Écriture
-- ---------------------------------------------------------------------------

local EDITED = table.concat({
	"-- en-tete",
	"return {",
	"    -- marge de retour",
	"    fuelMargin = 64,  -- en blocs",
	"",
	"    trash = {",
	"        \"minecraft:cobblestone\",",
	"    },",
	"}",
	"",
}, "\n")

H.case("set remplace les valeurs a leur place, commentaires compris", function()
	fresh()
	mock.putFile(PATH, EDITED)
	H.ok(ccConfig.set(PATH, { fuelMargin = 128, trash = { "a:b", "c:d" } }), "ecrit")

	local text = mock.getFile(PATH)
	H.contains(text, "-- en-tete", "en-tete conserve")
	H.contains(text, "-- marge de retour", "commentaire conserve")
	H.contains(text, "fuelMargin = 128,  -- en blocs", "valeur remplacee, fin de ligne intacte")
	H.eq(text:find("cobblestone", 1, true), nil, "ancienne liste remplacee")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(#warnings, 0, "toujours lisible")
	H.eq(config.fuelMargin, 128, "nombre relu")
	H.eq(table.concat(config.trash, ","), "a:b,c:d", "liste relue")
end)

H.case("set ajoute une option absente avant l'accolade finale", function()
	fresh()
	mock.putFile(PATH, EDITED)
	H.ok(ccConfig.set(PATH, { dropWhenNoChest = true, trashWhere = "down" }), "ecrit")

	local config, warnings = ccConfig.load(PATH, DEFAULTS)
	H.eq(#warnings, 0, "toujours lisible")
	H.eq(config.dropWhenNoChest, true, "booleen ajoute")
	H.eq(config.trashWhere, "down", "chaine ajoutee")
	H.eq(config.fuelMargin, 64, "le reste intact")
end)

H.case("set ignore la cle quand elle n'apparait qu'en commentaire", function()
	fresh()
	mock.putFile(PATH, "-- fuelMargin = 1 dans un commentaire\nreturn {\n  fuelMargin = 64,\n}\n")
	ccConfig.set(PATH, { fuelMargin = 9 })

	local text = mock.getFile(PATH)
	H.contains(text, "-- fuelMargin = 1 dans un commentaire", "commentaire intact")
	H.eq(ccConfig.load(PATH, DEFAULTS).fuelMargin, 9, "la vraie option est modifiee")
end)

H.case("set cree le fichier s'il n'existe pas", function()
	fresh()
	H.ok(ccConfig.set(PATH, { fuelMargin = 5 }), "ecrit")
	H.eq(ccConfig.load(PATH, DEFAULTS).fuelMargin, 5, "relu")
end)

H.case("serialize : chaines echappees, tables a cles sur une ligne", function()
	H.eq(ccConfig.serialize('a "b"'), '"a \\"b\\""', "chaine")
	H.eq(ccConfig.serialize({ width = 2, down = true }), "{ down = true, width = 2 }", "table a cles")
	H.eq(ccConfig.serialize({}), "{}", "table vide")
end)
