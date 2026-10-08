-- Cohérence statique : NEEDS de chaque script doit couvrir TOUTES les APIs
-- chargées, dépendances transitives comprises.
--
-- ccBoot n'installe que ce que NEEDS liste. Sous le mock, toutes les APIs sont
-- déjà sur le disque, donc un oubli passe inaperçu dans les tests de bout en
-- bout -- et ne se révèle qu'en jeu, sur une turtle neuve. C'est arrivé à
-- ccChopper : ccUtil retiré de NEEDS parce que le script ne l'utilise pas,
-- alors que ccUi le requiert.

local H = require("harness")

local SCRIPTS = { "ccQuarry.lua", "ccChopper.lua" }

local function read(path)
	local f = assert(io.open(path, "r"))
	local s = f:read("a")
	f:close()
	return s
end

--- Noms passés à require("cc...") dans un source.
local function requires(src)
	local out = {}
	for name in src:gmatch('require%("(cc%w+)"%)') do out[name] = true end
	return out
end

--- Fermeture transitive des APIs requises, ccBoot exclu (il s'installe seul).
local function closure(src)
	local seen, queue = {}, {}
	for name in pairs(requires(src)) do queue[#queue + 1] = name end
	while #queue > 0 do
		local name = table.remove(queue)
		if name ~= "ccBoot" and not seen[name] then
			seen[name] = true
			for dep in pairs(requires(read("apis/" .. name .. ".lua"))) do
				queue[#queue + 1] = dep
			end
		end
	end
	return seen
end

local function needs(src)
	local block = assert(src:match("local NEEDS = (%b{})"), "NEEDS introuvable")
	local out = {}
	for name in block:gmatch("(cc%w+)%s*=") do out[name] = true end
	return out
end

for _, script in ipairs(SCRIPTS) do
	H.case(script .. " : NEEDS couvre les dépendances transitives", function()
		local src = read(script)
		local declared = needs(src)
		local missing = {}
		for name in pairs(closure(src)) do
			if not declared[name] then missing[#missing + 1] = name end
		end
		table.sort(missing)
		H.eq(table.concat(missing, ", "), "", "APIs chargées mais absentes de NEEDS")
	end)
end

-- ---------------------------------------------------------------------------
-- Boutons : la touche annoncée à l'écran est celle qui agit
-- ---------------------------------------------------------------------------
-- ccUi surligne dans le libellé la lettre de raccourci, ou la PREMIÈRE lettre
-- quand la touche n'y figure pas. STOP était lié à x : l'écran montrait le S,
-- qui ne faisait rien.

for _, script in ipairs(SCRIPTS) do
	H.case(script .. " : chaque raccourci figure dans son libellé, sans doublon", function()
		local seen = {}
		for args in read(script):gmatch("ccUi%.addButton%((%b{})%)") do
			local label = assert(args:match('label%s*=%s*"([^"]+)"'), "libellé introuvable : " .. args)
			local key = (args:match('key%s*=%s*"([^"]+)"') or label:sub(1, 1)):lower()
			H.ok(label:lower():find(key, 1, true), ("%s : touche %q absente du libellé"):format(label, key))
			H.isNil(seen[key], ("touche %q partagée par %s et %s"):format(key, tostring(seen[key]), label))
			seen[key] = label
		end
	end)
end
