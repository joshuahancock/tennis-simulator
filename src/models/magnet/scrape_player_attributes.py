#!/usr/bin/env python3
"""
Scrape player biographical attributes (height, weight, DOB, handedness)
from tennisexplorer.com for ATP and WTA premium-tier players.

Usage:
    python scrape_player_attributes.py --tour atp
    python scrape_player_attributes.py --tour wta
    python scrape_player_attributes.py --tour both

Outputs (in data/raw/player_attributes/):
    te_scraped_atp.csv   -- successful scrapes for ATP
    te_scraped_wta.csv   -- successful scrapes for WTA
    te_failures_atp.csv  -- ATP players not matched (need manual slug)
    te_failures_wta.csv  -- WTA players not matched (need manual slug)

The script is resumable: already-scraped player_ids are skipped on re-run.
"""

import argparse
import logging
import re
import time
import unicodedata
from pathlib import Path
from typing import Dict, List, Optional, Set

import pandas as pd
import requests
from bs4 import BeautifulSoup

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
BASE_URL = "https://www.tennisexplorer.com/player/{slug}/"
RATE_LIMIT = 1.5          # seconds between requests (be polite)
RATE_JITTER = 0.3         # random jitter added to rate limit
MAX_RETRIES = 3           # retries on network error
RETRY_WAIT = 5            # seconds to wait before retry

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/120.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}

PROJECT_ROOT = Path(__file__).resolve().parents[3]
DATA_DIR     = PROJECT_ROOT / "data" / "raw"
OUT_DIR      = PROJECT_ROOT / "data" / "raw" / "player_attributes"
ATP_DIR      = DATA_DIR / "tennis_atp"
WTA_DIR      = DATA_DIR / "tennis_wta"
YEARS        = range(2014, 2025)

ATP_PREMIUM_LEVELS = {"G", "F", "M", "A"}
WTA_PREMIUM_LEVELS = {"G", "F", "PM", "P"}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Player list builders
# ---------------------------------------------------------------------------

def load_premium_players(tour: str) -> pd.DataFrame:
    """Return DataFrame with columns [player_id, player_name] for
    all unique players in premium-tier matches 2014-2024."""
    if tour == "atp":
        match_dir, premium_levels = ATP_DIR, ATP_PREMIUM_LEVELS
        id_cols   = ("winner_id",   "loser_id")
        name_cols = ("winner_name", "loser_name")
        level_col = "tourney_level"
    else:
        match_dir, premium_levels = WTA_DIR, WTA_PREMIUM_LEVELS
        id_cols   = ("winner_id",   "loser_id")
        name_cols = ("winner_name", "loser_name")
        level_col = "tourney_level"

    frames = []
    for year in YEARS:
        path = match_dir / f"{'atp' if tour == 'atp' else 'wta'}_matches_{year}.csv"
        if not path.exists():
            continue
        df = pd.read_csv(path, low_memory=False)
        df = df[df[level_col].isin(premium_levels)]
        w = df[[id_cols[0], name_cols[0]]].rename(
            columns={id_cols[0]: "player_id", name_cols[0]: "player_name"}
        )
        l = df[[id_cols[1], name_cols[1]]].rename(
            columns={id_cols[1]: "player_id", name_cols[1]: "player_name"}
        )
        frames.append(pd.concat([w, l], ignore_index=True))

    all_players = pd.concat(frames, ignore_index=True).drop_duplicates("player_id")
    log.info("Loaded %d unique %s premium-tier players", len(all_players), tour.upper())
    return all_players.reset_index(drop=True)


# ---------------------------------------------------------------------------
# Slug generation
# ---------------------------------------------------------------------------

def normalize(text: str) -> str:
    """Lowercase, strip accents, remove non-alphanumeric except hyphens."""
    text = unicodedata.normalize("NFD", text)
    text = "".join(c for c in text if unicodedata.category(c) != "Mn")
    text = text.lower()
    text = re.sub(r"[^a-z0-9\s\-]", "", text)
    text = text.strip()
    return text


