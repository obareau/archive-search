# Archive Search

Recherche dans plusieurs fonds en accès libre depuis une seule barre : films
vintage, audio, livres, images. Outil personnel, pensé pour tourner sur un
réseau local.

## Sources

| Source | Ce qu'on y trouve | Intégration |
|---|---|---|
| **archive.org** | films, audio, PDFs — avec collections (Prelinger, radio vintage, TV classique…) | résultats dans la liste, lecteur inline, panier |
| **Gutenberg** | livres du domaine public | résultats dans la liste |
| **Wikimedia Commons** | images et médias libres | résultats dans la liste |
| **LibriVox** | livres audio lus par des bénévoles | résultats dans la liste |
| **Freesound** | sons, bruitages, prises de terrain | résultats dans la liste, lecteur inline, panier — **clé requise** |
| **Library of Congress** | leur fonds audio | **renvoi** — voir plus bas |

### Freesound demande une clé

Leur API n'a aucun quota anonyme. En créer une (gratuite) sur
<https://freesound.org/apiv2/apply/> et la poser dans `FREESOUND_TOKEN` —
drop-in systemd de préférence, pour qu'elle ne traîne pas dans le dépôt :

```
sudo systemctl edit archive-search      # [Service] / Environment=FREESOUND_TOKEN=…
```

Sans clé, la source répond par un message qui le dit, plutôt que zéro résultat
— qu'on confondrait avec « rien trouvé ».

⚠️ L'API ne livre que la **prévisualisation mp3**, pas le fichier d'origine :
celui-ci exige OAuth2, pas le simple jeton.

## Propositions connexes

Sous la barre de recherche, trois familles de suggestions dérivées **des
résultats déjà obtenus** — aucun appel réseau de plus, et ça marche pour les
sources sans API de suggestion :

- **Affiner** — mots-clés récurrents (`subject` d'archive.org, `tags` de
  Freesound, mots des titres ailleurs)
- **Auteur** — contributeurs qui reviennent
- **Année** — pour rester dans une époque

Un clic relance la recherche sur la **même source**.

⚠️ Deux filtres appris en testant : un terme vu une seule fois sur vingt
résultats n'est pas un thème (seuil à 2), et les horodatages des descriptions
archive.org (`00am`, `01pm`) sont écartés — mais pas `16mm` ni `super8`, qui
sont de vrais termes pour un fonds film.

## Panier, favoris et téléchargement

Panier et favoris vivent **côté serveur** (`~/.local/share/archive-search/`),
pas en `localStorage` : ils suivent d'une machine à l'autre et survivent au
nettoyage du cache du navigateur. Route générique `/api/list/<cart|favorites>`.

⚠️ Dernier écrivain gagne — deux onglets qui modifient en même temps, c'est le
second qui reste. Pas de fusion : à cette échelle elle coûterait plus cher que
le problème qu'elle éviterait.

Le bouton **⬇ Télécharger…** ouvre un **navigateur de dossiers** (`<dialog>`
natif : Échap, piège de focus, fond inerte) — fil d'Ariane, entrée dans les
sous-dossiers, création d'un dossier sur place. Les fichiers partent ensuite sur
le disque du serveur, sous `~/archive-search-downloads/`, avec une barre de
progression et trois tentatives en cas d'erreur réseau.

⚠️ Un navigateur ne peut PAS ouvrir le sélecteur de dossiers du système pour le
disque du serveur : `showDirectoryPicker()` viserait la machine cliente, et
n'existe qu'en HTTPS sur Chromium. D'où la navigation côté serveur.

⚠️ La destination est validée côté serveur : `../../.ssh` est refusé, un chemin
absolu est traité comme relatif. Le champ vient du navigateur, il n'est jamais
pris pour argent comptant.

Par défaut, depuis la racine, le lot va dans un sous-dossier horodaté
`<AAAA-MM-JJ_HHMM>/<source>/`. Écriture en `.part` renommé à la fin, donc rien
d'incomplet ne porte le nom final, et les doublons de titre sont suffixés.

⚠️ **Seules archive.org et Freesound donnent un vrai fichier.** Gutenberg,
Wikimedia et LibriVox ne renvoient qu'une page web : ces items sont ignorés, et
le bilan dit lesquels et pourquoi.

### Gutendex est lent

Mesuré le 2026-10-10 : 15 à 30 s par requête, et une page d'erreur HTML sous
charge. Le timeout commun de 10 s le déclarait mort alors qu'il travaillait, et
`resp.json()` levait alors « Expecting value: line 1 column 1 », qui ressemble à
un bug local. D'où `SOURCE_TIMEOUT` — 30 s pour cette source seulement, car
allonger le délai pour toutes ferait patienter une minute sur une vraie coupure
d'archive.org — plus la détection d'une réponse non-JSON et un message lisible.

