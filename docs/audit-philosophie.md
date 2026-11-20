# Audit : Qlick Lab face à sa philosophie

Date : 20 novembre 2026. Branche lue : `feature/import-library` (refonte de la bibliothèque, R1 à R8, non poussée).
Sources : le code local, l'app RedLamp (`pdcgomes/redlamp`), l'app QLab (`Kede0111/QLab`), trois articles sur
l'interface Leica donnés par Quentin, et sa planche de pictogrammes en trait fin.

Ce document ne change rien au code. Chaque proposition attend l'accord de Quentin.

---

## 0. En bref

1. **L'âme est là.** Archives, Boxes, Rolls, la cartouche, la boîte à archives, le crayon rouge, la table lumineuse,
   la planche contact imprimable, la carte film et le moteur spectral sont exactement ce que dit la philosophie.
2. **Le problème est la quantité de portes, pas les fonctions.** Les recettes s'ouvrent par 4 chemins, l'avant/après
   par 4, le catalogue par 2 menus ; la barre latérale mélange des lieux (Archives, Boxes) et des pièces (Import,
   Develop, Compare, Recipes, Stocks). C'est ce qui donne l'impression de « trop de choses d'un coup ».
3. **Trois parties règlent l'essentiel** : un sélecteur central en haut, Library · Lab · Print (inspiré de RedLamp),
   une barre latérale qui ne montre plus que les lieux (Archives, Boxes, Rolls), les recettes et les stocks rangés
   dans le Lab, l'export sorti de l'inspecteur pour devenir Print.
4. **Recettes** : il manque l'export groupé, l'afficher/masquer par recette et par stock, et des favoris solides
   (aujourd'hui rangés par nom, perdus au renommage).
5. **Charte** : un seul fichier de jetons partagé avec QLab (noirs, gris, un rouge), la police système, des capitales
   espacées, des chiffres à chasse fixe, des pictos maison en trait fin. Rien de propriétaire à Leica.

Décisions à prendre par Quentin : voir la section 7. Version visuelle : `Qlick-Lab-Audit.pptx` (dossier du projet).

---

## 1. La grille de lecture

Chaque élément de l'app passe ces quatre questions, tirées de la philosophie :

| Question | Si la réponse est non |
|---|---|
| **Est-ce un geste de labo ?** (charger un film, développer, tirer, ranger en boîte, annoter la planche) | Le reformuler en geste de labo, ou le retirer. |
| **Sert-il le rendu argentique ou le flux d'un photographe argentique ?** | C'est de la retouche ou de la photothèque générale : le cacher ou le retirer. |
| **A-t-il une seule porte ?** | Garder la plus naturelle, supprimer les autres. |
| **Est-il visible seulement quand il sert ?** | Le replier un niveau plus bas. |

La règle Leica (section 5) se résume pareil : *das Wesentliche*, retirer un contrôle avant d'en ajouter un.

---

## 2. Écart entre l'app et sa philosophie

### 2.1 Ce qui est juste et à garder tel quel

- **Library** : Archives, Boxes (visuels boîte à archives et cartouche voulus), Rolls, planche contact (classique,
  compacte, détail), crayon rouge, table lumineuse, impression de planche, étagère de Boxes.
- **Lab** : la carte film, les plateaux film/papier, les curseurs rouges arrondis, la loupe, la légende (`PrintLabel`),
  le recadrage, la bordure, Compare (films, recettes, versions).
- **La règle des fichiers** : aucune photo déplacée ni supprimée, sidecars `.qlick`, seule exception « Remove
  rejected » derrière une confirmation.

### 2.2 En trop : à retirer

| Priorité | Élément | Où | Pourquoi (philosophie) |
|---|---|---|---|
| **P1** | Les 5 commandes « Build Thumbnails/Previews… » et « Stop All » du menu Lab | `App/LabMenu.swift` | Un labo ne demande pas au photographe de fabriquer ses caches. Le travail se fait seul ; la pilule de fond suffit. |
| **P1** | Le menu Catalogue en double (File et Lab) | `App/LabMenu.swift:26` | Une seule porte. Garder File. |
| **P1** | La pièce Recipes et la pièce Stocks au premier niveau de la barre latérale | `App/Sidebar.swift`, `App/LabState.swift:8` | Ce sont les étagères du Lab, pas des lieux. Elles rejoignent le Lab (section 4). |
| **P1** | Le réglage global « Fotufilm films » | `Develop/EditorModel.swift:137` | Remplacé par l'afficher/masquer par stock (section 3.3). Le crédit CC BY-SA reste sur la fiche du stock. |
| **P2** | L'onglet Effects, qui ne contient que l'aberration chromatique | `Develop/Inspector.swift` | Un onglet pour un seul réglage. Le fondre dans Emulsion (côté optique / appareil). |
| **P2** | Deux des quatre portes de l'avant/après (bouton de barre d'outils, ⌥⌘B) | `Develop/DevelopToolbar.swift`, `App/MainMenu.swift` | Garder la touche Y et le mode de Compare. |
| **P2** | Deux des quatre portes des recettes (la ligne « Recipe · Browse », le panneau ⌥⌘P séparé) | `Develop/DevelopControls.swift` (~637), `Recipes/PresetInspector.swift` | Garder le tiroir du Lab et le menu de la légende. |
| **P2** | « View › Show Grid (G) » comme deuxième nom de la planche | `App/MainMenu.swift` | La grille héritée de l'éditeur fait doublon avec le style `grid` de la planche. Une seule planche, plusieurs styles. |
| **P3** | La page Library quand elle répète la barre latérale | `Library/LibraryHome.swift` | Garder l'étagère de Boxes et la fiche d'archive ; retirer ce qui recopie la liste de gauche. |

