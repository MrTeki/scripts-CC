-- ccNav : déplacement du turtle, avec suivi de position par estime.
--
-- Remplace tUp, tDown, tForward, Forwards, GoUp, GoDown, GoXY et GoTo de
-- ccQuarry, ainsi que moveUp / moveDown / moveForward / moveToTarget de
-- ccChopper et move / dig de ccStairs.
--
-- Le contrat central : AUCUNE fonction ne boucle indéfiniment. Chaque tentative
-- est bornée, et l'échec est renvoyé à l'appelant plutôt que masqué.
--
--     local ok, raison, bloc = ccNav.forward()
--
--   raison vaut :
--     "blocked"      obstacle non dégagé dans le budget d'essais (gravier qui
--                    retombe plus vite qu'on ne creuse, ou dig désactivé)
--     "unbreakable"  turtle.dig() a échoué ; `bloc` porte le nom du bloc
--     "entity"       quelque chose de vivant bloque, toujours là après le budget
--     "no_fuel"      plus de carburant
--     "denied"       la garde canMove a refusé le mouvement
--
-- Les quatre blocages de ccQuarry disparaissent par construction :
--
--   * Panne sèche. turtle.forward() échouait, turtle.detect() était faux, donc
--     le code appelait turtle.attack() en boucle, sans fin ni message. Ici le
--     carburant est vérifié AVANT chaque tentative.
--   * Bedrock au-dessus. `while detectUp() and digUp() do end` sortait sur un
--     dig en échec, detectUp() restait vrai, et GoUp bouclait. Ici le dig en
--     échec devient "unbreakable".
--   * Bloc devant l'origine. tForward refusait de creuser en (0,0,0) et
--     n'avait alors aucune branche : GoXY bouclait.
--   * Direction invalide. La boucle de rotation de GoTo oscillait sur dir = -1.
--     Ici turnTo passe par ccVec.turnsBetween, borné à 2 rotations.
--
-- Et l'arrêt prématuré aussi : un unique turtle.forward() en échec avec un bloc
-- devant mettait done = true et terminait toute la carrière. C'était une course
-- banale, du gravier tombant entre la fin de la boucle de dig et le forward.
-- Ici c'est la séquence ENTIÈRE (bouger, creuser) qui est retentée.

local ccVec = require("ccVec")

local M = { _VERSION = 1 }

-- Noms d'opérations plutôt que références directes : le turtle global n'existe
-- pas encore au chargement du module sous le harnais de test.
local OPS = {
	forward = { move = "forward", detect = "detect",     dig = "dig",     attack = "attack",     inspect = "inspect" },
	up      = { move = "up",      detect = "detectUp",   dig = "digUp",   attack = "attackUp",   inspect = "inspectUp" },
	down    = { move = "down",    detect = "detectDown", dig = "digDown", attack = "attackDown", inspect = "inspectDown" },
}

local DEFAULTS = {
	tries = 8,        -- tentatives par mouvement
	dig = true,       -- creuser les obstacles
	attack = true,    -- attaquer ce qui bloque sans être un bloc
	order = "zxy",    -- ordre des axes dans goTo
}

local pos, stats, config

-- ---------------------------------------------------------------------------
-- Interne
-- ---------------------------------------------------------------------------

--- Niveau de carburant normalisé. turtle.getFuelLevel() renvoie la CHAÎNE
-- "unlimited" quand le serveur désactive le carburant : toute comparaison
-- numérique plante alors avec « attempt to compare string with number ».
local function fuelLevel()
	local f = turtle.getFuelLevel()
	if f == "unlimited" then return math.huge end
	return f
end

local function blockName(op)
	local seen, info = turtle[op.inspect]()
	if seen and info then return info.name end
	return nil
end

local function opts(o)
	if not o then return config end
	local merged = {}
	for k, v in pairs(config) do merged[k] = v end
	for k, v in pairs(o) do merged[k] = v end
	return merged
end

local function applyMove(where)
	if where == "up" then
		pos.z = pos.z + 1
	elseif where == "down" then
		pos.z = pos.z - 1
	else
		local dx, dy = ccVec.delta(pos.dir)
		pos.x, pos.y = pos.x + dx, pos.y + dy
	end
	stats.moves = stats.moves + 1
	if config.onMove then config.onMove(ccVec.copy(pos)) end
end

