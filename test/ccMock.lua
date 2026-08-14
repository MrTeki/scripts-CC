-- ccMock : simulateur des APIs ComputerCraft, pour tester hors Minecraft.
--
-- Ne part JAMAIS en jeu. Il sert à exécuter les APIs et la logique des scripts
-- sous un interpréteur Lua 5.4 standard, en quelques millisecondes au lieu de
-- 20 minutes de partie.
--
-- Conventions du projet (voir README) :
--   X / Y = plan horizontal, Z = vertical (haut = +Z)
--   direction : 0 = +X, 1 = +Y, 2 = -X, 3 = -Y
--
-- Le mock est volontairement PESSIMISTE : il modélise les comportements qui ont
-- réellement cassé ccQuarry (gravier qui retombe, bedrock, coffre plein, panne
-- sèche, écriture tronquée) plutôt que le cas nominal.

local M = {}

-- ---------------------------------------------------------------------------
-- État
-- ---------------------------------------------------------------------------

local files, dirs, writeFaults, truncateFaults
local world, entities, peripherals, gpsOrigin, ground
local t                    -- état du turtle
local clock, events, timers, nextTimer
local screen

local FUEL_VALUES = {
	["minecraft:coal"]        = 80,
	["minecraft:charcoal"]    = 80,
	["minecraft:coal_block"]  = 800,
	["minecraft:lava_bucket"] = 1000,
	["minecraft:oak_log"]     = 15,
	["minecraft:stick"]       = 5,
}

local DELTA = {
	[0] = { x =  1, y =  0 },
	[1] = { x =  0, y =  1 },
	[2] = { x = -1, y =  0 },
	[3] = { x =  0, y = -1 },
}

function M.reset(opts)
	opts = opts or {}
	files, dirs, writeFaults, truncateFaults = {}, { [""] = true }, {}, {}
	world, entities, peripherals, gpsOrigin, ground = {}, {}, {}, nil, {}
	clock, events, timers, nextTimer = 0, {}, {}, 1
	screen = { w = opts.termWidth or 39, h = opts.termHeight or 13, x = 1, y = 1, lines = {} }
	t = {
		x = 0, y = 0, z = 0, dir = 0,
		fuel = opts.fuel or 1000,
		fuelLimit = opts.fuelLimit or 100000,
		unlimitedFuel = opts.unlimitedFuel or false,
		selected = 1,
		inv = {},
	}
end

-- ---------------------------------------------------------------------------
-- Monde
-- ---------------------------------------------------------------------------

local function key(x, y, z) return x .. "," .. y .. "," .. z end

--- Définit un bloc. `def` accepte un nom court ou une table complète.
-- Champs : name, unbreakable (bedrock), falling (gravier/sable),
--          regenerates (générateur de cobble), inventory (coffre)
function M.setBlock(x, y, z, def)
	if def == nil then world[key(x, y, z)] = nil return end
	if type(def) == "string" then def = { name = def } end
	world[key(x, y, z)] = def
end

function M.getBlock(x, y, z) return world[key(x, y, z)] end

function M.fill(x1, y1, z1, x2, y2, z2, def)
	for x = x1, x2 do for y = y1, y2 do for z = z1, z2 do
		M.setBlock(x, y, z, def)
	end end end
end

--- Coffre posé dans le monde, avec un nombre de slots fini (=> peut déborder).
function M.setChest(x, y, z, contents, size)
	M.setBlock(x, y, z, {
		name = "minecraft:chest",
		inventory = contents or {},
		size = size or 27,
	})
end

function M.spawnEntity(x, y, z, hp)
	entities[key(x, y, z)] = { hp = hp or 2 }
end

--- Active le GPS, en donnant les coordonnées MONDE de l'origine locale (0,0,0).
-- Convention Minecraft pour le monde : wy est la verticale. Sans appel à cette
-- fonction, gps.locate() renvoie nil, comme sans constellation à portée.
function M.setGps(wx, wy, wz)
	gpsOrigin = { wx = wx, wy = wy, wz = wz }
end