def candidate_slugs(full_name: str) -> List[str]:
    """
    Generate ordered list of candidate tennisexplorer URL slugs from a
    full player name (Sackmann format: 'First [Middle] Last').

    Strategy (in priority order):
      1. last word only            e.g. 'federer'
      2. last two words hyphenated e.g. 'del-potro'
      3. all-but-first hyphenated  e.g. 'auger-aliassime', 'garcia-lopez'
      4. full name hyphenated      e.g. 'juan-martin-del-potro' (rare)
    Duplicates are removed while preserving order.
    """
    name = normalize(full_name)
    # replace internal hyphens that are part of compound names with space
    # so we split cleanly, then re-join with hyphens
    name = name.replace("-", " ")
    parts = name.split()

    if not parts:
        return []

    seen = set()
    slugs = []

    def add(s):
        if s and s not in seen:
            seen.add(s)
            slugs.append(s)

    # 1. last word
    add(parts[-1])
    # 2. last two words
    if len(parts) >= 2:
        add("-".join(parts[-2:]))
    # 3. everything after the first word
    if len(parts) >= 2:
        add("-".join(parts[1:]))
    # 4. full hyphenated name
    if len(parts) >= 3:
        add("-".join(parts))

    return slugs


# ---------------------------------------------------------------------------
# Page fetching and parsing
# ---------------------------------------------------------------------------

def fetch(url: str, session: requests.Session) -> Optional[requests.Response]:
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            resp = session.get(url, headers=HEADERS, timeout=15)
            return resp
        except requests.RequestException as exc:
            log.warning("Network error (attempt %d/%d): %s", attempt, MAX_RETRIES, exc)
            if attempt < MAX_RETRIES:
                time.sleep(RETRY_WAIT)
    return None


def parse_profile(html: str) -> Optional[Dict]:
    """
    Parse a tennisexplorer player profile page.
    Returns dict with keys: te_name, height_cm, weight_kg, dob, is_righthanded
    or None if the page is not a valid player profile.
    """
    soup = BeautifulSoup(html, "html.parser")

    # Check for 'Player does not exist' message
    if "does not exist" in html.lower():
        return None

    table = soup.find("table", class_="plDetail")
    if not table:
        return None

    # Player name is in <h3> inside the second <td>
    h3 = table.find("h3")
    te_name = h3.get_text(strip=True) if h3 else None

    result = {"te_name": te_name, "height_cm": None, "weight_kg": None,
              "dob": None, "is_righthanded": None}

    for div in table.find_all("div", class_="date"):
        text = div.get_text(strip=True)

        # Height / Weight: "187 cm / 85 kg"
        m = re.search(r"Height\s*/\s*Weight:\s*(\d+)\s*cm\s*/\s*(\d+)\s*kg", text, re.I)
        if m:
            result["height_cm"] = int(m.group(1))
            result["weight_kg"] = int(m.group(2))
            continue

        # Height only (no weight listed)
        m = re.search(r"Height\s*/\s*Weight:\s*(\d+)\s*cm", text, re.I)
        if m:
            result["height_cm"] = int(m.group(1))
            continue

        # Age / DOB: "38 (8. 8. 1981)" or "22 (16.8.2001)"
        m = re.search(r"Age:\s*\d+\s*\((.+?)\)", text, re.I)
        if m:
            result["dob"] = m.group(1).strip()
            continue

        # Plays: "right" / "left"
        m = re.search(r"Plays:\s*(right|left)", text, re.I)
        if m:
            result["is_righthanded"] = 1 if m.group(1).lower() == "right" else 0
            continue

    return result


# ---------------------------------------------------------------------------
# Name verification
# ---------------------------------------------------------------------------

def name_matches(te_name: Optional[str], target_name: str, threshold: float = 0.6) -> bool:
    """
    Check whether the scraped tennisexplorer name is a plausible match
    for the target Sackmann player name.

    tennisexplorer stores names as "Last First" (e.g. "Federer Roger").
    Sackmann stores names as "First Last" (e.g. "Roger Federer").
    We compare normalized token sets to handle both orderings.
    """
    if not te_name:
        return False

    def tokens(name):
        # split on whitespace AND hyphens so 'Juan-Martin' → {'juan', 'martin'}
        return set(re.split(r"[\s\-]+", normalize(name)))

    te_tokens  = tokens(te_name)
    tgt_tokens = tokens(target_name)

    # Check token overlap ratio
    if not te_tokens or not tgt_tokens:
        return False

    overlap = len(te_tokens & tgt_tokens)
    ratio   = overlap / max(len(te_tokens), len(tgt_tokens))
    return ratio >= threshold


