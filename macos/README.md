# Archive Search — app macOS native

Portage SwiftUI de `app.py`, construit avec les seuls Command Line Tools
(pas d'Xcode). macOS 26 minimum : la fouille passera par FoundationModels.

```bash
bash macos/build_app.sh            # → macos/build/Archive Search.app
bash macos/build_app.sh --install  # copie aussi dans ~/Applications
swift run --package-path macos archive-check --live   # auto-test + une requête par source
swift run --package-path macos archive-check --hunt "brume et cornes de brume sur une côte de nuit"   # mesure d'une fouille
```

## Où en est le portage

| Étape | Contenu | État |
|---|---|---|
| 1 | Recherche sur les sources, licences, propositions connexes, lecteur | **fait** |
| 2 | Panier et favoris, téléchargement, journal, `CREDITS.txt` | **fait** |
| 3 | Historique, nouveautés, veille et notifications | **fait** |
| 4 | Fouille : FoundationModels + `NLContextualEmbedding`, classement remesuré | **fait** |

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

## Fouille avec l'IA locale d'Apple

Plus d'Ollama : le champ lexical vient du modèle d'Apple Intelligence
(FoundationModels, sur l'appareil) et le classement de `NLContextualEmbedding`
(NaturalLanguage). Ollama reste proposé dans la feuille s'il tourne et a des
modèles installés.

Mesuré le 2026-11-15 sur « brume et cornes de brume sur une côte de nuit » :

| | version web | native |
|---|---|---|
| champ | `llama3.1:8b`, 5,7 s à chaud | modèle d'Apple, 1,4 à 3 s |
| classement de 250 documents | `nomic-embed-text`, ~22 s | NaturalLanguage, 3,9 s |
| écart haut/bas | 0,252 (champ EN) | 0,276 (thème traduit) |

⚠️ **Le prompt de la version web ne marche pas sur le modèle d'Apple** (~3 B) :
il répondait en français (« son rocher », « son ombre ») et jamais `foghorn`.
Ce qui l'a redressé : des instructions en anglais avec un exemple sur un thème
sans rapport, une liste de mots vagues interdits, et la traduction du thème
dans une séance à part — demandée en même temps, « orgue de barbarie » sortait
« orgue of barbarity ». La génération guidée passe par `DynamicGenerationSchema`
(`@Generable` est une macro, absente sans Xcode).

⚠️ **La requête de classement est le thème traduit**, plus le champ comme sur
la version web : le champ du modèle d'Apple porte son bruit (« kerosene tank »)
et faisait monter un jet « Skyhawk Tank » au 7e rang. Le thème français reste
le pire (écart 0,180, « Salt Spray » en tête), comme sur nomic.

La pesée ×14 / ×1 tient sur ce plongement : les proximités s'étalent sur ~0,28
comme sur nomic. `archive-check` fige l'ordre (proximité > centralité, déjà
pris rétrogradé, licence restrictive derrière) et contrôle sans réseau qu'un
foghorn passe devant un vaporisateur.

⚠️ **Seuls les termes du champ comptent pour la centralité.** Les termes du
fonds (passe 2) élargissent la récolte, ils n'attestent pas qu'un document est
dans le thème : « netherlands » faisait passer trois prises de vent sur la Meuse
(0,89) devant « Fog horn as heard from shore » (0,94). L'auto-test reproduit le
cas, et échoue sans la règle.

« geograph » (noms de fichiers geograph.org.uk sur Wikimedia) est écarté de la
passe 2 : un artefact de la source, pas du vocabulaire du thème.

Si Apple Intelligence est désactivé ou refuse un thème (garde-fous), la note
de la feuille le dit et le champ se réduit au thème, à compléter à la main.

## Captures du README

Faites par le mode démo, piloté au lancement par des variables
`ARCHIVE_DEMO_*` (recherche, type, sélection, panier, vue, fouille, rapport ;
liste dans `Sources/ArchiveSearch/Demo.swift`). Aucune frappe ni aucun clic
simulé : l'app se met en scène seule, et `screencapture -l` prend sa fenêtre.
Lancer avec un `DATA_DIR` jetable pour ne pas toucher aux vraies données.
