-- Tests de ccUi.

local H = require("harness")
local mock = require("ccMock")
local ccUi = require("ccUi")

local function fresh(o)
	mock.install()
	ccUi.reset(o)
end

-- ---------------------------------------------------------------------------
-- Dessin
-- ---------------------------------------------------------------------------

H.case("line écrit et efface le reste de la ligne", function()
	fresh()
	ccUi.line(3, "Blocs restants : 1250")
	H.eq(mock.screenLine(3), "Blocs restants : 1250", "écriture")

	ccUi.line(3, "court")
	H.eq(mock.screenLine(3), "court", "l'ancien contenu est effacé")
end)

H.case("size est relue à chaque appel", function()
	fresh()
	local w, h = ccUi.size()
	H.eq(w, 39, "largeur turtle")
	H.eq(h, 13, "hauteur turtle")

	-- ccQuarry capturait sizeX/sizeY une seule fois, au chargement.
	mock.install()
	mock.reset({ termWidth = 51, termHeight = 19 })
	w, h = ccUi.size()
	H.eq(w, 51, "nouvelle largeur")
	H.eq(h, 19, "nouvelle hauteur")
end)

H.case("bar remplit proportionnellement et centre le label", function()
	fresh()
	ccUi.bar({ x1 = 1, x2 = 20, y = 2, colorFull = colors.lime,
		colorEmpty = colors.gray, max = 100, current = 50, label = "Fuel" })

	local ligne = mock.screenLine(2)
	H.contains(ligne, "Fuel 50/100", "label présent")
end)

H.case("bar supporte un maximum nul sans division par zéro", function()
	fresh()
	ccUi.bar({ x1 = 1, x2 = 10, y = 1, colorFull = colors.lime,
		colorEmpty = colors.gray, max = 0, current = 0, label = "" })
	H.ok(true, "aucune erreur")
end)

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

H.case("log écrit en bas de l'écran", function()
	fresh()
	ccUi.log("Vidage ...")
	H.eq(mock.screenLine(13), "Vidage ...", "dernière ligne")
end)

H.case("un message répété est compté au lieu d'être empilé", function()
	fresh({ logLines = 3 })
	ccUi.log("Creuse")
	ccUi.log("Creuse")
	ccUi.log("Creuse")

	local buf = ccUi.logBuffer()
	H.eq(#buf, 1, "une seule entrée")
	H.eq(buf[1], "Creuse 2", "compteur")
end)

H.case("le journal fait défiler au-delà de sa hauteur", function()
	fresh({ logLines = 2 })
	ccUi.log("un")
	ccUi.log("deux")
	ccUi.log("trois")

	local buf = ccUi.logBuffer()
	H.eq(#buf, 2, "hauteur respectée")
	H.eq(buf[1], "deux", "le plus ancien est sorti")
	H.eq(buf[2], "trois", "le plus récent")
end)

-- ---------------------------------------------------------------------------
-- Boutons
-- ---------------------------------------------------------------------------

H.case("les boutons sont alignés à droite par défaut", function()
	fresh()
	ccUi.addButton({ label = "REFUEL", y = 1, cmd = "refuel" })
	ccUi.drawButtons()

	-- Largeur 39, label de 6 caractères : colonnes 34 à 39.
	H.eq(mock.screenLine(1):sub(34, 39), "REFUEL", "position")
end)

H.case("dispatch traduit un clic en commande, sans rien exécuter", function()
	fresh()
	ccUi.addButton({ label = "REFUEL", y = 1, cmd = "refuel" })
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })

	H.eq(ccUi.dispatch("mouse_click", 1, 36, 1), "refuel", "clic sur REFUEL")
	H.eq(ccUi.dispatch("mouse_click", 1, 36, 2), "pause", "clic sur PAUSE")
	H.isNil(ccUi.dispatch("mouse_click", 1, 5, 1), "clic à côté")
	H.isNil(ccUi.dispatch("mouse_click", 1, 36, 7), "clic sur une ligne vide")
end)

H.case("dispatch accepte le clavier, insensible à la casse", function()
	fresh()
	ccUi.addButton({ label = "REFUEL", y = 1, cmd = "refuel" })
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })

	H.eq(ccUi.dispatch("char", "r"), "refuel", "minuscule")
	H.eq(ccUi.dispatch("char", "R"), "refuel", "majuscule")
	H.eq(ccUi.dispatch("char", "p"), "pause", "pause")
	H.isNil(ccUi.dispatch("char", "z"), "touche inconnue")
end)

H.case("dispatch accepte le tactile d'un moniteur", function()
	fresh()
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	H.eq(ccUi.dispatch("monitor_touch", "right", 36, 2), "pause", "tactile")
end)

H.case("dispatch ignore les événements sans rapport", function()
	fresh()
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	H.isNil(ccUi.dispatch("turtle_inventory"), "événement turtle")
	H.isNil(ccUi.dispatch("timer", 3), "minuteur")
end)

H.case("une touche explicite prime sur la première lettre", function()
	fresh()
	ccUi.addButton({ label = "STOP", y = 3, cmd = "abort", key = "x" })
	H.eq(ccUi.dispatch("char", "x"), "abort", "touche explicite")
	H.isNil(ccUi.dispatch("char", "s"), "première lettre inactive")
end)

H.case("les boutons suivent le redimensionnement", function()
	fresh()
	ccUi.addButton({ label = "PAUSE", y = 2, cmd = "pause" })
	H.eq(ccUi.dispatch("mouse_click", 1, 35, 2), "pause", "à droite en 39 colonnes")

	mock.reset({ termWidth = 51, termHeight = 19 })
	H.isNil(ccUi.dispatch("mouse_click", 1, 35, 2), "l'ancienne position ne répond plus")
	H.eq(ccUi.dispatch("mouse_click", 1, 47, 2), "pause", "nouvelle position")
end)

-- ---------------------------------------------------------------------------
-- Cible
-- ---------------------------------------------------------------------------

H.case("useMonitor bascule sur un moniteur branché", function()
	fresh()
	H.eq(ccUi.useMonitor(), false, "aucun moniteur")

	local ecrit = {}
	mock.addPeripheral("right", "monitor", {
		getSize = function() return 29, 12 end,
		setCursorPos = function() end,
		clearLine = function() end,
		setBackgroundColour = function() end,
		setTextColour = function() end,
		write = function(s) ecrit[#ecrit + 1] = s end,
	})

	H.eq(ccUi.useMonitor(), true, "moniteur trouvé")
	local w = ccUi.size()
	H.eq(w, 29, "taille du moniteur")

	ccUi.line(1, "carriere")
	H.eq(ecrit[1], "carriere", "écrit sur le moniteur")
end)