### 2.3 À simplifier

| Priorité | Élément | Proposition | Pourquoi |
|---|---|---|---|
| **P1** | « Extend to 3:4 for Instagram » | Devient « Extend to 3:4 portrait », dans Print. | Le nom d'une autre app dans l'interface (règle du CLAUDE.md) ; c'est un réglage de tirage, pas de développement. |
| **P1** | L'onglet Output de l'inspecteur (taille, bordure, export) | Part dans Print. Develop garde Develop / Emulsion. | Développer et tirer sont deux étapes du labo. |
| **P1** | Réglages : Speed et Upkeep | Une seule section « Upkeep » (aperçus, proxies, stockage), en langage simple. | Moins de réglages techniques exposés. |
| **P2** | Mots-clés (panneau ⌘K, jeux ⌥1–9), titre et légende, langage `rating:>=3 film:…`, Smart Rolls à règles imbriquées, piles | **Ajoutés à ta demande en R4, R5, R7 : je signale l'écart, je ne propose pas de les retirer.** Garder crayon, étoiles, labels, recherche simple et piles de rafale (réflexe de planche). Ranger mots-clés et légende dans la fiche d'info de la photo, sans panneau ni jeux de touches ; Smart Rolls en formulaire simple à un niveau ; le langage de requête reste possible dans le champ de recherche sans être documenté dans l'interface. | Ce sont les fonctions les plus « photothèque générale » de l'app. |
| **P2** | Libellés techniques : « Scanner », « Color Management », « Output » | Mots de labo : « Scan », « Colour » ou « Paper », « Print ». À valider un par un. | Le vocabulaire du labo physique. |
| **P2** | Deux systèmes de favoris de stocks (`qlick.favouriteStocks` et `favoriteFilms` / `favoritePapers`) | Un seul. | Une étoile posée à un endroit doit se voir partout (règle du CLAUDE.md). |
| **P3** | Commentaires de code qui citent d'autres logiciels | Les reformuler (« as Lightroom… » dans `LibrarySorting.swift`, `PreviewBuilder.swift`, `MainMenu.swift`, `EditorModel+Rendering.swift`, etc.). | Règle du CLAUDE.md : dire ce que fait le code. |

### 2.4 À améliorer dans le sens de la philosophie

- **La bascule Lab ↔ planche contact** en une touche (aujourd'hui Esc/G et E/Return, mais rien ne l'annonce) : la
  rendre visible dans le sélecteur central (section 4.2).
