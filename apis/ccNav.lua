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

-- Hauteur maximale du monde : 384 depuis la 1.18 (Y de -64 à 319), 256 avant.
-- C'est la plus haute colonne de gravier ou de sable que le moteur autorise,
-- donc le plafond utile pour un seul mouvement.
local WORLD_HEIGHT = 384

local DEFAULTS = {
	-- Tentatives STÉRILES consécutives : attaques qui ne tuent pas, échecs
	-- inexpliqués. Un dig réussi remet ce compteur à zéro, puisqu'il constitue
	-- un progrès. Ce budget-là n'a donc pas à couvrir la hauteur d'une colonne.
	tries = 8,

	-- Plafond ABSOLU de blocs creusés pour un seul mouvement. Dimensionné sur
	-- la hauteur du monde : une colonne de gravier ou de sable, si haute
	-- soit-elle, passe. Sert de garde-fou contre les blocs qui repoussent
	-- (générateur de cobble, sources infinies de certains mods), où les dig
	-- réussiraient indéfiniment.
	maxDig = WORLD_HEIGHT,

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

--- Signale un changement d'état suivi : position OU cap.
--
-- Le crochet s'appelait onMove, et ne se déclenchait que sur les déplacements.
-- Les rotations changeaient `dir` sans rien notifier, donc sans être
-- sauvegardées : au rechargement de la partie, la turtle repartait avec un cap
-- faux, et tout le chantier était de travers. En quittant la partie, le jeu
-- n'accorde qu'un tick à la turtle pour finir son itération -- la sauvegarde
-- doit donc suivre CHAQUE changement, rotation comprise.
local function notify()
	if config.onChange then config.onChange(ccVec.copy(pos)) end
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
	notify()
end

-- ---------------------------------------------------------------------------
-- Configuration et état
-- ---------------------------------------------------------------------------

--- Réinitialise position, compteurs et configuration.
-- @param o  { tries, dig, attack, order,
--            onChange = function(pos),    appelé après CHAQUE changement de
--                                         position ou de cap, rotations
--                                         comprises
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

--- Installe ou retire la garde de mouvement.
-- Indispensable pour le trajet de retour : la garde de ccFuel raisonne sur la
-- position courante, donc au moment précis où la réserve est atteinte elle
-- interdirait aussi les mouvements qui RAPPROCHENT de l'origine. La machine à
-- états la lève en entrant dans son état de retour.
-- `configure` ne peut pas servir à cela : pairs() ignore les valeurs nil.
function M.setGuard(fn) config.canMove = fn end

--- Copie de la position courante.
function M.position() return ccVec.copy(pos) end

--- Force la position, après une reprise ou un recalage GPS.
function M.setPosition(p)
	pos.x, pos.y, pos.z = p.x, p.y, p.z
	if p.dir then pos.dir = p.dir % 4 end
	notify()
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
	local dug = 0

	-- Creuser est purement productif : seul le plafond absolu borne la boucle.
	while dug < o.maxDig do
		if not turtle[op.detect]() then return true end
		if not turtle[op.dig]() then
			return false, "unbreakable", blockName(op)
		end
		stats.dug = stats.dug + 1
		dug = dug + 1
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
	local idle, dug = 0, 0
	local lastReason, lastDetail = "blocked", nil

	-- maxDig borne le CREUSEMENT, pas la boucle : sinon le dernier bloc d'une
	-- colonne de hauteur maximale serait dégagé sans que le mouvement soit
	-- retenté, et le mouvement échouerait juste après avoir réussi son travail.
	while idle < o.tries do
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
			if dug >= o.maxDig then
				return false, "blocked", blockName(op)
			end
			if not turtle[op.dig]() then
				return false, "unbreakable", blockName(op)
			end
			-- Un dig réussi est un progrès : le compteur d'essais stériles
			-- repart de zéro. Une colonne de gravier n'est donc bornée que par
			-- maxDig, jamais par tries.
			stats.dug = stats.dug + 1
			dug = dug + 1
			idle = 0
			lastReason, lastDetail = "blocked", nil
		else
			-- Rien devant mais le mouvement échoue : une entité occupe la case.
			-- Elle ne compte pas comme un progrès : un flux continu de mobs
			-- (spawner) doit finir par rendre la main.
			if not o.attack then return false, "entity" end
			turtle[op.attack]()
			stats.attacks = stats.attacks + 1
			idle = idle + 1
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
	notify()
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
	notify()
	return true
end

function M.turnLeft()
	turtle.turnLeft()
	pos.dir = ccVec.turnLeft(pos.dir)
	stats.turns = stats.turns + 1
	notify()
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

--- Détermine le cap réel. Le GPS donne une position, jamais une orientation :
-- il faut donc bouger d'un bloc et comparer.
--
-- Le sondage vise une case adjacente DÉJÀ LIBRE, trouvée en pivotant sur place.
-- Trois raisons :
--
--   * Aucun bloc n'est cassé. Le repérage ne dégrade pas le terrain, en
--     particulier hors de l'emprise du chantier.
--   * Dans une carrière, le turtle se trouve dans le couloir qu'il vient de
--     creuser : une case libre existe toujours, et elle est à l'intérieur du
--     volume travaillé, donc dans un chunk qui était actif il y a un instant.
--     Un turtle dans un chunk déchargé ne tourne pas du tout ; le vrai risque
--     est de franchir une frontière vers un chunk inactif, et sonder une case
--     déjà creusée l'évite.
--   * Deux fois moins de carburant qu'un aller-retour à l'aveugle raté.
--
-- N'utilise pas les primitives de ce module et ne touche pas à la position
-- suivie : le cap est justement ce qu'on ne connaît pas encore. Le turtle est
-- remis dans son orientation et sa case d'origine.
--
-- @param o  { timeout, dig = false }  dig autorise à creuser si aucune case
--           adjacente n'est libre. À n'activer que si l'appelant sait que le
--           turtle est dans l'emprise du chantier.
-- @return dir, ou nil + raison
function M.gpsHeading(o)
	o = o or {}
	local before = M.gpsPosition(o.timeout)
	if not before then return nil, "gps indisponible" end

	-- Recherche d'une case libre, un quart de tour à la fois.
	local turns = 0
	while turns < 4 and turtle.detect() do
		turtle.turnRight()
		turns = turns + 1
	end

	if turns == 4 then
		-- Quatre quarts de tour : on est revenu à l'orientation de départ et
		-- rien n'est libre.
		if not o.dig then return nil, "aucune case libre pour se repérer" end
		if not turtle.dig() then return nil, "aucune case libre pour se repérer" end
		turns = 0
	end

	local function restore()
		for _ = 1, turns do turtle.turnLeft() end
	end

	if not turtle.forward() then
		restore()
		return nil, "déplacement impossible"
	end

	local after = M.gpsPosition(o.timeout)

	-- Retour sur la case d'origine. Si le recul échoue (quelque chose s'est
	-- glissé derrière), demi-tour, un pas, demi-tour.
	if not turtle.back() then
		turtle.turnRight() turtle.turnRight()
		turtle.forward()
		turtle.turnRight() turtle.turnRight()
	end
	restore()

	if not after then return nil, "gps indisponible après déplacement" end

	local dx, dy = after.x - before.x, after.y - before.y
	local measured
	if dx == 1 then measured = 0
	elseif dy == 1 then measured = 1
	elseif dx == -1 then measured = 2
	elseif dy == -1 then measured = 3
	else return nil, "déplacement non concluant" end

	-- Le cap mesuré est celui d'APRÈS les `turns` quarts de tour à droite.
	return (measured - turns) % 4
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