# ---------------------------------------------------------------------------
# Main scraping loop
# ---------------------------------------------------------------------------

def scrape_tour(tour: str, session: requests.Session) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    scraped_file  = OUT_DIR / f"te_scraped_{tour}.csv"
    failures_file = OUT_DIR / f"te_failures_{tour}.csv"

    # Load already-scraped player_ids for resumability
    already_done: Set[int] = set()
    if scraped_file.exists():
        done_df = pd.read_csv(scraped_file)
        already_done = set(done_df["player_id"].tolist())
        log.info("Resuming: %d players already scraped for %s", len(already_done), tour.upper())

    already_failed: Set[int] = set()
    if failures_file.exists():
        fail_df = pd.read_csv(failures_file)
        already_failed = set(fail_df["player_id"].tolist())
        log.info("Resuming: %d players already logged as failures for %s",
                 len(already_failed), tour.upper())

    players = load_premium_players(tour)
    to_scrape = players[
        ~players["player_id"].isin(already_done) &
        ~players["player_id"].isin(already_failed)
    ]
    log.info("%d players remaining to scrape for %s", len(to_scrape), tour.upper())

    scraped_rows  = []
    failure_rows  = []
    checkpoint_n  = 50   # write to disk every N players

    for i, (_, row) in enumerate(to_scrape.iterrows(), 1):
        player_id   = int(row["player_id"])
        player_name = str(row["player_name"])
        slugs       = candidate_slugs(player_name)

        log.info("[%d/%d] %s  →  trying slugs: %s",
                 i, len(to_scrape), player_name, slugs)

        matched = False
        for slug in slugs:
            url  = BASE_URL.format(slug=slug)
            resp = fetch(url, session)

            time.sleep(RATE_LIMIT)  # rate limit after every request

            if resp is None or resp.status_code != 200:
                continue

            profile = parse_profile(resp.text)
            if profile is None:
                continue

            if name_matches(profile["te_name"], player_name):
                log.info("  ✓ matched '%s' via slug '%s'", profile["te_name"], slug)
                scraped_rows.append({
                    "player_id":      player_id,
                    "player_name":    player_name,
                    "te_name":        profile["te_name"],
                    "te_slug":        slug,
                    "height_cm":      profile["height_cm"],
                    "weight_kg":      profile["weight_kg"],
                    "dob":            profile["dob"],
                    "is_righthanded": profile["is_righthanded"],
                })
                matched = True
                break

        if not matched:
            log.warning("  ✗ no match found for '%s' (tried: %s)", player_name, slugs)
            failure_rows.append({
                "player_id":      player_id,
                "player_name":    player_name,
                "slugs_tried":    "|".join(slugs),
                "manual_slug":    "",   # fill in manually if needed
            })

        # Checkpoint: flush to disk periodically
        if i % checkpoint_n == 0:
            _flush(scraped_rows, scraped_file)
            _flush(failure_rows, failures_file)
            scraped_rows  = []
            failure_rows  = []
            log.info("Checkpoint saved at player %d", i)

    # Final flush
    _flush(scraped_rows, scraped_file)
    _flush(failure_rows, failures_file)

    total_scraped  = len(already_done)  + (len(pd.read_csv(scraped_file))  if scraped_file.exists()  else 0)
    total_failures = len(already_failed) + (len(pd.read_csv(failures_file)) if failures_file.exists() else 0)
    log.info("Done with %s: %d scraped, %d failures",
             tour.upper(), total_scraped, total_failures)


def _flush(rows: list[dict], path: Path) -> None:
    """Append rows to CSV, creating file with header if it doesn't exist."""
    if not rows:
        return
    df = pd.DataFrame(rows)
    if path.exists():
        df.to_csv(path, mode="a", header=False, index=False)
    else:
        df.to_csv(path, index=False)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tour",
        choices=["atp", "wta", "both"],
        default="both",
        help="Which tour to scrape (default: both)",
    )
    args = parser.parse_args()

    session = requests.Session()

    tours = ["atp", "wta"] if args.tour == "both" else [args.tour]
    for tour in tours:
        scrape_tour(tour, session)


if __name__ == "__main__":
    main()
