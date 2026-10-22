-- ccCapa : classe les capacitors Ender IO (loot capacitors compris) des
-- inventaires accessibles et indique dans quelle machine chacun rend le plus.
--
-- CC ne voit pas les valeurs exactes d'un loot capacitor, seulement son nom,
-- qu'Ender IO compose à partir de ces valeurs : "<qualité> <type> <base>",
-- p. ex. "Good Hungry Enhanced Capacitor". Chaque mot correspond à une
-- tranche de valeurs (LootCapacitorItem, enderio 8.2) ; on raisonne sur le
-- milieu de la tranche. Un loot capacitor peut porter un 2e (15 %) voire un
-- 3e (2 %) bonus que le nom ne montre pas : ils échappent à l'analyse.
--
-- Effet des valeurs (m) dans les machines, configuration par défaut :
--   traitement (SAG Mill, Alloy Smelter, Slicer, Soul Binder...) :
--     consommation = base x m(energy_use)², la progression suit l'énergie
--     consommée, donc vitesse x m².
--   Stirling : production = 40 x m(burning_energy_generation) uI/t,
--     durée d'un combustible x (80 + 20 x m(fuel_efficiency)) %.
--   Obélisques : portée x m(energy_use) ; Soul Engine : seulement le tampon.
--   Une valeur absente vaut le niveau de base du capacitor.
--
-- Usage : ccCapa [inventaire]   (sans argument : tous les inventaires)
--         ccCapa update        (met à jour le script et ses APIs)
--
-- Écran : un onglet par famille de machines, un capacitor par ligne, du
-- meilleur au moins bon. Tab ou <> : onglet, ^v : ligne, R : relire les
-- coffres, Q : quitter. Clics et molette sur un écran avancé.

------------------------------------------------------------
-- Configuration
------------------------------------------------------------
local REPORT_FILE = "ccCapa.txt"
local REFERENCE   = 3      -- niveau de l'Octadic, le meilleur capacitor craftable
local SAME        = 0.02   -- écart relatif sous lequel on parle d'égalité

local args = { ... }

------------------------------------------------------------
-- Amorce
------------------------------------------------------------
-- Voir ccQuarry : un seul point d'entrée en dur, l'URL du dépôt.

local REPO = "https://raw.githubusercontent.com/MrTeki/scripts-CC/main/"

-- Version du script, comparée à celle du manifeste par `update`. À incrémenter,
-- ici ET dans manifest.lua, à chaque publication qui doit atteindre les ordinateurs.
local VERSION = 1

-- Version minimale de ccBoot : la première qui sait mettre à jour le script.
local BOOT = 2

local NEEDS = { ccUtil = 1, ccUi = 2 }

local function fetchBoot()
	if not http then
		error("apis/ccBoot.lua manquant ou trop ancien, et HTTP indisponible.\n"
			.. "Copier le dossier apis/ depuis " .. REPO, 0)
	end
	local res = http.get(REPO .. "apis/ccBoot.lua")
	if not res then error("Telechargement de ccBoot impossible : " .. REPO, 0) end
	local body = res.readAll()
	res.close()
	if not body or #body == 0 or not load(body, "@ccBoot") then
		error("ccBoot telecharge illisible : " .. REPO, 0)
	end
	fs.makeDir("apis")
	local f = fs.open("apis/ccBoot.lua", "w")
	f.write(body)
	f.close()
	package.loaded.ccBoot = nil
end

local function boot()
	package.path = "/apis/?.lua;apis/?.lua;" .. package.path
	local found, existing = pcall(require, "ccBoot")
	if not found or type(existing) ~= "table" or (existing._VERSION or 1) < BOOT then
		fetchBoot()
	end
	local ok, result = require("ccBoot").ensure(REPO, NEEDS)
	if not ok then error(result, 0) end
end

-- Chargé par les tests avec "--lib" : pas d'amorce, le lanceur de tests a
-- déjà mis apis/ dans package.path.
if args[1] ~= "--lib" then boot() end

