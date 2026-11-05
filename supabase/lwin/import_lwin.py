#!/usr/bin/env python3
"""Prepare the LWIN database for import into Decant's catalog.

LWIN (Liv-ex Wine Identification Number) is published by Liv-ex under
CC BY 4.0: https://www.liv-ex.com/lwin/ . Download the database from
https://www.liv-ex.com/lwin-database-download/ (xlsx or csv), then:

    python3 supabase/lwin/import_lwin.py ~/Downloads/LWINdatabase.xlsx

This writes, next to this script:
    out/lwin_clean.csv   one row per live LWIN wine, mapped to Decant's fields
    out/import.sql       loads the CSV into public.lwin_import and merges it

Then run the SQL against your project (needs the database connection string
from Supabase > Project Settings > Database):

    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/lwin/out/import.sql

Spirits, beers and mixed cases are skipped; only wines are imported.
The script is idempotent: re-running it links or skips wines already present.
"""
from __future__ import annotations

import csv
import re
import sys
import unicodedata
from pathlib import Path

OUT_COLUMNS = ["lwin", "producer", "wine_name", "type", "country", "region", "appellation", "vintage_config"]


def name_key(text: str) -> str:
    """Mirrors public.name_key(): case- and accent-insensitive."""
    folded = unicodedata.normalize("NFKD", text or "")
    return "".join(c for c in folded if not unicodedata.combining(c)).lower()


def disambiguate(rows: list[dict]) -> None:
    """The catalog allows one wine name per producer. LWIN can list several
    (e.g. a producer's "Riesling" from two sites), so qualify the clashes with
    appellation, then region, then colour, then the LWIN as a last resort."""
    def clashes() -> dict:
        groups: dict[tuple, list[dict]] = {}
        for r in rows:
            groups.setdefault((name_key(r["producer"]), name_key(r["wine_name"])), []).append(r)
        return {k: g for k, g in groups.items() if len(g) > 1}

    for field in ("appellation", "region", "type", "lwin"):
        groups = clashes()
        if not groups:
            return
        for group in groups.values():
            for r in group:
                extra = r[field] if field != "type" else r["type"].capitalize()
                if extra and name_key(extra) not in name_key(r["wine_name"]):
                    r["wine_name"] = f"{r['wine_name']}, {extra}"[:200]


def norm_header(h: str) -> str:
    return re.sub(r"[^A-Z0-9]+", "_", (h or "").strip().upper()).strip("_")


def read_rows(path: Path):
    if path.suffix.lower() in (".xlsx", ".xlsm"):
        try:
            import openpyxl
        except ImportError:
            sys.exit("Reading .xlsx needs openpyxl (pip install openpyxl), or export the sheet to CSV.")
        sheet = openpyxl.load_workbook(path, read_only=True, data_only=True).active
        rows = sheet.iter_rows(values_only=True)
        header = [norm_header(str(h or "")) for h in next(rows)]
        for values in rows:
            yield {header[i]: ("" if v is None else str(v)).strip() for i, v in enumerate(values) if i < len(header)}
    else:
        with path.open(newline="", encoding="utf-8-sig") as f:
            reader = csv.DictReader(f)
            for row in reader:
                yield {norm_header(k): (v or "").strip() for k, v in row.items() if k}


def clean(text) -> str:
    """Collapses whitespace; LWIN writes empty fields as the literal "NA"."""
    value = re.sub(r"\s+", " ", str(text or "")).strip()
    return "" if value.upper() in ("NA", "N/A", "NONE") else value


def wine_type(row: dict) -> str | None:
    kind = clean(row.get("TYPE")).upper()
    sub = clean(row.get("SUB_TYPE")).upper()
    colour = clean(row.get("COLOUR") or row.get("COLOR")).upper()
    if kind == "FORTIFIED WINE":
        return "fortified"  # Port, Sherry, Madeira, VDN … (colour is usually NA)
    if kind not in ("WINE", "STILL"):
        return None  # Spirit, Other (sake, vermouth, mixed cases), Cider, Beer
    if sub == "SPARKLING":
        return "sparkling"
    if colour == "RED":
        return "red"
    if colour == "WHITE":
        return "white"
    if colour == "ROSE":
        return "rose"
    return None  # Mixed or unknown colour


