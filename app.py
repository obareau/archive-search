#!/usr/bin/env python3
"""Archive Search — films vintage, audio, PDFs, livres et médias du domaine
public, à travers plusieurs sources (archive.org, Gutenberg, Wikimedia
Commons, LibriVox)."""

import os
import re
import time
import requests
from flask import Flask, render_template_string, request, jsonify

app = Flask(__name__)

ROWS_PER_PAGE = 20
REQUEST_TIMEOUT = 10
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

def search_archive_org(query, search_type, page):
    q = f'"{query}"'
    if search_type == "film":
        q += " AND mediatype:movies AND year:[1920 TO 1980]"
    elif search_type == "prelinger":
        q += " AND collection:prelinger"
    elif search_type == "audio":
        q += " AND mediatype:audio"
    elif search_type == "pdf":
        q += " AND mediatype:texts AND format:PDF"

    params = {
        "q": q,
        "fl": "identifier,title,creator,year,mediatype,description",
        "output": "json",
        "rows": ROWS_PER_PAGE,
        "page": page,
    }
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
        })
    return results, total


def search_gutenberg(query, _search_type, page):
    params = {"search": query, "page": page}
    resp = requests.get("https://gutendex.com/books/", params=params, headers=HEADERS, timeout=REQUEST_TIMEOUT)
    data = resp.json()
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


def search_wikimedia(query, _search_type, page):
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


def search_librivox(query, _search_type, page):
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


SOURCES = {
    "archive.org": search_archive_org,
    "gutenberg": search_gutenberg,
    "wikimedia": search_wikimedia,
    "librivox": search_librivox,
}

# ── Résolution du fichier direct (archive.org seulement — les autres
# sources renvoient déjà une URL de fichier/lecture directe). ──────────

PREFERRED_EXT = {
    "movies": [".mp4", ".ogv", ".webm"],
    "audio": [".mp3", ".ogg"],
    "texts": [".pdf"],
}


def resolve_archive_file(identifier):
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
        return None
    best = sorted(candidates, key=score)[0]
    name = best.get("name", "")
    if not name:
        return None
    return f"https://archive.org/download/{identifier}/{name}"


# ── UI ───────────────────────────────────────────────────────────────