### Pourquoi la Library of Congress n'est qu'un renvoi

`loc.gov` place l'ensemble de son site derrière un défi JavaScript (Cloudflare)
et répond **403 à tout programme**, y compris sur sa propre page de
documentation d'API. Un navigateur passe ce défi sans rien avoir à faire, pas un
serveur. La source ouvre donc la recherche chez eux dans un onglet, au lieu de
faire semblant de l'intégrer. Ni panier ni lecteur pour celle-là — les résultats
vivent chez eux.

Le fonds `library_of_congress` présent sur archive.org ne comble pas le manque :
c'est du texte numérisé, pas leur audio.

## Historique, nouveautés et veille

Chaque recherche est datée et enregistrée côté serveur (`history.json`, à côté
du panier), avec les identifiants déjà vus. La relancer depuis **🕘 Historique**
met donc en avant ce qui est **apparu depuis la dernière fois** : liseré ambre,
badge « nouveau », et les nouveautés remontées en tête de liste.

⚠️ Une recherche **inédite** ne signale rien comme nouveau — tout l'est, et
badger vingt résultats sur vingt n'apprend rien. La nouveauté commence au
deuxième passage. Le compteur ne bouge qu'en page 1, sinon feuilleter trois
pages le gonflerait sans qu'il soit rien arrivé. La clé d'une entrée ignore la
page : les pages 1 et 2 d'une même recherche sont la même recherche.

L'œil (👁) sur une ligne la met sous **veille** : un passage toutes les 6 h
(`WATCH_INTERVAL_S`), et une notification via `~/scripts/notify.sh` **seulement
s'il y a du neuf** — un passage silencieux est le cas normal. Les sources sont
espacées de 20 s (`WATCH_SPACING_S`) : six requêtes d'affilée ressemblent à du
moissonnage et finissent limitées. Une source en panne est journalisée, elle
n'arrête pas la veille des autres et ne réveille personne.

La croix oublie **une** recherche ; son « déjà vu » part avec elle, donc la
relancer repart de zéro. La confirmation n'apparaît que si la ligne est
surveillée — c'est le seul cas où supprimer arrête quelque chose.

## Licences

Chaque résultat porte sa licence : **vert** réutilisable, **rouge** restrictif
(`by-nc-nd` interdit la modification — un son sous cette licence ne peut pas
entrer dans un morceau publié), **gris** inconnu. La case « réutilisable
seulement » masque rouge **et** gris, et dit combien de cartes sont cachées.

⚠️ **« Inconnu » n'est pas « libre ».** C'est le cas le plus fréquent sur
archive.org : sur une recherche `prelinger`, 1 réutilisable, 3 restreints et
**16 inconnus** sur 20. Un fonds en accès libre n'est pas un fonds libre de
droits, et le filtre ne fait pas de ce gris un feu vert.

Le filtre porte sur les résultats **déjà reçus** — il ne rapatrie pas d'autres
pages pour remplir l'écran.

## Journal des téléchargements

Chaque fichier écrit est noté dans `downloads.json` (à côté du panier), avec
tous les endroits où il a été rangé. Une carte dont le fichier est encore sur
le disque porte **déjà pris**.

Reprendre un item déjà pris ne redemande **rien au réseau** :

| Situation | Ce qui se passe |
|---|---|
| le fichier est déjà sous le dossier choisi | rien, le lot le signale |
| il est ailleurs sur le disque | **copie locale**, sans réseau |
| il a été effacé ou déplacé à la main | téléchargement normal |

⚠️ Pas de refus du doublon : le même son sert à deux projets rangés dans deux
dossiers, et bloquer la seconde copie serait pire que de la faire. C'est la
**destination** qui décide, pas la présence dans le journal.

⚠️ Le journal retient **plusieurs chemins par item**, et ce n'est pas du
confort : n'en garder qu'un faisait recopier un fichier dans le dossier qui le
contenait déjà, avec un doublon `(1)` que rien n'expliquait. Les chemins morts
sont élagués à l'écriture suivante.

⚠️ **Le journal commence le 2026-10-11.** Les lots téléchargés avant ne s'y
trouvent pas — rien ne permet de remonter d'un nom de fichier à son
identifiant de source, donc aucun rattrapage n'est tenté.

## Fiche de crédits

Chaque lot écrit un `CREDITS.txt` dans son dossier : titre, auteur, source,
URL, licence. Les licences en « BY » **imposent** de créditer ; le badge le
disait, rien ne le permettait.

Un item dont la licence n'est pas franchement réutilisable porte un `⚠` avec
la raison — restrictive, ou inconnue. Une licence absente n'est pas une
autorisation.

