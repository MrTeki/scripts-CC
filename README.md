# scripts CC

Scripts ComputerCraft / CC:Tweaked pour Minecraft, par Teki.

Ce dépôt est la **source de vérité** des scripts. Les copies présentes ailleurs sur
le disque (`F:\Minecraft\scripts CC\*.lua`) sont désormais du legacy.

---

## Scripts

| Script | Machine | Rôle |
|---|---|---|
| `ccQuarry.lua` | turtle | Creuse une carrière rectangulaire, avec reprise après reboot |
| `ccChopper.lua` | turtle | Ferme à arbres : abattage, replantage, four à charbon de bois |
| `ccStairs.lua` | turtle | Creuse un escalier descendant, pose marches et torches |
| `ccFarm.lua` | turtle | Ferme à cultures : récolte et replantage |
| `ccInventory.lua` | computer | Gestion d'inventaire en réseau : coffres, moniteurs, crafting |
| `ccRemote.lua` | pocket | Interface de pilotage à distance des turtles via rednet |
| `ccClock.lua` | computer | Horloge sur moniteur |
| `ccDigiCode.lua` | computer | Digicode : signal redstone sur code correct |
| `ccNote.lua` | computer | Éditeur de notes |
| `ccSpeaker.lua` | computer | Lecture de mélodies sur speaker |

---

## Conventions

**Axes** (communs à tous les scripts de turtle, hérité de l'existant) :

- `X` / `Y` = plan horizontal, `Z` = **vertical**. Attention, ce n'est pas la
  convention Minecraft où `Y` est la verticale.
- `direction` : `0` = +X, `1` = +Y, `2` = -X, `3` = -Y.
- `turnRight()` = `dir + 1`, `turnLeft()` = `dir - 1`, modulo 4.
- Origine `(0, 0, 0)` = position de départ du turtle, en direction `0`.

**Slots réservés** (turtles) :

| Slot | Usage |
|---|---|
| 1 | Carburant — jamais vidé |
| 16 | Ender chest — jamais vidé |
| 2-15 | Butin et espace de travail |

---

## Architecture (refonte en cours)

Chaque script reste **un fichier unique**, déployable seul sur un ordinateur en jeu.
Le code commun est extrait dans des APIs partagées, installées au premier lancement.

```
/                     scripts, un fichier par programme
/apis/                APIs partagées, require-ables
/manifest.lua         nom -> url + version, source unique du bootstrap
/test/                harnais de test (mock turtle/fs/term) — ne part pas en jeu
```

### APIs

| API | État | Contenu |
|---|---|---|
| `ccBoot` | fait | installe les APIs manquantes depuis le dépôt, manifeste, atomique |
| `ccConfig` | fait | options dans un fichier Lua éditable en jeu, gabarit commenté, validation |
| `ccUtil` | fait | `roundTo`, `clamp`, `indexOf`, `contains`, `copy`, `count`, `findPeripheral(s)` |
| `ccPlan` | fait | parcours en serpentin d'un volume, en couches ; progression exacte |
| `ccVec` | fait | position et direction, normalisation `dir % 4`, `turnsBetween` |
| `ccNav` | fait | mouvement à contrat `ok, raison, bloc`, essais bornés, `goTo`, GPS |
| `ccSave` | fait | persistance atomique, clés nommées, versionnée + migration |
| `ccInv` | fait | slots réservés, recherche d'item, liste de rebut, coffre à pose vérifiée |
| `ccFuel` | fait | niveau normalisé (`"unlimited"`), budget de retour, ravitaillement au coffre |
| `ccUi` | fait | journal à ring buffer, `drawBar`, boutons clavier/souris/tactile, moniteur |
| `ccNet` | fait | sert `ccRemoteProtocol` sans bloquer, commandes mises en file |

`ccQuarry.lua` les consomme toutes. `test/test_integration.lua` les valide
ensemble, et `test/test_ccQuarry.lua` exécute le script entier sous le mock.

Deux règles structurantes, valables pour tout script qui les consomme :

- **`ccUi` et `ccNet` ne touchent jamais au turtle.** Ils traduisent une entrée
  en nom de commande et s'arrêtent là. C'est la machine à états qui exécute,
  entre deux transitions. Sans cela, un clic sur REFUEL peut changer le slot
  sélectionné au milieu d'un vidage en cours.
- **La garde carburant de `ccFuel` doit être levée pour le trajet de retour**
  (`ccNav.setGuard(nil)`). Elle raisonne sur la position courante, donc au
  moment précis où la réserve est atteinte, elle interdirait aussi les
  mouvements qui rapprochent de l'origine.

### Tests

Les APIs s'exécutent hors Minecraft, sous Lua 5.4 standard. `test/ccMock.lua`
simule `fs`, `textutils`, `turtle`, `term`, `os`, `peripheral` et `gps`, et
modélise les pannes plutôt que le cas nominal : gravier qui retombe, bedrock,
coffre plein, panne sèche, écriture disque tronquée.

```
lua test/run.lua
```

Prérequis : `winget install DEVCOM.Lua`. Ajouter chaque nouveau fichier de test
à la liste `MODULES` de `test/run.lua`.

Les cas sont vérifiés par mutation : on réintroduit le bug d'origine dans l'API
et on confirme que le test échoue, et qu'il échoue seul.

### Bootstrap

Une amorce d'une trentaine de lignes en tête de chaque script installe les APIs
manquantes depuis ce dépôt, via `raw.githubusercontent.com`. La logique vit dans
[`apis/ccBoot.lua`](apis/ccBoot.lua), pour qu'une évolution du mécanisme ne
demande pas de rééditer les scripts déjà installés.

1. **Un seul point d'entrée en dur** : `REPO`, l'URL du dépôt. Le reste passe par
   [`manifest.lua`](manifest.lua), qui décide où vivent les fichiers et quelles
   versions font foi. Déplacer un fichier ou publier une version se fait dans le
   dépôt, jamais en rééditant les scripts déployés.
   *(`CCSuiteUpdater` codait 11 identifiants pastebin en dur, dupliqués deux fois.
   Chaque mise à jour produisait un nouvel identifiant : le mécanisme est devenu
   ingérable dès la première évolution.)*
2. **Aucune requête réseau au démarrage** si tout est présent et à jour. Règle
   critique : un turtle reboote à chaque chargement de chunk et `startup` relance
   le script.
3. **Installation atomique** : téléchargement, contrôle de syntaxe par `load()`,
   écriture en `.tmp`, puis `fs.move`. Un téléchargement tronqué ne peut pas
   casser une installation qui fonctionnait.
4. **Échec doux** : si `http` est indisponible mais que tout est là, on continue
   en silence. Sinon, message nommant les APIs manquantes et l'URL.
5. `<script> update` consulte le manifeste et n'installe que ce qui est en
   retard — il ne retélécharge pas tout à l'aveugle.

Le dépôt doit rester **public** : un turtle ne peut pas garder un token GitHub
secret.

### Installer sur un ordinateur en jeu

```
pastebin get <id> ccQuarry
ccQuarry 16 16 64
```

Le premier lancement télécharge `apis/` tout seul. Sans HTTP, copier le dossier
`apis/` à la main ; le script le dit explicitement et donne l'URL.

---

## État

`main` contient les scripts tels qu'ils tournaient avant refonte, sans
modification. La refonte de `ccQuarry.lua` et l'extraction des APIs se font sur
`refonte/apis-socle`.