- **Recettes** : export groupé, afficher/masquer, favoris par identifiant (section 3.3).
- **Print comme pièce** : formats de tirage enregistrés (« Web », « Archive TIFF », « Planche »), la bordure et le
  papier, la file d'export, l'impression de planche, l'export LUT. Aujourd'hui l'export est un panneau de sauvegarde.
- **Clins d'œil de labo** à étendre là où ils manquent, sans décor : la pochette du Roll à l'import, la fiche de
  tirage sur Print (film, papier, recette, date), le numéro de vue sur la bande.

---

## 3. Ce que RedLamp fait bien et qui nous manque

RedLamp est une app Swift très ambitieuse (≈ 1 300 fichiers Swift, ≈ 456 000 lignes) qui reprend l'organisation
d'un logiciel de photothèque généraliste. **On ne copie ni son code ni son organisation** ; on retient quatre idées.

### 3.1 Le sélecteur central (P1)

Fichiers chez RedLamp : `packages/RedlampUI/Sources/Modules/ModulePicker.swift` et voisins.

- Une capsule à deux segments, posée dans la barre d'outils et **centrée sur la fenêtre**, sur une plaque de verre
  (Liquid Glass, rayon 18, hauteur 36). Les clics à côté passent à la barre pour déplacer la fenêtre.
- Le changement se fait **au `mouseDown`**, pas au relâchement : c'est une grande partie de la sensation de vitesse.
- **Aucune animation.** Les deux vues sont construites une fois au démarrage, superposées ; la bascule ne change que
  leur opacité (`alphaValue` 0/1). Masquer/réafficher forcerait une remise en page. Les clics, le défilement et
  VoiceOver ne vont qu'à la vue visible.
- **Un seul modèle** porte la sélection, la photo active et la vue courante : rien n'est perdu à la bascule. Revenir
  au développement montre d'abord l'aperçu, puis le rendu.
- Raccourcis ⌥⌘1 / ⌥⌘2, et une commande « revenir à la vue précédente ».

Chez nous : le point d'accroche est `TitleBand` (`App/TitleBar.swift`), bande de 38 pt commune à toutes les pièces,
centre libre. Attention : cette bande ne reçoit pas les clics (`EditorFrameView.hitTest`) ; ils passent par
`EditorWindow.sendEvent`, comme les miettes de titre, et le sélecteur doit suivre le même chemin. Mise à jour au même
endroit que les miettes (`EditorWindowController.swift:518`), action `lab.show(...)`.

### 3.2 L'infrastructure qui rend RedLamp si vif

Notre pipeline est déjà rapide (image rapide, puis à la taille de l'écran, puis détaillée ; balance par matrice ;
aperçus faits à l'avance). Les différences qui comptent, classées par intérêt pour nous :

| Priorité | Idée RedLamp | Chez nous aujourd'hui | Proposition |
|---|---|---|---|
| **P1** | Bascule par opacité, vues construites une fois | Develop est l'éditeur, les autres pièces le recouvrent | Avec le sélecteur : garder Library et Lab vivants, basculer par opacité. |
| **P2** | Préchargement selon la direction : 12 vignettes devant, aperçus des 2 photos suivantes | Aperçus faits à l'avance, sans tenir compte du sens de navigation | Précharger l'aperçu développé des 2 vues suivantes dans le sens des flèches. Le plus visible pour un coût faible. |
| **P2** | Rendus annulables (drapeau atomique par tâche, « le dernier gagne ») | Un rendu parti n'est pas interrompu ; les éditions dépassées sont seulement sautées | Un jeton d'annulation vérifié entre les étapes du moteur Rust (`spektrafilm-native`). Le gain est réel quand on change vite de film sur un gros fichier. Demande du travail côté Rust et des mesures avant. |
| **P2** | Travail de fond en trois voies (à l'écran, en avance, en fond), la voie de fond en QoS `utility` (le `background` strict mesuré 28 fois plus lent pendant l'indexation Spotlight), pause en économie d'énergie ou à chaud | Le travail de fond s'arrête quand l'éditeur travaille | Vérifier nos QoS ; ajouter la pause en économie d'énergie et en surchauffe. |
| **P3** | Paquets de vignettes par dossier, mappés en mémoire, budget disque 1 Go | Une vignette par fichier en Caches | À faire seulement si la planche rame sur de grosses archives. Mesurer d'abord. |
| **P3** | Index SQLite et colonnes pour trier et filtrer | Index du catalogue en JSON ; la première indexation d'un gros catalogue est lente | Même chose : mesurer d'abord sur 20 000 photos. |
| **P3** | Budgets de performance mesurés, historique (`docs/performance`) | Les tests de rendu rapides existent | Un petit fichier de mesures (ouverture, changement de film, bascule) relancé à chaque version. |

La règle de RedLamp à adopter telle quelle : **les sidecars sont la vérité, l'index est jetable**. C'est déjà notre
cas ; le garder.

### 3.3 Recettes : gestion, export, afficher/masquer (P1)

Chez nous : un fichier JSON par recette dans `Presets`, ordre manuel dans `.order.json` (glisser seulement dans le
panneau), import multiple, export d'une recette à la fois, favoris rangés **par nom** dans les préférences
(`LabState.swift:675`), donc perdus au renommage et absents du catalogue. Les stocks n'ont pas de masquage.

Ce que RedLamp et QLab apportent :

- **Un identifiant stable** (UUID) et une version dans chaque recette ; favoris et masquage s'appuient dessus.
- **Les groupes `includes`** (RedLamp) : une recette déclare ce qu'elle touche (film, papier, grain, halation,
  couleur…) et laisse le reste de la photo intact. Très labo : une recette « grain Tri-X » ne change pas la balance.
