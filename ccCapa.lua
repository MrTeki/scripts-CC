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

------------------------------------------------------------
-- Configuration
------------------------------------------------------------
local REPORT_FILE = "ccCapa.txt"
local REFERENCE   = 3      -- niveau de l'Octadic, le meilleur capacitor craftable

local args = { ... }

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
-- Rapport
------------------------------------------------------------

local ROLE_TITLE = {
	traitement = "Machines de traitement (vitesse)",
	stirling   = "Stirling Generator",
}

local function fmt(x) return string.format("%.1f", x) end

local function describe(e)
	local s = e.result.stats
	if e.result.role == "stirling" then
		return "prod x" .. fmt(s.power) .. ", combustible x" .. fmt(s.fuel)
	end
	return "vitesse x" .. fmt(s.speed) .. ", obelisque x" .. fmt(s.range)
end

--- Classe les capacitors trouvés et renvoie les lignes du rapport.
function M.report(found)
	local groups, unknown = { traitement = {}, stirling = {} }, {}
	for _, e in ipairs(found) do
		local info = M.parse(e.item, e.displayName)
		if info then
			e.result = M.assess(info)
			table.insert(groups[e.result.role], e)
		else
			unknown[#unknown + 1] = e
		end
	end

	local lines = {}
	local function out(s) lines[#lines + 1] = s or "" end

	if #found == 0 then
		out("Aucun capacitor trouve.")
		out("Brancher un coffre (a cote ou par modem).")
		return lines
	end

	local weak = 0
	for _, role in ipairs({ "traitement", "stirling" }) do
		local list = groups[role]
		table.sort(list, function(a, b) return a.result.ratio > b.result.ratio end)
		if #list > 0 then
			out("== " .. ROLE_TITLE[role] .. " ==")
			for i, e in ipairs(list) do
				local mark = e.result.ratio < 1 and " (< Octadic)" or ""
				if e.result.ratio < 1 then weak = weak + e.count end
				out(string.format("%d. %s%s", i, e.displayName,
					e.count > 1 and (" x" .. e.count) or ""))
				out("   " .. describe(e) .. mark)
				out("   " .. e.where)
			end
			out()
		end
	end

	if #unknown > 0 then
		out("== Non reconnus ==")
		for _, e in ipairs(unknown) do
			out(e.displayName .. "  " .. e.where)
		end
		out()
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

if args[1] == "--lib" then return M end

------------------------------------------------------------
-- Programme
------------------------------------------------------------

if args[1] and not peripheral.isPresent(args[1]) then
	print("Inventaire introuvable : " .. args[1])
	return
end

local lines = M.report(M.scan(args[1]))

local f = fs.open(REPORT_FILE, "w")
if f then
	f.write(table.concat(lines, "\n") .. "\n")
	f.close()
end

term.clear()
term.setCursorPos(1, 1)
textutils.pagedPrint(table.concat(lines, "\n"))
print("Rapport complet : " .. REPORT_FILE)
