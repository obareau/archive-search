"""Vérification du journal des téléchargements et de la fiche de crédits.

    python3 test_downloads.py

Pas de cadre de test : un fichier qui lève, c'est un échec. Ce qui est vérifié
ici est exactement ce qui est coûteux à découvrir en production — une fiche de
crédits écrasée, ou un badge « déjà pris » sur un fichier disparu.
"""
import os
import tempfile
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix="archive-search-test-"))
os.environ["DATA_DIR"] = str(TMP)
os.environ["DOWNLOADS_FILE"] = str(TMP / "downloads.json")
os.environ["HISTORY_FILE"] = str(TMP / "history.json")

import app  # noqa: E402  (les variables d'environnement doivent précéder l'import)

SON = {"title": "Pluie sur tôle.wav", "creator": "fieldrec", "source": "freesound",
       "identifier": "4242", "url": "https://freesound.org/s/4242/",
       "license": {"code": "CC BY", "free": True, "url": "https://creativecommons.org/licenses/by/4.0/"}}
FILM = {"title": "Coronet Instructional", "creator": "Coronet", "source": "archive.org",
        "identifier": "coronet01", "url": "https://archive.org/details/coronet01",
        "license": {"code": "", "free": None, "url": ""}}
ND = {"title": "Piste verrouillée", "creator": "qqn", "source": "freesound", "identifier": "9",
      "url": "u", "license": {"code": "CC BY-NC-ND", "free": False, "url": "x"}}


def test_cle_identique_au_panier():
    # La page badge avec `source:identifier` (favKey). Si le serveur clé
    # autrement, le badge ne s'allume jamais et rien ne le signale.
    assert app.item_key(SON) == "freesound:4242"
    assert app.item_key({"source": "s"}) == "s:"


def test_journal_oublie_un_fichier_disparu():
    f = TMP / "pluie.wav"
    f.write_bytes(b"RIFF")
    app.dl_log_note(SON, f, 4)
    e, live = app.dl_log_paths(SON)
    assert e and live == [f] and e["license"] == "CC BY"
    assert app.dl_log_paths(FILM) == (None, []), "un item jamais pris ne renvoie rien"
    f.unlink()
    assert app.dl_log_paths(SON) == (None, []), "fichier effacé à la main → à reprendre"


def test_journal_retient_chaque_emplacement():
    # Le bug trouvé en vrai : copier vers B faisait oublier la copie de A,
    # donc une troisième passe vers A y recopiait un doublon « (1) ».
    a, b = TMP / "projA" / "s.mp3", TMP / "projB" / "s.mp3"
    for f in (a, b):
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(b"x")
    app.dl_log_note(SON, a, 1)
    app.dl_log_note(SON, b, 1)
    _, live = app.dl_log_paths(SON)
    assert set(live) == {a, b}, live
    assert live[0] == b, "le plus récent d'abord"
    # Et l'élagage : un chemin mort ne survit pas à l'écriture suivante.
    a.unlink()
    app.dl_log_note(SON, b, 1)
    _, live = app.dl_log_paths(SON)
    assert live == [b], live


def test_journal_lit_la_forme_ancienne():
    # Les journaux écrits avant le passage au multi-chemins restent lisibles.
    assert app._entry_paths({"path": "/x/y.mp3"}) == ["/x/y.mp3"]
    assert app._entry_paths({"paths": ["/a", "/b"]}) == ["/a", "/b"]
    assert app._entry_paths({}) == []


def test_credits_signale_ce_qui_nest_pas_libre():
    assert "⚠" not in app._credit_line(SON, "a.wav")
    assert "licence inconnue" in app._credit_line(FILM, "b.mp4")
    assert "restrictive" in app._credit_line(ND, "c.wav")
    assert "non déclarée" in app._credit_line(FILM, "b.mp4")


def _credits(item, name):
    return [(name, app._credit_line(item, name))]


def test_credits_ajoute_sans_ecraser():
    d = TMP / "lot"
    d.mkdir()
    app.write_credits(d, _credits(SON, "a.wav"))
    app.write_credits(d, _credits(FILM, "b.mp4"))
    txt = (d / "CREDITS.txt").read_text(encoding="utf-8")
    assert txt.count("CRÉDITS") == 1, "l'en-tête ne doit figurer qu'une fois"
    assert "a.wav" in txt and "b.mp4" in txt, "le second lot a effacé le premier"
    assert txt.count("── lot du") == 2


def test_credits_ne_double_pas_un_fichier():
    # Reprendre le même lot dans le même dossier ne doit pas empiler trois
    # fois le même paragraphe.
    d = TMP / "lot2"
    d.mkdir()
    app.write_credits(d, _credits(SON, "a.wav"))
    app.write_credits(d, _credits(SON, "a.wav"))
    txt = (d / "CREDITS.txt").read_text(encoding="utf-8")
    assert txt.count("fichier : a.wav") == 1, txt
    assert txt.count("── lot du") == 1, "un lot sans rien à créditer n'écrit pas d'en-tête"


def test_credits_vide_necrit_rien():
    d = TMP / "vide"
    d.mkdir()
    app.write_credits(d, [])
    assert not (d / "CREDITS.txt").exists()


def test_destination_suffixe_les_homonymes():
    d = TMP / "dest"
    a = app._dest_path(d, SON, ".mp3")
    a.write_bytes(b"x")
    b = app._dest_path(d, SON, ".mp3")
    assert a.name == "Pluie sur tôle.mp3", a.name   # extension réelle, pas « .wav.mp3 »
    assert b.name == "Pluie sur tôle (1).mp3", b.name


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"✓ {name}")
    print(f"\ntout passe — {TMP}")
