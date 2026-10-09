-- ccUi : affichage et saisie.
--
-- Remplace logMsg / msg, dupliqués à l'identique dans ccStairs, ccFarm et
-- ccRemote, pmsg dans ccChopper et ccQuarry, et drawBar dans ccRemote et
-- ccInventory.
--
-- drawBar illustre le coût de cette duplication : la version de ccInventory a
-- reçu le centrage du label et l'inversion de la couleur de texte ; celle de
-- ccRemote ne les a jamais eus. C'est la version évoluée qui est reprise ici.
--
-- RÈGLE STRUCTURANTE : ce module ne touche JAMAIS au turtle. Il dessine et il
-- interprète les événements, rien d'autre. dispatch() renvoie un nom de
-- commande, à charge de la machine à états de l'exécuter entre deux
-- transitions.
--
-- C'est la correction de la course de ccQuarry : catchTermEvents appelait
-- Refuel() directement depuis la coroutine d'affichage, pendant que mainLoop
-- pouvait être au milieu d'un vidage. Les appels turtle rendent la main en
-- attendant leur réponse, donc un turtle.select() de l'UI pouvait changer le
-- slot sous un turtle.drop() en vol.
--
-- Les tailles sont relues à chaque appel plutôt que capturées une fois, ce qui
-- règle au passage l'absence de gestion du redimensionnement.

local ccUtil = require("ccUtil")

local M = { _VERSION = 2 }

local DEFAULTS = {
	logLines = 1,       -- hauteur de la zone de journal
	logTop = nil,       -- première ligne du journal ; nil = en bas de l'écran
	logKeep = nil,      -- messages conservés pour le défilement ; nil = logLines
	logX = 1,           -- colonne où commencent les messages
	textColor = nil,    -- nil = colors.white à l'exécution
	background = nil,   -- nil = colors.black
}

local target, buttons, logBuf, logLevels, logOffset, lastMsg, lastCount, config
local bufferWin, bufferParent

--- Cible de dessin, résolue paresseusement : le terminal n'existe pas
--- forcément au chargement du module.
local function out()
	if not target then target = term.current() end
	return target
end

-- ---------------------------------------------------------------------------
-- Cible et configuration
-- ---------------------------------------------------------------------------

function M.reset(o)
	target = o and o.target or nil
	bufferWin, bufferParent = nil, nil
	buttons = {}
	logBuf, logLevels, logOffset = {}, {}, 0
	lastMsg, lastCount = nil, 0
	config = {}
	for k, v in pairs(DEFAULTS) do config[k] = v end
	for k, v in pairs(o or {}) do config[k] = v end
end

function M.configure(o)
	for k, v in pairs(o or {}) do config[k] = v end
end

--- Bascule sur un moniteur externe s'il en existe un, sinon reste sur le terminal.
-- ccQuarry nommait sa cible « monitor » tout en utilisant term.current() : un
-- vrai moniteur branché n'était jamais utilisé.
-- @return true si un moniteur a été trouvé
function M.useMonitor()
	local side, api = ccUtil.findPeripheral("monitor")
	if not side then return false end
	target, bufferWin, bufferParent = api, nil, nil
	return true
end

function M.attach(t) target, bufferWin, bufferParent = t, nil, nil end
function M.target() return out() end

--- Taille courante. Relue à chaque appel : un redimensionnement est pris en
-- compte sans rien recalculer ailleurs.
function M.size() return out().getSize() end

-- ---------------------------------------------------------------------------
-- Dessin
-- ---------------------------------------------------------------------------

local function colorText() return config.textColor or colors.white end
local function colorBg() return config.background or colors.black end

local function normal()
	out().setBackgroundColour(colorBg())
	out().setTextColour(colorText())
end

function M.clear()
	normal()
	out().clear()
	out().setCursorPos(1, 1)
end

--- Écrit une ligne entière, en effaçant ce qui s'y trouvait.
function M.line(y, text)
	normal()
	out().setCursorPos(1, y)
	out().clearLine()
	out().write(tostring(text))
end

