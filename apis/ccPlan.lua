-- ccPlan : parcours en serpentin d'un volume, en couches.
--
-- Remplace Move, Forwards, Downwards, Upwards, FirstMove, le drapeau
-- `alternate` et tout l'estimateur de progression de ccQuarry.
--
-- Le changement de principe : la trajectoire n'est plus DÉDUITE de l'état
-- courant à chaque pas (« si dir == 0 et curX < targetX alors avancer, sinon
-- si alternate et curY > 0 alors tourner à gauche... »), elle est CALCULÉE à
-- partir d'un simple index. Trois conséquences.
--
--   * `alternate` disparaît. La parité du serpentin, c'est `row % 2`.
--   * Les branches sans `else` disparaissent. Move() n'en avait pas pour
--     dir == 1 et dir == 3 : dans ces états, si la condition d'avance était
--     fausse, la boucle principale tournait sans jamais rien faire.
--   * La progression devient EXACTE : index / total. Tout le calcul de
--     blocsLeftInCurLvl disparaît, avec ses comparaisons de flottants pour
--     tester une parité, sa valeur périmée quand aucune branche ne
--     s'appliquait, et ses « moves left » qui divisaient les blocs par 3.
--
-- Et surtout : ccQuarry peut sauvegarder le CURSEUR plutôt que des
-- coordonnées brutes. Une sauvegarde en retard d'un cran n'a alors plus
-- d'importance, puisque la reprise consiste à rejoindre la cellule de cet
-- index, quelle que soit la position réelle.
--
-- Conventions du projet : X / Y horizontaux, Z vertical.
-- Une « cellule » est une position de PARCOURS, pas un bloc : la turtle y
-- creuse aussi au-dessus et au-dessous, soit `thickness` blocs par cellule.

local M = { _VERSION = 1 }

--- Décrit un chantier.
-- @param o { width, depth, height, down = true, thickness = 3 }
function M.new(o)
	assert(o.width and o.width > 0, "largeur invalide")
	assert(o.depth and o.depth > 0, "profondeur invalide")
	assert(o.height and o.height > 0, "hauteur invalide")

	return {
		width = math.floor(o.width),
		depth = math.floor(o.depth),
		height = math.floor(o.height),
		down = o.down ~= false,
		thickness = o.thickness or 3,
	}
end

-- ---------------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------------

function M.perLayer(job) return job.width * job.depth end
function M.layers(job) return math.ceil(job.height / job.thickness) end
function M.total(job) return M.perLayer(job) * M.layers(job) end
function M.blocks(job) return job.width * job.depth * job.height end

--- Bande verticale couverte par une couche.
-- La dernière couche peut être plus mince que les autres : la turtle s'y place
-- de façon à ne jamais creuser sous la profondeur demandée.
-- @return { z, digUp, digDown, count }
function M.layerAt(job, layer)
	local t = job.thickness
	local top = layer * t                                  -- profondeur du haut
	local bottom = math.min(top + t - 1, job.height - 1)    -- profondeur du bas
	local count = bottom - top + 1

	-- Profondeur de parcours : une case sous le haut de la bande dès qu'elle
	-- fait au moins deux blocs, sinon le haut lui-même.
	local offset = (count >= 2) and (top + 1) or top
	local sign = job.down and -1 or 1

	return {
		z = sign * offset,
		digUp = offset > top,
		digDown = offset < bottom,
		count = count,
		top = sign * top,
		bottom = sign * bottom,
	}
end

--- Couche correspondant à une profondeur de parcours, ou nil.
function M.layerOf(job, z)
	for layer = 0, M.layers(job) - 1 do
		if M.layerAt(job, layer).z == z then return layer end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Parcours
-- ---------------------------------------------------------------------------

--- Cellule de parcours numéro `index` (1 à total).
-- @return { x, y, z, layer, digUp, digDown }
function M.cellAt(job, index)
	local perLayer = M.perLayer(job)
	local layer = math.floor((index - 1) / perLayer)
	local rest = (index - 1) % perLayer

	-- Une couche sur deux est parcourue à l'envers, de sorte que la dernière
	-- cellule d'une couche soit exactement au-dessus de la première de la
	-- suivante : le changement de couche est une simple descente.
	if layer % 2 == 1 then rest = perLayer - 1 - rest end

	local row = math.floor(rest / job.width)
	local col = rest % job.width
	-- Serpentin : une rangée sur deux est parcourue à l'envers.
	if row % 2 == 1 then col = job.width - 1 - col end

	local band = M.layerAt(job, layer)
	return {
		x = col, y = row, z = band.z,
		layer = layer,
		digUp = band.digUp,
		digDown = band.digDown,
	}
end

--- Index correspondant à une position de parcours, ou nil si elle n'en est pas.
-- Sert au recalage après une reprise.
function M.indexOf(job, pos)
	local layer = M.layerOf(job, pos.z)
	if not layer then return nil end
	if pos.x < 0 or pos.x >= job.width then return nil end
	if pos.y < 0 or pos.y >= job.depth then return nil end

	local col = pos.x
	if pos.y % 2 == 1 then col = job.width - 1 - col end
	local rest = pos.y * job.width + col

	local perLayer = M.perLayer(job)
	if layer % 2 == 1 then rest = perLayer - 1 - rest end
	return layer * perLayer + rest + 1
end

-- ---------------------------------------------------------------------------
-- Progression
-- ---------------------------------------------------------------------------

--- Avancement, de 0 à 1.
function M.progress(job, index)
	local total = M.total(job)
	return math.min(math.max((index - 1) / total, 0), 1)
end

--- Blocs restant à extraire à partir de `index`. Exact, contrairement à
-- l'estimateur d'origine : chaque couche connaît son épaisseur réelle.
function M.remainingBlocks(job, index)
	local perLayer = M.perLayer(job)
	local layers = M.layers(job)
	local startLayer = math.floor((index - 1) / perLayer)
	local done = (index - 1) % perLayer

	local total = 0
	for layer = startLayer, layers - 1 do
		local cells = perLayer - ((layer == startLayer) and done or 0)
		total = total + cells * M.layerAt(job, layer).count
	end
	return total
end

return M