--- Branche un périphérique sur un côté. `api` est la table renvoyée par wrap().
-- L'ordre d'ajout est conservé : peripheral.getNames() le respecte, comme en jeu.
function M.addPeripheral(side, ptype, api)
	peripherals[#peripherals + 1] = { side = side, ptype = ptype, api = api or {} }
end

--- Gravité : après retrait d'un bloc, ce qui est au-dessus retombe si `falling`.
local function settle(x, y, z)
	while true do
		local above = world[key(x, y, z + 1)]
		if not above or not above.falling then return end
		world[key(x, y, z)] = above
		world[key(x, y, z + 1)] = nil
		z = z + 1
	end
end

-- ---------------------------------------------------------------------------
-- Système de fichiers
-- ---------------------------------------------------------------------------

local function norm(path)
	path = tostring(path):gsub("\\", "/"):gsub("//+", "/"):gsub("^/", ""):gsub("/$", "")
	return path
end

--- Injection de panne : coupe l'écriture de `path` après `bytes` octets écrits.
-- Simule un turtle détruit / un chunk déchargé en pleine sauvegarde.
function M.failWriteAfter(path, bytes) writeFaults[norm(path)] = bytes end

--- Injection de panne : l'écriture est acquittée sans erreur, mais le fichier
-- est tronqué à `bytes` au moment du close. Simule une perte de données
-- silencieuse, le seul cas que la relecture de contrôle peut rattraper.
function M.truncateOnClose(path, bytes) truncateFaults[norm(path)] = bytes end

--- Écrit un contenu arbitraire sans passer par l'API (pour fabriquer un
-- fichier corrompu, ou une sauvegarde d'ancienne version).
function M.putFile(path, content) files[norm(path)] = content end
function M.getFile(path) return files[norm(path)] end
function M.listFiles()
	local out = {}
	for p in pairs(files) do out[#out + 1] = p end
	table.sort(out)
	return out
end

local fs = {}

function fs.exists(path) path = norm(path) return files[path] ~= nil or dirs[path] ~= nil end
function fs.isDir(path) return dirs[norm(path)] ~= nil end
function fs.getSize(path) return #(files[norm(path)] or "") end
function fs.makeDir(path) dirs[norm(path)] = true end
function fs.combine(a, b) return norm(norm(a) .. "/" .. norm(b)) end

function fs.delete(path)
	path = norm(path)
	files[path] = nil
	dirs[path] = nil
end

function fs.move(from, to)
	from, to = norm(from), norm(to)
	if files[from] == nil then error("No such file", 0) end
	if files[to] ~= nil then error("File exists", 0) end
	files[to], files[from] = files[from], nil
end

function fs.list(path)
	path = norm(path)
	local prefix = path == "" and "" or (path .. "/")
	local seen, out = {}, {}
	for p in pairs(files) do
		if p:sub(1, #prefix) == prefix then
			local rest = p:sub(#prefix + 1):match("^[^/]+")
			if rest and not seen[rest] then seen[rest] = true out[#out + 1] = rest end
		end
	end
	table.sort(out)
	return out
end

function fs.open(path, mode)
	local p = norm(path)

	if mode == "r" then
		if files[p] == nil then return nil, "No such file" end
		local content, pos = files[p], 1
		return {
			readAll = function() local r = content:sub(pos) pos = #content + 1 return r end,
			readLine = function()
				if pos > #content then return nil end
				local nl = content:find("\n", pos, true)
				local line
				if nl then line = content:sub(pos, nl - 1) pos = nl + 1
				else line = content:sub(pos) pos = #content + 1 end
				return line
			end,
			close = function() end,
		}
	end

	if mode == "w" or mode == "a" then
		-- CC tronque le fichier dès l'ouverture en "w" : on modélise pareil, et
		-- on écrit directement dans le "disque" à chaque write plutôt que de
		-- bufferiser. C'est le modèle le plus défavorable, donc le bon pour
		-- tester la durabilité.
		if mode == "w" then files[p] = "" elseif files[p] == nil then files[p] = "" end
		local written, budget = 0, writeFaults[p]
		local handle
		handle = {
			write = function(s)
				s = tostring(s)
				if budget then
					local room = budget - written
					if room <= 0 then error("Terminated", 0) end
					if #s > room then
						files[p] = files[p] .. s:sub(1, room)
						written = budget
						error("Terminated", 0)   -- coupure en plein milieu
					end
				end
				files[p] = files[p] .. s
				written = written + #s
			end,
			flush = function() end,
			close = function()
				local cut = truncateFaults[p]
				if cut then files[p] = (files[p] or ""):sub(1, cut) end
			end,
		}
		handle.writeLine = function(s) handle.write(tostring(s) .. "\n") end
		return handle
	end

	return nil, "Unsupported mode: " .. tostring(mode)
end

-- ---------------------------------------------------------------------------
-- textutils
-- ---------------------------------------------------------------------------

local textutils = {}

local function serializeValue(v, indent, seen)
	local ty = type(v)
	if ty == "number" or ty == "boolean" or ty == "nil" then return tostring(v) end
	if ty == "string" then return string.format("%q", v) end
	if ty ~= "table" then error("Cannot serialize type " .. ty, 0) end
	if seen[v] then error("Cannot serialize table with recursive entries", 0) end
	seen[v] = true

	local inner, parts = indent .. "  ", {}
	local intKeys, strKeys = {}, {}
	for k in pairs(v) do
		if type(k) == "number" then intKeys[#intKeys + 1] = k
		elseif type(k) == "string" then strKeys[#strKeys + 1] = k
		else error("Cannot serialize key of type " .. type(k), 0) end
	end
	-- ordre déterministe : indispensable pour comparer des sorties en test
	table.sort(intKeys)
	table.sort(strKeys)
	for _, k in ipairs(intKeys) do
		parts[#parts + 1] = inner .. "[" .. k .. "] = " .. serializeValue(v[k], inner, seen)
	end
	for _, k in ipairs(strKeys) do
		parts[#parts + 1] = inner .. k .. " = " .. serializeValue(v[k], inner, seen)
	end

	seen[v] = nil
	if #parts == 0 then return "{}" end
	return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. indent .. "}"
end

function textutils.serialize(v) return serializeValue(v, "", {}) end

function textutils.unserialize(s)
	if type(s) ~= "string" then return nil end
	local f = load("return " .. s, "unserialize", "t", {})
	if not f then return nil end
	local ok, res = pcall(f)
	if not ok then return nil end
	return res
end

textutils.serialise = textutils.serialize
textutils.unserialise = textutils.unserialize

-- ---------------------------------------------------------------------------
-- Turtle : inventaire
-- ---------------------------------------------------------------------------

local MAX_STACK = 64

local function slotCount(i) local s = t.inv[i] return s and s.count or 0 end

--- Range `count` items ; retourne ce qui n'a PAS pu être rangé (0 = tout rangé).
-- `prefer` : slot à remplir en priorité (sémantique de turtle.suck, qui remplit
-- le slot sélectionné avant de déborder sur les autres).
local function store(name, count, prefer)
	if prefer then
		local s = t.inv[prefer]
		if not s then
			local moved = math.min(MAX_STACK, count)
			t.inv[prefer] = { name = name, count = moved }
			count = count - moved
		elseif s.name == name and s.count < MAX_STACK then
			local moved = math.min(MAX_STACK - s.count, count)
			s.count = s.count + moved
			count = count - moved
		end
		if count == 0 then return 0 end
	end
	for i = 1, 16 do
		local s = t.inv[i]
		if s and s.name == name and s.count < MAX_STACK then
			local room = MAX_STACK - s.count
			local moved = math.min(room, count)
			s.count = s.count + moved
			count = count - moved
			if count == 0 then return 0 end
		end
	end
	for i = 1, 16 do
		if not t.inv[i] then
			local moved = math.min(MAX_STACK, count)
			t.inv[i] = { name = name, count = moved }
			count = count - moved
			if count == 0 then return 0 end
		end
	end
	return count
end

function M.setSlot(i, name, count)
	if name == nil then t.inv[i] = nil else t.inv[i] = { name = name, count = count or 1 } end
end

function M.getTurtle() return t end

--- Objets tombés au sol, dans l'ordre de dépôt.
function M.groundItems() return ground end

--- Nombre total d'objets d'un nom donné tombés au sol.
function M.groundCount(name)
	local n = 0
	for _, item in ipairs(ground) do
		if item.name == name then n = n + item.count end
	end
	return n
end

function M.inventorySummary()
	local out = {}
	for i = 1, 16 do
		local s = t.inv[i]
		out[i] = s and (s.name .. " x" .. s.count) or false
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Turtle : déplacement et minage
-- ---------------------------------------------------------------------------

local turtle = {}

local function ahead()
	local d = DELTA[t.dir]
	return t.x + d.x, t.y + d.y, t.z
end

local function spendFuel()
	if t.unlimitedFuel then return true end
	if t.fuel <= 0 then return false end
	t.fuel = t.fuel - 1
	return true
end

local function tryMove(x, y, z)
	if world[key(x, y, z)] then return false, "Movement obstructed" end
	if entities[key(x, y, z)] then return false, "Movement obstructed" end
	if not spendFuel() then return false, "Out of fuel" end
	t.x, t.y, t.z = x, y, z
	return true
end

function turtle.forward() local x, y, z = ahead() return tryMove(x, y, z) end
function turtle.up() return tryMove(t.x, t.y, t.z + 1) end
function turtle.down() return tryMove(t.x, t.y, t.z - 1) end

function turtle.back()
	local d = DELTA[t.dir]
	return tryMove(t.x - d.x, t.y - d.y, t.z)
end

function turtle.turnLeft() t.dir = (t.dir - 1) % 4 return true end
function turtle.turnRight() t.dir = (t.dir + 1) % 4 return true end

local function digAt(x, y, z)
	local b = world[key(x, y, z)]
	if not b then return false, "Nothing to dig here" end
	if b.unbreakable then return false, "Unbreakable block detected" end
	world[key(x, y, z)] = nil
	store(b.name, 1)                -- ce qui déborde est perdu, comme en jeu
	settle(x, y, z)
	-- Bloc qui repousse aussitôt : générateur de cobble, sources infinies de
	-- certains mods. Les dig réussissent alors indéfiniment.
	if b.regenerates and not world[key(x, y, z)] then world[key(x, y, z)] = b end
	return true
end

function turtle.dig() local x, y, z = ahead() return digAt(x, y, z) end
function turtle.digUp() return digAt(t.x, t.y, t.z + 1) end
function turtle.digDown() return digAt(t.x, t.y, t.z - 1) end

local function detectAt(x, y, z) return world[key(x, y, z)] ~= nil end

function turtle.detect() local x, y, z = ahead() return detectAt(x, y, z) end
function turtle.detectUp() return detectAt(t.x, t.y, t.z + 1) end
function turtle.detectDown() return detectAt(t.x, t.y, t.z - 1) end

local function inspectAt(x, y, z)
	local b = world[key(x, y, z)]
	if not b then return false, "No block to inspect" end
	return true, { name = b.name, state = {} }
end

function turtle.inspect() local x, y, z = ahead() return inspectAt(x, y, z) end
function turtle.inspectUp() return inspectAt(t.x, t.y, t.z + 1) end
function turtle.inspectDown() return inspectAt(t.x, t.y, t.z - 1) end

local function attackAt(x, y, z)
	local e = entities[key(x, y, z)]
	if not e then return false, "Nothing to attack here" end
	e.hp = e.hp - 1
	if e.hp <= 0 then entities[key(x, y, z)] = nil end
	return true
end

function turtle.attack() local x, y, z = ahead() return attackAt(x, y, z) end
function turtle.attackUp() return attackAt(t.x, t.y, t.z + 1) end
function turtle.attackDown() return attackAt(t.x, t.y, t.z - 1) end

-- ---------------------------------------------------------------------------
-- Turtle : slots, carburant
-- ---------------------------------------------------------------------------

function turtle.select(i) t.selected = i return true end
function turtle.getSelectedSlot() return t.selected end
function turtle.getItemCount(i) return slotCount(i or t.selected) end
function turtle.getItemSpace(i) return MAX_STACK - slotCount(i or t.selected) end

function turtle.getItemDetail(i)
	local s = t.inv[i or t.selected]
	if not s then return nil end
	return { name = s.name, count = s.count, damage = 0 }
end

function turtle.transferTo(target, count)
	local src = t.inv[t.selected]
	if not src then return false end
	count = math.min(count or src.count, src.count)
	local dst = t.inv[target]
	if dst and dst.name ~= src.name then return false end
	if not dst then t.inv[target] = { name = src.name, count = 0 } dst = t.inv[target] end
	local moved = math.min(count, MAX_STACK - dst.count)
	if moved <= 0 then return false end
	dst.count = dst.count + moved
	src.count = src.count - moved
	if src.count == 0 then t.inv[t.selected] = nil end
	return true
end

function turtle.getFuelLevel()
	if t.unlimitedFuel then return "unlimited" end
	return t.fuel
end

function turtle.getFuelLimit()
	if t.unlimitedFuel then return "unlimited" end
	return t.fuelLimit
end

--- Contrat critique, sur lequel repose ccFuel :
--- refuel(0) répond "est-ce du combustible ?" SANS rien consommer.
function turtle.refuel(count)
	local s = t.inv[t.selected]
	if not s then return false, "No items to combust" end
	local value = FUEL_VALUES[s.name]
	if not value then return false, "Items not combustible" end
	if count == 0 then return true end

	local n = math.min(count or s.count, s.count)
	s.count = s.count - n
	if s.count == 0 then t.inv[t.selected] = nil end
	if not t.unlimitedFuel then
		t.fuel = math.min(t.fuel + value * n, t.fuelLimit)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Turtle : pose, dépôt, aspiration
-- ---------------------------------------------------------------------------

local function placeAt(x, y, z)
	local s = t.inv[t.selected]
	if not s then return false, "No items to place" end
	if world[key(x, y, z)] then return false, "Cannot place block here" end
	if entities[key(x, y, z)] then return false, "Cannot place block here" end
	if s.name:find("chest") then
		M.setChest(x, y, z, {}, 27)
		world[key(x, y, z)].name = s.name
	else
		M.setBlock(x, y, z, { name = s.name })
	end
	s.count = s.count - 1
	if s.count == 0 then t.inv[t.selected] = nil end
	return true
end

function turtle.place() local x, y, z = ahead() return placeAt(x, y, z) end
function turtle.placeUp() return placeAt(t.x, t.y, t.z + 1) end
function turtle.placeDown() return placeAt(t.x, t.y, t.z - 1) end

--- Dépose dans le conteneur visé. Retourne false si PLEIN : c'est le cas qui
--- fait boucler ccQuarry à l'infini aujourd'hui.
--- Sans conteneur en face, l'objet tombe au sol et l'appel réussit, comme en
--- jeu. C'est ce sur quoi repose la mise au rebut.
local function dropAt(x, y, z, count)
	local s = t.inv[t.selected]
	if not s then return false, "No items to drop" end

	local b = world[key(x, y, z)]
	if not b or not b.inventory then
		local n = math.min(count or s.count, s.count)
		ground[#ground + 1] = { name = s.name, count = n }
		s.count = s.count - n
		if s.count == 0 then t.inv[t.selected] = nil end
		return true
	end

	local n = math.min(count or s.count, s.count)
	local inv, size = b.inventory, b.size
	for i = 1, size do
		if n == 0 then break end
		local slot = inv[i]
		if slot and slot.name == s.name and slot.count < MAX_STACK then
			local moved = math.min(MAX_STACK - slot.count, n)
			slot.count = slot.count + moved
			n = n - moved
		end
	end
	for i = 1, size do
		if n == 0 then break end
		if not inv[i] then
			local moved = math.min(MAX_STACK, n)
			inv[i] = { name = s.name, count = moved }
			n = n - moved
		end
	end

	local dropped = math.min(count or s.count, s.count) - n
	if dropped == 0 then return false, "No space for items" end
	s.count = s.count - dropped
	if s.count == 0 then t.inv[t.selected] = nil end
	return true
end

function turtle.drop(n) local x, y, z = ahead() return dropAt(x, y, z, n) end
function turtle.dropUp(n) return dropAt(t.x, t.y, t.z + 1, n) end
function turtle.dropDown(n) return dropAt(t.x, t.y, t.z - 1, n) end

--- Aspire depuis le PREMIER slot non vide du conteneur : c'est cette sémantique
--- qui impose de retenir le rebut au lieu de le rendre immédiatement.
local function suckAt(x, y, z, count)
	local b = world[key(x, y, z)]
	if not b or not b.inventory then return false, "No inventory to take from" end
	local inv = b.inventory
	for i = 1, b.size do
		local slot = inv[i]
		if slot and slot.count > 0 then
			local n = math.min(count or MAX_STACK, slot.count)
			local leftover = store(slot.name, n, t.selected)
			local taken = n - leftover
			if taken == 0 then return false, "No space for items" end
			slot.count = slot.count - taken
			if slot.count == 0 then inv[i] = nil end
			return true
		end
	end
	return false, "No items to take"
end

function turtle.suck(n) local x, y, z = ahead() return suckAt(x, y, z, n) end
function turtle.suckUp(n) return suckAt(t.x, t.y, t.z + 1, n) end
function turtle.suckDown(n) return suckAt(t.x, t.y, t.z - 1, n) end

-- ---------------------------------------------------------------------------
-- os / term / colors
-- ---------------------------------------------------------------------------

local os_ = {}

function os_.clock() return clock end
function os_.time() return (clock / 60) % 24 end
function os_.epoch() return math.floor(clock * 1000) end
function os_.sleep(s) clock = clock + (s or 0) end
function os_.queueEvent(...) events[#events + 1] = { ... } end
function os_.startTimer(s)
	local id = nextTimer
	nextTimer = nextTimer + 1
	timers[#timers + 1] = { id = id, at = clock + s }
	return id
end

function os_.pullEvent(filter)
	while true do
		if #events > 0 then
			local e = table.remove(events, 1)
			if not filter or e[1] == filter then return table.unpack(e) end
		elseif #timers > 0 then
			table.sort(timers, function(a, b) return a.at < b.at end)
			local tm = table.remove(timers, 1)
			clock = tm.at
			if not filter or filter == "timer" then return "timer", tm.id end
		else
			error("ccMock : pullEvent sans événement en attente (deadlock)", 0)
		end
	end
end

os_.pullEventRaw = os_.pullEvent

local term = {}

local function ensureLine(y) screen.lines[y] = screen.lines[y] or string.rep(" ", screen.w) end

function term.getSize() return screen.w, screen.h end
function term.setCursorPos(x, y) screen.x, screen.y = x, y end
function term.getCursorPos() return screen.x, screen.y end
function term.clear() screen.lines = {} end
function term.clearLine() screen.lines[screen.y] = string.rep(" ", screen.w) end
function term.setBackgroundColour() end
function term.setTextColour() end
function term.setCursorBlink() end
function term.isColour() return true end
function term.scroll(n)
	local out = {}
	for y = 1, screen.h do out[y] = screen.lines[y + n] end
	screen.lines = out
end

function term.write(s)
	s = tostring(s)
	ensureLine(screen.y)
	local line = screen.lines[screen.y]
	local before = line:sub(1, screen.x - 1)
	local after = line:sub(screen.x + #s)
	screen.lines[screen.y] = (before .. s .. after):sub(1, screen.w)
	screen.x = screen.x + #s
end

term.setBackgroundColor = term.setBackgroundColour
term.setTextColor = term.setTextColour
term.isColor = term.isColour
function term.current() return term end

--- Contenu d'une ligne d'écran, pour assertion dans les tests d'UI.
function M.screenLine(y) return (screen.lines[y] or ""):gsub("%s+$", "") end

local colors = setmetatable({}, { __index = function(_, k)
	local names = { white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16,
		lime = 32, pink = 64, gray = 128, lightGray = 256, cyan = 512, purple = 1024,
		blue = 2048, brown = 4096, green = 8192, red = 16384, black = 32768 }
	return names[k] or 1
end })

-- ---------------------------------------------------------------------------
-- Installation
-- ---------------------------------------------------------------------------

M.fs, M.textutils, M.turtle, M.term, M.colors, M.os = fs, textutils, turtle, term, colors, os_

--- Injecte les APIs simulées dans les globales, comme en jeu.
function M.install()
	M.reset()
	_G.fs = fs
	_G.textutils = textutils
	_G.turtle = turtle
	_G.term = term
	_G.colors = colors
	_G.colours = colors
	_G.peripheral = {
		getNames = function()
			local out = {}
			for _, p in ipairs(peripherals) do out[#out + 1] = p.side end
			return out
		end,
		getType = function(side)
			for _, p in ipairs(peripherals) do
				if p.side == side then return p.ptype end
			end
			return nil
		end,
		isPresent = function(side)
			for _, p in ipairs(peripherals) do
				if p.side == side then return true end
			end
			return false
		end,
		wrap = function(side)
			for _, p in ipairs(peripherals) do
				if p.side == side then return p.api end
			end
			return nil
		end,
		find = function(ptype)
			for _, p in ipairs(peripherals) do
				if p.ptype == ptype then return p.api, p.side end
			end
			return nil
		end,
	}
	_G.sleep = os_.sleep
	_G.gps = {
		locate = function()
			if not gpsOrigin then return nil end
			-- local (x, y, z=vertical) -> monde (wx, wy=vertical, wz)
			return gpsOrigin.wx + t.x, gpsOrigin.wy + t.z, gpsOrigin.wz + t.y
		end,
	}
	for k, v in pairs(os_) do _G.os[k] = v end
	return M
end

return M
