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

### Pourquoi la Library of Congress n'est qu'un renvoi

`loc.gov` place l'ensemble de son site derrière un défi JavaScript (Cloudflare)
et répond **403 à tout programme**, y compris sur sa propre page de
documentation d'API. Un navigateur passe ce défi sans rien avoir à faire, pas un
serveur. La source ouvre donc la recherche chez eux dans un onglet, au lieu de
faire semblant de l'intégrer. Ni panier ni lecteur pour celle-là — les résultats
vivent chez eux.

Le fonds `library_of_congress` présent sur archive.org ne comble pas le manque :
c'est du texte numérisé, pas leur audio.

## Lancer

```bash
uv run app.py          # port 5556 par défaut, ou $ARCHIVE_PORT
```

## Notes

- Favoris et panier vivent dans le `localStorage` du navigateur : pas de base,
  pas de compte.
- La résolution des fichiers directs ne vaut que pour archive.org ; les autres
  sources renvoient déjà une URL de lecture.
