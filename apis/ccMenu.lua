-- ccMenu : formulaire à onglets, au clavier et à la souris.
--
-- Sert d'écran de démarrage aux scripts qui ont plus de réglages que ne le
-- supporte une ligne de commande : ccQuarry y règle dimensions, dépôt,
-- carburant et liste de rebut.
--
-- Deux publics, une seule interface :
--
--   * Turtle NORMALE : noir et blanc, et surtout PAS DE SOURIS. Tout doit donc
--     se faire au clavier : Tab change de vue, haut/bas de champ, gauche/droite
--     de valeur, les chiffres saisissent un nombre, Entrée valide ou coche.
--     Comme la couleur ne peut pas signaler le champ actif, un « > » le marque
--     en marge, et sa valeur passe en négatif.
--   * Turtle AVANCÉE : la même chose, plus les clics sur les onglets, les
--     flèches < > et les cases, et la molette dans les listes.
--
-- Le contenu est décrit par des DONNÉES -- vues, champs, textes d'aide -- et
-- les valeurs vivent dans une table que le menu modifie en place. Le module ne
-- sait rien de ce qu'il édite.
--
-- Pas d'Échap : en jeu, la touche ferme l'interface au lieu d'atteindre
-- l'ordinateur. Abandonner se fait par Ctrl+T, renvoyé comme une annulation.
--
-- Description d'un menu :
--   {
--     values = { ... },                  -- modifiée en place
--     views = {
--       { title = "Chantier",
--         header = function(values) return texte, couleur end,   -- optionnel
--         before = function(values) return { lignes } end,       -- optionnel
--         after  = function(values) return { lignes } end,       -- optionnel
--         fields = { champ, ... } },
--     },
--     validate = function(values) return nil ou message end,     -- optionnel
--     refresh = function(values) end,    -- sur turtle_inventory, optionnel
--   }
-- Une ligne d'information est un texte, ou { texte, couleur }.
--
-- Champs (tous acceptent `hint`, texte ou function(values, item)) :
--   { kind = "number", key, label, min, max, step = 1 }
--   { kind = "choice", key, label, options = { { value, label, hint }, ... } }
--   { kind = "check",  key, label }
--   { kind = "set",    key, items = function(values) return { noms } end,
--                      display = function(nom) end, tag = function(nom) end,
--                      add = "+ Saisir un nom", prefix = "minecraft:" }
--   { kind = "button", label, action = "submit" | function(values) }
-- Un champ "set" édite un tableau de noms : chaque nom proposé devient une
-- ligne à cocher.

local ccUi = require("ccUi")

local M = { _VERSION = 1 }

-- Aide de la dernière ligne. Les caractères de flèche n'existent pas dans la
-- police de CC : « ^v » et « <> » en tiennent lieu.
local HELP = "Tab:vue ^v:champ <>:valeur Ent:ok"
local HELP_ENTRY = "Entree: ajouter  (vide: annuler)"

local ENTRY_CHARS = "[%w_:%.%-/]"

-- ---------------------------------------------------------------------------
-- Outils
-- ---------------------------------------------------------------------------

local function contains(list, name)
	for _, v in ipairs(list or {}) do
		if v == name then return true end
	end
	return false
end

local function clamp(v, lo, hi)
	if lo and v < lo then v = lo end
	if hi and v > hi then v = hi end
	return v
end

local function evalText(t, ...)
	if type(t) == "function" then return t(...) end
	return t
end

--- Une ligne d'information, normalisée en texte + couleur.
local function infoLine(line)
	if type(line) == "table" then return tostring(line[1] or ""), line[2] end
	return tostring(line or ""), nil
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

function M.new(spec)
	local self = setmetatable({}, Menu)
	self.spec = spec
	self.values = spec.values or {}
	self.view = 1
	self.focus = {}     -- ligne active, par vue
	self.scroll = {}    -- première ligne visible, par vue
	self.known = {}     -- noms déjà proposés, par champ "set"
	self.typing = false -- saisie de chiffres en cours sur le champ actif
	self.entry = nil    -- saisie de texte en cours, ou nil
	self.message = nil
	self.hits = {}
	self.shift = false
	for i = 1, #spec.views do
		self.focus[i], self.scroll[i] = 1, 0
	end
	return self
end