--- Barre de progression. Reprise de la version de ccInventory : label centré,
-- couleur de texte inversée selon le remplissage.
-- @param spec { x1, x2, y, colorFull, colorEmpty, max, current, label }
function M.bar(spec)
	local x1, x2, y = spec.x1, spec.x2, spec.y
	local span = x2 - x1 + 1
	local denom = (spec.max == nil or spec.max == 0) and 1 or spec.max

	local label = (spec.label or "") .. " " .. spec.current .. "/" .. spec.max
	while (span - #label) / 2 >= 1 do
		label = " " .. label .. " "
	end

	local length = span * (spec.current / denom)
	for i = x1, x2 do
		out().setCursorPos(i, y)
		if i - x1 + 1 <= length then
			out().setBackgroundColour(spec.colorFull)
			out().setTextColour(spec.colorEmpty)
		else
			out().setBackgroundColour(spec.colorEmpty)
			out().setTextColour(spec.colorFull)
		end
		local ch = label:sub(i - x1 + 1, i - x1 + 1)
		out().write(ch == "" and " " or ch)
	end
	normal()
end

-- ---------------------------------------------------------------------------
-- Couleurs
-- ---------------------------------------------------------------------------
-- Une turtle avancée a 16 couleurs, une turtle normale le noir et le blanc
-- seulement. Tout ce qui suit dessine en couleur quand l'écran le permet, et
-- se replie sinon sur une règle simple : un fond qui n'est pas noir devient
-- blanc, et le texte prend toujours la couleur opposée à son fond. Un bloc
-- coloré devient ainsi un bloc en négatif, lisible sur les deux écrans.

--- L'écran courant affiche-t-il les couleurs ?
function M.isColor()
	local t = out()
	local f = t.isColour or t.isColor
	if not f then return false end
	local ok, res = pcall(f)
	return ok and res == true
end

--- Écrit `text` en (x, y), avec ses couleurs, sans rien effacer d'autre.
-- Le texte est coupé au bord droit de l'écran.
function M.write(x, y, text, fg, bg)
	local w = M.size()
	text = tostring(text)
	if x > w then return end
	if x + #text - 1 > w then text = text:sub(1, w - x + 1) end

	if not M.isColor() then
		local light = bg ~= nil and bg ~= colors.black
		bg = light and colors.white or colors.black
		fg = light and colors.black or colors.white
	end

	local t = out()
	t.setCursorPos(x, y)
	t.setBackgroundColour(bg or colorBg())
	t.setTextColour(fg or colorText())
	t.write(text)
	normal()
end

--- Efface une ligne entière, dans une couleur de fond.
function M.fill(y, bg)
	local w = M.size()
	M.write(1, y, string.rep(" ", w), nil, bg)
end

--- Bandeau sur toute la largeur : un texte à gauche, un autre à droite.
-- Texte noir sur le fond donné ; en négatif sur un écran noir et blanc.
function M.banner(y, left, right, bg)
	local w = M.size()
	bg = bg or colors.gray
	M.fill(y, bg)
	right = right or ""
	if #right > 0 then M.write(math.max(1, w - #right), y, right, colors.black, bg) end
	local room = w - #right - 3
	M.write(2, y, tostring(left or ""):sub(1, math.max(0, room)), colors.black, bg)
end

-- Caractère de la police de CC : un trait horizontal au milieu de la case
-- (bloc 2x3 dont seule la rangée du milieu est allumée).
local RULE_CHAR = "\140"
-- Damier : la partie vide d'une jauge sur un écran noir et blanc.
local EMPTY_CHAR = "\127"

--- Trait de séparation sur toute la largeur.
function M.rule(y, color)
	local w = M.size()
	M.write(1, y, string.rep(RULE_CHAR, w), color or colors.gray)
end

--- Jauge horizontale : libellé à gauche, barre, texte à droite.
-- En couleur, la barre est un aplat ; en noir et blanc, le plein est en
-- négatif et le vide en damier.
-- @param spec { y, label, labelWidth, current, max, text, textWidth, color }
function M.gauge(spec)
	local w = M.size()
	local y = spec.y
	local label = spec.label or ""
	local labelWidth = math.max(spec.labelWidth or 0, #label)
	local text = spec.text or ""
	local textWidth = math.max(spec.textWidth or 0, #text)

	M.fill(y)
	M.write(2, y, label)

	local x1 = 2 + labelWidth + 1
	local x2 = w - textWidth - 2
	local span = x2 - x1 + 1
	if span > 0 then
		local max = (spec.max and spec.max > 0) and spec.max or 1
		local ratio = math.max(0, math.min(1, (spec.current or 0) / max))
		local full = math.floor(ratio * span + 0.5)
		if M.isColor() then
			M.write(x1, y, string.rep(" ", full), nil, spec.color or colors.lime)
			M.write(x1 + full, y, string.rep(" ", span - full), nil, colors.gray)
		else
			M.write(x1, y, string.rep(" ", full), nil, colors.white)
			M.write(x1 + full, y, string.rep(EMPTY_CHAR, span - full))
		end
	end
	M.write(w - textWidth, y, string.rep(" ", textWidth - #text) .. text)
end

-- ---------------------------------------------------------------------------
-- Double tampon
-- ---------------------------------------------------------------------------
-- Redessiner un écran ligne à ligne le fait scintiller : chaque ligne est
-- effacée puis réécrite sous les yeux du joueur. On dessine donc dans une
-- fenêtre invisible (API window), puis on l'affiche d'un coup.

--- Dessine désormais dans un tampon. Sans API window -- hors jeu --, ne fait
--- rien et le dessin reste direct.
-- @return true si le tampon est en place
function M.buffered()
	if bufferWin then return true end
	if type(window) ~= "table" or not window.create then return false end
	bufferParent = out()
	local w, h = bufferParent.getSize()
	bufferWin = window.create(bufferParent, 1, 1, w, h, true)
	target = bufferWin
	return true
end

--- Exécute `fn` comme une image complète : rien n'apparaît avant la fin.
function M.frame(fn)
	if bufferWin then
		local w, h = bufferParent.getSize()
		local bw, bh = bufferWin.getSize()
		if w ~= bw or h ~= bh then bufferWin.reposition(1, 1, w, h) end
		bufferWin.setVisible(false)
	end
	local ok, err = pcall(fn)
	if bufferWin then bufferWin.setVisible(true) end
	if not ok then error(err, 0) end
end

-- ---------------------------------------------------------------------------
-- Journal
-- ---------------------------------------------------------------------------

-- Couleur d'un message selon sa gravité.
local LEVEL_COLORS = { ok = "lime", warn = "yellow", error = "red", dim = "lightGray" }

local function keep() return math.max(config.logLines, config.logKeep or 0) end

--- Ajoute un message au journal et le redessine.
-- Un message identique au précédent n'ajoute pas de ligne : il est suffixé
-- d'un compteur, comme dans ccChopper et ccStairs.
-- @param level  nil (normal), "ok", "warn", "error" ou "dim"
function M.log(msg, level)
	msg = tostring(msg)
	if msg == lastMsg then
		lastCount = lastCount + 1
		logBuf[#logBuf] = msg .. " " .. lastCount
	else
		lastMsg, lastCount = msg, 0
		logBuf[#logBuf + 1] = msg
		logLevels[#logBuf] = level
		-- Un journal qu'on fait défiler ne doit pas bouger sous les yeux :
		-- la vue reste sur les mêmes messages.
		if logOffset > 0 then logOffset = logOffset + 1 end
		while #logBuf > keep() do
			table.remove(logBuf, 1)
			table.remove(logLevels, 1)
		end
		logOffset = math.min(logOffset, math.max(0, #logBuf - config.logLines))
	end
	M.drawLog()
end

--- Première ligne de la zone de journal.
local function logTop()
	local _, height = M.size()
	return config.logTop or (height - config.logLines + 1)
end

function M.drawLog()
	local top = logTop()
	local last = #logBuf - logOffset
	for i = 1, config.logLines do
		local index = last - config.logLines + i
		local level = logLevels[index]
		M.fill(top + i - 1)
		M.write(config.logX or 1, top + i - 1, logBuf[index] or "",
			level and colors[LEVEL_COLORS[level]] or nil)
	end
end

--- Fait défiler le journal : `delta` positif remonte vers les anciens.
function M.scrollLog(delta)
	logOffset = math.max(0, math.min(logOffset + delta, #logBuf - config.logLines))
end

function M.logOffset() return logOffset end

function M.logBuffer() return logBuf end

-- ---------------------------------------------------------------------------
-- Boutons
-- ---------------------------------------------------------------------------

--- Déclare un bouton.
--
-- Deux styles. Sans `bg`, le libellé nu, lettre de raccourci en négatif --
-- celui de la version 1. Avec `bg`, un bloc coloré « LABEL » en texte noir,
-- celui de ccFarmer ; sur un écran noir et blanc, un bloc blanc dont la
-- lettre de raccourci est en négatif.
--
-- `row = true` répartit le bouton, avec les autres boutons de sa ligne, sur
-- toute la largeur de l'écran, dans l'ordre de déclaration.
-- @param spec { label, cmd, y, x = aligné à droite si omis, key = 1re lettre,
--               bg, pad = 1 avec bg, row }
function M.addButton(spec)
	local b = {
		label = spec.label,
		cmd = spec.cmd or spec.label:lower(),
		y = spec.y,
		x = spec.x,
		key = (spec.key or spec.label:sub(1, 1)):lower(),
		bg = spec.bg,
		pad = spec.pad or (spec.bg and 1 or 0),
		row = spec.row,
	}
	buttons[#buttons + 1] = b
	return b
end

--- Modifie un bouton déjà déclaré, retrouvé par sa commande.
function M.setButton(cmd, fields)
	for _, b in ipairs(buttons) do
		if b.cmd == cmd then
			for k, v in pairs(fields) do b[k] = v end
			return b
		end
	end
	return nil
end

function M.clearButtons() buttons = {} end
function M.buttons() return buttons end

local function widthOf(b) return #b.label + 2 * b.pad end

--- Abscisse d'un bouton réparti sur sa ligne : espaces égaux entre eux et
--- aux bords.
local function rowX(b)
	local width = M.size()
	local row, total = {}, 0
	for _, o in ipairs(buttons) do
		if o.row and o.y == b.y then
			row[#row + 1] = o
			total = total + widthOf(o)
		end
	end
	local gap = math.max(1, math.floor((width - total) / (#row + 1)))
	local x = gap + 1
	for _, o in ipairs(row) do
		if o == b then return x end
		x = x + widthOf(o) + gap
	end
	return 1
end

local function boxOf(b)
	local width = M.size()
	local x = b.x or (b.row and rowX(b)) or (width - widthOf(b) + 1)
	return x, x + widthOf(b) - 1
end

--- Dessine les boutons. La lettre de raccourci est mise en évidence, comme
-- dans ccQuarry.
function M.drawButtons()
	for _, b in ipairs(buttons) do
		local x = boxOf(b)
		local keyIndex = b.label:lower():find(b.key, 1, true) or 1

		if b.bg then
			local pad = string.rep(" ", b.pad)
			M.write(x, b.y, pad .. b.label .. pad, colors.black, b.bg)
			if not M.isColor() then
				-- Pas de couleur, donc pas de souris : la touche est l'unique
				-- moyen d'agir, elle doit se voir.
				M.write(x + b.pad + keyIndex - 1, b.y, b.label:sub(keyIndex, keyIndex))
			end
		else
			out().setCursorPos(x, b.y)
			for i = 1, #b.label do
				if i == keyIndex then
					out().setBackgroundColour(colorText())
					out().setTextColour(colorBg())
				else
					out().setBackgroundColour(colorBg())
					out().setTextColour(colorText())
				end
				out().write(b.label:sub(i, i))
			end
		end
	end
	normal()
end

--- Bouton situé à ces coordonnées, ou nil.
function M.hitTest(x, y)
	for _, b in ipairs(buttons) do
		local x1, x2 = boxOf(b)
		if b.y == y and x >= x1 and x <= x2 then return b end
	end
	return nil
end

--- Bouton associé à ce caractère, ou nil.
function M.keyTest(char)
	if type(char) ~= "string" then return nil end
	char = char:lower()
	for _, b in ipairs(buttons) do
		if b.key == char then return b end
	end
	return nil
end

--- Traduit un événement en nom de commande, sans jamais rien exécuter.
-- Accepte char, mouse_click et monitor_touch. La molette, sur le journal, le
-- fait défiler : c'est de l'affichage pur, aucune commande n'en sort.
-- @return cmd, bouton  ou nil
function M.dispatch(event, p1, p2, p3)
	local b
	if event == "mouse_scroll" then
		local top = logTop()
		if p3 and p3 >= top and p3 < top + config.logLines then M.scrollLog(-p1) end
		return nil
	elseif event == "char" then
		b = M.keyTest(p1)
	elseif event == "mouse_click" or event == "monitor_touch" then
		b = M.hitTest(p2, p3)
	end
	if not b then return nil end
	return b.cmd, b
end

M.reset()

return M