def wine_name(row: dict, producer: str) -> str:
    """LWIN leaves WINE empty when the producer *is* the wine (Bordeaux châteaux,
    Dom Perignon) and for Burgundy-style site wines, whose identity is in
    DISPLAY_NAME after the producer ("Nuits-Saint-Georges Premier Cru, Les Saints-Georges")."""
    name = clean(row.get("WINE"))
    if name:
        return name
    display = clean(row.get("DISPLAY_NAME"))
    rest = display[len(producer):].lstrip(" ,") if display.lower().startswith(producer.lower()) else ""
    if not rest or clean(row.get("REGION")).upper() == "BORDEAUX" and not clean(row.get("SITE")):
        return producer
    return rest


def map_row(row: dict) -> dict | None:
    if clean(row.get("STATUS")).upper() != "LIVE":
        return None  # Combined / Deleted
    try:
        lwin = str(int(float(str(row.get("LWIN", "")).strip()))).zfill(7)
    except ValueError:
        return None
    if len(lwin) != 7:
        return None
    kind = wine_type(row)
    if kind is None:
        return None

    producer = clean(" ".join(filter(None, [clean(row.get("PRODUCER_TITLE")), clean(row.get("PRODUCER_NAME"))])))
    if not producer or producer.upper().startswith("MIXED CASE"):
        return None
    name = wine_name(row, producer)
    if len(producer) > 200 or len(name) > 200:
        return None

    # sequential / nonSequential = vintage wines; singleVintageOnly = NV (Brut NV, tawny, …).
    config = clean(row.get("VINTAGE_CONFIG")).lower()
    return {
        "lwin": lwin,
        "producer": producer,
        "wine_name": name,
        "type": kind,
        "country": clean(row.get("COUNTRY")) or None,
        "region": clean(row.get("REGION")) or None,
        "appellation": clean(row.get("SUB_REGION")) or None,
        "vintage_config": "non_vintage" if config == "singlevintageonly" else "vintage",
    }


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = Path(sys.argv[1]).expanduser()
    out_dir = Path(__file__).resolve().parent / "out"
    out_dir.mkdir(exist_ok=True)

    seen: set[str] = set()
    kept: list[dict] = []
    skipped = 0
    first = None
    for row in read_rows(source):
        if first is None:
            first = row
            missing = {"LWIN", "STATUS", "PRODUCER_NAME", "COUNTRY", "COLOUR", "TYPE"} - row.keys()
            if missing:
                sys.exit(f"Unexpected LWIN format; missing columns {sorted(missing)}. Found: {sorted(row.keys())}")
        mapped = map_row(row)
        if mapped is None or mapped["lwin"] in seen:
            skipped += 1
            continue
        seen.add(mapped["lwin"])
        kept.append(mapped)
    disambiguate(kept)

    csv_path = out_dir / "lwin_clean.csv"
    with csv_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=OUT_COLUMNS)
        writer.writeheader()
        writer.writerows(kept)

    sql_path = out_dir / "import.sql"
    sql_path.write_text(
        "-- Generated by supabase/lwin/import_lwin.py. LWIN © Liv-ex, CC BY 4.0.\n"
        "begin;\n"
        "truncate public.lwin_import;\n"
        f"\\copy public.lwin_import ({', '.join(OUT_COLUMNS)}) from '{csv_path}' with (format csv, header true)\n"
        "select * from public.merge_lwin_import();\n"
        "commit;\n"
        "analyze public.wineries; analyze public.wine_products; analyze public.wine_vintages;\n",
        encoding="utf-8",
    )
    print(f"{len(kept):,} wines ready, {skipped:,} rows skipped (spirits, mixed cases, retired or duplicate LWINs).")
    print(f"Wrote {csv_path}\nWrote {sql_path}")
    print('Next: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ' + str(sql_path))


if __name__ == "__main__":
    main()