- **Les valeurs sont copiées dans le développement**, jamais une référence vivante : modifier une recette plus tard
  ne change pas les tirages déjà faits (déjà notre cas, à garantir par un test).
- **Une vignette intégrée** (QLab) pour reconnaître la recette sans rendu.

Proposition :

1. **Afficher / masquer** par recette et par stock. Les masqués ne paraissent plus dans le plateau ni dans Compare,
   restent dans l'étagère du Lab avec un filtre « Hidden ». Le réglage « Fotufilm films » disparaît.
2. **Favoris par identifiant**, rangés avec la recette, un seul système pour films, papiers et recettes.
3. **Export groupé** : sélection multiple → un paquet (un dossier zippé, extension à choisir, par exemple
   `.qlickrecipes`) avec les presets de section utilisés. Import par glisser-déposer.
4. **Tri** : ordre manuel (déjà là, à rendre possible partout), par film, par date, par usage ; recherche dans
   l'étagère.
5. **Un format commun avec QLab** : aujourd'hui `.qlabrecipe` côté QLab et le JSON spektrafilm côté Qlick Lab.
   Décider d'un seul schéma (ou d'une conversion à l'import) avant la fusion.

### 3.4 À ne pas reprendre de RedLamp

L'organisation en modules d'un logiciel de photothèque, les dizaines de panneaux, les imports de presets d'autres
logiciels, le magasin de recettes et les signatures, l'IA générative, le débruitage, les masques. Tout cela nous
éloignerait du labo.

---

## 4. Restructuration : Library · Lab · Print

### 4.1 Où va chaque surface

| Partie | Ce qu'on y trouve | Vient de |
|---|---|---|
| **Library** | Import, planche contact (tous ses styles), Archives, Boxes, Rolls, Last Import, Picks, recherche, table lumineuse, impression de planche | Sidebar, `Library/`, `Import/`, `ContactSheet/` |
| **Lab** | Développement (Develop, Emulsion), carte film, plateaux, loupe, recadrage, légende ; **étagère** des recettes et des stocks (tiroir à droite) ; Compare comme outil ; la planche contact du Lab (même vue, mêmes photos) | `Develop/`, `Recipes/`, `Compare/` |
| **Print** | Tirage : taille, bordure et papier, espace couleur, format ; formats enregistrés ; file d'export ; export LUT ; impression de planche (aussi accessible depuis Library) | Onglet Output, `Export/`, `ContactSheet/SheetPrint.swift` |
| **Partout** | Archives et Boxes dans la barre latérale ; réglages dans le menu de l'app (⌘,) | |

### 4.2 Le sélecteur central

