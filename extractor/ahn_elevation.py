"""
Junction elevations from AHN (Actueel Hoogtebestand Nederland), via the PDOK WCS.

* Source: AHN DTM 0.5 m ("maaiveld": bare ground, buildings and trees removed), in m NAP.
  Licence CC0 – no attribution required, though crediting "AHN / PDOK" is good practice.
* Method: request a 5 × 5 m window (10 × 10 pixels) around each junction and take the
  median of valid pixels. If the window is all no-data (building, water, bridge – AHN
  removes bridges from the DTM), retry with a 25 × 25 m window.
* Outside AHN coverage (junctions just across the border) fall back to the Copernicus
  90 m model via Open-Meteo, flagged as such.
* Results are cached in a JSON file keyed by junction id and position, so re-runs only
  fetch new or moved junctions.
"""
from __future__ import annotations

import json
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np
from pyproj import Transformer
from rasterio.io import MemoryFile

WCS = "https://service.pdok.nl/rws/ahn/wcs/v1_0"
OPEN_METEO = "https://api.open-meteo.com/v1/elevation"
UA = {"User-Agent": "LoopRouter-extractor/0.1"}
SMALL_HALF, WIDE_HALF = 2.5, 12.5  # metres
WORKERS = 6

_to_rd = Transformer.from_crs(4326, 28992, always_xy=True)


def _get(url: str, retries: int = 4) -> bytes:
    delay = 2.0
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                return r.read()
        except Exception:
            if attempt == retries:
                raise
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("unreachable")


def _ahn_window(x: float, y: float, half: float) -> tuple[float | None, int]:
    q = urllib.parse.urlencode([
        ("service", "WCS"), ("version", "2.0.1"), ("request", "GetCoverage"),
        ("coverageId", "dtm_05m"), ("format", "image/tiff"),
        ("subset", f"x({x - half},{x + half})"), ("subset", f"y({y - half},{y + half})"),
    ])
    data = _get(f"{WCS}?{q}")
    with MemoryFile(data) as mem, mem.open() as ds:
        a = ds.read(1, masked=True)
    v = a.compressed()
    v = v[np.isfinite(v) & (np.abs(v) < 1000)]
    return (float(np.median(v)), int(v.size)) if v.size else (None, 0)


def ahn_point(lon: float, lat: float) -> tuple[float | None, str | None]:
    x, y = _to_rd.transform(lon, lat)
    z, _ = _ahn_window(x, y, SMALL_HALF)
    if z is not None:
        return z, "ahn_dtm_05m"
    z, _ = _ahn_window(x, y, WIDE_HALF)
    if z is not None:
        return z, "ahn_dtm_05m_25m_window"
    return None, None


def copernicus_points(points: list[tuple[float, float]]) -> list[float | None]:
    out: list[float | None] = []
    for i in range(0, len(points), 100):
        batch = points[i:i + 100]
        q = urllib.parse.urlencode({
            "latitude": ",".join(f"{lat:.5f}" for _, lat in batch),
            "longitude": ",".join(f"{lon:.5f}" for lon, _ in batch),
        })
        try:
            out += json.loads(_get(f"{OPEN_METEO}?{q}"))["elevation"]
        except Exception:
            out += [None] * len(batch)
        time.sleep(1)
    return out


def junction_elevations(points: dict[int, tuple[float, float]], cache_path: Path,
                        log=print) -> dict[int, tuple[float | None, str | None]]:
    """points: junction_id -> (lon, lat). Returns junction_id -> (elevation m NAP, source)."""
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    def key(jid, lon, lat):
        return f"{jid}:{lon:.6f}:{lat:.6f}"

    todo = {jid: p for jid, p in points.items() if key(jid, *p) not in cache}
    log(f"AHN: {len(points) - len(todo):,} cached, fetching {len(todo):,} junctions with {WORKERS} workers")
    t0, done = time.time(), 0
    with ThreadPoolExecutor(WORKERS) as pool:
        futures = {pool.submit(ahn_point, *p): jid for jid, p in todo.items()}
        for f in as_completed(futures):
            jid = futures[f]
            try:
                z, src = f.result()
            except Exception:
                z, src = None, None  # leave uncached so the next run retries
                continue
            cache[key(jid, *todo[jid])] = [z, src]
            done += 1
            if done % 500 == 0:
                cache_path.write_text(json.dumps(cache))
                log(f"  {done:,}/{len(todo):,} ({time.time() - t0:.0f}s)")
    cache_path.write_text(json.dumps(cache))

    # Copernicus fallback for junctions AHN doesn't cover (cached as source "none" first).
    missing = [jid for jid, p in points.items()
               if cache.get(key(jid, *p), [None, None])[0] is None and key(jid, *p) in cache]
    if missing:
        log(f"AHN: {len(missing)} junctions without AHN data, falling back to Copernicus 90 m")
        zs = copernicus_points([points[j] for j in missing])
        for jid, z in zip(missing, zs):
            if z is not None:
                cache[key(jid, *points[jid])] = [float(z), "copernicus_90m"]
        cache_path.write_text(json.dumps(cache))

    return {jid: tuple(cache.get(key(jid, *p), [None, None])) for jid, p in points.items()}
