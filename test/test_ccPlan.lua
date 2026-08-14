-- Tests de ccPlan.
--
-- Les cas exhaustifs sont l'intérêt principal de ce module : la géométrie est
-- ce qui était le plus faux dans ccQuarry, et elle est ici vérifiable sans
-- lancer une partie.

local H = require("harness")
local ccPlan = require("ccPlan")

--- Parcourt toutes les cellules d'un chantier.
local function each(job, fn)
	for i = 1, ccPlan.total(job) do fn(i, ccPlan.cellAt(job, i)) end
end

local function key(c) return c.x .. "," .. c.y .. "," .. c.z end

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

H.case("dimensions d'un chantier", function()
	local job = ccPlan.new({ width = 16, depth = 16, height = 64 })
	H.eq(ccPlan.perLayer(job), 256, "cellules par couche")
	H.eq(ccPlan.layers(job), 22, "couches (64 / 3 arrondi au-dessus)")
	H.eq(ccPlan.total(job), 5632, "cellules au total")
	H.eq(ccPlan.blocks(job), 16384, "blocs du volume")
end)

H.case("new refuse les dimensions nulles ou négatives", function()
	-- `ccquarry 1` produisait des dimensions nulles sans le moindre message.
	H.eq(pcall(ccPlan.new, { width = 0, depth = 3, height = 3 }), false, "largeur nulle")
	H.eq(pcall(ccPlan.new, { width = 3, depth = -1, height = 3 }), false, "profondeur négative")
	H.eq(pcall(ccPlan.new, { width = 3, depth = 3, height = 0 }), false, "hauteur nulle")
end)

-- ---------------------------------------------------------------------------
-- Couches
-- ---------------------------------------------------------------------------

H.case("une couche pleine se parcourt au milieu et creuse des deux côtés", function()
	local job = ccPlan.new({ width = 3, depth = 3, height = 9 })
	local band = ccPlan.layerAt(job, 0)
	H.eq(band.z, -1, "profondeur de parcours")
	H.eq(band.digUp, true, "creuse au-dessus")
	H.eq(band.digDown, true, "creuse au-dessous")
	H.eq(band.count, 3, "trois blocs")

	H.eq(ccPlan.layerAt(job, 1).z, -4, "couche suivante")
	H.eq(ccPlan.layerAt(job, 2).z, -7, "troisième couche")
end)

H.case("la dernière couche ne creuse jamais sous la profondeur demandée", function()
	-- Hauteur 5 : couche 0 couvre 0..-2, couche 1 ne couvre que -3 et -4.
	local job = ccPlan.new({ width = 2, depth = 2, height = 5 })
	H.eq(ccPlan.layers(job), 2, "deux couches")

	local last = ccPlan.layerAt(job, 1)
	H.eq(last.z, -4, "parcours au bas de la bande")
	H.eq(last.digUp, true, "creuse au-dessus")
	H.eq(last.digDown, false, "ne creuse PAS au-dessous")
	H.eq(last.count, 2, "deux blocs")
end)

H.case("une couche d'un seul bloc ne creuse ni au-dessus ni au-dessous", function()
	local job = ccPlan.new({ width = 2, depth = 2, height = 4 })
	local last = ccPlan.layerAt(job, 1)
	H.eq(last.z, -3, "profondeur")
	H.eq(last.digUp, false, "pas de creusement au-dessus")
	H.eq(last.digDown, false, "pas de creusement au-dessous")
	H.eq(last.count, 1, "un bloc")
end)

