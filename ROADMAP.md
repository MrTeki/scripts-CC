# Feuille de route

État au dernier essai en jeu : `ccQuarry` tourne sur les APIs partagées, le
bootstrap installe tout seul, et le chantier va au bout. Ce qui suit est ce qui
reste, par ordre de valeur décroissante.

---

## Prochaine étape

### Fusionner `refonte/apis-socle` dans `main`

`REPO` pointe encore sur la branche de refonte. Une fois fusionnée, rebasculer
la constante en tête de [ccQuarry.lua](ccQuarry.lua) **et de**
[ccChopper.lua](ccChopper.lua) sur `.../scripts-CC/main/`. Ça raccourcit l'URL
d'installation et évite d'oublier qu'on tourne sur une branche.

C'est la seule chose que le manifeste ne peut pas porter — il faut bien une URL
en dur pour aller le chercher. La corvée grandit donc d'une ligne par script
migré : à six scripts, prévoir un `sed` plutôt que six éditions à la main.

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

`ccStairs`, `ccFarm`, `ccRemote`, `ccInventory`. Chacun récupère au passage les
corrections déjà faites :

- `getFuelLevel()` qui renvoie `"unlimited"` et fait planter les comparaisons ;
- `drawBar` centré, que `ccInventory` a et que `ccRemote` n'a jamais reçu ;
- sauvegarde atomique et versionnée ;
- options éditables en jeu.

Leçon de la migration de `ccChopper` : **le gain n'est pas en lignes.** Le
code utile est passé de 772 à 784 lignes, dont 30 de gabarit d'options. Le
mouvement, l'inventaire, le carburant et la sauvegarde ont bien fondu, mais
l'amorce, les options éditables, l'interface à boutons et le trajet de secours
n'existaient pas avant et reprennent la place. Le gain réel est ailleurs : neuf
états nommés au lieu de trois drapeaux, et plus une seule boucle non bornée.

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
- **`ccChopper` ne fait pas de recherche de chemin non plus.** Le retour
  nominal déroule la récursion d'abattage, ce qui est exact. Après un
  redémarrage cette pile est perdue, et le trajet de secours monte au-dessus de
  la canopée avant de rejoindre l'origine : correct dans une forêt, mais mis en
  échec par un surplomb.
- **`ccChopper` n'alimente le four que par le conteneur.** Une turtle ne peut
  pas viser un slot précis d'un voisin — `turtle.drop()` laisse le conteneur
  choisir, et une bûche est à la fois fondable et combustible, donc ce choix est
  indéterminé. Le four et le conteneur doivent donc être tous deux contre la
  turtle.
- **Le bois est exclu de la protection du carburant.** Dans une ferme à bois le
  butin *est* du combustible : `ccFuel.protectSlots` garderait la récolte
  entière. `ccChopper` ne protège que le combustible non ligneux, et brûle les
  bûches explicitement quand il en a besoin.
- **La marge `spareSlots` n'est pas une prévision.** Prévoir si le prochain bloc
  tiendra est impossible : `inspect()` donne le nom du bloc, pas celui du butin,
  et un même bloc peut lâcher plusieurs objets différents.

---

## Vérifications en attente

Ce qui n'a jamais tourné en conditions réelles, et qu'un essai devrait couvrir.

- **Le cycle complet de `refuelFromChest`** : aspirer, tester, retenir le rebut,
  restituer dans l'ordre. La primitive sur laquelle il repose,
  `turtle.refuel(0)`, est **confirmée en jeu** -- elle renvoie true sur un
  combustible sans rien consommer -- mais l'enchaînement complet avec un vrai
  conteneur n'a jamais tourné. Pour le déclencher : peu de carburant en slot 1,
  une pile de charbon dans le conteneur, et un chantier profond.
- **Le ravitaillement au conteneur fixe**, ajouté en même temps.
- **Le mode `dropWhenNoChest = true`**, jamais exercé en jeu.
- **`ccChopper` en entier.** Il passe 30 cas sous le mock, dont l'abattage
  complet, le retour, le four et la reprise, mais n'a jamais tourné en jeu
  depuis la migration. À surveiller en priorité : la reconnaissance du four par
  `peripheral.getNames()`, et `chest.pushItems(<côté du four>, slot, n, 1)` —
  c'est-à-dire qu'un conteneur accepte bien un nom de côté relatif au turtle
  pour désigner sa cible.

Confirmé depuis la rédaction de cette liste :

- `turtle.refuel(0)` répond sans consommer.
- `peripheral` voit bien les blocs voisins d'un turtle sur CC:Tweaked récent.
- La reprise après un vrai rechargement de partie -- elle a d'ailleurs révélé
  que les rotations n'étaient pas sauvegardées.
