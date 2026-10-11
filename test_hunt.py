"""Vérification de la fouille : hygiène des termes et pesée du classement.

    uv run test_hunt.py

Le cas qui compte est `test_proximite_bat_la_centralite` : c'est le bug trouvé
en mesurant, et la pesée est le genre de constante qu'on retouche sans voir
qu'on casse l'ordre.
"""
import os
import tempfile

TMP = tempfile.mkdtemp(prefix="archive-search-hunt-")
os.environ["DATA_DIR"] = TMP
os.environ["DOWNLOADS_FILE"] = os.path.join(TMP, "downloads.json")

import app  # noqa: E402


def entry(rel_terms, lic_free=True, source="freesound", preview="p"):
    return {"item": {"title": "t", "source": source, "identifier": "i",
                     "license": {"code": "c", "free": lic_free}, "preview": preview},
            "terms": rel_terms}


def test_termes_nettoyes():
    assert app._clean_terms([" FogHorn ", "fog  bank", "foghorn"]) == ["foghorn", "fog bank"]
    assert app._clean_terms(["a"]) == [], "un terme d'une lettre ne cherche rien"
    assert app._clean_terms(["x" * 60]) == [], "borne haute"
    # Un mot collé passe : le refuser écarterait aussi « foghorn » ou « super8 ».
    assert app._clean_terms(["weatherphenomena"]) == ["weatherphenomena"]
    assert len(app._clean_terms([f"t{i}" for i in range(40)])) == app.HUNT_TERMS_MAX


def test_cosinus():
    assert abs(app._cos([1, 0], [1, 0]) - 1) < 1e-9
    assert abs(app._cos([1, 0], [0, 1])) < 1e-9
    assert app._cos([0, 0], [1, 1]) == 0.0, "vecteur nul : pas de division par zéro"


def test_proximite_bat_la_centralite():
    # Le bug mesuré le 2026-10-11 : « coast river » (proximité 0.514, deux
    # termes) passait devant un foghorn (0.708, un terme). La proximité doit
    # l'emporter dès qu'elle est franchement meilleure.
    proche = app._hunt_score(entry(["foghorn"]), rel=0.708)
    large = app._hunt_score(entry(["seawall", "coast"]), rel=0.514)
    assert proche > large, f"{proche} <= {large} : la centralité pèse encore trop"
    # À proximité égale, la centralité départage — c'est son rôle restant.
    a = app._hunt_score(entry(["x", "y"]), rel=0.6)
    b = app._hunt_score(entry(["x"]), rel=0.6)
    assert a > b


def test_deja_pris_retrograde():
    import pathlib
    f = pathlib.Path(TMP) / "pris.mp3"
    f.write_bytes(b"x")
    it = entry(["foghorn"])
    libre = app._hunt_score(it, rel=0.6)
    app.dl_log_note(it["item"], f, 1)
    assert app._hunt_score(it, rel=0.6) < libre - 3, "on fouille pour du neuf"


def test_licence_restrictive_derriere():
    assert app._hunt_score(entry(["a"], lic_free=True), rel=0.5) > \
           app._hunt_score(entry(["a"], lic_free=False), rel=0.5)


def test_texte_du_document_borne_la_description():
    long = {"title": "T", "description": "d" * 500}
    assert len(app._doc_text(long)) < 230


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"✓ {name}")
    print("\ntout passe")