H.case("les bandes couvrent exactement la hauteur, sans trou ni recouvrement", function()
	for height = 1, 40 do
		local job = ccPlan.new({ width = 2, depth = 2, height = height })
		local couvert = {}
		for layer = 0, ccPlan.layers(job) - 1 do
			local band = ccPlan.layerAt(job, layer)
			for z = band.top, band.bottom, -1 do
				H.isNil(couvert[z], "hauteur " .. height .. " : z=" .. z .. " couvert deux fois")
				couvert[z] = true
			end
		end
		for z = 0, -(height - 1), -1 do
			H.ok(couvert[z], "hauteur " .. height .. " : z=" .. z .. " jamais couvert")
		end
		H.eq(#couvert + 0, 0, "table à index négatifs")   -- garde-fou de forme
	end
end)

-- ---------------------------------------------------------------------------
-- Parcours
-- ---------------------------------------------------------------------------

H.case("chaque cellule est visitée une fois et une seule", function()
	for _, dims in ipairs({ { 1, 1, 1 }, { 3, 3, 9 }, { 4, 3, 7 }, { 5, 4, 10 }, { 2, 7, 5 } }) do
		local job = ccPlan.new({ width = dims[1], depth = dims[2], height = dims[3] })
		local vu, n = {}, 0
		each(job, function(_, c)
			local k = key(c)
			H.isNil(vu[k], "cellule " .. k .. " visitée deux fois")
			vu[k] = true
			n = n + 1
			H.ok(c.x >= 0 and c.x < job.width, "x dans les bornes")
			H.ok(c.y >= 0 and c.y < job.depth, "y dans les bornes")
		end)
		H.eq(n, ccPlan.total(job), "compte")
	end
end)

H.case("deux cellules consécutives sont toujours adjacentes", function()
	-- C'est la propriété qui garantit que le déplacement entre deux cellules
	-- est un pas horizontal, ou une descente de changement de couche.
	for _, dims in ipairs({ { 3, 3, 9 }, { 4, 3, 7 }, { 5, 4, 12 }, { 1, 4, 6 }, { 6, 1, 3 } }) do
		local job = ccPlan.new({ width = dims[1], depth = dims[2], height = dims[3] })
		local thickness = job.thickness
		for i = 1, ccPlan.total(job) - 1 do
			local a, b = ccPlan.cellAt(job, i), ccPlan.cellAt(job, i + 1)
			local dx, dy, dz = math.abs(b.x - a.x), math.abs(b.y - a.y), math.abs(b.z - a.z)
			local label = table.concat(dims, "x") .. " cellule " .. i

			if dz == 0 then
				H.eq(dx + dy, 1, label .. " : un seul pas horizontal")
			else
				H.eq(dx + dy, 0, label .. " : le changement de couche est vertical")
				-- La descente vaut l'épaisseur nominale, sauf vers une dernière
				-- couche partielle, où elle est plus courte.
				H.ok(dz >= 1 and dz <= thickness,
					label .. " : descente de " .. dz .. ", hors de [1, " .. thickness .. "]")
				H.eq(dz, math.abs(ccPlan.layerAt(job, a.layer).z - ccPlan.layerAt(job, b.layer).z),
					label .. " : descente cohérente avec les couches")
			end
		end
	end
end)

H.case("le serpentin repart bien dans l'autre sens à chaque rangée", function()
	local job = ccPlan.new({ width = 3, depth = 2, height = 3 })
	local suite = {}
	each(job, function(_, c) suite[#suite + 1] = c.x .. c.y end)
	-- Rangée 0 de gauche à droite, rangée 1 de droite à gauche.
	H.eq(table.concat(suite, " "), "00 10 20 21 11 01", "ordre")
end)

H.case("indexOf est l'inverse exact de cellAt", function()
	for _, dims in ipairs({ { 3, 3, 9 }, { 4, 5, 11 }, { 1, 1, 1 }, { 7, 2, 8 } }) do
		local job = ccPlan.new({ width = dims[1], depth = dims[2], height = dims[3] })
		each(job, function(i, c)
			H.eq(ccPlan.indexOf(job, c), i, table.concat(dims, "x") .. " index " .. i)
		end)
	end
end)

H.case("indexOf rejette ce qui n'est pas une position de parcours", function()
	local job = ccPlan.new({ width = 3, depth = 3, height = 9 })
	H.isNil(ccPlan.indexOf(job, { x = 0, y = 0, z = 0 }), "z hors couche")
	H.isNil(ccPlan.indexOf(job, { x = 9, y = 0, z = -1 }), "x hors bornes")
	H.isNil(ccPlan.indexOf(job, { x = 0, y = -1, z = -1 }), "y négatif")
end)

H.case("le chantier vers le haut inverse simplement le signe", function()
	local job = ccPlan.new({ width = 2, depth = 2, height = 6, down = false })
	H.eq(ccPlan.cellAt(job, 1).z, 1, "première couche au-dessus")
	H.eq(ccPlan.layerAt(job, 1).z, 4, "seconde couche")
	H.eq(ccPlan.indexOf(job, ccPlan.cellAt(job, 7)), 7, "aller-retour")
end)

-- ---------------------------------------------------------------------------
-- Progression
-- ---------------------------------------------------------------------------

H.case("la progression est exacte, pas estimée", function()
	local job = ccPlan.new({ width = 4, depth = 4, height = 12 })
	H.eq(ccPlan.progress(job, 1), 0, "au départ")
	H.eq(ccPlan.progress(job, ccPlan.total(job) + 1), 1, "à la fin")
	H.eq(ccPlan.progress(job, 33), 0.5, "à la moitié de la première couche sur deux")
end)

H.case("remainingBlocks tient compte des couches partielles", function()
	-- Hauteur 5 sur 2x2 : couche 0 fait 3 blocs par cellule, couche 1 en fait 2.
	local job = ccPlan.new({ width = 2, depth = 2, height = 5 })
	H.eq(ccPlan.remainingBlocks(job, 1), 20, "tout le volume")
	H.eq(ccPlan.blocks(job), 20, "cohérent avec le volume")

	-- Après la première couche entière (4 cellules), il reste 4 * 2 = 8 blocs.
	H.eq(ccPlan.remainingBlocks(job, 5), 8, "après la première couche")
	H.eq(ccPlan.remainingBlocks(job, ccPlan.total(job) + 1), 0, "à la fin")
end)

H.case("remainingBlocks décroît strictement", function()
	local job = ccPlan.new({ width = 3, depth = 3, height = 8 })
	local last = ccPlan.remainingBlocks(job, 1)
	for i = 2, ccPlan.total(job) + 1 do
		local n = ccPlan.remainingBlocks(job, i)
		H.ok(n < last, "décroissance à l'index " .. i)
		last = n
	end
	H.eq(last, 0, "zéro à la fin")
end)