HTML = """
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Archive Search</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0a0e27;
            color: #e0e0e0;
            padding: 20px;
        }
        .container { max-width: 1200px; margin: 0 auto; }
        h1 { color: #d4af37; margin-bottom: 30px; text-align: center; }

        .search-box {
            display: flex;
            gap: 10px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }

        input, select, button {
            padding: 12px 16px;
            border: 1px solid #333;
            border-radius: 6px;
            background: #1a1f3a;
            color: #e0e0e0;
            font-size: 14px;
        }

        input { flex: 1; min-width: 200px; }
        button {
            background: #d4af37;
            color: #0a0e27;
            font-weight: 600;
            cursor: pointer;
        }
        button:hover { background: #e6c44a; }
        button:disabled { opacity: 0.35; cursor: default; background: #555; color: #aaa; }

        select { min-width: 150px; }

        .results {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(300px, 1fr));
            gap: 20px;
        }

        .item {
            background: #0f1428;
            border: 1px solid #333;
            border-radius: 8px;
            padding: 16px;
            transition: all 0.2s;
            display: flex;
            flex-direction: column;
        }

        .item:hover {
            background: #151a38;
            border-color: #d4af37;
            box-shadow: 0 4px 12px rgba(212, 175, 55, 0.1);
        }

        .item-thumb {
            width: 100%;
            height: 160px;
            object-fit: cover;
            border-radius: 6px;
            margin-bottom: 10px;
            background: #060812;
        }

        .item-title {
            font-weight: 600;
            margin-bottom: 8px;
            color: #fff;
        }

        .item-meta {
            font-size: 12px;
            color: #888;
            margin-bottom: 8px;
        }
        .item-meta .src {
            color: #d4af37;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            font-size: 10px;
        }

        .item-desc {
            font-size: 13px;
            color: #aaa;
            margin-bottom: 12px;
            line-height: 1.4;
            flex: 1;
        }

        .item-links { display: flex; gap: 8px; }

        .item-link {
            display: inline-block;
            padding: 6px 12px;
            background: #1a2840;
            color: #4a9eff;
            text-decoration: none;
            border-radius: 4px;
            font-size: 12px;
            transition: all 0.2s;
        }

        .item-link:hover {
            background: #2a3860;
            color: #6ab3ff;
        }

        .loading { text-align: center; padding: 40px; color: #888; }
        .error { color: #ff6b6b; padding: 16px; background: #1a2525; border-radius: 6px; }

        .pagination {
            display: flex;
            justify-content: center;
            align-items: center;
            gap: 16px;
            margin-top: 24px;
        }
        .pagination span { color: #888; font-size: 13px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Archive Search</h1>

        <div class="search-box">
            <input type="text" id="query" placeholder="Chercher... (titre, auteur, etc)" value="">
            <select id="source">
                <option value="archive.org">Archive.org</option>
                <option value="gutenberg">Gutenberg (livres)</option>
                <option value="wikimedia">Wikimedia Commons</option>
                <option value="librivox">LibriVox (audio livres)</option>
            </select>
            <select id="type">
                <option value="">Tous</option>
                <option value="film">Films (1920-1980)</option>
                <option value="prelinger">Prelinger (films éphémères)</option>
                <option value="audio">Audio</option>
                <option value="pdf">PDFs</option>
            </select>
            <button onclick="search(1)">Chercher</button>
        </div>

        <div id="results"></div>
        <div class="pagination" id="pagination" style="display:none">
            <button id="btnPrev">◀ Précédent</button>
            <span id="pageInfo"></span>
            <button id="btnNext">Suivant ▶</button>
        </div>
    </div>

    <script>
        let state = { page: 1, hasMore: false };

        document.getElementById("source").addEventListener("change", () => {
            const isArchive = document.getElementById("source").value === "archive.org";
            document.getElementById("type").style.display = isArchive ? "" : "none";
        });

        async function resolveDirectUrl(item, linkEl) {
            if (item.source !== "archive.org" || !item.identifier) return;
            linkEl.textContent = "…";
            try {
                const res = await fetch(`/api/file/${encodeURIComponent(item.identifier)}`);
                const data = await res.json();
                if (data.url) {
                    linkEl.href = data.url;
                    linkEl.textContent = "Fichier direct";
                    linkEl.target = "_blank";
                    return;
                }
            } catch (e) { /* on garde le fallback fiche */ }
            linkEl.textContent = "Fichier direct (indisponible)";
        }

        function renderResults(items) {
            const el = document.getElementById("results");
            if (items.length === 0) {
                el.innerHTML = '<div class="error">Aucun résultat</div>';
                return;
            }
            el.innerHTML = `<div class="results">${items.map((item, i) => `
                <div class="item">
                    ${item.thumbnail ? `<img class="item-thumb" src="${item.thumbnail}" loading="lazy" onerror="this.style.display='none'">` : ""}
                    <div class="item-title">${item.title}</div>
                    <div class="item-meta"><span class="src">${item.source}</span> · ${item.year || item.type} · ${item.creator || "N/A"}</div>
                    <div class="item-desc">${item.description || ""}</div>
                    <div class="item-links">
                        <a href="${item.url}" target="_blank" class="item-link">Ouvrir</a>
                        ${item.source === "archive.org" ? `<a href="#" class="item-link" data-idx="${i}" onclick="event.preventDefault(); resolveDirectUrl(items[${i}], this)">Fichier direct</a>` : ""}
                    </div>
                </div>
            `).join("")}</div>`;
        }

        let items = [];

        async function search(page) {
            const query = document.getElementById("query").value;
            const source = document.getElementById("source").value;
            const type = document.getElementById("type").value;

            if (!query) {
                alert("Entrez un terme de recherche");
                return;
            }
            state.page = page;

            document.getElementById("results").innerHTML = '<div class="loading">⏳ Recherche...</div>';
            document.getElementById("pagination").style.display = "none";

            try {
                const res = await fetch(`/api/search?q=${encodeURIComponent(query)}&type=${type}&source=${source}&page=${page}`);
                const data = await res.json();

                if (data.error) {
                    document.getElementById("results").innerHTML = `<div class="error">❌ ${data.error}</div>`;
                    return;
                }

                items = data.results;
                renderResults(items);

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
    </script>
</body>
</html>
"""


@app.route("/")
def index():
    return render_template_string(HTML)


@app.route("/api/search")
def api_search():
    query = request.args.get("q", "")
    search_type = request.args.get("type", "")
    source = request.args.get("source", "archive.org")
    page = max(1, int(request.args.get("page", 1)))

    if not query:
        return jsonify({"error": "Requête vide"})

    search_fn = SOURCES.get(source)
    if not search_fn:
        return jsonify({"error": f"Source inconnue : {source}"}), 400

    cache_key = (source, query, search_type, page)
    cached = cache_get(cache_key)
    if cached is not None:
        return jsonify(cached)

    try:
        results, total = search_fn(query, search_type, page)
        has_more = (total is not None and page * ROWS_PER_PAGE < total) or (total is None and len(results) >= ROWS_PER_PAGE)
        payload = {"results": results, "total": total, "has_more": has_more}
        cache_set(cache_key, payload)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/file/<path:identifier>")
def api_file(identifier):
    cache_key = ("file", identifier)
    cached = cache_get(cache_key)
    if cached is not None:
        return jsonify(cached)
    try:
        url = resolve_archive_file(identifier)
        payload = {"url": url}
        cache_set(cache_key, payload)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"url": None, "error": str(e)})


if __name__ == "__main__":
    os.makedirs("/home/olivier/DEV/archive-search", exist_ok=True)
    port = int(os.getenv("ARCHIVE_PORT", 5556))
    print(f"🎬 Archive Search @ http://127.0.0.1:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
