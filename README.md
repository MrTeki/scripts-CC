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
| `ccUtil` | fait | `roundTo`, `clamp`, `indexOf`, `contains`, `copy`, `count`, `findPeripheral(s)` |
| `ccVec` | fait | position et direction, normalisation `dir % 4`, `turnsBetween` |
| `ccNav` | fait | mouvement à contrat `ok, raison, bloc`, essais bornés, `goTo`, GPS |
| `ccSave` | fait | persistance atomique, clés nommées, versionnée + migration |
| `ccUi` | à faire | log à ring buffer, `drawBar`, table de boutons clavier/souris, moniteur externe |
| `ccInv` | à faire | listing de slots, slots réservés, recherche d'item, interaction coffre |
| `ccFuel` | à faire | niveau normalisé (`"unlimited"`), budget de retour, ravitaillement au coffre |
| `ccNet` | à faire | protocole rednet commun : `status`, `pause`, `resume`, `abort`, `home` |

Aucune de ces APIs n'est encore consommée par un script : la migration de
`ccQuarry.lua` et le bootstrap viennent après.

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

Un préambule identique en tête de chaque script installe les APIs manquantes depuis
ce dépôt, via `raw.githubusercontent.com`. Règles :

1. **Un seul point d'entrée en dur** : l'URL de `manifest.lua`. Mettre à jour une API
   = mettre à jour le manifeste, jamais les scripts déployés.
   *(L'ancien `CCSuiteUpdater` codait 11 ids pastebin en dur et est devenu ingérable.)*
2. **Pas de requête réseau au démarrage** si tout est présent et à jour. Un turtle
   reboote à chaque chargement de chunk ; télécharger à chaque boot ferait tomber
   les limites de débit.
3. **Installation atomique** : téléchargement en `.tmp`, vérification syntaxique via
   `load()`, puis `fs.move`. Un téléchargement tronqué ne doit jamais casser
   l'installation.
4. **Échec doux** : si `http` est indisponible mais que les APIs sont déjà là, on
   continue. Sinon, message explicite nommant l'API et son URL.
5. Rafraîchissement forcé par `<script> update`.

Le dépôt doit rester **public** : un turtle ne peut pas garder un token GitHub secret.

---

## État

`main` contient les scripts tels qu'ils tournaient avant refonte, sans
modification. La refonte de `ccQuarry.lua` et l'extraction des APIs se font sur
`refonte/apis-socle`.
