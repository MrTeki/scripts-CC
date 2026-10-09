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

-- ---------------------------------------------------------------------------
-- Version 2 : couleurs, jauges, boutons en blocs, journal défilant
-- ---------------------------------------------------------------------------

--- Faux terminal qui retient, pour chaque case, le caractère et ses couleurs.
local function canvas(color, w, h)
	w, h = w or 39, h or 13
	local t = { cells = {} }
	local x, y, fg, bg = 1, 1, colors.white, colors.black
	local function row(r) t.cells[r] = t.cells[r] or {} return t.cells[r] end
	function t.getSize() return w, h end
	function t.isColour() return color end
	t.isColor = t.isColour
	function t.setCursorPos(nx, ny) x, y = nx, ny end
	function t.getCursorPos() return x, y end
	function t.setTextColour(c) fg = c end
	function t.setBackgroundColour(c) bg = c end
	t.setTextColor, t.setBackgroundColor = t.setTextColour, t.setBackgroundColour
	function t.setCursorBlink() end
	function t.clear() t.cells = {} end
	function t.clearLine() t.cells[y] = {} end
	function t.write(s)
		for i = 1, #s do
			if x >= 1 and x <= w then row(y)[x] = { ch = s:sub(i, i), fg = fg, bg = bg } end
			x = x + 1
		end
	end
	--- Texte d'une ligne, espaces de fin retirés.
	function t.text(r)
		local out = {}
		for i = 1, w do out[i] = (t.cells[r] and t.cells[r][i] or {}).ch or " " end
		return (table.concat(out):gsub("%s+$", ""))
	end
	function t.cell(cx, cy) return t.cells[cy] and t.cells[cy][cx] or {} end
	return t
end

local function onCanvas(color, o)
	mock.install()
	ccUi.reset(o)
	local t = canvas(color)
	ccUi.attach(t)
	return t
end

H.case("v2 : un écran noir et blanc rend un bloc coloré en négatif", function()
	-- Une turtle normale n'a que le noir et le blanc : un fond vert y devient
	-- blanc, et le texte prend la couleur opposée pour rester lisible.
	local t = onCanvas(false)
	ccUi.write(1, 1, "AB", colors.black, colors.green)
	H.eq(t.cell(1, 1).bg, colors.white, "fond blanc")
	H.eq(t.cell(1, 1).fg, colors.black, "texte noir")

	ccUi.write(1, 2, "CD", colors.yellow)
	H.eq(t.cell(1, 2).bg, colors.black, "fond noir conservé")
	H.eq(t.cell(1, 2).fg, colors.white, "texte blanc")
end)

H.case("v2 : write coupe au bord droit", function()
	local t = onCanvas(true)
	ccUi.write(37, 1, "ABCDEF")
	H.eq(t.text(1):sub(37), "ABC", "trois caractères tiennent")
end)

H.case("v2 : le bandeau porte un texte à gauche et un à droite", function()
	local t = onCanvas(true)
	ccUi.banner(1, "FERME", "ABATTAGE", colors.green)
	H.eq(t.text(1):sub(2, 6), "FERME", "à gauche")
	H.eq(t.text(1):sub(-8), "ABATTAGE", "à droite")
	H.eq(t.cell(20, 1).bg, colors.green, "fond sur toute la largeur")
end)

H.case("v2 : une jauge remplit à proportion, texte à droite", function()
	local t = onCanvas(true)
	ccUi.gauge({ y = 2, label = "Fuel", current = 50, max = 100, text = "50/100", color = colors.lime })
	local filled, empty = 0, 0
	for x = 1, 39 do
		local c = t.cell(x, 2)
		if c.bg == colors.lime then filled = filled + 1 elseif c.bg == colors.gray then empty = empty + 1 end
	end
	H.ok(filled > 0 and math.abs(filled - empty) <= 1, ("moitié pleine : %d / %d"):format(filled, empty))
	H.eq(t.text(2):sub(-6), "50/100", "texte à droite")
	H.eq(t.text(2):sub(2, 5), "Fuel", "libellé à gauche")
end)

H.case("v2 : en noir et blanc, le vide d'une jauge est un damier", function()
	local t = onCanvas(false)
	ccUi.gauge({ y = 2, label = "Fuel", current = 0, max = 100, text = "0" })
	H.ok(t.text(2):find("\127", 1, true), "damier présent")
end)