⚠️ **Ajout, jamais écrasement** : au fil d'un projet on télécharge plusieurs
fois dans le même dossier, et le second lot ne doit pas effacer l'attribution
du premier. Un fichier déjà crédité là n'est pas recrédité, donc reprendre un
lot n'empile pas le même paragraphe.

## Fouille (mode agent)

Une recherche ordinaire pose **une** question. Fouiller, c'est en poser vingt
et recouper — ce qu'on faisait à la main en cliquant les propositions connexes
une par une. Le bouton **🔎 Fouiller** le fait d'un coup, à partir d'un thème
en clair : « brume et cornes de brume sur une côte de nuit ».

**Deux passes, et la seconde est celle qui compte.** Un modèle local déplie le
thème en champ lexical — surtout en anglais, parce qu'un terme français ne
ramène presque rien de ces fonds. Puis la récolte est relue par
`related_terms()`, qui en tire le vocabulaire **du fonds lui-même** : c'est là
qu'apparaissent les mots qu'aucun modèle n'avait, comme `perranporth` (une
plage de Cornouailles) sur une fouille de brume côtière.

Le champ est **éditable avant de lancer** : le modèle en propose toujours deux
ou trois à jeter.

### Le modèle, mesuré

Sur « brume et cornes de brume sur une côte de nuit », le 2026-10-11 :

| Modèle | À chaud | Ce qu'il sort |
|---|---|---|
| `llama3.1:8b` **(défaut)** | 5,7 s | `foghorn`, `fog bank`, `fogbound`, `headland` |
| `kimi-k2.6:cloud` | 113 s | `diaphone`, `tyfon`, `fog bell` — les vraies technologies |
| `qwen2.5:7b` | 4,5 s | `caveat`, `weatherphenomena` : mots collés, et pas de `foghorn` |

Le local par défaut, le cloud en option assumée. Le premier appel de la session
paie le chargement du modèle (une minute) ; `keep_alive` le garde ensuite.

### Classement : proximité au thème

⚠️ **La centralité ne suffit pas, c'est mesuré.** « Un document trouvé par six
termes est plus au cœur du thème » paraissait évident — sauf que sur 400
documents récoltés, **un seul** avait été trouvé par deux termes : les sources
rendent vingt résultats par terme et les listes ne se recoupent pas. Le score
retombait donc sur la licence, et une fouille sur la brume marine sortait
`Spray Bottle` et `Spritzing.wav` en tête, parce que `mist` avait ramené
quarante vaporisateurs.

D'où un classement par plongement (`nomic-embed-text`, local). Deux détails qui
renversent le résultat, tous deux mesurés :

- **les préfixes de tâche de nomic sont obligatoires** (`search_query:` /
  `search_document:`) — sans eux, 46 s et un classement inutilisable ;
- **la requête n'est pas le thème français mais le champ lexical anglais.**
  Avec le thème FR : `Albi Centre du Parc` en tête, écart haut/bas 0.173. Avec
  le champ EN : `North Sea foghorn` en tête, écart 0.252.

⚠️ La pesée (proximité ×14, centralité ×1) est **mesurée, pas choisie** : à 10
et 2, un document trouvé par deux termes passait devant un foghorn 0,2 plus
proche du thème. `test_hunt.py` pinne cet ordre.

La licence réutilisable et le fichier téléchargeable ajoutent quelques points,
et **ce qui est déjà pris est rétrogradé** — on fouille pour du neuf.

### Ce que la fouille se refuse

- **Gutenberg est hors du lot** : 15 à 30 s la requête, il mangerait sept
  minutes à lui seul. Il reste accessible à la main.
- **Une fouille à la fois**, et 1,2 s entre deux requêtes : quinze termes
  d'affilée sur une source ressemblent à du moissonnage.
- **Rien n'est écrit dans l'historique.** Une fouille de quinze termes y
  créerait quinze entrées et enterrerait un mois de recherches.
- **Rien ne part au panier tout seul.** Deux cents résultats déversés dedans
  détruiraient une sélection faite à la main.
- Une source qui tombe **sort de la rotation** et le rapport le dit une fois,
  au lieu de coûter quinze échecs.
- Le rapport **« Voir le rendement »** dit quels termes ont donné et lesquels
  n'ont rien rendu — sans ça, le champ du modèle reste invérifiable.

## Lancer

```bash
uv run app.py              # port 5556 par défaut, ou $ARCHIVE_PORT
uv run test_downloads.py   # journal + fiche de crédits
uv run test_hunt.py        # hygiène des termes + pesée du classement
```

## Notes

- La résolution des fichiers directs ne vaut que pour archive.org ; les autres
  sources renvoient déjà une URL de lecture.