-- ---------------------------------------------------------------------------
-- Configuration et état
-- ---------------------------------------------------------------------------

--- Réinitialise position, compteurs et configuration.
-- @param o  { tries, dig, attack, order,
--            onMove = function(pos),      appelé après chaque mouvement réussi
--            canMove = function(where) }  garde : retourner false interdit le
--                                         mouvement (réserve de carburant)
function M.reset(o)
	pos = { x = 0, y = 0, z = 0, dir = 0 }
	stats = { moves = 0, dug = 0, turns = 0, attacks = 0 }
	config = {}
	for k, v in pairs(DEFAULTS) do config[k] = v end
	for k, v in pairs(o or {}) do config[k] = v end
end

function M.configure(o)
	for k, v in pairs(o or {}) do config[k] = v end
end

--- Copie de la position courante.
function M.position() return ccVec.copy(pos) end

--- Force la position, après une reprise ou un recalage GPS.
function M.setPosition(p)
	pos.x, pos.y, pos.z = p.x, p.y, p.z
	if p.dir then pos.dir = p.dir % 4 end
end

function M.stats()
	local out = {}
	for k, v in pairs(stats) do out[k] = v end
	return out
end

M.fuelLevel = fuelLevel

-- ---------------------------------------------------------------------------
-- Creusement
-- ---------------------------------------------------------------------------

--- Dégage la case dans la direction donnée ("forward", "up" ou "down").
-- Boucle bornée : le gravier et le sable retombent, donc un seul dig ne suffit
-- pas, mais un `while` non borné n'est pas acceptable non plus.
-- @return true, ou false + raison + nom du bloc
function M.dig(where, o)
	o = opts(o)
	local op = assert(OPS[where], "direction inconnue: " .. tostring(where))

	for _ = 1, o.tries do
		if not turtle[op.detect]() then return true end
		if not turtle[op.dig]() then
			return false, "unbreakable", blockName(op)
		end
		stats.dug = stats.dug + 1
	end

	if turtle[op.detect]() then
		return false, "blocked", blockName(op)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Mouvement
-- ---------------------------------------------------------------------------

--- Un pas dans la direction donnée ("forward", "up" ou "down").
-- @return true, ou false + raison + nom du bloc
local function step(where, o)
	o = opts(o)
	local op = OPS[where]
	local lastReason, lastDetail = "blocked", nil

	for _ = 1, o.tries do
		-- Vérifié en PREMIER : sans carburant, le mouvement échoue et rien
		-- n'est détecté devant. C'est ce qui envoyait ccQuarry attaquer le vide
		-- indéfiniment.
		if fuelLevel() <= 0 then return false, "no_fuel" end
		if config.canMove and not config.canMove(where) then return false, "denied" end

		if turtle[op.move]() then
			applyMove(where)
			return true
		end

		if turtle[op.detect]() then
			if not o.dig then
				return false, "blocked", blockName(op)
			end
			if not turtle[op.dig]() then
				return false, "unbreakable", blockName(op)
			end
			stats.dug = stats.dug + 1
			lastReason, lastDetail = "blocked", nil
		else
			-- Rien devant mais le mouvement échoue : une entité occupe la case.
			if not o.attack then return false, "entity" end
			turtle[op.attack]()
			stats.attacks = stats.attacks + 1
			lastReason, lastDetail = "entity", nil
		end
	end

	return false, lastReason, lastDetail
end

function M.forward(o) return step("forward", o) end
function M.up(o) return step("up", o) end
function M.down(o) return step("down", o) end

--- Recule sans se retourner. Ne creuse ni n'attaque : le turtle ne voit pas
-- derrière lui.
function M.back()
	if fuelLevel() <= 0 then return false, "no_fuel" end
	if config.canMove and not config.canMove("back") then return false, "denied" end
	if not turtle.back() then return false, "blocked" end

	local dx, dy = ccVec.delta(pos.dir)
	pos.x, pos.y = pos.x - dx, pos.y - dy
	stats.moves = stats.moves + 1
	if config.onMove then config.onMove(ccVec.copy(pos)) end
	return true
end

-- ---------------------------------------------------------------------------
-- Rotation
-- ---------------------------------------------------------------------------

-- La rotation et la mise à jour de dir se font dans la MÊME fonction. Dans
-- ccQuarry elles étaient séparées, d'où deux bugs : Downwards écrivait lastDir
-- avant de décrémenter dir, et Upwards associait turtle.turnLeft() à dir + 1.