if args[1] == "update" then
	local path = shell and shell.getRunningProgram and shell.getRunningProgram()
	local ok, report = require("ccBoot").update(REPO, NEEDS,
		{ name = "ccCapa", version = VERSION, path = path })
	if not ok then error(report, 0) end

	if report.boot then print("ccBoot mis a jour : v" .. report.boot) end
	if report.script then
		print("ccCapa mis a jour : v" .. report.script .. ", relancer pour l'utiliser")
	end
	if #report.apis > 0 then print("APIs installees : " .. table.concat(report.apis, ", ")) end
	if not report.boot and not report.script and #report.apis == 0 then
		print("Tout est deja a jour.")
	end
	return
end

local ccUi = require("ccUi")

local M = {}

-- Capacitors craftables : niveau fixe.
local FIXED = {
	["enderio:basic_capacitor"]        = 1,
	["enderio:double_layer_capacitor"] = 2,
	["enderio:octadic_capacitor"]      = 3,
}
local LOOT_ITEM = "enderio:loot_capacitor"

-- Tranches [min, max[ des mots du nom. Les bornes ouvertes sont fermées sur
-- la plage du loot de la table common_loot (1 à 4).
local BASES = {
	["Capacitor Dud"]        = { 0.5, 1 },
	["Capacitor"]            = { 1, 1.5 },
	["Enhanced Capacitor"]   = { 1.5, 2.5 },
	["Wonder Capacitor"]     = { 2.5, 3.5 },
	["Impossible Capacitor"] = { 3.5, 4 },
}
local QUALITIES = {
	Failed     = { 0.5, 1 },
	Simple     = { 1, 1.5 },
	Nice       = { 1.5, 2.5 },
	Good       = { 2.5, 3 },
	Enhanced   = { 3, 3.5 },
	Premium    = { 3.5, 4 },
	Incredibly = { 4, 4.25 },
	Unstable   = { 4.25, 4.5 },
}
local TYPES = {
	Hot        = "burning_energy_generation",
	Insatiable = "energy_capacity",
	Hungry     = "energy_use",
	Efficient  = "fuel_efficiency",
	Mystery    = "unknown",
}

-- Si le serveur n'a pas chargé la traduction d'Ender IO, le nom arrive sous
-- forme de clés : on les ramène à l'anglais.
local KEYS = {
	["enderio.capacitor.loot.base.dud"]        = "Capacitor Dud",
	["enderio.capacitor.loot.base.normal"]     = "Capacitor",
	["enderio.capacitor.loot.base.enhanced"]   = "Enhanced Capacitor",
	["enderio.capacitor.loot.base.wonder"]     = "Wonder Capacitor",
	["enderio.capacitor.loot.base.impossible"] = "Impossible Capacitor",
	["enderio.capacitor.loot.modifier.failed"]     = "Failed",
	["enderio.capacitor.loot.modifier.simple"]     = "Simple",
	["enderio.capacitor.loot.modifier.nice"]       = "Nice",
	["enderio.capacitor.loot.modifier.good"]       = "Good",
	["enderio.capacitor.loot.modifier.enhanced"]   = "Enhanced",
	["enderio.capacitor.loot.modifier.premium"]    = "Premium",
	["enderio.capacitor.loot.modifier.incredibly"] = "Incredibly",
	["enderio.capacitor.loot.modifier.unstable"]   = "Unstable",
	["enderio.capacitor.loot.type.burning_energy_generation"] = "Hot",
	["enderio.capacitor.loot.type.energy_capacity"]           = "Insatiable",
	["enderio.capacitor.loot.type.energy_use"]                = "Hungry",
	["enderio.capacitor.loot.type.fuel_efficiency"]           = "Efficient",
	["enderio.capacitor.loot.type.unknown.Mystery"]           = "Mystery",
}

local function mid(range) return (range[1] + range[2]) / 2 end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Décode un capacitor. Renvoie { base = n, mods = { [type] = n } } ou nil
--- si le nom n'est pas reconnu (capacitor renommé à l'enclume, autre langue).
function M.parse(itemName, displayName)
	if FIXED[itemName] then
		return { base = FIXED[itemName], mods = {} }
	end
	if itemName ~= LOOT_ITEM or type(displayName) ~= "string" then return nil end

	local name = trim(displayName:gsub("enderio%.capacitor%.loot%.[%w_%.]+", KEYS))
	-- La base termine le nom ; la plus longue d'abord, "Capacitor" étant le
	-- suffixe de toutes les autres.
	local baseName, rest
	for b in pairs(BASES) do
		if (name == b or name:sub(-#b - 1) == " " .. b)
			and (not baseName or #b > #baseName) then
			baseName, rest = b, trim(name:sub(1, #name - #b))
		end
	end
	if not baseName then return nil end

	local info = { base = mid(BASES[baseName]), mods = {} }
	if rest == "" then return info end
	local quality, kind = rest:match("^(%a+) (%a+)$")
	if not (QUALITIES[quality] and TYPES[kind]) then return nil end
	info.mods[TYPES[kind]] = mid(QUALITIES[quality])
	return info
end

local function value(info, modifier)
	return info.mods[modifier] or info.base
end

--- Gains par rôle, en multiple d'un Basic Capacitor.
function M.stats(info)
	local use = value(info, "energy_use")
	local gen = value(info, "burning_energy_generation")
	local eff = value(info, "fuel_efficiency")
	return {
		speed    = use * use,                 -- machines de traitement
		range    = use,                       -- obélisques
		power    = gen,                       -- Stirling : uI/t
		fuel     = (80 + 20 * eff) / 100,     -- Stirling : durée du combustible
		stirling = gen * (80 + 20 * eff) / 100, -- Stirling : énergie par combustible
		buffer   = value(info, "energy_capacity") ^ 2,
	}
end

local REF = M.stats({ base = REFERENCE, mods = {} })

--- Machine conseillée : celle où le capacitor dépasse le plus l'Octadic.
function M.assess(info)
	local s = M.stats(info)
	local ratios = {
		traitement = s.speed / REF.speed,
		stirling   = s.stirling / REF.stirling,
	}
	local role = ratios.stirling > ratios.traitement and "stirling" or "traitement"
	return { role = role, ratio = ratios[role], stats = s }
end

------------------------------------------------------------
-- Inventaires
------------------------------------------------------------

local function isCapacitor(name)
	return FIXED[name] or name == LOOT_ITEM
end

--- Liste les capacitors : { label, item, displayName, count, where }.
function M.scan(only)
	local found = {}
	local function add(detail, where)
		found[#found + 1] = {
			item = detail.name, displayName = detail.displayName,
			count = detail.count, where = where,
		}
	end

	if turtle and not only then
		for slot = 1, 16 do
			local d = turtle.getItemDetail(slot)
			if d and isCapacitor(d.name) then
				add(turtle.getItemDetail(slot, true), "turtle:" .. slot)
			end
		end
	end

	for _, side in ipairs(peripheral.getNames()) do
		if (not only or side == only) and peripheral.hasType(side, "inventory") then
			local inv = peripheral.wrap(side)
			local ok, list = pcall(inv.list)
			if ok and list then
				for slot, item in pairs(list) do
					if isCapacitor(item.name) then
						local d = inv.getItemDetail(slot)
						if d then add(d, side .. ":" .. slot) end
					end
				end
			end
		end
	end
	return found
end

------------------------------------------------------------
-- Classement
------------------------------------------------------------

-- Un onglet par famille de machines, plus les capacitors illisibles.
-- `cols` : colonnes de valeurs, en multiple d'un Basic Capacitor.
M.TABS = {
	{ key = "traitement", title = "Traitement", short = "Trait.",
		cols = { { "Vitesse", "speed", "%.1f" }, { "Portee", "range", "%.1f" } },
		ref = "Octadic x9 / x3",
		full = "Machines de traitement (vitesse)" },
	{ key = "stirling", title = "Stirling", short = "Stirl.",
		cols = { { "Prod", "power", "%.1f" }, { "Comb.", "fuel", "%.2f" } },
		ref = "Octadic x3 / x1.40",
		full = "Stirling Generator" },
	{ key = "autres", title = "Autres", short = "Autres",
		cols = {},
		ref = "Shift + survol en jeu",
		full = "Non reconnus" },
}

--- Rang face à l'Octadic : "+" mieux, "=" autant, "-" moins bien.
function M.mark(ratio)
	if ratio > 1 + SAME then return "+" end
	if ratio < 1 - SAME then return "-" end
	return "="
end

--- Range les capacitors trouvés par onglet, du meilleur au moins bon.
function M.classify(found)
	local groups = { traitement = {}, stirling = {}, autres = {} }
	for _, e in ipairs(found) do
		local info = M.parse(e.item, e.displayName)
		if info then
			e.result = M.assess(info)
			table.insert(groups[e.result.role], e)
		else
			e.result = nil
			table.insert(groups.autres, e)
		end
	end
	for _, role in ipairs({ "traitement", "stirling" }) do
		table.sort(groups[role], function(a, b)
			if a.result.ratio ~= b.result.ratio then return a.result.ratio > b.result.ratio end
			return a.where < b.where
		end)
	end
	return groups
end

local function fmt(x) return string.format("%.1f", x) end

--- Nom affiché : sans le « Capacitor » final, commun à tous. S'il dépasse
--- `width`, les mots longs sont abrégés (« Premium » -> « Prem. ») : couper
--- la fin ferait perdre la base, qui compte autant que le bonus.
local function shortName(e, width)
	local name = (e.displayName or e.item):gsub(" Capacitor$", "")
	local suffix = (e.count and e.count > 1) and (" x" .. e.count) or ""
	if width and #name + #suffix > width then
		name = name:gsub("(%a%a%a%a)%a%a+", "%1.")
	end
	return name .. suffix
end

--- Rapport texte, écrit dans REPORT_FILE.
function M.report(found)
	local groups = M.classify(found)
	local lines = {}
	local function out(s) lines[#lines + 1] = s or "" end

	if #found == 0 then
		out("Aucun capacitor trouve.")
		out("Brancher un coffre (a cote ou par modem).")
		return lines
	end

	local weak = 0
	for _, tab in ipairs(M.TABS) do
		local list = groups[tab.key]
		if #list > 0 then
			out("== " .. tab.full .. " ==")
			for i, e in ipairs(list) do
				local head = tab.key == "autres" and "-" or (i .. ".")
				out(string.format("%s %s%s", head, e.displayName,
					e.count > 1 and (" x" .. e.count) or ""))
				if e.result then
					local s = e.result.stats
					local mark = e.result.ratio < 1 - SAME and " (< Octadic)" or ""
					if e.result.ratio < 1 - SAME then weak = weak + e.count end
					if tab.key == "stirling" then
						out("   prod x" .. fmt(s.power) .. ", combustible x" .. fmt(s.fuel) .. mark)
					else
						out("   vitesse x" .. fmt(s.speed) .. ", obelisque x" .. fmt(s.range) .. mark)
					end
				end
				out("   " .. e.where)
			end
			out()
		end
	end

	out("Gains par rapport a un Basic Capacitor.")
	out("Octadic : vitesse x9, Stirling x3 / x1.4.")
	if weak > 0 then
		out(weak .. " capacitor(s) moins bon(s) qu'un Octadic.")
	end
	out("Traitement : SAG Mill, Alloy Smelter, Slicer,")
	out("Soul Binder, Painting, Crafter, Spawner...")
	out("Un 2e bonus cache par le nom reste invisible.")
	return lines
end

------------------------------------------------------------
-- Écran
------------------------------------------------------------
-- Disposition, de haut en bas :
--   1        bandeau : onglets, nombre de capacitors
--   2        en-têtes de colonnes
--   3..h-4   liste, une ligne par capacitor
--   h-3      nom complet du capacitor choisi
--   h-2      bandeau : son emplacement
--   h-1      référence Octadic de l'onglet
--   h        aide clavier

local COL_W = 7     -- largeur d'une colonne de valeurs
local MARK_COLOR = { ["+"] = "lime", ["="] = "yellow", ["-"] = "red" }

--- État de l'écran : onglet courant, ligne choisie et décalage par onglet.
function M.newView(groups)
	return { groups = groups, tab = 1, sel = { 1, 1, 1 }, top = { 1, 1, 1 } }
end

local function currentList(v) return v.groups[M.TABS[v.tab].key] end

local function listRows()
	local _, h = ccUi.size()
	return math.max(1, h - 6)
end

--- Garde la ligne choisie dans la liste et visible.
local function clampView(v)
	local n = #currentList(v)
	local t = v.tab
	v.sel[t] = math.max(1, math.min(v.sel[t], math.max(1, n)))
	local rows = listRows()
	if v.sel[t] < v.top[t] then v.top[t] = v.sel[t] end
	if v.sel[t] > v.top[t] + rows - 1 then v.top[t] = v.sel[t] - rows + 1 end
	v.top[t] = math.max(1, math.min(v.top[t], math.max(1, n - rows + 1)))
end

--- Position des onglets dans le bandeau : { { x1, x2, label }, ... }.
-- Titre et libellés longs quand ils tiennent, sinon les courts.
local function tabLayout(w, count)
	local variants = { { true, "title" }, { false, "title" }, { false, "short" } }
	for n, variant in ipairs(variants) do
		local withName, field = variant[1], variant[2]
		local x = withName and 9 or 1
		local out = {}
		for i, tab in ipairs(M.TABS) do
			local label = " " .. tab[field] .. " "
			out[i] = { x, x + #label - 1, label }
			x = x + #label
		end
		if x - 1 + #count + 1 <= w or n == #variants then return out, withName end
	end
end

local function pad(s, n) return #s >= n and s:sub(1, n) or s .. string.rep(" ", n - #s) end
local function lpad(s, n) return #s >= n and s:sub(1, n) or string.rep(" ", n - #s) .. s end

function M.draw(v)
	clampView(v)
	local w, h = ccUi.size()
	local tab = M.TABS[v.tab]
	local list = currentList(v)
	local total = 0
	for _, t in ipairs(M.TABS) do
		for _, e in ipairs(v.groups[t.key]) do total = total + (e.count or 1) end
	end

	ccUi.frame(function()
		ccUi.clear()

		-- Bandeau des onglets
		local count = total .. " capa "
		local layout, withName = tabLayout(w, count)
		v.layout = layout
		ccUi.fill(1, colors.gray)
		if withName then ccUi.write(1, 1, " ccCapa ", colors.orange, colors.gray) end
		for i, pos in ipairs(layout) do
			if i == v.tab then
				ccUi.write(pos[1], 1, pos[3], colors.black, colors.white)
			else
				-- En noir et blanc, un fond gris passe en négatif : seul
				-- l'onglet courant doit l'être, les autres restent sur noir.
				ccUi.write(pos[1], 1, pos[3], colors.white, ccUi.isColor() and colors.gray or nil)
			end
		end
		local last = layout[#layout][2]
		if last + #count < w then
			ccUi.write(w - #count + 1, 1, count, colors.white,
				ccUi.isColor() and colors.gray or nil)
		end

		-- En-têtes. Sur un écran étroit (poche), une seule colonne de valeurs.
		local cols = tab.cols
		if w < 39 and #cols > 1 then cols = { cols[1] } end
		local valuesW = #cols * COL_W
		local nameW = math.max(4, w - 4 - valuesW - 2)
		local head = "  # " .. pad(tab.key == "autres" and "Non reconnus" or "Capacitor", nameW)
		for _, c in ipairs(cols) do head = head .. lpad(c[1], COL_W) end
		ccUi.write(1, 2, pad(head, w), colors.lightGray)

		-- Liste
		local rows = listRows()
		if #list == 0 then
			ccUi.write(3, 4, tab.key == "autres" and "Rien a signaler." or "Aucun capacitor ici.",
				colors.lightGray)
		end
		for r = 0, rows - 1 do
			local i = v.top[v.tab] + r
			local e = list[i]
			if not e then break end
			local y = 3 + r
			local selected = i == v.sel[v.tab]
			local rank = tab.key == "autres" and "  " or lpad(tostring(i), 2)
			local left = (selected and ">" or " ") .. rank .. " " .. pad(shortName(e, nameW), nameW)
			local values = ""
			for _, c in ipairs(cols) do
				values = values .. lpad(string.format(c[3], e.result.stats[c[2]]), COL_W)
			end
			local mark = e.result and M.mark(e.result.ratio) or " "
			local right = values .. " " .. mark .. " "
			if selected then
				ccUi.write(1, y, pad(left .. right, w), colors.white, colors.blue)
			else
				ccUi.write(1, y, left)
				ccUi.write(#left + 1, y, right, e.result and colors[MARK_COLOR[mark]] or nil)
			end
		end

		-- Détail du capacitor choisi
		local e = list[v.sel[v.tab]]
		if e then
			ccUi.write(1, h - 3, pad(" " .. (e.displayName or e.item), w), colors.white)
			ccUi.banner(h - 2, "Emplacement : " .. e.where, nil, colors.gray)
		else
			ccUi.fill(h - 2, colors.gray)
		end
		local legend = tab.key == "autres" and "" or "  +:mieux -:moins"
		ccUi.write(1, h - 1, pad(" " .. tab.ref .. legend, w), colors.lightGray)
		ccUi.write(1, h, pad(" Tab:onglet ^v:ligne R:relire Q:quitter", w), colors.gray)
	end)
end

--- Applique un événement. Renvoie "quit", "rescan" ou nil.
function M.handle(v, event, p1, p2, p3)
	local list = currentList(v)
	local t = v.tab
	if event == "terminate" then return "quit" end
	if event == "char" then
		local c = p1:lower()
		if c == "q" then return "quit" end
		if c == "r" then return "rescan" end
	elseif event == "key" then
		if p1 == keys.tab or p1 == keys.right then
			v.tab = v.tab % #M.TABS + 1
		elseif p1 == keys.left then
			v.tab = (v.tab - 2) % #M.TABS + 1
		elseif p1 == keys.up then
			v.sel[t] = v.sel[t] - 1
		elseif p1 == keys.down then
			v.sel[t] = v.sel[t] + 1
		elseif keys.pageUp and p1 == keys.pageUp then
			v.sel[t] = v.sel[t] - listRows()
		elseif keys.pageDown and p1 == keys.pageDown then
			v.sel[t] = v.sel[t] + listRows()
		elseif keys.home and p1 == keys.home then
			v.sel[t] = 1
		elseif keys["end"] and p1 == keys["end"] then
			v.sel[t] = #list
		end
	elseif event == "mouse_scroll" then
		v.sel[t] = v.sel[t] + p1
	elseif event == "mouse_click" or event == "monitor_touch" then
		local x, y = p2, p3
		if y == 1 then
			for i, pos in ipairs(v.layout or {}) do
				if x >= pos[1] and x <= pos[2] then v.tab = i end
			end
		elseif y >= 3 and y < 3 + listRows() then
			local i = v.top[t] + y - 3
			if list[i] then v.sel[t] = i end
		end
	end
	clampView(v)
	return nil
end

if args[1] == "--lib" then return M end

------------------------------------------------------------
-- Programme
------------------------------------------------------------

if args[1] and not peripheral.isPresent(args[1]) then
	print("Inventaire introuvable : " .. args[1])
	return
end

local function scanAll()
	local found = M.scan(args[1])
	local f = fs.open(REPORT_FILE, "w")
	if f then
		f.write(table.concat(M.report(found), "\n") .. "\n")
		f.close()
	end
	return found
end

ccUi.reset()
ccUi.buffered()

local view = M.newView(M.classify(scanAll()))
-- Ouvre sur le premier onglet qui a quelque chose à montrer.
for i, tab in ipairs(M.TABS) do
	if #view.groups[tab.key] > 0 then view.tab = i break end
end

while true do
	M.draw(view)
	local action = M.handle(view, os.pullEventRaw())
	if action == "quit" then break end
	if action == "rescan" then
		local tab, sel, top = view.tab, view.sel, view.top
		view = M.newView(M.classify(scanAll()))
		view.tab, view.sel, view.top = tab, sel, top
	end
end

ccUi.clear()
print("Rapport complet : " .. REPORT_FILE)
