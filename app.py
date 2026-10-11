#!/usr/bin/env python3
"""Archive Search — films vintage, audio, PDFs, livres et médias du domaine
public, à travers plusieurs sources (archive.org, Gutenberg, Wikimedia
Commons, LibriVox)."""

import json
import os
import subprocess
import random
import threading
import re
import time
from pathlib import Path
from urllib.parse import quote, urlparse

import requests
from flask import Flask, render_template_string, request, jsonify

app = Flask(__name__)

ROWS_PER_PAGE = 20
REQUEST_TIMEOUT = 10
# Gutendex répond en 20-30 s quand il est chargé (mesuré le 2026-10-10). À 10 s
# on le déclarait mort alors qu'il travaillait : le timeout est la panne, pas
# le service. Par source, parce qu'allonger le délai POUR TOUTES ferait
# patienter une minute sur une vraie coupure d'archive.org.
SOURCE_TIMEOUT = {"gutenberg": 30}
# Wikimedia (et d'autres APIs) rejettent le user-agent par défaut de
# `requests` (403 "Please set a user-agent...", politique anti-bot) —
# identifiant explicite requis sur tous les appels sortants.
HEADERS = {"User-Agent": "archive-search/1.0 (outil personnel, usage local - olivier@robotariis.com)"}

# ── Cache mémoire simple (TTL) — évite de re-taper les APIs sources sur des
# requêtes identiques répétées. Pas de persistance : un dict suffit pour un
# outil perso à faible trafic, pas besoin de sqlite.
CACHE_TTL = 3600
_cache: dict = {}


def cache_get(key):
    entry = _cache.get(key)
    if entry and time.time() - entry[0] < CACHE_TTL:
        return entry[1]
    return None


def cache_set(key, value):
    _cache[key] = (time.time(), value)
    if len(_cache) > 500:
        for k, _ in sorted(_cache.items(), key=lambda kv: kv[1][0])[:100]:
            _cache.pop(k, None)


def first(value, default=""):
    """Archive.org renvoie parfois une liste, parfois une valeur seule."""
    if isinstance(value, list):
        return value[0] if value else default
    return value or default


_TAG_RE = re.compile(r"<[^>]+>")


def strip_html(text):
    """Wikimedia (extmetadata) et LibriVox renvoient parfois du HTML brut
    (liens, spans de tri cachés, italiques) dans des champs texte."""
    return _TAG_RE.sub("", str(text or "")).strip()


# ── Sources ────────────────────────────────────────────────────────────

SORT_OPTIONS = {
    "": None,
    "date_desc": "date desc",
    "downloads_desc": "downloads desc",
}

COLLECTIONS = {
    "": None,
    "prelinger": "prelinger",
    "opensource_movies": "opensource_movies",
    "classic_tv": "classic_tv",
    "oldtimeradio": "oldtimeradio",
}