function M.turnRight()
	turtle.turnRight()
	pos.dir = ccVec.turnRight(pos.dir)
	stats.turns = stats.turns + 1
	return true
end

function M.turnLeft()
	turtle.turnLeft()
	pos.dir = ccVec.turnLeft(pos.dir)
	stats.turns = stats.turns + 1
	return true
end

function M.turnAround()
	M.turnRight()
	M.turnRight()
	return true
end

--- Oriente le turtle vers `dir`, en 2 rotations au plus.
function M.turnTo(dir)
	local turns = ccVec.turnsBetween(pos.dir, dir)
	if turns < 0 then
		for _ = 1, -turns do M.turnLeft() end
	else
		for _ = 1, turns do M.turnRight() end
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Trajet
-- ---------------------------------------------------------------------------

--- Aligne un axe sur la cible. Chaque mouvement réussi rapproche strictement de
-- la cible, et tout échec remonte immédiatement : la terminaison est acquise.
local function alignAxis(axis, target, o)
	if axis == "z" then
		while pos.z ~= target.z do
			local ok, reason, detail
			if pos.z < target.z then ok, reason, detail = M.up(o)
			else ok, reason, detail = M.down(o) end
			if not ok then return false, reason, detail end
		end
		return true
	end

	local plus = (axis == "x") and 0 or 1
	local minus = (axis == "x") and 2 or 3
	while pos[axis] ~= target[axis] do
		M.turnTo(pos[axis] < target[axis] and plus or minus)
		local ok, reason, detail = M.forward(o)
		if not ok then return false, reason, detail end
	end
	return true
end

--- Rejoint `target` en parcourant les axes dans l'ordre configuré.
-- @param target  { x, y, z, dir } ; dir est optionnel
-- @param o       options, dont order ("zxy" par défaut)
-- @return true, ou false + raison + nom du bloc
function M.goTo(target, o)
	o = opts(o)
	local order = o.order

	for i = 1, #order do
		local ok, reason, detail = alignAxis(order:sub(i, i), target, o)
		if not ok then return false, reason, detail end
	end

	if target.dir then M.turnTo(target.dir) end
	return true
end

-- ---------------------------------------------------------------------------
-- GPS
-- ---------------------------------------------------------------------------

--- Position monde, convertie dans la convention du projet.
-- Le GPS renvoie les coordonnées Minecraft, où wy est la verticale ; ici c'est
-- z. La correspondance est donc x <-> wx, y <-> wz, z <-> wy.
-- @return { x, y, z } ou nil si aucune constellation n'est à portée
function M.gpsPosition(timeout)
	if not gps then return nil end
	local wx, wy, wz = gps.locate(timeout or 2)
	if not wx then return nil end
	return { x = wx, y = wz, z = wy }
end

--- Détermine le cap réel, en faisant un aller-retour d'un bloc.
-- Coûte 2 unités de carburant et exige une case libre devant ou derrière.
-- N'utilise pas les primitives de ce module et ne touche pas à la position
-- suivie : le cap est justement ce qu'on ne connaît pas encore.
-- @return dir, ou nil + raison
function M.gpsHeading(timeout)
	local before = M.gpsPosition(timeout)
	if not before then return nil, "gps indisponible" end

	local sign = 1
	if not turtle.forward() then
		if not turtle.back() then return nil, "aucune case libre pour se repérer" end
		sign = -1
	end

	local after = M.gpsPosition(timeout)
	if sign == 1 then turtle.back() else turtle.forward() end
	if not after then return nil, "gps indisponible après déplacement" end

	local dx = (after.x - before.x) * sign
	local dy = (after.y - before.y) * sign
	if dx == 1 then return 0 end
	if dy == 1 then return 1 end
	if dx == -1 then return 2 end
	if dy == -1 then return 3 end
	return nil, "déplacement non concluant"
end

--- Recale la position suivie sur le GPS, en coordonnées locales au chantier.
-- @param origin  position monde de l'origine du chantier, dans la convention
--                du projet ({ x, y, z })
-- @return true, ou false + raison
function M.calibrate(origin, timeout)
	local world = M.gpsPosition(timeout)
	if not world then return false, "gps indisponible" end
	pos.x = world.x - origin.x
	pos.y = world.y - origin.y
	pos.z = world.z - origin.z
	return true
end

M.reset()

return M
