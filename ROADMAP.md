# Feuille de route

État au dernier essai en jeu : `ccQuarry` tourne sur les APIs partagées, le
bootstrap installe tout seul, et le chantier va au bout. Ce qui suit est ce qui
reste, par ordre de valeur décroissante.

---

## Prochaine étape

### Fusionner `refonte/apis-socle` dans `main`

`REPO` pointe encore sur la branche de refonte. Une fois fusionnée, rebasculer
la constante en tête de [ccQuarry.lua](ccQuarry.lua) sur `.../scripts-CC/main/`.
Ça raccourcit l'URL d'installation et évite d'oublier qu'on tourne sur une
branche.

### Détecter les APIs modifiées sans montée de version

Aujourd'hui, une API qui change sans que `_VERSION` bouge doit être supprimée à
la main sur chaque ordinateur — c'est arrivé quatre fois de suite. `ccBoot`
pourrait comparer un hachage du fichier distant au local lors d'un
`<script> update`, ce qui coûte une requête par API à ce moment-là, et jamais
au démarrage normal.

Alternative plus simple : discipline stricte d'incrément de `_VERSION`. Le
mécanisme existe déjà et est testé ; il n'a pas été utilisé par choix.

---

## Inventaire et rebut

### `keepOnly` : lister ce qu'on garde plutôt que ce qu'on jette

C'est le vrai levier en monde moddé. Aucune liste de rebut ne peut suivre les
variantes de pierre d'un modpack, mais on peut énumérer ce qu'on veut :
minerais, gemmes, ancient debris. Si `keepOnly` est non vide, la logique
s'inverse — *tout ce qui n'y est pas est du rebut*.

Effet direct : la turtle ne rapporte que du butin utile, donc les trajets
s'espacent énormément.

### Journaliser la composition de l'inventaire

À chaque service : quels noms, combien de slots chacun. Sans ça, impossible de
savoir quoi mettre dans `trash` ou dans `keepOnly` autrement qu'au jugé. Presque
gratuit, et c'est ce qui rend les deux listes exploitables.

Les deux se tiennent : le second alimente le premier.

---

## Migration des autres scripts

`ccChopper`, `ccStairs`, `ccFarm`, `ccRemote`, `ccInventory`. Chacun perd 150 à
300 lignes et récupère au passage les corrections déjà faites :

- `getFuelLevel()` qui renvoie `"unlimited"` et fait planter les comparaisons ;
- `drawBar` centré, que `ccInventory` a et que `ccRemote` n'a jamais reçu ;
- sauvegarde atomique et versionnée ;
- options éditables en jeu.

`ccRemote` mérite une attention particulière : sa moitié turtle tourne dans un
`while true` bloquant, donc incompatible avec un script de travail. `ccNet`
existe pour ça et sert déjà le même protocole — il reste à câbler le contrôleur.

---

## Confort d'utilisation

### Assistant de configuration au premier lancement

Dimensions, sens de creusement, mode de dépôt, politique de rebut. Il n'aurait
qu'à **écrire `ccquarry.cfg`**, puis tout le reste fonctionne à l'identique —
ce qui évite deux chemins de configuration concurrents.
`ccStairs.lua` a déjà le motif avec `cc.completion` et `askUserForAgreement`.

### Estimation avant lancement

`ccQuarry estimate 16 16 64` : blocs, mouvements, carburant nécessaire, durée
attendue, stacks produits. `ccPlan` et `ccFuel` étant purs, c'est une vingtaine
de lignes.

### Prévision de suffisance carburant, et ETA

« Il te manque 9 200 unités pour finir », affiché en continu, plutôt que la
découverte de la panne à mi-chemin. Et cellules/minute mesurées × cellules
restantes : impossible avec l'ancien estimateur, trivial avec un compteur exact.

### Pilotage à distance complet

Pause, reprise, abandon, rappel depuis `ccRemote`. `ccNet` sert déjà le
protocole et met les commandes en file ; il manque le câblage côté contrôleur.

---

## Extensions du chantier

### Mode « minerais seulement »

`turtle.inspect()` avant de creuser, whitelist de minerais. Une carrière
d'exploration à 10 % du coût en carburant. Ne creuse pas le volume, donc
c'est un mode distinct, pas une option.

### Gestion des liquides

Détecter eau et lave devant, poser un bloc de colmatage depuis un slot dédié.
Aujourd'hui une poche de lave noie le chantier. Variante : récupérer la lave au
seau comme carburant.

### Puits d'accès dédié

Creuser une colonne verticale en (0,0) et faire les allers-retours par là, au
lieu de tunneler au niveau du sol comme aujourd'hui. Trajets plus courts, moins
de dégâts au paysage. C'est un changement d'ordre d'axes dans `goTo`.

### Formes alternatives

Tunnel 1×3, salle, cylindre. Ce n'est qu'un `ccPlan` différent — c'est
précisément l'intérêt d'avoir isolé le plan.

### Multi-turtles

Partitionner le volume par bandes de colonnes, coordination par `ccNet`. Le
plan étant paramétrable sur un sous-volume, l'architecture s'y prête.

---

## Limites connues

Ce ne sont pas des bugs, mais des contraintes assumées, à connaître.

- **Pas de recherche de chemin.** Une cellule inatteignable est contournée par
  la couche du dessus, ce qui règle un bloc isolé mais pas un champ
  d'obstacles. Un massif de bedrock coupant une couche en deux laisse la partie
  inaccessible non creusée, comptée dans « cellules inatteignables ».
- **Le coffre unique n'est vu que sur ses premières piles**, autant que de slots
  libres. Inhérent : `drop` remplit toujours par l'avant, aucune rotation n'est
  possible en vanilla.
- **Le conteneur fixe doit être derrière, à gauche ou au-dessus.** La carrière
  s'étend vers l'avant et vers la droite : un coffre posé de ces côtés-là est
  miné avec le reste.
- **`gpsHeading` coûte 2 carburant** et exige une case libre adjacente : le cap
  ne se déduit que d'un déplacement réel.
- **La marge `spareSlots` n'est pas une prévision.** Prévoir si le prochain bloc
  tiendra est impossible : `inspect()` donne le nom du bloc, pas celui du butin,
  et un même bloc peut lâcher plusieurs objets différents.

---

## Vérifications en attente

Ce qui n'a jamais tourné en conditions réelles, et qu'un essai devrait couvrir.

- **`turtle.refuel(0)`**, pivot de tout `refuelFromChest`. Le contrat « count = 0
  ne consomme rien » est documenté côté CC:Tweaked mais n'a pas été confirmé en
  jeu. Pour le déclencher : peu de carburant en slot 1, une pile de charbon dans
  le conteneur, et un chantier profond.
- **Le ravitaillement au conteneur fixe**, ajouté en même temps.
- **La reprise après un vrai reboot de chunk**, par opposition à un `Ctrl+T`
  volontaire.
- **Le mode `dropWhenNoChest = true`**, jamais exercé en jeu.
