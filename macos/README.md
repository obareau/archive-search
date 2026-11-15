# Archive Search — app macOS native

Portage SwiftUI de `app.py`, construit avec les seuls Command Line Tools
(pas d'Xcode). macOS 26 minimum : la fouille passera par FoundationModels.

```bash
bash macos/build_app.sh            # → macos/build/Archive Search.app
bash macos/build_app.sh --install  # copie aussi dans ~/Applications
swift run --package-path macos archive-check --live   # auto-test + une requête par source
```

## Où en est le portage

| Étape | Contenu | État |
|---|---|---|
| 1 | Recherche sur les sources, licences, propositions connexes, lecteur | **fait** |
| 2 | Panier et favoris, téléchargement, journal, `CREDITS.txt` | **fait** |
| 3 | Historique, nouveautés, veille et notifications | **fait** |
| 4 | Fouille : FoundationModels + `NLContextualEmbedding`, classement remesuré | à faire |

## Ce qui change par rapport au Flask

- **Lecteur** : `AVPlayerView` (film, audio, prévisualisation Freesound),
  `PDFView` pour les textes, image en grand pour Wikimedia.
- **Wikimedia porte maintenant sa licence** (`LicenseUrl` de l'extmetadata) ;
  la version web la laissait vide.
- **Clé Freesound** : Réglages (⌘,), rangée dans
  `~/Library/Application Support/Archive Search/freesound-token` en 0600.
  `$FREESOUND_TOKEN` prime. Pas le Trousseau : avec une signature ad hoc, chaque
  build change d'identité et il redemanderait le mot de passe à chaque lancement.
- **Library of Congress** : toujours un renvoi, ouvert dans le navigateur.
- **Dossier de téléchargement** : le dialogue natif (`NSOpenPanel`) remplace le
  navigateur de dossiers fait main et la validation `_safe_subdir` — ils
  n'existaient que parce que le disque était celui d'un serveur. Racine par
  défaut `~/archive-search-downloads` (`$DOWNLOAD_DIR`) ; la choisir telle quelle
  range le lot dans `<AAAA-MM-JJ_HHMM>/`.
- **Un refus 4xx n'est plus retenté** : un item réservé (archive.org répond 401
  sur certains) ne coûtait que trois essais et quatorze secondes d'attente.
- **Arrêter** un lot en cours : rien d'incomplet n'est gardé.
- **Données de la version web** : Fichier › Importer… reprend `cart.json`,
  `favorites.json`, `downloads.json` et `history.json` d'une copie de
  `~/.local/share/archive-search`, par fusion. Les chemins du journal écrits sur
  l'ancien serveur n'existent pas ici : ces entrées s'affichent « disparu ».

- **Veille** : tant que l'app tourne (fermer la fenêtre ne la quitte pas
  quand une veille est active ; ⌘Q quitte). La date du dernier passage est
  gardée : un Mac rallumé rattrape le passage manqué 20 s après le lancement.
  Notifications macOS au lieu de `~/scripts/notify.sh` (absent de ce Mac) ; un
  clic sur la notification rouvre la recherche.
- **Pas de restauration de fenêtres** : après un arrêt brutal, macOS relançait
  l'app sans aucune fenêtre (processus vivant, rien à l'écran).

⚠️ La progression se lit sur la tâche toutes les 0,4 s : l'observation KVO de
`task.progress` ne remonte rien pour un téléchargement async (barre figée à
0 Ko sur 127 Mo, constaté le 2026-11-15).

⚠️ Pas de `VideoPlayer` SwiftUI : compilé sans Xcode, `_AVKit_SwiftUI` plante à
l'initialisation de ses métadonnées dès qu'un film s'affiche (SIGABRT,
2026-11-15). `AVPlayerView` enveloppé à la main le remplace.

⚠️ Sans Xcode, pas de macros : `@Local` (Sources/ArchiveSearch/Local.swift)
remplace `@State`, et les modèles sont des `ObservableObject`.
