-- Tests de ccMenu.

local H = require("harness")
local mock = require("ccMock")
local ccUi = require("ccUi")
local ccMenu = require("ccMenu")

local function fresh()
	mock.install()
	ccUi.reset()
end

--- Menu de démonstration : deux vues, de quoi couvrir chaque type de champ.
local function spec(o)
	o = o or {}
	return {
		values = o.values or { width = 16, down = true, keep = false, trash = { "minecraft:dirt" } },
		validate = o.validate,
		views = {
			{ title = "Chantier", fields = {
				{ kind = "number", key = "width", label = "Largeur", min = 1, max = 256 },
				{ kind = "choice", key = "down", label = "Sens", options = {
					{ true, "Bas", "Creuse sous la turtle" }, { false, "Haut" } } },
				{ kind = "check", key = "keep", label = "Memoriser" },
			} },
			{ title = "Rebut", fields = {
				{ kind = "set", key = "trash", add = "+ Saisir un nom", prefix = "minecraft:",
					items = o.items or function() return { "minecraft:stone" } end },
				{ kind = "button", label = "Lancer", action = "submit" },
			} },
		},
	}
end

local function feed(menu, events)
	local result
	for _, e in ipairs(events) do
		result = menu:handle(table.unpack(e))
		menu:render()
	end
	return result
end

local function screen()
	local lines = {}
	for y = 1, 13 do lines[y] = mock.screenLine(y) end
	return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Clavier
-- ---------------------------------------------------------------------------

H.case("les chiffres remplacent la valeur puis s'y ajoutent", function()
	fresh()
	local m = ccMenu.new(spec())
	m:render()
	feed(m, { { "char", "4" }, { "char", "2" } })
	H.eq(m.values.width, 42, "saisie directe")

	-- Revenir sur le champ recommence une saisie neuve.
	feed(m, { { "key", keys.down }, { "key", keys.up }, { "char", "7" } })
	H.eq(m.values.width, 7, "nouvelle saisie")
end)

H.case("un nombre est ramene dans ses bornes en quittant le champ", function()
	fresh()
	local m = ccMenu.new(spec())
	feed(m, { { "char", "0" }, { "key", keys.down } })
	H.eq(m.values.width, 1, "minimum applique")

	feed(m, { { "key", keys.up }, { "char", "9" }, { "char", "9" }, { "char", "9" } })
	H.eq(m.values.width, 256, "maximum applique pendant la saisie")

	feed(m, { { "key", keys.left } })
	H.eq(m.values.width, 255, "gauche retire un pas")
	feed(m, { { "key", keys.backspace } })
	H.eq(m.values.width, 25, "retour arriere efface un chiffre")
end)

H.case("gauche / droite et Entree font tourner un choix", function()
	fresh()
	local m = ccMenu.new(spec())
	feed(m, { { "key", keys.down }, { "key", keys.right } })
	H.eq(m.values.down, false, "droite")
	feed(m, { { "key", keys.right } })
	H.eq(m.values.down, true, "retour au debut")
	feed(m, { { "key", keys.enter } })
	H.eq(m.values.down, false, "Entree")
end)

H.case("Entree et espace cochent une case", function()
	fresh()
	local m = ccMenu.new(spec())
	feed(m, { { "key", keys.down }, { "key", keys.down }, { "key", keys.enter } })
	H.eq(m.values.keep, true, "Entree coche")
	feed(m, { { "char", " " } })
	H.eq(m.values.keep, false, "espace decoche")
end)

H.case("Tab change de vue, Maj+Tab revient", function()
	fresh()
	local m = ccMenu.new(spec())
	feed(m, { { "key", keys.tab } })
	H.eq(m.view, 2, "vue suivante")
	feed(m, { { "key", keys.tab } })
	H.eq(m.view, 1, "boucle")
	feed(m, { { "key", keys.leftShift }, { "key", keys.tab }, { "key_up", keys.leftShift } })
	H.eq(m.view, 2, "Maj+Tab : vue precedente")
	feed(m, { { "key", keys.tab } })
	H.eq(m.view, 1, "Maj relachee : de nouveau vers l'avant")
end)

-- ---------------------------------------------------------------------------
-- Listes
-- ---------------------------------------------------------------------------

H.case("une liste propose les noms connus ET ceux deja coches", function()
	fresh()
	local m = ccMenu.new(spec())
	feed(m, { { "key", keys.tab } })
	local s = screen()
	H.contains(s, "[x] minecraft:dirt", "coche, bien qu'absent des propositions")
	H.contains(s, "[ ] minecraft:stone", "propose, non coche")
	H.contains(s, "+ Saisir un nom", "ligne de saisie")
end)

H.case("cocher puis decocher un nom de la liste", function()
	fresh()
	local m = ccMenu.new(spec())
	-- Lignes : stone, dirt, saisie, bouton. Les noms proposés passent d'abord.
	feed(m, { { "key", keys.tab }, { "key", keys.enter } })
	H.eq(table.concat(m.values.trash, ","), "minecraft:dirt,minecraft:stone", "stone coche")
	feed(m, { { "key", keys.down }, { "char", " " } })
	H.eq(table.concat(m.values.trash, ","), "minecraft:stone", "dirt decoche")
	H.contains(screen(), "[ ] minecraft:dirt", "un nom decoche reste propose")
end)