- Trois segments **Library · Lab · Print**, au centre de la bande de titre, capsule unique, segment actif en rouge
  (comme `SegmentedChoice` de QLab), libellés en capitales espacées.
- Raccourcis : ⌘1, ⌘2, ⌘3 (à vérifier contre les raccourcis existants ; aujourd'hui ⌥⌘2 / ⌥⌘3 servent aux pièces).
- **Une touche pour Lab ↔ planche contact** : on garde ce qui existe (Esc ou G vers la planche, Return ou E vers le
  développement) et on l'annonce dans l'aide du sélecteur. Dans le Lab, la planche s'affiche sans quitter le Lab ;
  elle montre ce qui est sélectionné dans les Archives et les Boxes.
- Bascule instantanée par opacité, sans animation, au `mouseDown` (section 3.1).

### 4.3 La barre latérale simplifiée

Avant : en-tête de catalogue, six pièces (Import, Contact Sheet, Develop, Compare, Recipes, Stocks), Library
repliable, Archives, Boxes, Settings.

Après : **la barre suit le sélecteur**. En haut, les pièces de la partie choisie (Library : Import, Contact Sheet ;
Lab : Develop, Recipes, Stocks ; Print : Export). En dessous, toujours : Archives (avec leurs Rolls) et Boxes. Picks,
Rejects et étoiles passent dans la barre de tri du bas (4.4). Settings rejoint le menu de l'app. Une barre qui
listerait les trois parties en permanence ferait double porte avec le sélecteur.

### 4.4 Les images d'inspiration de Quentin (20 novembre)

Deux maquettes générées, à ne pas recopier. Ce qu'on reprend, parce que c'est du labo :

- le sélecteur Library · Lab · Print au centre de la bande de titre ;
- **la cartouche avec sa languette de film** pour les Rolls (image 2), numéro et photo affichés par l'app en vrai
  texte et vraie image ; fichier demandé en SVG, ou PNG transparent d'au moins 2048 px ;
- **une barre de tri en bas** de la planche : All, Picks, Rejects, Unmarked, étoiles, Sort ;
- l'état vide dessiné en trait fin.

Ce qu'on laisse ou vérifie : les boîtes des deux images (Quentin ne les aime pas ; les visuels boîte à archives de R8
restent) ; les emballages de marques de films
(citer le nom du film, ne pas copier l'habillage) ; une barre latérale qui répète les trois parties.

Le logo de Qlick Lab, cercle et point rouge, **est gardé** (Quentin, 20 novembre) : c'est la marque de l'app, pas un
écart.

---

## 5. Charte visuelle : esprit Leica, harmonisée avec QLab

### 5.1 Ce qu'on retient de Leica (inspiration, rien de propriétaire)

D'après l'entretien Macfilos (mars 2026) : l'objectif est de « continuer à simplifier (*das Wesentliche*) » ; les
tuiles sont passées de 12 à 8, les lignes de page de 6 à 5, les boutons de 5 à 3. Menus linéaires, nom de section
toujours affiché, un centre de contrôle où l'on choisit ce qui paraît. Un lecteur reproche des symboles difficiles à
lire : d'où notre règle « un mot avec chaque icône ».

**À ne pas reprendre** : la police maison (LG1050 et ses variantes), les icônes Leica, le logo Leica, les noms
Leica, FOTOS, LUX, la grammaire gravée exacte. Le point rouge du logo de Qlick Lab, lui, reste : c'est sa marque.

Huit règles pour Qlick Lab :

1. **Un seul accent.** Le rouge marque l'actif, le sélectionné, l'action principale. Jamais en décor. Une zone rouge
   dominante par vue.
2. **Des gris en paliers fixes**, pas de dégradés décoratifs. Le centre de l'écran reste neutre pour juger l'image.
3. **L'essentiel visible, le reste un niveau plus bas.** Viser cinq entrées visibles par section.
4. **Menus linéaires**, nom de section toujours affiché, pas d'arbre profond.
5. **Un mot avec chaque icône**, sauf pour les gestes universels.
6. **Retirer avant d'ajouter.** Chaque version enlève un contrôle avant d'en ajouter un.
7. **Typographie technique** : chiffres à chasse fixe, une famille, deux graisses, étiquettes en capitales grises,
   valeurs en blanc.
8. **Mouvement et son discrets** : transitions de 120 à 200 ms en ease-out, sans rebond ; aucun son par défaut.

### 5.2 Jetons communs avec QLab

Les deux apps sont déjà proches. Proposition : **un seul fichier de jetons** (`design-tokens.json`), copié dans les
deux dépôts, d'où chaque app génère son `Theme` (SwiftUI et AppKit).

| Jeton | Qlick Lab aujourd'hui (`Design/Theme.swift`) | QLab (`App/Sources/Design/Theme.swift`) | Proposition |
|---|---|---|---|
| fond | `#0a0a0b` | noir `#000` | `#000` dans la planche (le noir du film), `#0a0a0b` autour |
| surface | panel `#141415` | blanc 7 % ≈ `#121212` | `#131314` |
| surface levée | raised `#1d1d1d` | blanc 11,5 % ≈ `#1d1d1d` | `#1d1d1d` (identique) |
| filet | line `#28282a` | blanc 20 % | `#28282a` sur macOS (les écrans de bureau en demandent moins) |
| discret | faint `#525252` | blanc 32 % ≈ `#525252` | `#525252` (identique) |
| secondaire | dim `#8a8a8f` | blanc 50 % ≈ `#808080` | `#8a8a8f` |
| texte | paper `#f0f0f0` | blanc 94 % ≈ `#f0f0f0` | `#f0f0f0` (identique) |
| **rouge** | sRGB `#e5222b` | Display P3 (0,89 ; 0,11 ; 0,14) | **Une seule définition**, à fixer à l'œil sur les deux écrans, écrite dans les deux espaces. |
| alerte | warn `#ffa64d` | — | Garder, uniquement pour les vraies alertes. |

Formes : rayons continus. Bouton, tuile, ligne de réglage : 14 ; dialogue : 22 ; panneau flottant : 26 ; vignette
de recette : 7. Capsule pour les segments et les pilules. Ressorts : réponse 0,34, amortissement 0,86 ; rapide :
ease-out 0,16 s.

### 5.3 Typographie

- Police système (SF Pro) partout ; aucune police de marque. Chiffres en `monospacedDigit`.
- **Étiquette en capitales** (`CapsLabel` de QLab) : 11 pt medium, interlettrage 0,11 × la taille. À reprendre
  telle quelle pour les en-têtes de section, le sélecteur central, les onglets.
- Valeurs : 13 à 15 pt regular, chasse fixe. Titres : 22 pt semibold.
- Pour les micro-étiquettes de pictos (ISO, format, « 35 MM »), la largeur condensée de SF Pro, en capitales, sur
  deux lignes empilées, comme sur la planche de pictos de référence.

### 5.4 Pictogrammes

Référence : la planche en trait fin donnée par Quentin (trait unique d'environ 1,5 pt, angles nets ou légèrement
arrondis, pas de remplissage, micro-texte en capitales condensées dans le picto). **On dessine les nôtres**, sur une
grille de 24 pt, dans `LabGlyph` (déjà commencé en R8) :

cartouche 135, boîte à archives, Roll, planche contact, loupe, table lumineuse, agrandisseur, cuve, bac de
développement, pince à film, ciseaux (couper une bande), crayon, tirage, papier, lampe inactinique, flèche de vue
(le triangle de numérotation des films).

Chaque picto est accompagné d'un mot (règle 5).

### 5.5 Réglages façon QLab

L'écran Réglages de QLab est le modèle : une liste courte de catégories (cartes de 54 pt de haut, rayon 14, icône
fine, chevron), puis des pages simples. Interrupteurs teintés en rouge, segments en capsule rouge, curseur fin à
remplissage rouge **à partir du neutre**, double-clic pour revenir au neutre, valeur en chasse fixe et estompée au
neutre. Pour Qlick Lab : 4 catégories au plus (Photographs, Upkeep, Shortcuts, About), au lieu de 4 onglets
techniques.