H.case("v2 : une jauge supporte un maximum nul et un dépassement", function()
	onCanvas(true)
	ccUi.gauge({ y = 2, label = "A", current = 5, max = 0, text = "" })
	ccUi.gauge({ y = 3, label = "B", current = 500, max = 100, text = "" })
end)

H.case("v2 : boutons en blocs répartis sur la ligne, clic dans la marge compris", function()
	local t = onCanvas(true)
	ccUi.addButton({ label = "OPTIONS", y = 13, cmd = "options", bg = colors.lightBlue, row = true })
	ccUi.addButton({ label = "PAUSE", y = 13, cmd = "pause", bg = colors.yellow, row = true })
	ccUi.addButton({ label = "STOP", y = 13, cmd = "abort", bg = colors.red, row = true })
	ccUi.drawButtons()

	local line = t.text(13)
	local o, p, s = line:find("OPTIONS", 1, true), line:find("PAUSE", 1, true), line:find("STOP", 1, true)
	H.ok(o and p and s and o < p and p < s, "dans l'ordre : " .. line)
	H.ok(o > 2 and #line < 39, "marges à gauche et à droite : " .. line)
	H.eq(t.cell(o - 1, 13).bg, colors.lightBlue, "le bloc déborde d'une case à gauche")

	H.eq(ccUi.dispatch("mouse_click", 1, o - 1, 13), "options", "clic dans la marge")
	H.eq(ccUi.dispatch("mouse_click", 1, s + 3, 13), "abort", "clic sur STOP")
	H.isNil(ccUi.dispatch("mouse_click", 1, s + 5, 13), "hors du bloc")
end)

H.case("v2 : en noir et blanc, la touche d'un bouton en bloc est en négatif", function()
	local t = onCanvas(false)
	ccUi.addButton({ label = "PAUSE", y = 13, x = 1, cmd = "pause", bg = colors.yellow })
	ccUi.drawButtons()
	H.eq(t.cell(2, 13).ch, "P", "la touche")
	H.eq(t.cell(2, 13).bg, colors.black, "en négatif")
	H.eq(t.cell(3, 13).bg, colors.white, "le reste du bloc en blanc")
end)

H.case("v2 : setButton modifie un bouton par sa commande", function()
	local t = onCanvas(true)
	ccUi.addButton({ label = "STOP", y = 13, x = 1, cmd = "abort", bg = colors.red })
	ccUi.setButton("abort", { label = "STOP ?" })
	ccUi.drawButtons()
	H.eq(t.text(13), " STOP ?", "libellé changé")
	H.eq(ccUi.dispatch("char", "s"), "abort", "la touche reste")
end)

H.case("v2 : le journal colore selon la gravité, à la position voulue", function()
	local t = onCanvas(true, { logLines = 3, logTop = 7 })
	ccUi.log("normal")
	ccUi.log("attention", "warn")
	ccUi.log("panne", "error")
	H.eq(t.text(7), "normal", "première ligne de la zone")
	H.eq(t.cell(1, 8).fg, colors.yellow, "avertissement en jaune")
	H.eq(t.cell(1, 9).fg, colors.red, "erreur en rouge")
end)

H.case("v2 : la molette fait défiler le journal, et seulement sur lui", function()
	local t = onCanvas(true, { logLines = 2, logTop = 7, logKeep = 10 })
	for i = 1, 5 do ccUi.log("m" .. i) end
	H.eq(t.text(8), "m5", "les plus récents")

	H.isNil(ccUi.dispatch("mouse_scroll", -1, 5, 7), "aucune commande")
	ccUi.drawLog()
	H.eq(t.text(8), "m4", "un cran plus haut")

	ccUi.dispatch("mouse_scroll", -1, 5, 2)
	ccUi.drawLog()
	H.eq(t.text(8), "m4", "hors du journal : rien ne bouge")

	ccUi.log("m6")
	H.eq(t.text(8), "m4", "un nouveau message ne déplace pas la vue")

	for _ = 1, 10 do ccUi.dispatch("mouse_scroll", 1, 5, 7) end
	ccUi.drawLog()
	H.eq(t.text(8), "m6", "redescendu jusqu'au plus récent")
end)

H.case("v2 : sans API window, le double tampon s'efface sans rien casser", function()
	onCanvas(true)
	H.eq(ccUi.buffered(), false, "pas de tampon hors jeu")
	local ran = false
	ccUi.frame(function() ran = true end)
	H.ok(ran, "frame exécute quand même")
end)
