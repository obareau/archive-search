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
| 2 | Panier et favoris, téléchargement, journal, `CREDITS.txt` | à faire |
| 3 | Historique, nouveautés, veille et notifications | à faire |
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

⚠️ Pas de `VideoPlayer` SwiftUI : compilé sans Xcode, `_AVKit_SwiftUI` plante à
l'initialisation de ses métadonnées dès qu'un film s'affiche (SIGABRT,
2026-11-15). `AVPlayerView` enveloppé à la main le remplace.

⚠️ Sans Xcode, pas de macros : `@Local` (Sources/ArchiveSearch/Local.swift)
remplace `@State`, et les modèles sont des `ObservableObject`.