---

## 6. Plan proposé, par lots

Chaque lot est un commit (ou quelques-uns), testé dans Qlick Lab Dev, sur une branche locale à partir de
`feature/import-library`.

| Lot | Contenu | Priorité | Taille |
|---|---|---|---|
| **A. Ménage** | Retirer les commandes de caches du menu Lab, le menu Catalogue en double, fondre Speed et Upkeep, « Extend to 3:4 portrait », commentaires qui citent d'autres logiciels | P1 | petit |
| **B. Jetons** | `design-tokens.json` partagé, `Theme` généré, rouge commun, `CapsLabel` | P1 | petit |
| **C. Sélecteur Library · Lab · Print** | Capsule centrale, ⌘1/2/3, bascule par opacité au `mouseDown`, barre latérale réduite aux lieux | P1 | moyen |
| **D. Étagère du Lab** | Recipes et Stocks en tiroir du Lab ; une porte par fonction ; favoris par identifiant ; afficher/masquer ; tri | P1 | moyen |
| **E. Export des recettes** | Paquet de recettes, import par dépôt, format décidé avec QLab | P1 | petit à moyen |
| **F. Print** | Pièce Print : onglet Output déplacé, formats enregistrés, file d'export, impression de planche, LUT | P2 | moyen |
| **G. Simplifications** | Effects fondu dans Emulsion ; avant/après et grille à une porte ; mots-clés et légende dans la fiche d'info ; Smart Rolls à un niveau ; libellés de labo | P2 | moyen |
| **H. Vitesse** | Préchargement directionnel, QoS et pause thermique, puis rendus annulables côté Rust après mesures | P2 / P3 | moyen à grand |
| **I. Pictos** | Compléter `LabGlyph` en trait fin, un mot avec chaque icône | P2 | moyen |