def search_archive_org(query, search_type, page, sort="", collection=""):
    q = f'"{query}"'
    if search_type == "film":
        q += " AND mediatype:movies AND year:[1920 TO 1980]"
    elif search_type == "audio":
        q += " AND mediatype:audio"
    elif search_type == "pdf":
        q += " AND mediatype:texts AND format:PDF"
    if COLLECTIONS.get(collection):
        q += f" AND collection:{COLLECTIONS[collection]}"

    params = {
        "q": q,
        "fl": "identifier,title,creator,year,mediatype,description,subject,licenseurl",
        "output": "json",
        "rows": ROWS_PER_PAGE,
        "page": page,
    }
    if SORT_OPTIONS.get(sort):
        params["sort[]"] = SORT_OPTIONS[sort]
    resp = requests.get("https://archive.org/advancedsearch.php", params=params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
    docs = data.get("response", {}).get("docs", [])
    total = data.get("response", {}).get("numFound")

    results = []
    for doc in docs:
        identifier = doc.get("identifier", "")
        results.append({
            "title": doc.get("title", identifier or "N/A"),
            "creator": first(doc.get("creator"), "N/A"),
            "year": doc.get("year", ""),
            "type": doc.get("mediatype", ""),
            "description": str(first(doc.get("description"), ""))[:150],
            "url": f"https://archive.org/details/{identifier}",
            "thumbnail": f"https://archive.org/services/img/{identifier}" if identifier else "",
            "source": "archive.org",
            "identifier": identifier,
            "keywords": [str(x) for x in (doc.get("subject") or ([] if doc.get("subject") is None else [doc["subject"]]))][:12],
            "license": normalize_license(first(doc.get("licenseurl"), "")),
        })
    return results, total


def search_gutenberg(query, _search_type, page, _sort="", _collection=""):
    params = {"search": query, "page": page}
    resp = requests.get("https://gutendex.com/books/", params=params, headers=HEADERS,
                        timeout=SOURCE_TIMEOUT.get("gutenberg", REQUEST_TIMEOUT))
    # Sous charge, gutendex rend une page d'erreur HTML avec un code 5xx. Sans
    # ce test, resp.json() lève « Expecting value: line 1 column 1 », qui
    # ressemble à un bug chez nous.
    if resp.status_code >= 500:
        raise RuntimeError(f"Gutendex est en difficulté (HTTP {resp.status_code}) — réessaie plus tard.")
    try:
        data = resp.json()
    except ValueError:
        raise RuntimeError("Gutendex a renvoyé une réponse illisible (pas du JSON) — service instable.")
    total = data.get("count")

    results = []
    for book in data.get("results", []):
        authors = ", ".join(a["name"] for a in book.get("authors", [])) or "N/A"
        formats = book.get("formats", {})
        file_url = (
            formats.get("text/html; charset=utf-8")
            or formats.get("text/html")
            or formats.get("application/epub+zip")
            or f"https://www.gutenberg.org/ebooks/{book.get('id')}"
        )
        results.append({
            "title": book.get("title", "N/A"),
            "creator": authors,
            "year": "",
            "type": "book",
            "description": ", ".join(book.get("subjects", [])[:3]),
            "url": file_url,
            "thumbnail": formats.get("image/jpeg", ""),
            "source": "gutenberg",
            "identifier": str(book.get("id", "")),
        })
    return results, total


def search_wikimedia(query, _search_type, page, _sort="", _collection=""):
    offset = (page - 1) * ROWS_PER_PAGE
    search_params = {
        # srnamespace=6 = espace de noms "File" — sans ça, la recherche renvoie
        # aussi des pages Catégorie/Galerie (ns 0/14) qui n'ont pas d'imageinfo,
        # d'où des résultats avec titre mais sans vignette/url/métadonnées.
        "action": "query", "list": "search", "srsearch": query, "srnamespace": 6,
        "srlimit": ROWS_PER_PAGE, "sroffset": offset, "format": "json",
    }
    resp = requests.get("https://commons.wikimedia.org/w/api.php", params=search_params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
    total = data.get("query", {}).get("searchinfo", {}).get("totalhits")
    titles = [item["title"] for item in data.get("query", {}).get("search", [])]

    results = []
    if titles:
        info_params = {
            "action": "query", "titles": "|".join(titles), "prop": "imageinfo",
            "iiprop": "url|extmetadata", "iiurlwidth": 300, "format": "json",
        }
        info_resp = requests.get("https://commons.wikimedia.org/w/api.php", params=info_params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
        pages = info_resp.json().get("query", {}).get("pages", {})
        for page_data in pages.values():
            imageinfo = (page_data.get("imageinfo") or [{}])[0]
            meta = imageinfo.get("extmetadata", {})
            artist = strip_html(meta.get("Artist", {}).get("value", "N/A")) if "Artist" in meta else "N/A"
            date = meta.get("DateTimeOriginal", {}).get("value", "") if "DateTimeOriginal" in meta else ""
            desc = strip_html(meta.get("ImageDescription", {}).get("value", "")) if "ImageDescription" in meta else ""
            results.append({
                "title": page_data.get("title", "N/A").replace("File:", ""),
                "creator": artist,
                "year": date[:4] if date else "",
                "type": "media",
                "description": str(desc)[:150],
                "url": imageinfo.get("descriptionurl", ""),
                "thumbnail": imageinfo.get("thumburl", imageinfo.get("url", "")),
                "source": "wikimedia",
                "identifier": page_data.get("title", ""),
            })
    return results, total


def search_librivox(query, _search_type, page, _sort="", _collection=""):
    # API LibriVox limitée : recherche par PRÉFIXE de titre (^) uniquement,
    # pas de plein texte. Pas de total fiable — pagination gérée par offset,
    # "page suivante" activée seulement si la page courante est pleine.
    offset = (page - 1) * ROWS_PER_PAGE
    params = {
        "title": f"^{query}", "format": "json", "extended": 1,
        "limit": ROWS_PER_PAGE, "offset": offset,
    }
    resp = requests.get("https://librivox.org/api/feed/audiobooks/", params=params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
    books = data.get("books") or []
    if not isinstance(books, list):
        books = []

    results = []
    for book in books:
        authors = book.get("authors") or []
        creator = ", ".join(f"{a.get('first_name', '')} {a.get('last_name', '')}".strip() for a in authors) or "N/A"
        results.append({
            "title": book.get("title", "N/A"),
            "creator": creator,
            "year": "",
            "type": "audiobook",
            "description": strip_html(book.get("description", ""))[:150],
            "url": book.get("url_librivox") or book.get("url_zip_file") or "",
            "thumbnail": "",
            "source": "librivox",
            "identifier": str(book.get("id", "")),
        })
    return results, None  # pas de total exploitable côté API


def search_freesound(query, _search_type, page, _sort="", _collection=""):
    # Freesound exige un jeton : pas de quota anonyme, même en lecture.
    # Sans jeton on le DIT plutôt que de renvoyer zéro résultat, qui se
    # confondrait avec « rien trouvé » (même raison que le renvoi loc.gov).
    token = os.getenv("FREESOUND_TOKEN", "").strip()
    if not token:
        raise RuntimeError(
            "Freesound demande une clé d'API. En créer une sur "
            "https://freesound.org/apiv2/apply/ puis la poser dans "
            "FREESOUND_TOKEN (unité systemd ou .env)."
        )
    params = {
        "query": query, "page": page, "page_size": ROWS_PER_PAGE,
        # `previews` porte le mp3 écoutable, `images` la forme d'onde.
        "fields": "id,name,username,description,previews,images,duration,license,url,created,tags",
        "token": token,
    }
    resp = requests.get("https://freesound.org/apiv2/search/text/", params=params,
                        headers=HEADERS, timeout=REQUEST_TIMEOUT)
    if resp.status_code in (401, 403):
        raise RuntimeError("Freesound refuse la clé (401/403) — vérifier FREESOUND_TOKEN.")
    data = resp.json()

    results = []
    for snd in data.get("results") or []:
        previews = snd.get("previews") or {}
        dur = snd.get("duration")
        results.append({
            "title": snd.get("name", "N/A"),
            "creator": snd.get("username", "N/A"),
            "year": (snd.get("created") or "")[:4],
            "type": f"son · {dur:.0f}s" if isinstance(dur, (int, float)) else "son",
            "description": strip_html(snd.get("description", ""))[:150],
            "url": snd.get("url", ""),
            "thumbnail": (snd.get("images") or {}).get("waveform_m", ""),
            "source": "freesound",
            "identifier": str(snd.get("id", "")),
            "keywords": [str(t) for t in (snd.get("tags") or [])][:12],
            "license": normalize_license(snd.get("license")),
            # Écoutable sans second appel : l'API donne déjà le mp3.
            "preview": previews.get("preview-hq-mp3") or previews.get("preview-lq-mp3") or "",
        })
    return results, data.get("count")


SOURCES = {
    "archive.org": search_archive_org,
    "gutenberg": search_gutenberg,
    "wikimedia": search_wikimedia,
    "librivox": search_librivox,
    "freesound": search_freesound,
}

# ── Résolution du fichier direct (archive.org seulement — les autres
# sources renvoient déjà une URL de fichier/lecture directe). ──────────

PREFERRED_EXT = {
    "movies": [".mp4", ".ogv", ".webm"],
    "audio": [".mp3", ".ogg"],
    "texts": [".pdf"],
}


def resolve_archive_file(identifier):
    """Renvoie (url, mediatype) du fichier lisible le plus adapté, ou
    (None, mediatype) si aucun fichier utilisable n'a été trouvé — le
    mediatype est renvoyé même dans ce cas pour que le frontend sache quel
    lecteur (audio/vidéo) aurait été utilisé."""
    resp = requests.get(f"https://archive.org/metadata/{identifier}", headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
    files = data.get("files", [])
    mediatype = data.get("metadata", {}).get("mediatype", "")
    exts = PREFERRED_EXT.get(mediatype, [])

    def score(f):
        name = f.get("name", "").lower()
        for i, ext in enumerate(exts):
            if name.endswith(ext):
                return (i, -int(f.get("size", 0) or 0))
        return (len(exts), 0)

    # Pas de fallback vers "n'importe quel fichier" : un item sans .mp4/.mp3/
    # .pdf trouvable (upload incomplet, item retiré...) doit rester "indisponible"
    # plutôt que de renvoyer une vignette ou un fichier de métadonnées au hasard.
    candidates = [f for f in files if any(f.get("name", "").lower().endswith(e) for e in exts)]
    if not candidates:
        return None, mediatype
    best = sorted(candidates, key=score)[0]
    name = best.get("name", "")
    if not name:
        return None, mediatype
    return f"https://archive.org/download/{identifier}/{name}", mediatype


def resolve_archive_torrent(identifier):
    """Archive.org génère un .torrent pour (quasi) chaque item — fair-use
    natif : le téléchargement réel passe par le client torrent de
    l'utilisateur (pause/reprise déjà géré par le protocole, pas besoin de
    réinventer un gestionnaire de téléchargement côté serveur)."""
    resp = requests.get(f"https://archive.org/metadata/{identifier}", headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
    for f in data.get("files", []):
        name = f.get("name", "")
        if name.lower().endswith(".torrent"):
            return f"https://archive.org/download/{identifier}/{name}"
    return None


# ── "Surprise-moi" : pioche un item au hasard dans une collection vintage. ─

RANDOM_COLLECTIONS = ["prelinger", "opensource_movies", "classic_tv", "oldtimeradio"]


def random_archive_item():
    collection = random.choice(RANDOM_COLLECTIONS)
    params = {
        "q": f"collection:{collection}",
        "fl": "identifier,title,creator,year,mediatype,description",
        "output": "json",
        "rows": 1,
        "start": random.randint(0, 2000),
    }
    resp = requests.get("https://archive.org/advancedsearch.php", params=params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    docs = resp.json().get("response", {}).get("docs", [])
    if not docs:
        return None
    doc = docs[0]
    identifier = doc.get("identifier", "")
    return {
        "title": doc.get("title", identifier or "N/A"),
        "creator": first(doc.get("creator"), "N/A"),
        "year": doc.get("year", ""),
        "type": doc.get("mediatype", ""),
        "description": str(first(doc.get("description"), ""))[:150],
        "url": f"https://archive.org/details/{identifier}",
        "thumbnail": f"https://archive.org/services/img/{identifier}" if identifier else "",
        "source": "archive.org",
        "identifier": identifier,
    }


# ── UI ───────────────────────────────────────────────────────────────

HTML = """
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Archive Search</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
    <style>
/* Outil d'archive : dense, neutre, un seul accent. Le gris porte une légère
   dérive bleutée — un gris parfaitement neutre a l'air non choisi. */
:root {
    --bg: #101214;
    --panel: #171a1d;
    --panel-2: #1d2125;
    --line: #2a2f35;
    --line-soft: #22262b;
    --text: #e6e8ea;
    --muted: #9099a3;
    --accent: #c9893f;          /* ambre sourd : lisible sur fond sombre */
    --accent-soft: rgba(201, 137, 63, .12);
    --ok: #4f9a63;
    --err: #c0564a;
    --radius: 6px;
    --mono: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
    --sans: "IBM Plex Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    color-scheme: dark;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
    font-family: var(--sans);
    font-size: 14px;
    line-height: 1.5;
    background: var(--bg);
    color: var(--text);
    -webkit-font-smoothing: antialiased;
}
.container { max-width: 1320px; margin: 0 auto; padding: 0 20px 48px; }

/* ── En-tête : une barre d'application, pas un titre centré ─────────────── */
.appbar {
    position: sticky; top: 0; z-index: 50;
    background: rgba(16, 18, 20, .92);
    backdrop-filter: blur(10px);
    border-bottom: 1px solid var(--line);
    margin-bottom: 20px;
}
.appbar-inner {
    max-width: 1320px; margin: 0 auto; padding: 12px 20px;
    display: flex; align-items: center; gap: 14px; flex-wrap: wrap;
}
.brand {
    font-family: var(--mono); font-size: 13px; font-weight: 500;
    letter-spacing: .14em; text-transform: uppercase; color: var(--accent);
    white-space: nowrap;
}
h1 { display: none; }

/* ── Contrôles ─────────────────────────────────────────────────────────── */
input, select, button, textarea {
    font-family: inherit; font-size: 13px;
    padding: 8px 11px;
    border: 1px solid var(--line);
    border-radius: var(--radius);
    background: var(--panel-2);
    color: var(--text);
    transition: border-color .12s, background .12s, color .12s;
}
input::placeholder { color: var(--muted); }
input:hover, select:hover, button:hover { border-color: #3a424b; }
button { cursor: pointer; font-weight: 500; }
button:hover { color: var(--accent); }
button:active { transform: translateY(1px); }
button:disabled { opacity: .4; cursor: default; color: var(--muted); }
:where(input, select, button, a, [tabindex]):focus-visible {
    outline: 2px solid var(--accent); outline-offset: 1px;
}
/* Une seule action primaire par barre — sinon plus rien ne ressort. */
.primary { background: var(--accent); border-color: var(--accent); color: #17120b; font-weight: 600; }
.primary:hover { background: #d89a52; border-color: #d89a52; color: #17120b; }

.search-box { display: flex; gap: 8px; flex: 1; flex-wrap: wrap; min-width: 280px; }
.search-box input { flex: 1; min-width: 200px; }
.toolbar { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 14px; align-items: center; }
.count { font-family: var(--mono); font-size: 11px; color: var(--muted); }

/* ── Résultats ─────────────────────────────────────────────────────────── */
.results {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(270px, 1fr));
    gap: 14px;
}
.item {
    background: var(--panel);
    border: 1px solid var(--line-soft);
    border-radius: 8px;
    padding: 0 0 12px;
    display: flex; flex-direction: column;
    overflow: hidden;
    transition: border-color .15s, background .15s;
}
.item:hover { border-color: var(--line); background: var(--panel-2); }
.item-thumb {
    width: 100%; height: 150px; object-fit: cover; display: block;
    background: #0b0d0f; border-bottom: 1px solid var(--line-soft);
    margin: 0;
}
.item > *:not(.item-thumb):not(.item-player) { margin-left: 13px; margin-right: 13px; }
.item-title-row { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; margin-top: 12px; }
.item-title { font-weight: 600; font-size: 14px; line-height: 1.35; overflow-wrap: anywhere; }
.item-meta {
    font-family: var(--mono); font-size: 11px; color: var(--muted);
    margin-top: 5px; display: flex; flex-wrap: wrap; gap: 6px; align-items: center;
}
.item-meta .src {
    background: var(--accent-soft); color: var(--accent);
    padding: 1px 6px; border-radius: 3px; letter-spacing: .04em;
}
.item-desc {
    font-size: 12.5px; color: var(--muted); margin-top: 8px;
    display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden;
}
.item-links { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 10px; }
.item-link {
    font-size: 12px; padding: 5px 9px; border-radius: var(--radius);
    border: 1px solid var(--line); background: transparent; color: var(--text);
    text-decoration: none; cursor: pointer;
}
.item-link:hover { border-color: var(--accent); color: var(--accent); }
.item-player { width: calc(100% - 26px); margin: 10px 13px 0; height: 32px; display: block; }
.fav-btn, .cart-btn {
    background: none; border: none; padding: 2px 4px; font-size: 15px;
    color: var(--muted); opacity: .75;
}
.fav-btn:hover, .cart-btn:hover, .fav-btn.active, .cart-btn.active { opacity: 1; color: var(--accent); }

.error, .empty { color: var(--muted); padding: 28px; text-align: center; border: 1px dashed var(--line); border-radius: 8px; }
.loading { color: var(--muted); padding: 28px; text-align: center; }
.pagination { display: flex; gap: 10px; align-items: center; justify-content: center; margin-top: 22px; }
#pageInfo { font-family: var(--mono); font-size: 12px; color: var(--muted); }

/* Licence : trois états, trois couleurs. « Inconnu » est gris et PAS vert —
   l'absence d'information n'est pas une autorisation. */
.lic { font-family: var(--mono); font-size: 9.5px; letter-spacing: .06em; padding: 1px 6px;
       border-radius: 3px; border: 1px solid transparent; white-space: nowrap; text-decoration: none; }
.lic.free { color: var(--ok); border-color: rgba(79,154,99,.35); background: rgba(79,154,99,.10); }
.lic.restricted { color: var(--err); border-color: rgba(192,86,74,.35); background: rgba(192,86,74,.10); }
.lic.unknown { color: var(--muted); border-color: var(--line); }
a.lic:hover { border-color: currentColor; }
.lic-filter { display: flex; align-items: center; gap: 6px; font-size: 12px; color: var(--muted); cursor: pointer; }
.lic-filter input { width: auto; padding: 0; margin: 0; accent-color: var(--accent); }

/* Nouveauté : un liseré sur le bord gauche plutôt qu'un fond coloré — la
   carte reste lisible, et vingt cartes neuves ne font pas un mur de couleur. */
.item.is-new { border-left: 2px solid var(--accent); }
.badge-new {
    font-family: var(--mono); font-size: 9.5px; letter-spacing: .1em;
    text-transform: uppercase; color: var(--accent); background: var(--accent-soft);
    padding: 1px 6px; border-radius: 3px; white-space: nowrap;
}
.hist-row {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    padding: 9px 11px; border-bottom: 1px solid var(--line-soft);
}
.hist-row:last-child { border-bottom: none; }
.hist-main { min-width: 0; }
.hist-q { font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.hist-meta { font-family: var(--mono); font-size: 10.5px; color: var(--muted); margin-top: 2px; }
.watch-btn { background: none; border: 1px solid var(--line); padding: 4px 8px; font-size: 12px; }
.watch-btn.on { color: var(--accent); border-color: var(--accent); }
.hist-list { border: 1px solid var(--line); border-radius: var(--radius); background: var(--bg);
             max-height: 55vh; overflow-y: auto; }

/* Propositions connexes : une bande discrète, jamais un bloc qui pousse les
   résultats hors de l'écran. */
.related { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-bottom: 14px; }
.related-label {
    font-family: var(--mono); font-size: 10.5px; text-transform: uppercase;
    letter-spacing: .1em; color: var(--muted); margin-right: 2px;
}
.rel {
    font-size: 12px; padding: 3px 9px; border-radius: 999px;
    border: 1px solid var(--line); background: transparent; color: var(--muted);
    cursor: pointer; font-family: inherit;
}
.rel:hover { border-color: var(--accent); color: var(--accent); }
.rel.who { border-style: dashed; }
.rel.when { font-family: var(--mono); }

/* ── Téléchargement ────────────────────────────────────────────────────── */
.dl-wrap { display: flex; flex-direction: column; gap: 6px; width: 100%; }
.dl-line { display: flex; justify-content: space-between; gap: 12px; font-size: 12.5px; }
.dl-line .dl-file { color: var(--muted); font-family: var(--mono); font-size: 11.5px;
                    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.dl-bar { height: 4px; background: var(--panel-2); border-radius: 999px; overflow: hidden; }
.dl-fill { height: 100%; width: 0; background: var(--accent); transition: width .25s ease; }
.dl-fill.err { background: var(--err); }
.dl-fill.done { background: var(--ok); }
.dl-sub { font-size: 11.5px; color: var(--muted); font-family: var(--mono); }

/* ── Dialogues natifs : <dialog> apporte Échap, le piège de focus et le
      fond inerte sans une ligne de script. ──────────────────────────────── */
dialog {
    border: 1px solid var(--line); border-radius: 10px;
    background: var(--panel); color: var(--text);
    padding: 0; width: min(560px, calc(100vw - 32px));
    box-shadow: 0 24px 60px rgba(0, 0, 0, .6);
}
dialog::backdrop { background: rgba(0, 0, 0, .6); backdrop-filter: blur(2px); }
.dlg-head {
    display: flex; align-items: center; justify-content: space-between; gap: 12px;
    padding: 14px 16px; border-bottom: 1px solid var(--line);
}
.dlg-head h2 { font-size: 14px; font-weight: 600; }
.dlg-body { padding: 16px; display: flex; flex-direction: column; gap: 14px; }
.dlg-foot {
    display: flex; justify-content: space-between; align-items: center; gap: 10px;
    padding: 12px 16px; border-top: 1px solid var(--line); background: var(--panel-2);
}
.dlg-close { background: none; border: none; color: var(--muted); font-size: 16px; padding: 2px 6px; }
.dlg-close:hover { color: var(--text); }
.field { display: flex; flex-direction: column; gap: 6px; }
.field label {
    font-family: var(--mono); font-size: 10.5px; text-transform: uppercase;
    letter-spacing: .1em; color: var(--muted);
}

/* Fil d'Ariane + liste de dossiers : le comportement d'un sélecteur système. */
.crumbs { display: flex; flex-wrap: wrap; gap: 4px; align-items: center; font-family: var(--mono); font-size: 11.5px; }
.crumb { background: none; border: none; color: var(--accent); padding: 2px 4px; font-family: inherit; font-size: inherit; }
.crumb:hover { text-decoration: underline; color: var(--accent); }
.crumb-sep { color: var(--muted); }
.crumb.current { color: var(--text); cursor: default; }
.dir-list {
    border: 1px solid var(--line); border-radius: var(--radius);
    background: var(--bg); max-height: 240px; overflow-y: auto;
}
.dir-row {
    display: flex; align-items: center; justify-content: space-between; gap: 10px;
    width: 100%; padding: 8px 11px; background: none; border: none;
    border-bottom: 1px solid var(--line-soft); color: var(--text);
    font-size: 13px; text-align: left; border-radius: 0;
}
.dir-row:last-child { border-bottom: none; }
.dir-row:hover { background: var(--panel-2); color: var(--text); }
.dir-row[aria-selected="true"] { background: var(--accent-soft); color: var(--accent); }
.dir-row .n { font-family: var(--mono); font-size: 11px; color: var(--muted); }
.dir-empty { padding: 20px; text-align: center; color: var(--muted); font-size: 12.5px; }
.dest { font-family: var(--mono); font-size: 11.5px; color: var(--muted); overflow-wrap: anywhere; }
.dest b { color: var(--text); font-weight: 500; }

#modalLinksList { display: flex; flex-direction: column; gap: 8px; max-height: 50vh; overflow-y: auto; }

@media (prefers-reduced-motion: reduce) { * { transition: none !important; } }
@media (max-width: 640px) {
    .appbar-inner { padding: 10px 16px; }
    .container { padding: 0 16px 36px; }
}
</style>
</head>
<body>
    <header class="appbar">
        <div class="appbar-inner">
            <span class="brand">Archive Search</span>
            <div class="search-box">
            <input type="text" id="query" placeholder="Chercher... (titre, auteur, etc)" value="">
            <select id="source">
                <option value="archive.org">Archive.org</option>
                <option value="gutenberg">Gutenberg (livres)</option>
                <option value="wikimedia">Wikimedia Commons</option>
                <option value="librivox">LibriVox (audio livres)</option>
                <option value="freesound">Freesound (sons)</option>
                <option value="loc.gov">Library of Congress (audio) ↗</option>
            </select>
            <select id="type">
                <option value="">Tous types</option>
                <option value="film">Films (1920-1980)</option>
                <option value="audio">Audio</option>
                <option value="pdf">PDFs</option>
            </select>
            <select id="collection">
                <option value="">Toutes collections</option>
                <option value="prelinger">Prelinger (films éphémères)</option>
                <option value="opensource_movies">Films libres</option>
                <option value="classic_tv">TV classique</option>
                <option value="oldtimeradio">Radio vintage</option>
            </select>
            <select id="sort">
                <option value="">Pertinence</option>
                <option value="date_desc">Plus récent</option>
                <option value="downloads_desc">Plus téléchargé</option>
            </select>
                <button id="btnSearch" class="primary" onclick="search(1)">Chercher</button>
            </div>
        </div>
    </header>

    <div class="container">
        <div class="toolbar">
            <button id="btnSurprise">🎲 Surprise-moi</button>
            <button id="btnFavorites">★ Favoris <span class="count" id="favCount">0</span></button>
            <button id="btnCart">🧺 Panier <span class="count" id="cartCount">0</span></button>
            <button id="btnHistory">🕘 Historique</button>
            <label class="lic-filter" title="Masque les licences restrictives ET celles qu'on ne connaît pas">
                <input type="checkbox" id="onlyFree"> réutilisable seulement
            </label>
            <span class="count" id="licHidden"></span>
        </div>
        <div class="toolbar" id="cartBulkBar" style="display:none">
            <button id="btnDownloadAll" class="primary">⬇ Télécharger…</button>
            <button id="btnResolveAll">Récupérer tous les liens (.torrent en priorité)</button>
            <button id="btnShowLinks">🔗 Liens <span class="count" id="linksCount">0</span></button>
            <button id="btnClearCart">Vider le panier</button>
        </div>

        <div id="dlStatus" class="toolbar" style="display:none;gap:10px;align-items:center"></div>
        <div class="related" id="related" style="display:none"></div>
        <div id="results"></div>
        <div class="pagination" id="pagination" style="display:none">
            <button id="btnPrev">◀ Précédent</button>
            <span id="pageInfo"></span>
            <button id="btnNext">Suivant ▶</button>
        </div>
    </div>

    <dialog id="dirModal" aria-labelledby="dirTitle">
        <div class="dlg-head">
            <h2 id="dirTitle">Choisir la destination</h2>
            <button class="dlg-close" data-close="dirModal" aria-label="Fermer">&#10005;</button>
        </div>
        <div class="dlg-body">
            <div class="field">
                <label>Emplacement</label>
                <div class="crumbs" id="dirCrumbs"></div>
            </div>
            <div class="dir-list" id="dirList"></div>
            <div class="field">
                <label for="newDirName">Nouveau dossier ici</label>
                <div style="display:flex;gap:8px">
                    <input type="text" id="newDirName" placeholder="nom du dossier" style="flex:1">
                    <button id="btnMkdir">Créer</button>
                </div>
            </div>
        </div>
        <div class="dlg-foot">
            <span class="dest" id="dirDest"></span>
            <span style="display:flex;gap:8px">
                <button data-close="dirModal">Annuler</button>
                <button id="btnDirGo" class="primary">Télécharger ici</button>
            </span>
        </div>
    </dialog>

    <dialog id="histModal" aria-labelledby="histTitle">
        <div class="dlg-head">
            <h2 id="histTitle">Historique des recherches</h2>
            <button class="dlg-close" data-close="histModal" aria-label="Fermer">&#10005;</button>
        </div>
        <div class="dlg-body"><div class="hist-list" id="histList"></div></div>
        <div class="dlg-foot">
            <span class="dest" id="watchInfo">Les recherches suivies sont vérifiées toutes les 6 h.</span>
            <span style="display:flex;gap:8px">
                <button id="btnCheckNow">Vérifier maintenant</button>
                <button id="btnClearHistory">Vider l'historique</button>
            </span>
        </div>
    </dialog>

    <dialog id="linksModal" aria-labelledby="linksTitle">
        <div class="dlg-head">
            <h2 id="linksTitle">Liens récupérés</h2>
            <button class="dlg-close" data-close="linksModal" aria-label="Fermer">&#10005;</button>
        </div>
        <div class="dlg-body"><div id="modalLinksList"></div></div>
        <div class="dlg-foot">
            <span></span>
            <button id="btnCopyAllLinks">Copier tous les liens</button>
        </div>
    </dialog>

    <script>
        let state = { page: 1, hasMore: false, favoritesView: false, cartView: false, resolvedLinks: [], cart: [], favorites: [], newIds: new Set() };
        let items = [];

        document.getElementById("source").addEventListener("change", () => {
            const src = document.getElementById("source").value;
            const isArchive = src === "archive.org";
            document.getElementById("type").style.display = isArchive ? "" : "none";
            document.getElementById("collection").style.display = isArchive ? "" : "none";
            document.getElementById("sort").style.display = isArchive ? "" : "none";
        });

        // ── Favoris et panier (stockés côté serveur, cf. /api/list) ──────────
        function favKey(item) { return `${item.source}:${item.identifier}`; }
        // Favoris côté serveur, comme le panier : ils suivent d'une machine à
        // l'autre. `state.favorites` en est le miroir local, pour garder des
        // lectures synchrones (isFavorite est appelé pour chaque carte).
        function getFavorites() { return state.favorites; }
        function setFavorites(list) {
            state.favorites = list;
            document.getElementById("favCount").textContent = list.length;
            saveList("favorites", list);
        }
        // Envoi partagé par les deux listes. En tâche de fond : l'interface
        // n'attend pas le réseau, mais un échec se DIT — sinon on croit la
        // liste enregistrée alors qu'elle ne vit que dans cet onglet.
        function saveList(name, list) {
            fetch(`/api/list/${name}`, {
                method: "PUT",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ items: list }),
            }).catch(() => {
                const bar = document.getElementById("dlStatus");
                bar.style.display = "flex";
                bar.textContent = `✗ ${name === "cart" ? "Panier" : "Favoris"} non enregistrés sur le serveur — modification locale seulement.`;
            });
        }
        async function loadList(name) {
            try {
                const d = await (await fetch(`/api/list/${name}`)).json();
                return Array.isArray(d.items) ? d.items : [];
            } catch (e) { return []; }
        }
        function isFavorite(item) { return getFavorites().some(f => favKey(f) === favKey(item)); }
        function toggleFavorite(i) {
            const item = items[i];
            const favs = getFavorites();
            const idx = favs.findIndex(f => favKey(f) === favKey(item));
            if (idx >= 0) favs.splice(idx, 1); else favs.push(item);
            setFavorites(favs);
            if (state.favoritesView) renderResults(getFavorites());
            else {
                const btn = document.querySelector(`.fav-btn[data-idx="${i}"]`);
                if (btn) { btn.classList.toggle("active", isFavorite(item)); btn.textContent = isFavorite(item) ? "★" : "☆"; }
            }
        }

        // ── Lecteur inline (archive.org) : résout le fichier direct puis
        // embarque <video>/<audio> dans la carte plutôt qu'un simple lien. ──
        async function resolveDirectUrl(item, btnEl) {
            if (item.source !== "archive.org" || !item.identifier) return;
            btnEl.textContent = "…";
            try {
                const res = await fetch(`/api/file/${encodeURIComponent(item.identifier)}`);
                const data = await res.json();
                const card = btnEl.closest(".item");
                if (data.url && data.mediatype === "movies") {
                    card.insertAdjacentHTML("beforeend", `<video class="item-player" src="${data.url}" controls></video>`);
                    btnEl.remove();
                    return;
                }
                if (data.url && data.mediatype === "audio") {
                    card.insertAdjacentHTML("beforeend", `<audio class="item-player" src="${data.url}" controls></audio>`);
                    btnEl.remove();
                    return;
                }
                if (data.url) {
                    btnEl.outerHTML = `<a href="${data.url}" target="_blank" class="item-link">Fichier direct</a>`;
                    return;
                }
            } catch (e) { /* fallback texte ci-dessous */ }
            btnEl.textContent = "Fichier direct (indisponible)";
            btnEl.disabled = true;
        }

        // ── Panier : liens vers les documents (torrent en priorité pour
        // archive.org — fair-use, reprise/pause déjà gérées par le client
        // torrent de l'utilisateur ; lien direct sinon). ──────────────────
        // Le panier vit sur le serveur : il suit d'une machine à l'autre et
        // survit au nettoyage du cache. `state.cart` en est le miroir local,
        // pour que les lectures restent synchrones partout dans la page.
        function getCart() { return state.cart; }
        function setCart(list) {
            state.cart = list;
            document.getElementById("cartCount").textContent = list.length;
            saveList("cart", list);
        }
        // Lecture seule au démarrage : écrire ici effacerait ce qu'une autre
        // machine a déposé, puisque le miroir local est encore vide.
        async function loadStored() {
            state.cart = await loadList("cart");
            state.favorites = await loadList("favorites");
            document.getElementById("cartCount").textContent = state.cart.length;
            document.getElementById("favCount").textContent = state.favorites.length;
            if (state.cartView) { renderResults(state.cart); renderRelated(null); }
            if (state.favoritesView) { renderResults(state.favorites); renderRelated(null); }
        }
        function isInCart(item) { return getCart().some(c => favKey(c) === favKey(item)); }
        function toggleCart(i) {
            const item = items[i];
            const cart = getCart();
            const idx = cart.findIndex(c => favKey(c) === favKey(item));
            if (idx >= 0) cart.splice(idx, 1); else cart.push(item);
            setCart(cart);
            if (state.cartView) renderResults(getCart());
            else {
                const btn = document.querySelector(`.cart-btn[data-idx="${i}"]`);
                if (btn) { btn.classList.toggle("active", isInCart(item)); btn.textContent = isInCart(item) ? "🧺" : "➕"; }
            }
        }

        // Résout un item du panier vers son meilleur lien (torrent > direct >
        // fiche), sans toucher au DOM — pur pour être réutilisable par le
        // bouton individuel et par la résolution en masse.
        async function resolveCartItem(item) {
            try {
                if (item.source === "archive.org") {
                    const tres = await fetch(`/api/torrent/${encodeURIComponent(item.identifier)}`);
                    const tdata = await tres.json();
                    if (tdata.url) return { type: "torrent", url: tdata.url, label: "⬇ .torrent" };
                    const fres = await fetch(`/api/file/${encodeURIComponent(item.identifier)}`);
                    const fdata = await fres.json();
                    if (fdata.url) return { type: "direct", url: fdata.url, label: "Lien direct" };
                    return { type: "fiche", url: item.url, label: "Voir la fiche" };
                }
                return { type: "direct", url: item.url, label: "Télécharger" };
            } catch (e) {
                return null;
            }
        }

        // ── Téléchargement groupé : le serveur écrit sur disque, la page
        // ne fait que suivre. Un navigateur ne peut pas ranger des fichiers
        // dans un dossier choisi — c'est tout l'intérêt de passer par lui. ──
        // Demander la destination AVANT de lancer : un lot de trente fichiers
        // rangé au mauvais endroit se retrie à la main. <dialog> natif pour
        // Échap, le piège de focus et le fond inerte — rien à écrire pour ça.
        let dirPath = "";

        function escapeAttr(v) {
            return String(v).replace(/[&<>"']/g, c =>
                ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
        }

        async function downloadAll() {
            if (!getCart().length) return;
            await openDir("");
            document.getElementById("dirModal").showModal();
        }

        async function openDir(path) {
            const list = document.getElementById("dirList");
            try {
                const d = await (await fetch(`/api/download/dirs?path=${encodeURIComponent(path)}`)).json();
                if (d.error) { list.innerHTML = `<div class="dir-empty">${escapeAttr(d.error)}</div>`; return; }
                dirPath = d.path;
                renderCrumbs(d);
                // Le nom voyage en data-*, jamais dans une chaîne JS : un
                // dossier nommé « l'été » casserait un onclick interpolé.
                list.innerHTML = d.dirs.length
                    ? d.dirs.map(e => `<button class="dir-row" data-dir="${escapeAttr(e.name)}">
                            <span>${escapeAttr(e.name)}</span><span class="n">${e.count}</span></button>`).join("")
                    : '<div class="dir-empty">Dossier vide — le téléchargement se fera ici.</div>';
                list.querySelectorAll(".dir-row").forEach(b =>
                    b.addEventListener("click", () => openDir(dirPath ? `${dirPath}/${b.dataset.dir}` : b.dataset.dir)));
                document.getElementById("dirDest").innerHTML =
                    `Destination : <b>${escapeAttr(d.base + (d.path ? "/" + d.path : ""))}</b>` +
                    (d.path ? "" : " <span>(un sous-dossier horodaté sera créé)</span>");
            } catch (e) {
                list.innerHTML = `<div class="dir-empty">Dossiers illisibles : ${escapeAttr(e.message)}</div>`;
            }
        }

        function renderCrumbs(d) {
            const parts = d.path ? d.path.split("/") : [];
            const el = document.getElementById("dirCrumbs");
            let acc = "";
            const nodes = [`<button class="crumb${parts.length ? "" : " current"}" data-path="">racine</button>`];
            parts.forEach((p, i) => {
                acc = acc ? `${acc}/${p}` : p;
                const last = i === parts.length - 1;
                nodes.push('<span class="crumb-sep">/</span>');
                nodes.push(`<button class="crumb${last ? " current" : ""}" data-path="${escapeAttr(acc)}">${escapeAttr(p)}</button>`);
            });
            el.innerHTML = nodes.join("");
            el.querySelectorAll(".crumb:not(.current)").forEach(b =>
                b.addEventListener("click", () => openDir(b.dataset.path)));
        }

        async function makeDir() {
            const input = document.getElementById("newDirName");
            const name = input.value.trim();
            if (!name) return;
            try {
                const res = await fetch("/api/download/mkdir", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ path: dirPath, name }),
                });
                const d = await res.json();
                if (d.error) { alert(d.error); return; }
                input.value = "";
                openDir(d.path);          // on entre dans le dossier créé
            } catch (e) { alert(e.message); }
        }

        async function startDownload() {
            const subdir = dirPath;
            document.getElementById("dirModal").close();
            const bar = document.getElementById("dlStatus");
            bar.style.display = "flex";
            bar.innerHTML = '<div class="dl-wrap"><div class="dl-line"><span>Démarrage…</span></div></div>';
            try {
                const res = await fetch("/api/download", {
                    method: "POST",
                    headers: { "Content-Type": "application/json" },
                    body: JSON.stringify({ items: getCart(), subdir }),
                });
                const data = await res.json();
                if (data.error) { renderDl({ error: data.error }); return; }
                pollDownload();
            } catch (e) { renderDl({ error: e.message }); }
        }

        function humanBytes(n) {
            if (!n) return "";
            const u = ["o", "Ko", "Mo", "Go"];
            let i = 0;
            while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
            return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
        }

        function renderDl(d) {
            const bar = document.getElementById("dlStatus");
            if (d.error) {
                bar.innerHTML = `<div class="dl-wrap"><div class="dl-line"><span>✗ ${d.error}</span></div>
                    <div class="dl-bar"><div class="dl-fill err" style="width:100%"></div></div></div>`;
                return;
            }
            // Progression du LOT, pas du fichier : avec des tailles très
            // inégales, une barre par fichier sauterait sans rien dire.
            const pct = d.total ? Math.round((d.done / d.total) * 100) : 0;
            const sizes = d.bytes_total ? ` · ${humanBytes(d.bytes)} / ${humanBytes(d.bytes_total)}` : (d.bytes ? ` · ${humanBytes(d.bytes)}` : "");
            const retry = d.attempt > 1 ? ` · tentative ${d.attempt}` : "";
            const head = d.running
                ? `⬇ ${d.done}/${d.total}`
                : `✓ ${d.written.length} fichier(s)`;
            const file = d.running && d.current ? `${d.current}${sizes}${retry}` : d.folder;
            let html = `<div class="dl-wrap">
                <div class="dl-line"><span>${head}</span><span class="dl-file" title="${file}">${file}</span></div>
                <div class="dl-bar"><div class="dl-fill ${d.running ? "" : (d.errors.length ? "err" : "done")}" style="width:${d.running ? pct : 100}%"></div></div>`;
            if (!d.running && d.errors.length) {
                html += `<div class="dl-sub">${d.errors.length} ignoré(s) : ${d.errors.join(" | ")}</div>`;
            }
            bar.innerHTML = html + "</div>";
        }

        async function pollDownload() {
            try {
                const d = await (await fetch("/api/download/status")).json();
                renderDl(d);
                // 500 ms : assez vif pour que la taille bouge visiblement sur
                // un gros fichier, assez lent pour ne pas marteler le serveur.
                if (d.running) setTimeout(pollDownload, 500);
            } catch (e) { renderDl({ error: "suivi interrompu : " + e.message }); }
        }

        // ── Modale des liens récupérés — vue centralisée pour tout copier/
        // ouvrir d'un coup, plutôt que d'aller chercher chaque lien dans sa
        // carte au milieu du panier. ────────────────────────────────────────
        function addResolvedLink(entry) {
            state.resolvedLinks.push(entry);
            document.getElementById("linksCount").textContent = state.resolvedLinks.length;
            renderLinksModal();
        }
        function renderLinksModal() {
            const list = document.getElementById("modalLinksList");
            if (state.resolvedLinks.length === 0) {
                list.innerHTML = `<div class="loading">Aucun lien récupéré pour l'instant</div>`;
                return;
            }
            list.innerHTML = state.resolvedLinks.map(l => `
                <div class="link-row">
                    <span class="link-row-tag ${l.type}">${l.type}</span>
                    <span class="link-row-title">${l.title}</span>
                    <a href="${l.url}" target="_blank" class="item-link"${l.type === "torrent" ? " download" : ""}>Ouvrir</a>
                </div>
            `).join("");
        }
        function openLinksModal() {
            renderLinksModal();
            const m = document.getElementById("linksModal");
            if (!m.open) m.showModal();
        }
                        document.getElementById("btnShowLinks").addEventListener("click", openLinksModal);
        document.getElementById("btnCopyAllLinks").addEventListener("click", () => {
            const text = state.resolvedLinks.map(l => l.url).join("\\n");
            navigator.clipboard.writeText(text);
            const btn = document.getElementById("btnCopyAllLinks");
            const original = btn.textContent;
            btn.textContent = "Copié !";
            setTimeout(() => { btn.textContent = original; }, 1500);
        });

        async function resolveCartLink(i, btnEl) {
            const item = items[i];
            btnEl.textContent = "…";
            const resolved = await resolveCartItem(item);
            if (!resolved) {
                btnEl.textContent = "Erreur — réessayer";
                return;
            }
            btnEl.outerHTML = `<a href="${resolved.url}" class="item-link"${resolved.type === "torrent" ? " download" : ' target="_blank"'}>${resolved.label}</a>`;
            addResolvedLink({ title: item.title, type: resolved.type, url: resolved.url });
            openLinksModal();
        }

        // Trois états, et « inconnu » ne bascule JAMAIS du côté permissif :
        // sur archive.org c'est le cas le plus fréquent, et le plus trompeur.
        function licBadge(item) {
            const l = item.license;
            if (!l || !l.code) return '<span class="lic unknown" title="Aucune licence déclarée — vérifier à la source avant réutilisation">licence ?</span>';
            const cls = l.free === true ? "free" : l.free === false ? "restricted" : "unknown";
            const tip = l.free === true ? "Réutilisable, attribution selon la licence"
                      : l.free === false ? "Restrictive : pas de modification et/ou pas d'usage commercial"
                      : "Licence non reconnue — vérifier à la source";
            return l.url
                ? `<a class="lic ${cls}" href="${escapeAttr(l.url)}" target="_blank" title="${tip}">${escapeAttr(l.code)}</a>`
                : `<span class="lic ${cls}" title="${tip}">${escapeAttr(l.code)}</span>`;
        }

        // Filtrage côté page : il porte sur les résultats DÉJÀ reçus, il ne
        // rapatrie pas d'autres pages. Le compteur dit combien sont masqués,
        // sinon une page presque vide passerait pour un manque de résultats.
        function applyLicenseFilter() {
            const only = document.getElementById("onlyFree").checked;
            const hiddenEl = document.getElementById("licHidden");
            if (!only) {
                document.querySelectorAll(".item").forEach(el => { el.hidden = false; });
                hiddenEl.textContent = "";
                return;
            }
            let hidden = 0;
            document.querySelectorAll(".item").forEach((el, i) => {
                const free = items[i] && items[i].license && items[i].license.free === true;
                el.hidden = !free;
                if (!free) hidden++;
            });
            hiddenEl.textContent = hidden ? `${hidden} masqué(s)` : "";
        }

        function isNew(item) {
            return state.newIds.has(String(item.identifier || item.url || item.title)) ? 1 : 0;
        }

        // ── Historique ────────────────────────────────────────────────────
        async function openHistory() {
            const list = document.getElementById("histList");
            list.innerHTML = '<div class="dir-empty">Chargement…</div>';
            document.getElementById("histModal").showModal();
            try {
                const d = await (await fetch("/api/history")).json();
                if (!d.entries.length) {
                    list.innerHTML = '<div class="dir-empty">Aucune recherche enregistrée.</div>';
                    return;
                }
                list.innerHTML = d.entries.map(e => {
                    const when = (e.last_run || "").replace("T", " à ").slice(0, 16);
                    const bits = [e.source, `${e.runs} passage${e.runs > 1 ? "s" : ""}`, `${e.known} connus`];
                    if (e.new_count) bits.push(`${e.new_count} neufs au dernier`);
                    return `<div class="hist-row">
                        <div class="hist-main">
                            <div class="hist-q">${escapeAttr(e.query)}</div>
                            <div class="hist-meta">${when} · ${bits.join(" · ")}</div>
                        </div>
                        <span style="display:flex;gap:6px;flex:none">
                            <button class="watch-btn${e.watch ? " on" : ""}" data-watch="${escapeAttr(e.key)}"
                                title="${e.watch ? "Surveillée : une notification part quand du neuf apparaît" : "Surveiller cette recherche"}">${e.watch ? "👁 suivie" : "👁"}</button>
                            <button class="item-link" data-replay="${escapeAttr(JSON.stringify({
                                q: e.query, source: e.source, type: e.type || "",
                                sort: e.sort || "", collection: e.collection || "" }))}">Relancer</button>
                            <button class="watch-btn" data-forget="${escapeAttr(e.key)}"
                                title="Oublier cette recherche">&#10005;</button>
                        </span>
                    </div>`;
                }).join("");
                list.querySelectorAll("[data-replay]").forEach(b =>
                    b.addEventListener("click", () => replay(JSON.parse(b.dataset.replay))));
                list.querySelectorAll("[data-forget]").forEach(b =>
                    b.addEventListener("click", async () => {
                        // Confirmation seulement si la recherche est SUIVIE :
                        // la supprimer arrête une veille, ce qui ne se devine
                        // pas. Pour une ligne ordinaire, demander serait du
                        // bruit — elle se recrée en relançant la recherche.
                        const watched = b.closest(".hist-row").querySelector(".watch-btn.on");
                        if (watched && !confirm("Cette recherche est surveillée. L'oublier arrête la veille. Continuer ?")) return;
                        await fetch("/api/history/entry", {
                            method: "DELETE", headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ key: b.dataset.forget }),
                        });
                        openHistory();
                    }));
                list.querySelectorAll("[data-watch]").forEach(b =>
                    b.addEventListener("click", async () => {
                        const on = !b.classList.contains("on");
                        await fetch("/api/history/watch", {
                            method: "POST", headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ key: b.dataset.watch, watch: on }),
                        });
                        openHistory();
                    }));
            } catch (e) {
                list.innerHTML = `<div class="dir-empty">Historique illisible : ${escapeAttr(e.message)}</div>`;
            }
        }

        function replay(p) {
            document.getElementById("histModal").close();
            state.cartView = false;
            state.favoritesView = false;
            applyParams(p);
            search(1);
            window.scrollTo({ top: 0, behavior: "smooth" });
        }

        function itemCard(item, i) {
            const fav = isFavorite(item);
            const cart = isInCart(item);
            const cartAction = state.cartView
                ? `<button class="item-link" onclick="resolveCartLink(${i}, this)">Récupérer le lien</button>`
                : "";
            return `
                <div class="item${isNew(item) ? " is-new" : ""}">
                    ${item.thumbnail ? `<img class="item-thumb" src="${item.thumbnail}" loading="lazy" onerror="this.style.display='none'">` : ""}
                    <div class="item-title-row">
                        <div class="item-title">${item.title}</div>
                        <div>
                            <button class="cart-btn ${cart ? "active" : ""}" data-idx="${i}" onclick="toggleCart(${i})" title="Panier">${cart ? "🧺" : "➕"}</button>
                            <button class="fav-btn ${fav ? "active" : ""}" data-idx="${i}" onclick="toggleFavorite(${i})" title="Favori">${fav ? "★" : "☆"}</button>
                        </div>
                    </div>
                    <div class="item-meta">${isNew(item) ? '<span class="badge-new">nouveau</span>' : ""}<span class="src">${item.source}</span>${licBadge(item)} · ${item.year || item.type} · ${item.creator || "N/A"}</div>
                    <div class="item-desc">${item.description || ""}</div>
                    <div class="item-links">
                        <a href="${item.url}" target="_blank" class="item-link">Ouvrir</a>
                        ${item.source === "archive.org" ? `<button class="item-link" onclick="resolveDirectUrl(items[${i}], this)">▶ Lire ici</button>` : ""}
                    </div>
                    ${item.preview ? `<audio class="item-player" src="${item.preview}" controls preload="none"></audio>` : ""}
                    <div class="item-links">
                        ${cartAction}
                    </div>
                </div>
            `;
        }

        // Propositions connexes : dérivées des résultats, pas d'un service
        // tiers. Un clic relance la recherche sur la même source — rester
        // dans le fonds qu'on explore, plutôt que repartir de zéro.
        function renderRelated(rel) {
            const el = document.getElementById("related");
            if (!rel) { el.style.display = "none"; el.innerHTML = ""; return; }
            const groups = [
                ["Affiner", rel.keywords || [], "", t => t],
                ["Auteur", rel.creators || [], "who", t => `"${t}"`],
                ["Année", rel.years || [], "when", t => t],
            ];
            const parts = [];
            for (const [label, list, cls, toQuery] of groups) {
                if (!list.length) continue;
                parts.push(`<span class="related-label">${label}</span>`);
                for (const t of list) {
                    parts.push(`<button class="rel ${cls}" data-q="${escapeAttr(toQuery(t))}">${escapeAttr(t)}</button>`);
                }
            }
            if (!parts.length) { el.style.display = "none"; el.innerHTML = ""; return; }
            el.innerHTML = parts.join("");
            el.style.display = "flex";
            el.querySelectorAll(".rel").forEach(b => b.addEventListener("click", () => {
                document.getElementById("query").value = b.dataset.q;
                search(1);
                window.scrollTo({ top: 0, behavior: "smooth" });
            }));
        }

        function renderResults(list) {
            const el = document.getElementById("results");
            if (list.length === 0) {
                el.innerHTML = '<div class="error">Aucun résultat</div>';
                return;
            }
            items = list;
            el.innerHTML = `<div class="results">${list.map((item, i) => itemCard(item, i)).join("")}</div>`;
            applyLicenseFilter();
        }

        // ── État de recherche dans l'URL (partage, retour navigateur) ─────
        function currentParams() {
            return {
                q: document.getElementById("query").value,
                source: document.getElementById("source").value,
                type: document.getElementById("type").value,
                collection: document.getElementById("collection").value,
                sort: document.getElementById("sort").value,
            };
        }
        function applyParams(p) {
            document.getElementById("query").value = p.q || "";
            document.getElementById("source").value = p.source || "archive.org";
            document.getElementById("type").value = p.type || "";
            document.getElementById("collection").value = p.collection || "";
            document.getElementById("sort").value = p.sort || "";
            document.getElementById("source").dispatchEvent(new Event("change"));
        }

        async function search(page, pushHistory) {
            if (pushHistory === undefined) pushHistory = true;
            state.favoritesView = false;
            state.cartView = false;
            syncViewToggles();
            const p = currentParams();
            if (!p.q) { alert("Entrez un terme de recherche"); return; }
            state.page = page;

            if (pushHistory) {
                const url = `?${new URLSearchParams({ ...p, page }).toString()}`;
                history.pushState({ ...p, page }, "", url);
            }

            document.getElementById("results").innerHTML = '<div class="loading">⏳ Recherche...</div>';
            document.getElementById("pagination").style.display = "none";

            // La Library of Congress place tout son site derrière un défi
            // Cloudflare : un serveur ne peut pas l'interroger, seul un
            // navigateur passe. On renvoie donc la recherche chez eux plutôt que
            // de faire semblant — et on dit pourquoi, pour que la liste vide ne
            // passe pas pour une panne.
            if (p.source === "loc.gov") {
                const cible = `https://www.loc.gov/audio/?q=${encodeURIComponent(p.q)}`;
                document.getElementById("results").innerHTML = `
                    <div class="renvoi">
                        <h3>↗ Library of Congress — « ${p.q.replace(/[<>&]/g, "")} »</h3>
                        <p>Leur fonds audio ne peut pas être interrogé depuis ce serveur.
                           La recherche s'ouvre chez eux, dans un onglet.</p>
                        <a class="go" href="${cible}" target="_blank" rel="noopener">Ouvrir sur loc.gov ↗</a>
                        <div class="pourquoi">
                            loc.gov protège tout son site par un défi JavaScript (Cloudflare) :
                            il répond 403 à un programme, y compris sur sa propre documentation
                            d'API. Un navigateur le passe sans rien avoir à faire. Ni panier ni
                            lecteur intégré pour cette source — les résultats vivent chez eux.
                        </div>
                    </div>`;
                return;
            }

            try {
                const res = await fetch(`/api/search?${new URLSearchParams({ ...p, page }).toString()}`);
                const data = await res.json();

                if (data.error) {
                    document.getElementById("results").innerHTML = `<div class="error">❌ ${data.error}</div>`;
                    renderRelated(null);
                    return;
                }

                // Les nouveautés d'abord : on relance une recherche POUR
                // elles, les faire chercher au milieu de vingt cartes
                // annulerait l'intérêt.
                state.newIds = new Set(data.new_ids || []);
                const ordered = state.newIds.size
                    ? [...data.results].sort((a, b) => isNew(b) - isNew(a))
                    : data.results;
                renderResults(ordered);
                renderRelated(data.related);
                if (state.newIds.size) {
                    const bar = document.getElementById("dlStatus");
                    bar.style.display = "flex";
                    bar.innerHTML = `<div class="dl-wrap"><div class="dl-line"><span>` +
                        `✦ ${state.newIds.size} nouveauté(s) depuis la dernière fois</span></div></div>`;
                }

                state.hasMore = data.has_more;
                document.getElementById("pagination").style.display = "flex";
                document.getElementById("btnPrev").disabled = page <= 1;
                document.getElementById("btnNext").disabled = !data.has_more;
                document.getElementById("pageInfo").textContent = data.total != null
                    ? `Page ${page} / ${Math.max(1, Math.ceil(data.total / 20))} (${data.total} résultats)`
                    : `Page ${page}`;
            } catch (err) {
                document.getElementById("results").innerHTML = `<div class="error">Erreur: ${err.message}</div>`;
            }
        }

        document.getElementById("btnPrev").addEventListener("click", () => { if (state.page > 1) search(state.page - 1); });
        document.getElementById("btnNext").addEventListener("click", () => { if (state.hasMore) search(state.page + 1); });

        document.getElementById("query").addEventListener("keypress", (e) => {
            if (e.key === "Enter") search(1);
        });

        function syncViewToggles() {
            document.getElementById("btnFavorites").classList.toggle("on", state.favoritesView);
            document.getElementById("btnCart").classList.toggle("on", state.cartView);
            document.getElementById("cartBulkBar").style.display = state.cartView ? "flex" : "none";
        }

        document.getElementById("btnFavorites").addEventListener("click", () => {
            state.favoritesView = !state.favoritesView;
            state.cartView = false;
            syncViewToggles();
            document.getElementById("pagination").style.display = "none";
            if (state.favoritesView) renderResults(getFavorites());
            else document.getElementById("results").innerHTML = "";
        });

        document.getElementById("btnCart").addEventListener("click", () => {
            state.cartView = !state.cartView;
            state.favoritesView = false;
            syncViewToggles();
            document.getElementById("pagination").style.display = "none";
            if (state.cartView) renderResults(getCart());
            else document.getElementById("results").innerHTML = "";
        });

        document.getElementById("btnClearCart").addEventListener("click", () => {
            setCart([]);
            renderResults(getCart());
        });

        document.getElementById("btnDownloadAll").addEventListener("click", downloadAll);
        document.getElementById("btnDirGo").addEventListener("click", startDownload);
        document.getElementById("onlyFree").addEventListener("change", applyLicenseFilter);
        document.getElementById("btnHistory").addEventListener("click", openHistory);
        document.getElementById("btnCheckNow").addEventListener("click", async (e) => {
            const info = document.getElementById("watchInfo");
            e.target.disabled = true;
            try {
                const d = await (await fetch("/api/history/check", { method: "POST" })).json();
                // Le passage tourne en fond : on ne peut pas promettre un
                // résultat tout de suite, on dit ce qui a démarré.
                info.textContent = d.watched
                    ? `Passage lancé sur ${d.watched} recherche(s) — notification s'il y a du neuf.`
                    : "Aucune recherche suivie : active l'œil sur une ligne.";
            } catch (err) { info.textContent = "Échec : " + err.message; }
            setTimeout(() => { e.target.disabled = false; }, 3000);
        });
        document.getElementById("btnClearHistory").addEventListener("click", async () => {
            await fetch("/api/history", { method: "DELETE" });
            openHistory();
        });
        document.getElementById("btnMkdir").addEventListener("click", makeDir);
        document.getElementById("newDirName").addEventListener("keydown", e => {
            if (e.key === "Enter") { e.preventDefault(); makeDir(); }
        });
        // Un seul écouteur pour tous les boutons de fermeture des dialogues.
        document.querySelectorAll("[data-close]").forEach(b =>
            b.addEventListener("click", () => document.getElementById(b.dataset.close).close()));
        document.getElementById("btnResolveAll").addEventListener("click", async () => {
            const btn = document.getElementById("btnResolveAll");
            btn.disabled = true;
            // Séquentiel + petite pause : plusieurs déclenchements de
            // téléchargement d'affilée depuis un seul clic peuvent se faire
            // bloquer par le navigateur — un par un reste fiable. La modale
            // ne s'ouvre qu'une fois à la fin, pas à chaque item résolu.
            const buttons = [...document.querySelectorAll(".item-links button")].filter(b => b.textContent.includes("Récupérer le lien"));
            for (const b of buttons) {
                const idx = parseInt(b.closest(".item").querySelector(".cart-btn").dataset.idx, 10);
                const item = items[idx];
                b.textContent = "…";
                const resolved = await resolveCartItem(item);
                if (resolved) {
                    b.outerHTML = `<a href="${resolved.url}" class="item-link"${resolved.type === "torrent" ? " download" : ' target="_blank"'}>${resolved.label}</a>`;
                    addResolvedLink({ title: item.title, type: resolved.type, url: resolved.url });
                } else {
                    b.textContent = "Erreur";
                }
                await new Promise(r => setTimeout(r, 400));
            }
            btn.disabled = false;
            openLinksModal();
        });

        document.getElementById("btnSurprise").addEventListener("click", async () => {
            state.favoritesView = false;
            state.cartView = false;
            syncViewToggles();
            document.getElementById("pagination").style.display = "none";
            document.getElementById("results").innerHTML = '<div class="loading">🎲 Pioche en cours...</div>';
            try {
                const res = await fetch("/api/random");
                const data = await res.json();
                if (data.error) { document.getElementById("results").innerHTML = `<div class="error">${data.error}</div>`; return; }
                renderResults([data.result]);
            } catch (err) {
                document.getElementById("results").innerHTML = `<div class="error">Erreur: ${err.message}</div>`;
            }
        });

        window.addEventListener("popstate", (e) => {
            if (e.state) { applyParams(e.state); search(e.state.page || 1, false); }
        });

        // Init : favoris + panier + recherche depuis l'URL si présente.
        // On LIT les deux listes, on n'écrit que sur une action de l'usager :
        // un setX(getX()) au chargement enverrait un miroir vide et effacerait
        // ce qui a été posé depuis une autre machine.
        loadStored();
        (function initFromUrl() {
            const p = Object.fromEntries(new URLSearchParams(location.search));
            if (p.q) {
                applyParams(p);
                search(parseInt(p.page || "1", 10), false);
            } else {
                document.getElementById("source").dispatchEvent(new Event("change"));
            }
        })();
    </script>
</body>
</html>
"""


DATA_DIR = Path(os.getenv("DATA_DIR", Path.home() / ".local/share/archive-search"))

# ── Panier partagé ────────────────────────────────────────────────────────
# Panier et favoris vivaient en localStorage : une liste par navigateur, perdue au
# nettoyage du cache et invisible depuis une autre machine. Il vit maintenant
# ici, dans un fichier, parce qu'une seule personne l'utilise depuis plusieurs
# postes du même réseau.
# ⚠️ Dernier écrivain gagne : deux onglets qui modifient en même temps, c'est le
# second qui reste. Pas de verrou ni de fusion — à cette échelle, une
# réconciliation coûterait plus cher que le problème qu'elle éviterait.
# Panier ET favoris : même besoin, même mécanique, un fichier chacun.
LISTS = {
    "cart": Path(os.getenv("CART_FILE", DATA_DIR / "cart.json")),
    "favorites": Path(os.getenv("FAVORITES_FILE", DATA_DIR / "favorites.json")),
}
_list_lock = threading.Lock()


def _list_read(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []


def _list_write(path, items):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(items, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)             # remplacement atomique : jamais de liste tronquée


@app.route("/api/list/<name>", methods=["GET", "PUT"])
def api_list(name):
    path = LISTS.get(name)
    if path is None:
        return jsonify({"error": f"Liste inconnue : {name}"}), 404
    if request.method == "GET":
        with _list_lock:
            return jsonify({"items": _list_read(path)})
    items = (request.get_json(silent=True) or {}).get("items")
    if not isinstance(items, list):
        return jsonify({"error": "items doit être une liste"}), 400
    with _list_lock:
        _list_write(path, items)
    return jsonify({"items": items})


# Ancienne route, gardée : une page encore ouverte dans un onglet continue de
# l'appeler après le redémarrage du service.
@app.route("/api/cart", methods=["GET", "PUT"])
def api_cart():
    return api_list("cart")


# ── Téléchargement groupé du panier ───────────────────────────────────────
# Un seul lot à la fois, dans un thread : un film d'archive.org se compte en
# gigaoctets, et une requête HTTP qui attend la fin expirerait bien avant.
# L'état vit en mémoire — relancer le service annule le suivi, pas les fichiers
# déjà écrits.
DOWNLOAD_DIR = Path(os.getenv("DOWNLOAD_DIR", Path.home() / "archive-search-downloads"))
DOWNLOAD_CHUNK = 1 << 16

DOWNLOAD_RETRIES = 3
_dl_lock = threading.Lock()
_dl = {"running": False, "done": 0, "total": 0, "folder": "", "current": "",
       "bytes": 0, "bytes_total": 0, "attempt": 0, "errors": [], "written": []}


def _safe_subdir(raw):
    """Chemin de destination sous DOWNLOAD_DIR, ou None s'il en sort.

    Validation obligatoire : le dossier vient du navigateur. Sans ce test,
    « ../../.ssh » écrirait où bon lui semble sous l'utilisateur du service.
    """
    raw = (raw or "").strip().strip("/")
    base = DOWNLOAD_DIR.resolve()
    target = (base / raw).resolve() if raw else base
    if target != base and base not in target.parents:
        return None
    return target


def _safe_name(name, maxlen=90):
    """Nom de fichier sûr : pas de séparateur, pas de point initial, borné."""
    name = re.sub(r"[^\w\s.\-()\[\]]", "", name, flags=re.UNICODE).strip()
    name = re.sub(r"\s+", " ", name).lstrip(".")
    return (name[:maxlen].strip() or "sans-titre")


def _resolve_download_url(item):
    """(url, raison_du_refus). Seules les sources donnant un VRAI fichier passent."""
    source = item.get("source", "")
    if source == "archive.org":
        try:
            url, _ = resolve_archive_file(item.get("identifier", ""))
            return (url, None) if url else (None, "aucun fichier média trouvé")
        except Exception as e:
            return None, f"résolution impossible ({e})"
    if source == "freesound":
        # L'API ne donne que la prévisualisation : le fichier d'origine exige
        # OAuth2, pas le simple jeton. C'est un mp3 utilisable, pas le master.
        return (item.get("preview") or None, None if item.get("preview") else "pas de prévisualisation")
    # Gutenberg, Wikimedia, LibriVox : `url` pointe une PAGE, pas un fichier.
    return None, "cette source ne renvoie qu'une page web, pas un fichier"


def _download_worker(items, folder):
    for item in items:
        title = item.get("title", "sans-titre")
        with _dl_lock:
            _dl["current"] = title
        url, refus = _resolve_download_url(item)
        if not url:
            with _dl_lock:
                _dl["errors"].append(f"{title} — {refus}")
                _dl["done"] += 1
            continue
        try:
            sub = folder / _safe_name(item.get("source", "divers"), 40)
            sub.mkdir(parents=True, exist_ok=True)
            ext = os.path.splitext(urlparse(url).path)[1][:8] or ".bin"
            # Beaucoup de titres Freesound finissent par « .wav » : sans ça on
            # écrirait « pluie.wav.mp3 », qui ment sur le format réel.
            base = _safe_name(re.sub(r"\.(wav|aiff?|flac|mp3|ogg|m4a)$", "", title, flags=re.I))
            dest = sub / (base + ext)
            n = 1
            while dest.exists():           # deux sons peuvent porter le même titre
                dest = sub / f"{base} ({n}){ext}"
                n += 1
            # Reprise : une coupure réseau ou un 5xx passager ne doit pas
            # condamner un fichier au milieu d'un lot de trente.
            last = None
            for attempt in range(1, DOWNLOAD_RETRIES + 1):
                with _dl_lock:
                    _dl["attempt"] = attempt
                    _dl["bytes"] = 0
                    _dl["bytes_total"] = 0
                try:
                    with requests.get(url, headers=HEADERS, stream=True, timeout=60) as r:
                        r.raise_for_status()
                        if "text/html" in (r.headers.get("Content-Type") or ""):
                            raise RuntimeError("le serveur renvoie une page web, pas un fichier")
                        total_b = int(r.headers.get("Content-Length") or 0)
                        with _dl_lock:
                            _dl["bytes_total"] = total_b
                        tmp = dest.with_suffix(dest.suffix + ".part")
                        got = 0
                        with open(tmp, "wb") as fh:
                            for chunk in r.iter_content(DOWNLOAD_CHUNK):
                                fh.write(chunk)
                                got += len(chunk)
                                with _dl_lock:
                                    _dl["bytes"] = got
                        tmp.rename(dest)   # rien d'incomplet ne porte le nom final
                    last = None
                    break
                except Exception as e:
                    last = e
                    # Une page web n'est pas une panne passagère : réessayer
                    # trente fois ne la transformera pas en fichier.
                    if "page web" in str(e):
                        break
                    if attempt < DOWNLOAD_RETRIES:
                        time.sleep(2 ** attempt)
            if last:
                raise last
            with _dl_lock:
                _dl["written"].append(str(dest.relative_to(folder)))
        except Exception as e:
            with _dl_lock:
                _dl["errors"].append(f"{title} — {e}")
        finally:
            with _dl_lock:
                _dl["done"] += 1
    with _dl_lock:
        _dl["running"] = False
        _dl["current"] = ""


@app.route("/api/download", methods=["POST"])
def api_download():
    with _dl_lock:
        if _dl["running"]:
            return jsonify({"error": "Un téléchargement est déjà en cours."}), 409
    body = request.get_json(silent=True) or {}
    items = body.get("items") or []
    if not items:
        return jsonify({"error": "Panier vide."}), 400
    folder = _safe_subdir(body.get("subdir"))
    if folder is None:
        return jsonify({"error": "Destination hors du dossier de téléchargement."}), 400
    if not body.get("subdir"):
        folder = folder / time.strftime("%Y-%m-%d_%H%M")
    folder.mkdir(parents=True, exist_ok=True)
    with _dl_lock:
        _dl.update(running=True, done=0, total=len(items), folder=str(folder),
                   current="", bytes=0, bytes_total=0, attempt=0, errors=[], written=[])
    threading.Thread(target=_download_worker, args=(items, folder), daemon=True).start()
    return jsonify({"started": True, "folder": str(folder), "total": len(items)})


@app.route("/api/download/dirs")
def api_download_dirs():
    """Contenu d'un dossier, pour naviguer l'arborescence comme dans une
    boîte de dialogue. `path` est TOUJOURS relatif à DOWNLOAD_DIR : la racine
    du serveur ne se parcourt pas depuis le navigateur."""
    rel = request.args.get("path", "")
    target = _safe_subdir(rel)
    if target is None:
        return jsonify({"error": "Chemin hors du dossier de téléchargement."}), 400
    target.mkdir(parents=True, exist_ok=True)
    base = DOWNLOAD_DIR.resolve()
    entries = []
    for child in sorted(target.iterdir(), key=lambda c: c.name.lower()):
        if not child.is_dir():
            continue
        try:
            n = sum(1 for _ in child.iterdir())
        except OSError:
            n = 0
        entries.append({"name": child.name, "count": n})
    return jsonify({
        "base": str(base),
        "path": "" if target == base else str(target.relative_to(base)),
        # "" = la racine ; "." viendrait de relative_to et casserait le fil d'Ariane.
        "parent": None if target == base else str(target.parent.relative_to(base)).replace(".", "", 1) if target.parent == base else str(target.parent.relative_to(base)),
        "dirs": entries,
    })


@app.route("/api/download/mkdir", methods=["POST"])
def api_download_mkdir():
    """Créer un dossier depuis la boîte de dialogue, sans quitter la page."""
    body = request.get_json(silent=True) or {}
    parent = (body.get("path") or "").strip().strip("/")
    name = (body.get("name") or "").strip()
    # Un nom, pas un chemin : « ../x » doit échouer ici, pas être rattrapé
    # plus loin par _safe_subdir.
    if not name or "/" in name or name in (".", ".."):
        return jsonify({"error": "Nom de dossier invalide."}), 400
    target = _safe_subdir(f"{parent}/{name}" if parent else name)
    if target is None:
        return jsonify({"error": "Destination hors du dossier de téléchargement."}), 400
    try:
        target.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        return jsonify({"error": str(e)}), 500
    return jsonify({"path": str(target.relative_to(DOWNLOAD_DIR.resolve()))})


@app.route("/api/download/status")
def api_download_status():
    with _dl_lock:
        return jsonify(dict(_dl))


@app.route("/")
def index():
    return render_template_string(HTML)


# ── Licences ──────────────────────────────────────────────────────────────
# Un fonds en accès libre n'est PAS un fonds libre de droits. « by-nc-nd »
# interdit la modification : un son sous cette licence ne peut pas entrer dans
# un morceau publié. L'outil doit le dire AVANT le téléchargement, pas après.
#
# Trois états seulement, parce qu'un dégradé de nuances ne se lit pas sur une
# carte : réutilisable, restreint, inconnu. « Inconnu » n'est pas « libre » —
# c'est le cas le plus fréquent sur archive.org, et le plus trompeur.
LICENSES = [
    ("publicdomain/zero", "CC0", True),
    ("publicdomain/mark", "Domaine public", True),
    ("licenses/by-nc-nd", "CC BY-NC-ND", False),
    ("licenses/by-nc-sa", "CC BY-NC-SA", False),
    ("licenses/by-nc", "CC BY-NC", False),
    ("licenses/by-nd", "CC BY-ND", False),
    ("licenses/by-sa", "CC BY-SA", True),
    ("licenses/by", "CC BY", True),
    ("licenses/sampling+", "Sampling+", False),
]


def normalize_license(url):
    """URL de licence → {code, libre}. `libre` vaut None quand on ne sait pas."""
    u = (url or "").strip().lower()
    if not u:
        return {"code": "", "label": "", "free": None, "url": ""}
    for needle, label, free in LICENSES:
        if needle in u:
            return {"code": label, "label": label, "free": free, "url": url}
    return {"code": "autre", "label": "licence non reconnue", "free": None, "url": url}


# ── Historique des recherches ─────────────────────────────────────────────
# Sur le serveur, comme le panier : une recherche lancée depuis le portable se
# relance depuis la machine du studio. Chaque entrée retient les identifiants
# déjà vus, ce qui permet de dire ce qui est APPARU depuis la dernière fois —
# c'est tout l'intérêt de relancer une recherche sur un fonds vivant.
HISTORY_FILE = Path(os.getenv("HISTORY_FILE", DATA_DIR / "history.json"))
HISTORY_MAX = 120
SEEN_MAX = 400            # par recherche : au-delà, on oublie les plus anciens
_hist_lock = threading.Lock()


def _hist_key(source, query, search_type, sort, collection):
    # La PAGE n'entre pas dans la clé : les pages 1 et 2 d'une même recherche
    # sont la même recherche, et leurs résultats alimentent le même « déjà vu ».
    return "|".join([source, query.strip().lower(), search_type or "", sort or "", collection or ""])


def _hist_read():
    try:
        return json.loads(HISTORY_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def _hist_write(data):
    HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = HISTORY_FILE.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    tmp.replace(HISTORY_FILE)


def record_search(source, query, search_type, sort, collection, page, results):
    """Enregistre le passage et retourne les identifiants JAMAIS vus avant.

    ⚠️ Une recherche inédite ne renvoie RIEN comme nouveau : tout l'est, et
    badger vingt résultats sur vingt n'apprendrait rien. La nouveauté n'a de
    sens qu'au deuxième passage.
    """
    key = _hist_key(source, query, search_type, sort, collection)
    ids = [str(r.get("identifier") or r.get("url") or r.get("title")) for r in results]
    now = time.strftime("%Y-%m-%dT%H:%M:%S")
    with _hist_lock:
        data = _hist_read()
        entry = data.get(key)
        first_run = entry is None
        if first_run:
            entry = {"query": query, "source": source, "type": search_type,
                     "sort": sort, "collection": collection,
                     "first_seen": now, "runs": 0, "seen": {}, "new_count": 0}
        fresh = [] if first_run else [i for i in ids if i not in entry["seen"]]
        for i in ids:
            entry["seen"].setdefault(i, now)
        if len(entry["seen"]) > SEEN_MAX:
            keep = sorted(entry["seen"].items(), key=lambda kv: kv[1], reverse=True)[:SEEN_MAX]
            entry["seen"] = dict(keep)
        # Le compteur ne vaut que pour la page 1 : sinon feuilleter trois pages
        # gonflerait le chiffre sans qu'il soit rien arrivé.
        if page == 1:
            entry["new_count"] = len(fresh)
        entry["last_run"] = now
        entry["runs"] = entry.get("runs", 0) + (1 if page == 1 else 0)
        data[key] = entry
        if len(data) > HISTORY_MAX:
            oldest = sorted(data.items(), key=lambda kv: kv[1].get("last_run", ""))[:len(data) - HISTORY_MAX]
            for k, _ in oldest:
                data.pop(k, None)
        _hist_write(data)
    return fresh


@app.route("/api/history", methods=["GET", "DELETE"])
def api_history():
    if request.method == "DELETE":
        with _hist_lock:
            _hist_write({})
        return jsonify({"entries": []})
    with _hist_lock:
        data = _hist_read()
    entries = [{
        "key": k, "query": e.get("query"), "source": e.get("source"),
        "type": e.get("type"), "sort": e.get("sort"), "collection": e.get("collection"),
        "first_seen": e.get("first_seen"), "last_run": e.get("last_run"),
        "runs": e.get("runs", 0), "known": len(e.get("seen") or {}),
        "new_count": e.get("new_count", 0), "watch": bool(e.get("watch")),
    } for k, e in data.items()]
    entries.sort(key=lambda e: e["last_run"] or "", reverse=True)
    return jsonify({"entries": entries})


# ── Veille sur les recherches ─────────────────────────────────────────────
# Relancer à la main suppose d'y penser. Sur des fonds qui bougent lentement,
# personne ne va vérifier tous les jours s'il y a une nouvelle prise de terrain
# bretonne — donc c'est la machine qui regarde, et elle ne parle QUE s'il y a
# du neuf. Un passage silencieux est le cas normal.
WATCH_INTERVAL_S = int(os.getenv("WATCH_INTERVAL_S", 6 * 3600))
WATCH_SPACING_S = int(os.getenv("WATCH_SPACING_S", 20))   # entre deux sources
NOTIFY_CMD = os.getenv("NOTIFY_CMD", str(Path.home() / "scripts/notify.sh"))


def notify(title, body):
    """Passe par notify.sh — le point unique du homelab vers Discord.

    Jamais d'URL de webhook ici : elle vit dans ~/.config/robotariis/, et ce
    dépôt est public. Un échec se journalise, il n'interrompt pas la veille.
    """
    try:
        subprocess.run([NOTIFY_CMD, title, body], timeout=20,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception as e:
        print(f"[veille] notification impossible : {e}", flush=True)


def watched_entries():
    with _hist_lock:
        data = _hist_read()
    return [(k, e) for k, e in data.items() if e.get("watch")]


def _watch_pass():
    entries = watched_entries()
    if not entries:
        return
    print(f"[veille] {len(entries)} recherche(s) surveillée(s)", flush=True)
    for key, e in entries:
        source, query = e.get("source"), e.get("query")
        fn = SOURCES.get(source)
        if not fn:
            continue
        try:
            results, _ = fn(query, e.get("type") or "", 1, e.get("sort") or "", e.get("collection") or "")
        except Exception as err:
            # Une source en panne ne doit pas arrêter la veille des autres,
            # ni réveiller quelqu'un : c'est leur problème, pas un événement.
            print(f"[veille] {source} « {query} » : {err}", flush=True)
            time.sleep(WATCH_SPACING_S)
            continue
        fresh = record_search(source, query, e.get("type") or "", e.get("sort") or "",
                              e.get("collection") or "", 1, results)
        if fresh:
            titles = [r.get("title", "?") for r in results
                      if str(r.get("identifier") or r.get("url") or r.get("title")) in set(fresh)][:5]
            notify(f"Archive Search — {len(fresh)} nouveauté(s)",
                   f"« {query} » sur {source}\n" + "\n".join(f"· {t}" for t in titles))
            print(f"[veille] {len(fresh)} neufs pour « {query} » ({source})", flush=True)
        # Espacer : six recherches d'affilée sur la même source ressemblent à
        # du moissonnage et finissent par se faire limiter.
        time.sleep(WATCH_SPACING_S)


def _watch_loop():
    while True:
        time.sleep(WATCH_INTERVAL_S)
        try:
            _watch_pass()
        except Exception as e:
            print(f"[veille] passage interrompu : {e}", flush=True)


@app.route("/api/history/entry", methods=["DELETE"])
def api_history_delete_entry():
    """Oublier UNE recherche. Son « déjà vu » part avec elle : la relancer
    ensuite repartira de zéro, et ne marquera donc rien comme nouveau."""
    key = (request.get_json(silent=True) or {}).get("key")
    with _hist_lock:
        data = _hist_read()
        if key not in data:
            return jsonify({"error": "Recherche inconnue."}), 404
        data.pop(key)
        _hist_write(data)
    return jsonify({"deleted": key})


@app.route("/api/history/watch", methods=["POST"])
def api_history_watch():
    body = request.get_json(silent=True) or {}
    key, on = body.get("key"), bool(body.get("watch"))
    with _hist_lock:
        data = _hist_read()
        if key not in data:
            return jsonify({"error": "Recherche inconnue."}), 404
        data[key]["watch"] = on
        _hist_write(data)
    return jsonify({"key": key, "watch": on})


@app.route("/api/history/check", methods=["POST"])
def api_history_check():
    """Déclenche un passage tout de suite, pour ne pas attendre six heures
    quand on veut juste vérifier que la veille fonctionne."""
    threading.Thread(target=_watch_pass, daemon=True).start()
    return jsonify({"started": True, "watched": len(watched_entries())})


# ── Propositions connexes ─────────────────────────────────────────────────
# Dérivées des résultats DÉJÀ obtenus : aucun appel réseau de plus, et ça
# marche pour toute source, même celles sans API de suggestion.
# Trois familles, parce qu'elles ne servent pas la même chose : affiner le
# sujet (mots-clés), suivre un auteur, ou rester dans la même époque.
STOPWORDS = set("""
le la les un une des du de d l et ou à a au aux en dans sur pour par avec sans
sous the a an and or of in on for to with from at by is it this that
no 01 02 03 mp3 wav flac the_ vol part no. feat remix live edit mix
""".split())


def _tokens(text):
    for w in re.split(r"[^\w\u00c0-\u024f]+", (text or "").lower()):
        # 4 lettres minimum : « the », « mix », « 02 » ne proposent rien.
        # On écarte aussi les horodatages (« 00am », « 01pm », « 14h ») qui
        # polluent les descriptions d'archive.org — mais PAS « 16mm » ni
        # « super8 », qui sont de vrais termes de recherche pour un fonds film.
        if (len(w) >= 4 and w not in STOPWORDS and not w.isdigit()
                and not re.fullmatch(r"\d+(am|pm|h|hrs?|min|sec)", w)):
            yield w


def related_terms(results, query):
    asked = set(_tokens(query))
    kw, creators, years = {}, {}, {}
    for r in results:
        for k in (r.get("keywords") or []):
            k = str(k).strip().lower()
            if len(k) >= 3 and k not in asked and k not in STOPWORDS:
                kw[k] = kw.get(k, 0) + 1
        for w in _tokens(r.get("title")):
            if w not in asked:
                kw[w] = kw.get(w, 0) + 1
        c = (r.get("creator") or "").strip()
        if c and c.upper() != "N/A":
            creators[c] = creators.get(c, 0) + 1
        y = str(r.get("year") or "")[:4]
        if y.isdigit():
            years[y] = years.get(y, 0) + 1

    def top(d, n, mini=2):
        # Vu une seule fois sur vingt résultats, ce n'est pas un thème.
        return [k for k, c in sorted(d.items(), key=lambda kv: (-kv[1], kv[0])) if c >= mini][:n]

    return {
        "keywords": top(kw, 10),
        "creators": top(creators, 5),
        "years": sorted(top(years, 5), reverse=True),
    }


@app.route("/api/search")
def api_search():
    query = request.args.get("q", "")
    search_type = request.args.get("type", "")
    source = request.args.get("source", "archive.org")
    sort = request.args.get("sort", "")
    collection = request.args.get("collection", "")
    page = max(1, int(request.args.get("page", 1)))

    if not query:
        return jsonify({"error": "Requête vide"})

    # loc.gov ne s'interroge pas depuis un serveur : tout leur site répond 403
    # derrière un défi Cloudflare, y compris leur documentation d'API. La page
    # renvoie l'usager chez eux ; si quelqu'un appelle quand même cette route
    # (URL partagée, historique), autant dire pourquoi plutôt que « source
    # inconnue ».
    if source == "loc.gov":
        return jsonify({
            "error": "loc.gov ne peut pas être interrogé depuis le serveur "
                     "(défi Cloudflare) — la recherche s'ouvre sur leur site.",
            "handoff": f"https://www.loc.gov/audio/?q={quote(query)}",
        }), 501

    search_fn = SOURCES.get(source)
    if not search_fn:
        return jsonify({"error": f"Source inconnue : {source}"}), 400

    cache_key = (source, query, search_type, sort, collection, page)
    cached = cache_get(cache_key)
    if cached is not None:
        # L'historique s'enregistre MÊME sur un cache touché : relancer une
        # recherche est un geste de l'usager, il doit être daté. La nouveauté,
        # elle, se calcule contre ce qu'on savait avant ce passage.
        fresh = record_search(source, query, search_type, sort, collection, page, cached["results"])
        return jsonify({**cached, "new_ids": fresh})

    try:
        results, total = search_fn(query, search_type, page, sort, collection)
        has_more = (total is not None and page * ROWS_PER_PAGE < total) or (total is None and len(results) >= ROWS_PER_PAGE)
        payload = {"results": results, "total": total, "has_more": has_more,
                   "related": related_terms(results, query)}
        cache_set(cache_key, payload)
        fresh = record_search(source, query, search_type, sort, collection, page, results)
        return jsonify({**payload, "new_ids": fresh})
    except requests.exceptions.Timeout:
        # « HTTPSConnectionPool… Read timed out » n'apprend rien à l'usager.
        secs = SOURCE_TIMEOUT.get(source, REQUEST_TIMEOUT)
        return jsonify({"error": f"{source} n'a pas répondu en {secs} s — "
                                 f"leur service est lent ou indisponible, réessaie plus tard."}), 504
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/file/<path:identifier>")
def api_file(identifier):
    cache_key = ("file", identifier)
    cached = cache_get(cache_key)
    if cached is not None:
        return jsonify(cached)
    try:
        url, mediatype = resolve_archive_file(identifier)
        payload = {"url": url, "mediatype": mediatype}
        cache_set(cache_key, payload)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"url": None, "mediatype": None, "error": str(e)})


@app.route("/api/torrent/<path:identifier>")
def api_torrent(identifier):
    cache_key = ("torrent", identifier)
    cached = cache_get(cache_key)
    if cached is not None:
        return jsonify(cached)
    try:
        url = resolve_archive_torrent(identifier)
        payload = {"url": url}
        cache_set(cache_key, payload)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"url": None, "error": str(e)})


@app.route("/api/random")
def api_random():
    try:
        item = random_archive_item()
        if not item:
            return jsonify({"error": "Aucun résultat au hasard, réessaie"}), 500
        return jsonify({"result": item})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    os.makedirs("/home/olivier/DEV/archive-search", exist_ok=True)
    port = int(os.getenv("ARCHIVE_PORT", 5556))
    print(f"🎬 Archive Search @ http://127.0.0.1:{port}")
    # Fil de veille : démon, donc il ne retient pas l'arrêt du service. Lancé
    # ici et pas au niveau module — sous un rechargeur, le module est importé
    # deux fois et on obtiendrait deux veilles en parallèle.
    threading.Thread(target=_watch_loop, daemon=True).start()
    print(f"   veille : {len(watched_entries())} recherche(s), toutes les {WATCH_INTERVAL_S // 3600} h")
    app.run(host="0.0.0.0", port=port, debug=False)
