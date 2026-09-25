#!/usr/bin/env python3
"""Zaciąg specyfikacji silników z car2db do lokalnej bazy Dynomic Diag.

Pobiera wersje (trims) z API car2db, wyciąga kod silnika i podstawowe dane
(paliwo, pojemność, moc, moment, doładowanie, roczniki, marka/model) i zapisuje
je do jednego pliku JSON, którego aplikacja używa OFFLINE. Dedupuje po kodzie
silnika — jedna pozycja na kod, z listą modeli, w których występuje.

Klucz API czytany jest ze zmiennej środowiskowej CAR2DB_API_KEY (nie zapisuj go
w kodzie ani w repo). Limit demo to 1000 zapytań/mies. — skrypt pilnuje budżetu
(--budget) i zapisuje postęp, więc można go wznawiać bez marnowania zapytań.

Użycie:
    export CAR2DB_API_KEY=...              # Twój klucz
    python3 tool/import_car2db.py --budget 200
    python3 tool/import_car2db.py --budget 200 --makes 10,18 --per-model 6

Wynik: assets/data/engine_specs.json  (+ cache w tool/.car2db_cache/)
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://v3.api.car2db.com"
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "data" / "engine_specs.json"
CACHE = Path(__file__).resolve().parent / ".car2db_cache"


class Budget:
    """Licznik zapytań sieciowych z twardym limitem."""

    def __init__(self, limit):
        self.limit = limit
        self.used = 0

    def spend(self):
        if self.used >= self.limit:
            raise StopIteration("Wyczerpano budżet zapytań")
        self.used += 1


def _get(path, key, budget, use_cache=True):
    """GET z cache na dysku (żeby wznawianie nie zużywało budżetu)."""
    CACHE.mkdir(exist_ok=True)
    safe = urllib.parse.quote(path, safe="")
    cache_file = CACHE / f"{safe}.json"
    if use_cache and cache_file.exists():
        return json.loads(cache_file.read_text())
    budget.spend()
    req = urllib.request.Request(
        BASE + path,
        headers={"Authorization": f"Bearer {key}", "Referer": "https://dynomic.pro"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode())
    cache_file.write_text(json.dumps(data))
    time.sleep(0.15)  # łagodnie dla API
    return data


def _spec(items, name):
    for it in items:
        if it.get("name") == name:
            return it.get("value")
    return None


def _num(v):
    if v is None:
        return None
    try:
        return float(str(v).replace(",", "."))
    except ValueError:
        return None


def parse_trim(full):
    """Wyciąga interesujące pola z /trims/{id}/full."""
    bc = full.get("breadcrumbs", {})
    ks = full.get("keySpecifications", {})
    engine_items = []
    for cat in full.get("specifications", []):
        if cat.get("category", {}).get("name") == "Engine":
            engine_items = cat.get("items", [])
            break
    code = _spec(engine_items, "Engine code")
    if not code:
        return None  # bez kodu silnika pozycja jest dla nas bezwartościowa
    fuel = _spec(engine_items, "Engine type")  # Gasoline / Diesel
    boost = _spec(engine_items, "Boost type")  # none / turbocharging...
    return {
        "code": code.strip().upper(),
        "make": bc.get("make", {}).get("name"),
        "model": bc.get("model", {}).get("name"),
        "fuel": fuel,
        "volumeCcm": _num(ks.get("engineVolume")) or _num(_spec(engine_items, "Capacity")),
        "powerHp": _num(ks.get("power")) or _num(_spec(engine_items, "Engine power")),
        "powerKw": _num(ks.get("powerKw")),
        "torqueNm": _num(_spec(engine_items, "Maximum torque")),
        "cylinders": _num(_spec(engine_items, "Number of cylinders")),
        "boost": None if boost in (None, "none") else boost,
        "yearBegin": full.get("yearBegin"),
        "yearEnd": full.get("yearEnd"),
    }


def merge(db, t):
    """Dodaje/uaktualnia pozycję po kodzie silnika (dedup + zakres lat + modele)."""
    code = t["code"]
    e = db.get(code)
    if e is None:
        db[code] = {
            "code": code,
            "make": t["make"],
            "fuel": t["fuel"],
            "volumeCcm": t["volumeCcm"],
            "powerHp": t["powerHp"],
            "powerKw": t["powerKw"],
            "torqueNm": t["torqueNm"],
            "cylinders": t["cylinders"],
            "boost": t["boost"],
            "yearBegin": t["yearBegin"],
            "yearEnd": t["yearEnd"],
            "models": [],
            "powerVariants": [],
        }
        e = db[code]
    # zakres lat
    if t["yearBegin"] and (not e["yearBegin"] or t["yearBegin"] < e["yearBegin"]):
        e["yearBegin"] = t["yearBegin"]
    if t["yearEnd"] and (not e["yearEnd"] or t["yearEnd"] > e["yearEnd"]):
        e["yearEnd"] = t["yearEnd"]
    label = f'{t["make"]} {t["model"]}'.strip()
    if label and label not in e["models"]:
        e["models"].append(label)
    if t["powerHp"] and t["powerHp"] not in e["powerVariants"]:
        e["powerVariants"].append(t["powerHp"])
    return e


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=int, default=200, help="maks. liczba zapytań do API")
    ap.add_argument("--makes", default="", help="ID marek po przecinku (domyślnie wszystkie z demo)")
    ap.add_argument("--models", default="", help="ID modeli po przecinku (pomija iterację po markach)")
    ap.add_argument("--per-model", type=int, default=8, help="ile wersji pobrać na model")
    args = ap.parse_args()

    key = os.environ.get("CAR2DB_API_KEY")
    if not key:
        sys.exit("Ustaw CAR2DB_API_KEY (klucz API car2db).")

    budget = Budget(args.budget)
    db = {}
    if OUT.exists():
        for e in json.loads(OUT.read_text()).get("engines", []):
            db[e["code"]] = e

    def _sample(ids, n):
        """Równomierne próbkowanie n pozycji z całej listy (stare→nowe), nie tylko początek."""
        if n <= 0 or len(ids) <= n:
            return ids
        step = len(ids) / n
        return [ids[int(i * step)] for i in range(n)]

    def pull_model(model_id):
        model = _get(f"/models/{model_id}", key, budget)
        for tid in _sample(model.get("trimIds", []), args.per_model):
            full = _get(f"/trims/{tid}/full", key, budget)
            t = parse_trim(full)
            if t:
                merge(db, t)

    try:
        if args.models:
            for mid in (int(x) for x in args.models.split(",")):
                pull_model(mid)
        else:
            make_list = _get("/makes", key, budget)["member"]
            if args.makes:
                wanted = {int(x) for x in args.makes.split(",")}
                make_list = [m for m in make_list if m["id"] in wanted]
            for m in make_list:
                for model_id in m.get("modelIds", []):
                    pull_model(model_id)
    except StopIteration:
        print(f"Budżet {args.budget} wyczerpany — zapisuję to, co mam.")
    except Exception as e:  # noqa: BLE001
        print(f"Przerwano ({e}) — zapisuję to, co mam.")

    engines = sorted(db.values(), key=lambda e: (e.get("make") or "", e["code"]))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({"source": "car2db.com (demo)", "engines": engines},
                              ensure_ascii=False, indent=2))
    print(f"Zapytań: {budget.used}/{args.budget}. Silników w bazie: {len(engines)}. Plik: {OUT}")


if __name__ == "__main__":
    main()