---

## 7. Décisions pour Quentin

1. **Le sélecteur** : trois segments Library · Lab · Print (ma recommandation, c'est ta structure), ou deux comme
   RedLamp (Library · Lab) avec Print en bouton ?
2. **Mots-clés, légende, Smart Rolls, langage de requête** (ajoutés en R4/R5) : les garder en les rangeant comme en
   2.3 (ma recommandation), ou les retirer ?
3. **Effects** : fondre l'aberration chromatique dans Emulsion ?
4. **Format de recette commun avec QLab** : un schéma unique dès maintenant, avant que les deux divergent (ma
   recommandation), ou une conversion à l'import plus tard ?
5. **Le rouge commun** : partir de celui de QLab (P3, écrit aussi en sRGB pour macOS ; ma recommandation) ou de
   celui de Qlick Lab (`#e5222b`) ?
6. **L'ordre des lots** : A, B, C, D, E d'abord (ma recommandation), puis F, G, H, I.

### Décisions de Quentin (20 novembre 2026)

Les six recommandations sont validées, avec ces réserves :

1. **Sélecteur** : trois segments Library · Lab · Print. La barre latérale suit le sélecteur : les pièces de la
   partie choisie en haut, Archives et Boxes toujours en dessous. Bascule au `mouseDown`, sans animation ; ⌘1/2/3 et
   la touche unique Lab ↔ planche.
2. **Mots-clés, légende, Smart Rolls, langage de requête** : gardés et rangés comme en 2.3 (mots-clés et légende
   dans la fiche d'info, Smart Rolls à un niveau, barre de tri en bas de la planche).
3. **Effects** : fondu dans Emulsion.
4. **Format de recette commun avec QLab** : **reporté tout à la fin**, à rediscuter. Le lot E fait l'export et
   l'import groupés en paquet sans format commun ; le dépôt QLab n'est pas touché.
5. **Le rouge commun** : celui de QLab, Display P3 (0,89 ; 0,11 ; 0,14), avec son équivalent sRGB pour AppKit. Le
   fichier de jetons vit dans ce dépôt seulement, d'où le `Theme` est généré.
6. **Ordre** : A, B, C, D, E, F, G, I. **Le lot H (vitesse) est exclu** : ni le moteur de rendu, ni le pipeline
   d'aperçu, ni les caches, ni le moteur Rust. Les idées RedLamp viendront plus tard, dans une branche de test séparée.

Le point rouge du logo est gardé (sections 4.4 et 5.1 corrigées).