--- Lignes d'une vue : un champ ordinaire en occupe une, un champ "set" une
--- par nom proposé, plus celle de saisie.
function Menu:rows(view)
	local out = {}
	for _, f in ipairs(self.spec.views[view or self.view].fields) do
		if f.kind == "set" then
			-- Un nom une fois proposé le reste : décoché, il doit pouvoir être
			-- recoché, même s'il ne figurait que dans la valeur de départ.
			local names = self.known[f.key] or {}
			self.known[f.key] = names
			for _, n in ipairs(f.items and f.items(self.values) or {}) do
				if not contains(names, n) then names[#names + 1] = n end
			end
			for _, n in ipairs(self.values[f.key] or {}) do
				if not contains(names, n) then names[#names + 1] = n end
			end
			for _, n in ipairs(names) do out[#out + 1] = { field = f, item = n } end
			if f.add then out[#out + 1] = { field = f, add = true } end
		else
			out[#out + 1] = { field = f }
		end
	end
	return out
end

function Menu:current()
	local rows = self:rows()
	self.focus[self.view] = clamp(self.focus[self.view], 1, math.max(1, #rows))
	return rows[self.focus[self.view]], rows
end

-- ---------------------------------------------------------------------------
-- Valeurs
-- ---------------------------------------------------------------------------

local function optionIndex(f, value)
	for i, o in ipairs(f.options) do
		if o[1] == value then return i end
	end
	return nil
end

function Menu:display(row, active)
	local f = row.field
	local v = self.values[f.key]
	if f.kind == "number" then
		return tostring(v) .. ((self.typing and active) and "_" or "")
	elseif f.kind == "choice" then
		local i = optionIndex(f, v)
		return i and f.options[i][2] or tostring(v)
	end
	return ""
end

function Menu:isChecked(row)
	local f = row.field
	if f.kind == "check" then return self.values[f.key] == true end
	return contains(self.values[f.key], row.item)
end

--- Termine une saisie de chiffres : la valeur est ramenée dans ses bornes.
function Menu:commit()
	if not self.typing then return end
	self.typing = false
	local row = self:current()
	if row and row.field.kind == "number" then
		local f = row.field
		self.values[f.key] = clamp(self.values[f.key] or f.min or 0, f.min, f.max)
	end
end

function Menu:step(row, delta)
	self:commit()
	local f = row.field
	if f.kind == "number" then
		local v = (self.values[f.key] or f.min or 0) + delta * (f.step or 1)
		self.values[f.key] = clamp(v, f.min, f.max)
	elseif f.kind == "choice" then
		local n = #f.options
		local i = optionIndex(f, self.values[f.key]) or (delta > 0 and 0 or 1)
		self.values[f.key] = f.options[(i - 1 + delta) % n + 1][1]
	end
end

function Menu:toggle(row)
	local f = row.field
	if f.kind == "check" then
		self.values[f.key] = not self.values[f.key]
		return
	end
	local list = self.values[f.key] or {}
	self.values[f.key] = list
	for i, v in ipairs(list) do
		if v == row.item then
			table.remove(list, i)
			return
		end
	end
	list[#list + 1] = row.item
end

--- Action d'un champ : Entrée, espace ou clic.
-- @return "submit" quand le formulaire est validé
function Menu:activate(row)
	self:commit()
	local f = row.field
	if f.kind == "choice" then
		self:step(row, 1)
	elseif f.kind == "check" or (f.kind == "set" and not row.add) then
		self:toggle(row)
	elseif row.add then
		self.entry = f.prefix or ""
	elseif f.kind == "button" then
		if f.action == "submit" then return self:submit() end
		if type(f.action) == "function" then f.action(self.values) end
	end
	return nil
end

function Menu:submit()
	self:commit()
	local err = self.spec.validate and self.spec.validate(self.values)
	if err then
		self.message = { err, colors.red }
		return nil
	end
	return "submit"
end

-- ---------------------------------------------------------------------------
-- Saisie de texte
-- ---------------------------------------------------------------------------

function Menu:finishEntry()
	local row = self:current()
	local text = (self.entry or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local prefix = row and row.field.prefix or ""
	self.entry = nil
	if not row or text == "" or text == prefix then return end

	if not text:find(":", 1, true) then
		self.message = { "Il faut un identifiant mod:nom", colors.red }
		return
	end
	local key = row.field.key
	self.values[key] = self.values[key] or {}
	if not contains(self.values[key], text) then table.insert(self.values[key], text) end
	self.message = { "Ajoute : " .. text, colors.lime }
end

-- ---------------------------------------------------------------------------
-- Événements
-- ---------------------------------------------------------------------------

function Menu:switchView(delta)
	self:commit()
	self.entry = nil
	self.view = (self.view - 1 + delta) % #self.spec.views + 1
end

function Menu:moveFocus(delta)
	self:commit()
	local _, rows = self:current()
	self.focus[self.view] = clamp(self.focus[self.view] + delta, 1, math.max(1, #rows))
end

function Menu:onKey(k)
	if self.entry then
		if k == keys.enter or k == keys.numPadEnter then
			self:finishEntry()
		elseif k == keys.backspace then
			self.entry = self.entry:sub(1, -2)
		elseif k == keys.tab or k == keys.up or k == keys.down then
			self.entry = nil
		end
		return nil
	end

	local row = self:current()
	if k == keys.tab then
		self:switchView(self.shift and -1 or 1)
	elseif k == keys.up then
		self:moveFocus(-1)
	elseif k == keys.down then
		self:moveFocus(1)
	elseif not row then
		return nil
	elseif k == keys.left then
		self:step(row, -1)
	elseif k == keys.right then
		self:step(row, 1)
	elseif k == keys.enter or k == keys.numPadEnter then
		if row.field.kind == "number" then self:commit() return nil end
		return self:activate(row)
	elseif k == keys.backspace and row.field.kind == "number" then
		self.typing = true
		self.values[row.field.key] = math.floor((self.values[row.field.key] or 0) / 10)
	end
	return nil
end

function Menu:onChar(ch)
	if self.entry then
		if ch:match(ENTRY_CHARS) then self.entry = self.entry .. ch:lower() end
		return nil
	end
	local row = self:current()
	if not row then return nil end
	local f = row.field

	if f.kind == "number" and ch:match("%d") then
		local v = self.typing and (self.values[f.key] or 0) * 10 + tonumber(ch) or tonumber(ch)
		self.typing = true
		self.values[f.key] = clamp(v, nil, f.max)
	elseif ch == " " and f.kind ~= "number" then
		return self:activate(row)
	end
	return nil
end

function Menu:onClick(x, y)
	self:commit()
	self.entry = nil
	for i = #self.hits, 1, -1 do
		local h = self.hits[i]
		if h.y == y and x >= h.x1 and x <= h.x2 then return h.fn() end
	end
	return nil
end

function Menu:onScroll(dir)
	local rows = self:rows()
	local room = self.room or #rows
	local maxScroll = math.max(0, #rows - room)
	local s = clamp(self.scroll[self.view] + dir, 0, maxScroll)
	self.scroll[self.view] = s
	-- Le champ actif suit la fenêtre, sinon le rendu la ramènerait aussitôt.
	local f = self.focus[self.view]
	if f <= s then self.focus[self.view] = s + 1 end
	if f > s + room then self.focus[self.view] = s + room end
end

--- Traite un événement.
-- @return "submit", "cancel" ou nil
function Menu:handle(event, a, b, c)
	if event ~= "key_up" and event ~= "turtle_inventory" then self.message = nil end

	if event == "terminate" then
		return "cancel"
	elseif event == "key" then
		if a == keys.leftShift or a == keys.rightShift then
			self.shift = true
			return nil
		end
		return self:onKey(a)
	elseif event == "key_up" then
		if a == keys.leftShift or a == keys.rightShift then self.shift = false end
	elseif event == "char" then
		return self:onChar(a)
	elseif event == "mouse_click" then
		return self:onClick(b, c)
	elseif event == "mouse_scroll" then
		self:onScroll(a)
	elseif event == "turtle_inventory" and self.spec.refresh then
		self.spec.refresh(self.values)
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Dessin
-- ---------------------------------------------------------------------------

function Menu:hit(x1, x2, y, fn)
	self.hits[#self.hits + 1] = { x1 = x1, x2 = x2, y = y, fn = fn }
end

function Menu:drawTabs(w)
	local views = self.spec.views
	local total = 0
	for _, v in ipairs(views) do total = total + #v.title + 2 end
	-- Trop d'onglets pour la largeur : chaque titre est raccourci d'autant.
	local cut = total > w and math.max(1, math.floor(w / #views) - 2) or nil

	local x = 1
	for i, v in ipairs(views) do
		local text = " " .. (cut and v.title:sub(1, cut) or v.title) .. " "
		local active = i == self.view
		ccUi.write(x, 1, text, active and colors.black or colors.lightGray,
			active and colors.yellow or colors.black)
		self:hit(x, x + #text - 1, 1, function()
			self:switchView(i - self.view)
			return nil
		end)
		x = x + #text
	end
end

function Menu:drawRow(row, index, y, w)
	local f = row.field
	local active = index == self.focus[self.view]
	local labelColor = active and colors.yellow or colors.white
	local function focus()
		self.focus[self.view] = index
	end

	self:hit(1, w, y, function() focus() return nil end)
	if active then ccUi.write(1, y, ">", colors.yellow) end

	if f.kind == "number" or f.kind == "choice" then
		-- Valeur dans une case fixe, entre deux flèches cliquables.
		local vx = math.max(12, w - 21)
		local box = 14
		ccUi.write(3, y, f.label:sub(1, vx - 4), labelColor)
		ccUi.write(vx, y, "<", active and colors.yellow or colors.gray)
		ccUi.write(vx + box + 1, y, ">", active and colors.yellow or colors.gray)
		local text = self:display(row, active):sub(1, box - 2)
		local pad = math.floor((box - #text) / 2)
		local bg = active and colors.gray or colors.black
		ccUi.write(vx + 1, y, string.rep(" ", box), colors.white, bg)
		ccUi.write(vx + 1 + pad, y, text, colors.white, bg)
		self:hit(vx - 1, vx, y, function() focus() self:step(row, -1) return nil end)
		self:hit(vx + box + 1, vx + box + 2, y, function() focus() self:step(row, 1) return nil end)

	elseif f.kind == "check" or (f.kind == "set" and not row.add) then
		local on = self:isChecked(row)
		ccUi.write(2, y, on and "[x]" or "[ ]",
			active and colors.black or (on and colors.lime or colors.lightGray),
			active and colors.yellow or colors.black)
		local label = f.kind == "set" and (f.display and f.display(row.item) or row.item) or f.label
		local tag = f.kind == "set" and f.tag and f.tag(row.item) or nil
		local room = w - 6 - (tag and #tag + 1 or 0)
		ccUi.write(6, y, label:sub(1, room), labelColor)
		if tag then ccUi.write(w - #tag, y, tag, colors.cyan) end
		self:hit(2, w - 1, y, function() focus() return self:activate(row) end)

	elseif row.add then
		ccUi.write(2, y, f.add, active and colors.yellow or colors.cyan)
		self:hit(2, w - 1, y, function() focus() return self:activate(row) end)

	elseif f.kind == "button" then
		local text = " " .. f.label .. " "
		local x = math.floor((w - #text) / 2) + 1
		ccUi.write(x, y, text, colors.black, active and colors.yellow or colors.lime)
		self:hit(x, x + #text - 1, y, function() focus() return self:activate(row) end)
	end
end

function Menu:hintOf(row)
	if not row then return nil end
	local f = row.field
	if f.kind == "choice" then
		local i = optionIndex(f, self.values[f.key])
		if i and f.options[i][3] then return f.options[i][3] end
	end
	return evalText(f.hint, self.values, row.item)
end

function Menu:drawLines(lines, y)
	for _, line in ipairs(lines) do
		local text, color = infoLine(line)
		ccUi.write(2, y, text, color or colors.lightGray)
		y = y + 1
	end
	return y
end

function Menu:render()
	local w, h = ccUi.size()
	local view = self.spec.views[self.view]
	self.hits = {}

	ccUi.frame(function()
		ccUi.clear()
		self:drawTabs(w)
		ccUi.rule(2)

		local y = 3
		if view.header then
			local text, color = view.header(self.values)
			if text then
				ccUi.write(2, y, text, color or colors.lightGray)
				y = y + 1
			end
		end
		if view.before then y = self:drawLines(view.before(self.values), y) + 1 end

		local after = view.after and view.after(self.values) or {}
		local row, rows = self:current()
		local bottom = h - 2
		local room = bottom - y + 1
		-- Les lignes d'information de fin cèdent la place aux champs quand
		-- l'écran est trop court : un champ inaccessible serait pire.
		if #rows + 1 + #after > room then after = {} end
		self.room = math.max(1, room)

		-- Fenêtre de défilement : le champ actif reste toujours visible.
		local focus = self.focus[self.view]
		local s = self.scroll[self.view]
		if focus <= s then s = focus - 1 end
		if focus > s + self.room then s = focus - self.room end
		s = clamp(s, 0, math.max(0, #rows - self.room))
		self.scroll[self.view] = s

		for i = s + 1, math.min(#rows, s + self.room) do
			self:drawRow(rows[i], i, y + (i - s - 1), w)
		end
		if s > 0 then ccUi.write(w, y, "^", colors.orange) end
		if s + self.room < #rows then ccUi.write(w, bottom, "v", colors.orange) end

		if #after > 0 then self:drawLines(after, y + #rows + 1) end

		-- Avant-dernière ligne : saisie, message, ou aide du champ actif.
		if self.entry then
			ccUi.fill(h - 1, colors.gray)
			ccUi.write(2, h - 1, ("Nom: " .. self.entry .. "_"):sub(-(w - 2)), colors.white, colors.gray)
		elseif self.message then
			local text, color = infoLine(self.message)
			ccUi.write(2, h - 1, text, color or colors.orange)
		else
			local hint = self:hintOf(row)
			if hint then ccUi.write(2, h - 1, hint, colors.lightGray) end
		end
		ccUi.write(1, h, self.entry and HELP_ENTRY or HELP, colors.gray)
	end)
end

--- Affiche le menu jusqu'à validation ou abandon.
-- @return la table des valeurs, ou nil si l'utilisateur a abandonné (Ctrl+T)
function Menu:run()
	local t = ccUi.target()
	if t.setCursorBlink then t.setCursorBlink(false) end
	while true do
		self:render()
		local result = self:handle(os.pullEventRaw())
		if result then
			ccUi.clear()
			if result == "submit" then return self.values end
			return nil
		end
	end
end

return M
