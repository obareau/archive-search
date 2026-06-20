#!/usr/bin/env python3
"""Archive.org search — films vintage, audio, PDFs"""

import os
import requests
from flask import Flask, render_template_string, request, jsonify

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Archive.org Search</title>
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
            margin-bottom: 30px;
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
        }

        .item:hover {
            background: #151a38;
            border-color: #d4af37;
            box-shadow: 0 4px 12px rgba(212, 175, 55, 0.1);
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

        .item-desc {
            font-size: 13px;
            color: #aaa;
            margin-bottom: 12px;
            line-height: 1.4;
        }

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
    </style>
</head>
<body>
    <div class="container">
        <h1>🎬 Archive.org Search</h1>

        <div class="search-box">
            <input type="text" id="query" placeholder="Chercher... (titre, acteur, etc)" value="">
            <select id="type">
                <option value="">Tous</option>
                <option value="film">Films (1920-1980)</option>
                <option value="audio">Audio</option>
                <option value="pdf">PDFs</option>
            </select>
            <button onclick="search()">Chercher</button>
        </div>

        <div id="results"></div>
    </div>

    <script>
        async function search() {
            const query = document.getElementById('query').value;
            const type = document.getElementById('type').value;

            if (!query) {
                alert('Entrez un terme de recherche');
                return;
            }

            document.getElementById('results').innerHTML = '<div class="loading">⏳ Recherche...</div>';

            try {
                const res = await fetch(`/api/search?q=${encodeURIComponent(query)}&type=${type}`);
                const data = await res.json();

                if (data.error) {
                    document.getElementById('results').innerHTML = `<div class="error">❌ ${data.error}</div>`;
                    return;
                }

                if (data.results.length === 0) {
                    document.getElementById('results').innerHTML = '<div class="error">Aucun résultat</div>';
                    return;
                }

                const html = data.results.map(item => `
                    <div class="item">
                        <div class="item-title">${item.title}</div>
                        <div class="item-meta">${item.year || item.type} · ${item.creator || 'N/A'}</div>
                        <div class="item-desc">${item.description || ''}</div>
                        <a href="${item.url}" target="_blank" class="item-link">Ouvrir</a>
                    </div>
                `).join('');

                document.getElementById('results').innerHTML = html;
            } catch (err) {
                document.getElementById('results').innerHTML = `<div class="error">Erreur: ${err.message}</div>`;
            }
        }

        document.getElementById('query').addEventListener('keypress', (e) => {
            if (e.key === 'Enter') search();
        });
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML)

@app.route('/api/search')
def api_search():
    query = request.args.get('q', '')
    search_type = request.args.get('type', '')

    if not query:
        return jsonify({'error': 'Requête vide'})

    try:
        # Construire la requête Archive.org
        q = f'"{query}"'

        if search_type == 'film':
            q += ' AND mediatype:movies AND year:[1920 TO 1980]'
        elif search_type == 'audio':
            q += ' AND mediatype:audio'
        elif search_type == 'pdf':
            q += ' AND mediatype:texts AND format:PDF'

        # API Archive.org
        params = {
            'q': q,
            'fl': 'identifier,title,creator,year,mediatype,description',
            'output': 'json',
            'rows': 50
        }

        resp = requests.get('https://archive.org/advancedsearch.php', params=params, timeout=10)
        data = resp.json()

        results = []
        for doc in data.get('response', {}).get('docs', [])[:20]:
            creator = doc.get('creator')
            if isinstance(creator, list) and creator:
                creator = creator[0]
            else:
                creator = creator or 'N/A'

            description = doc.get('description')
            if isinstance(description, list) and description:
                description = description[0]
            else:
                description = description or ''

            item = {
                'title': doc.get('title', doc.get('identifier', 'N/A')),
                'creator': creator,
                'year': doc.get('year', ''),
                'type': doc.get('mediatype', ''),
                'description': str(description)[:150],
                'url': f"https://archive.org/details/{doc.get('identifier', '')}"
            }
            results.append(item)

        return jsonify({'results': results})

    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    os.makedirs('/home/olivier/DEV/archive-search', exist_ok=True)
    port = int(os.getenv('ARCHIVE_PORT', 5556))
    print(f"🎬 Archive Search @ http://127.0.0.1:{port}")
    app.run(host='127.0.0.1', port=port, debug=False)
