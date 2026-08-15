-- Manifeste du dépôt : source unique de vérité pour le bootstrap.
--
-- Les scripts déployés ne codent en dur qu'une seule chose, l'URL du dépôt.
-- Déplacer un fichier ou publier une nouvelle version se fait ICI, jamais en
-- rééditant les scripts installés sur les ordinateurs.
--
-- Ce fichier est évalué dans un environnement vide : uniquement des données.

return {
	version = 1,

	apis = {
		ccBoot  = { version = 1, path = "apis/ccBoot.lua" },
		ccUtil  = { version = 1, path = "apis/ccUtil.lua" },
		ccVec   = { version = 1, path = "apis/ccVec.lua" },
		ccPlan  = { version = 1, path = "apis/ccPlan.lua" },
		ccNav   = { version = 1, path = "apis/ccNav.lua" },
		ccInv   = { version = 1, path = "apis/ccInv.lua" },
		ccFuel  = { version = 1, path = "apis/ccFuel.lua" },
		ccSave  = { version = 1, path = "apis/ccSave.lua" },
		ccUi    = { version = 1, path = "apis/ccUi.lua" },
		ccNet   = { version = 1, path = "apis/ccNet.lua" },
	},

	scripts = {
		ccQuarry    = { path = "ccQuarry.lua" },
		ccChopper   = { path = "ccChopper.lua" },
		ccStairs    = { path = "ccStairs.lua" },
		ccFarm      = { path = "ccFarm.lua" },
		ccInventory = { path = "ccInventory.lua" },
		ccRemote    = { path = "ccRemote.lua" },
		ccClock     = { path = "ccClock.lua" },
		ccDigiCode  = { path = "ccDigiCode.lua" },
		ccNote      = { path = "ccNote.lua" },
		ccSpeaker   = { path = "ccSpeaker.lua" },
	},
}
