-- ccVec : positions et directions. Lua pur, aucune dépendance à l'API turtle,
-- donc entièrement testable hors Minecraft.
--
-- Conventions du projet (voir README) :
--   X / Y = plan horizontal, Z = vertical (haut = +Z)
--   direction : 0 = +X, 1 = +Y, 2 = -X, 3 = -Y
--   turnRight = dir + 1, turnLeft = dir - 1, modulo 4
--
-- Cette API existe surtout pour concentrer en un seul endroit la normalisation
-- des directions. Dans ccQuarry, elle était un EFFET DE BORD de Save() :
--
--   function Save()
--       if dir > 3 then dir = dir - 4 elseif dir < 0 then dir = dir + 4 end
--       ...
--
-- La boucle de rotation de GoTo dépendait de cet effet de bord pour terminer :
-- sauter un appel à Save() la transformait en boucle infinie. Et comme la
-- correction ne s'appliquait qu'une fois (-4 ou +4), une direction à 8 ou -8
-- n'était pas rattrapée. Ici, dir est toujours normalisé, par construction.

local M = { _VERSION = 1 }

local DELTA = {
	[0] = { x =  1, y =  0 },
	[1] = { x =  0, y =  1 },
	[2] = { x = -1, y =  0 },
	[3] = { x =  0, y = -1 },
}

-- ---------------------------------------------------------------------------
-- Directions
-- ---------------------------------------------------------------------------

--- Ramène n'importe quel entier dans [0, 3].
function M.normalize(dir)
	return dir % 4
end

function M.turnRight(dir) return (dir + 1) % 4 end
function M.turnLeft(dir)  return (dir - 1) % 4 end
function M.turnAround(dir) return (dir + 2) % 4 end

--- Déplacement unitaire associé à une direction.
-- @return dx, dy
function M.delta(dir)
	local d = DELTA[dir % 4]
	return d.x, d.y
end

--- Rotations à effectuer pour passer de `from` à `to`.
-- @return un entier dans [-1, 2] : positif = rotations à droite,
--         négatif = rotations à gauche, 2 = demi-tour.
--
-- Le résultat est TOUJOURS le chemin le plus court, et toujours borné. C'est
-- ce qui remplace la boucle `while dir ~= toDir` de ccQuarry, qui pouvait
-- osciller indéfiniment quand dir valait une valeur invalide (-1 par exemple,
-- ce que Downwards persistait réellement en sauvegarde).
function M.turnsBetween(from, to)
	local diff = (to - from) % 4
	if diff == 3 then return -1 end
	return diff
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

--- Nouvelle position. `dir` est optionnel.
function M.new(x, y, z, dir)
	return { x = x or 0, y = y or 0, z = z or 0, dir = dir and (dir % 4) or nil }
end

--- Copie d'une position. Remplace ccChopper.copyPosition.
function M.copy(p)
	return { x = p.x, y = p.y, z = p.z, dir = p.dir }
end

--- Égalité de positions. Remplace ccChopper.arePositionEquals.
-- @param checkDir  si vrai, compare aussi la direction
function M.equals(a, b, checkDir)
	if a.x ~= b.x or a.y ~= b.y or a.z ~= b.z then return false end
	if checkDir then return a.dir == b.dir end
	return true
end

--- Somme de deux positions (la direction de `a` est conservée).
function M.add(a, b)
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z, dir = a.dir }
end

--- Différence `a - b` (sans direction).
function M.sub(a, b)
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

--- Distance de Manhattan : le nombre exact de mouvements nécessaires pour
-- relier deux positions, rotations exclues. C'est la base du budget carburant.
function M.manhattan(a, b)
	return math.abs(a.x - b.x) + math.abs(a.y - b.y) + math.abs(a.z - b.z)
end

--- Position obtenue en avançant de `n` pas (1 par défaut) dans `dir`.
-- Si `dir` est omis, celle de la position est utilisée.
function M.ahead(p, n, dir)
	n = n or 1
	local dx, dy = M.delta(dir or p.dir or 0)
	return { x = p.x + dx * n, y = p.y + dy * n, z = p.z, dir = p.dir }
end

--- Représentation lisible, pour l'affichage et les journaux.
function M.tostring(p)
	local s = p.x .. " " .. p.y .. " " .. p.z
	if p.dir then s = s .. " " .. p.dir end
	return s
end

return M