H.case("un nom saisi a la main est ajoute et coche", function()
	fresh()
	local m = ccMenu.new(spec({ items = function() return {} end }))
	feed(m, { { "key", keys.tab }, { "key", keys.down }, { "key", keys.enter } })
	H.eq(m.entry, "minecraft:", "saisie prefixee")
	for ch in ("tuff"):gmatch(".") do feed(m, { { "char", ch } }) end
	feed(m, { { "key", keys.enter } })

	H.isNil(m.entry, "saisie terminee")
	H.eq(m.values.trash[2], "minecraft:tuff", "ajoute")
	-- Décoché, il reste proposé : sinon on ne pourrait plus le recocher.
	feed(m, { { "key", keys.up }, { "key", keys.up }, { "key", keys.down }, { "char", " " } })
	H.contains(screen(), "[ ] minecraft:tuff", "toujours propose une fois decoche")
end)

H.case("une saisie sans mod: est refusee, une saisie vide annule", function()
	fresh()
	local m = ccMenu.new(spec({ items = function() return {} end }))
	feed(m, { { "key", keys.tab }, { "key", keys.down }, { "key", keys.enter } })
	for _ = 1, #"minecraft:" do feed(m, { { "key", keys.backspace } }) end
	for ch in ("tuff"):gmatch(".") do feed(m, { { "char", ch } }) end
	feed(m, { { "key", keys.enter } })
	H.eq(#m.values.trash, 1, "rien d'ajoute")
	H.contains(screen(), "mod:nom", "raison affichee")

	feed(m, { { "key", keys.enter }, { "key", keys.enter } })
	H.eq(#m.values.trash, 1, "prefixe seul : annule")
end)

H.case("une longue liste defile avec le champ actif", function()
	fresh()
	local many = {}
	for i = 1, 20 do many[i] = ("mod:bloc%02d"):format(i) end
	local m = ccMenu.new(spec({ items = function() return many end }))
	feed(m, { { "key", keys.tab } })
	for _ = 1, 15 do feed(m, { { "key", keys.down } }) end
	local s = screen()
	H.contains(s, "mod:bloc16", "le champ actif est visible")
	H.eq(s:find("mod:bloc01", 1, true), nil, "le debut a defile")
	H.contains(s, "^", "indicateur de defilement")
end)

-- ---------------------------------------------------------------------------
-- Validation et sortie
-- ---------------------------------------------------------------------------

H.case("le bouton valide, sauf si validate refuse", function()
	fresh()
	local refuse = true
	local m = ccMenu.new(spec({ validate = function() return refuse and "Pas encore" or nil end }))
	local go = { { "key", keys.tab }, { "key", keys.down }, { "key", keys.down },
		{ "key", keys.down }, { "key", keys.enter } }
	H.isNil(feed(m, go), "refus")
	H.contains(screen(), "Pas encore", "raison affichee")

	refuse = false
	H.eq(feed(m, { { "key", keys.enter } }), "submit", "validation")
end)

H.case("run renvoie les valeurs, ou nil sur Ctrl+T", function()
	fresh()
	os.queueEvent("char", "8")
	os.queueEvent("key", keys.tab)
	os.queueEvent("key", keys.down)
	os.queueEvent("key", keys.down)
	os.queueEvent("key", keys.down)
	os.queueEvent("key", keys.enter)
	local v = ccMenu.new(spec()):run()
	H.eq(v.width, 8, "valeurs rendues")

	os.queueEvent("terminate")
	H.isNil(ccMenu.new(spec()):run(), "abandon")
end)

-- ---------------------------------------------------------------------------
-- Écran
-- ---------------------------------------------------------------------------

H.case("le champ actif est marque en marge, utile en noir et blanc", function()
	fresh()
	mock.setColour(false)
	local m = ccMenu.new(spec())
	m:render()
	H.eq(mock.screenLine(3):sub(1, 1), ">", "marque sur le premier champ")
	H.contains(mock.screenLine(3), "Largeur", "libelle")
	H.contains(mock.screenLine(3), "16", "valeur")
	H.contains(mock.screenLine(13), "Tab:vue", "aide clavier")
	feed(m, { { "key", keys.down } })
	H.eq(mock.screenLine(3):sub(1, 1), " ", "la marque suit le champ")
	H.eq(mock.screenLine(4):sub(1, 1), ">", "sur le deuxieme")
	H.contains(mock.screenLine(12), "Creuse sous la turtle", "aide de l'option")
end)

H.case("la souris change d'onglet et actionne les fleches", function()
	fresh()
	local m = ccMenu.new(spec())
	m:render()
	-- « Rebut » commence apres « Chantier » : colonnes 11 a 17.
	feed(m, { { "mouse_click", 1, 12, 1 } })
	H.eq(m.view, 2, "clic sur l'onglet")

	feed(m, { { "mouse_click", 1, 3, 1 } })
	H.eq(m.view, 1, "retour")
	local line = mock.screenLine(3)
	local right = line:find(">", 2, true)
	feed(m, { { "mouse_click", 1, right, 3 } })
	H.eq(m.values.width, 17, "fleche droite")
	local left = mock.screenLine(3):find("<", 1, true)
	feed(m, { { "mouse_click", 1, left, 3 }, { "mouse_click", 1, left, 3 } })
	H.eq(m.values.width, 15, "fleche gauche")
end)
