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

local M = { _VERSION = 1 }

local DEFAULTS = {
	logLines = 1,       -- hauteur de la zone de journal, en bas de l'écran
	textColor = nil,    -- nil = colors.white à l'exécution
	background = nil,   -- nil = colors.black
}

local target, buttons, logBuf, lastMsg, lastCount, config

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
	buttons = {}
	logBuf = {}
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
	target = api
	return true
end

function M.attach(t) target = t end
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
-- Journal
-- ---------------------------------------------------------------------------

--- Ajoute un message au journal et le redessine.
-- Un message identique au précédent n'ajoute pas de ligne : il est suffixé
-- d'un compteur, comme dans ccChopper et ccStairs.
function M.log(msg)
	msg = tostring(msg)
	if msg == lastMsg then
		lastCount = lastCount + 1
		logBuf[#logBuf] = msg .. " " .. lastCount
	else
		lastMsg, lastCount = msg, 0
		logBuf[#logBuf + 1] = msg
		while #logBuf > config.logLines do table.remove(logBuf, 1) end
	end
	M.drawLog()
end

function M.drawLog()
	local _, height = M.size()
	local first = height - config.logLines + 1
	for i = 1, config.logLines do
		M.line(first + i - 1, logBuf[i] or "")
	end
end

function M.logBuffer() return logBuf end

-- ---------------------------------------------------------------------------
-- Boutons
-- ---------------------------------------------------------------------------

--- Déclare un bouton.
-- @param spec { label, cmd, y, x = aligné à droite si omis, key = 1re lettre }
function M.addButton(spec)
	local b = {
		label = spec.label,
		cmd = spec.cmd or spec.label:lower(),
		y = spec.y,
		x = spec.x,
		key = (spec.key or spec.label:sub(1, 1)):lower(),
	}
	buttons[#buttons + 1] = b
	return b
end

function M.clearButtons() buttons = {} end
function M.buttons() return buttons end

local function boxOf(b)
	local width = M.size()
	local x = b.x or (width - #b.label + 1)
	return x, x + #b.label - 1
end

--- Dessine les boutons. La lettre de raccourci est mise en évidence, comme
-- dans ccQuarry.
function M.drawButtons()
	for _, b in ipairs(buttons) do
		local x = boxOf(b)
		local keyIndex = b.label:lower():find(b.key, 1, true) or 1

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
-- Accepte char, mouse_click et monitor_touch.
-- @return cmd, bouton  ou nil
function M.dispatch(event, p1, p2, p3)
	local b
	if event == "char" then
		b = M.keyTest(p1)
	elseif event == "mouse_click" or event == "monitor_touch" then
		b = M.hitTest(p2, p3)
	end
	if not b then return nil end
	return b.cmd, b
end

M.reset()

return M
