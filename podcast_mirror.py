#!/usr/bin/env python3
"""
podcast_mirror.py — Mirror a podcast (RSS feed + all referenced media) to a local folder.

Downloads:
  * The RSS/Atom feed XML itself (feed.xml), following <atom:link rel="next">
    pagination if the provider paginates the feed.
  * Every episode enclosure (audio/video file).
  * Channel and per-episode artwork (<itunes:image>, <image><url>).
  * Podcasting-2.0 extras when present: transcripts (<podcast:transcript>),
    chapters (<podcast:chapters>), soundbites' parent media.
  * A manifest.json mapping every saved file back to its source URL, episode
    GUID, title, and publish date — everything needed to re-upload to a new
    provider.

Design goals: stdlib only (runs on a stock macOS/Linux Python 3), resumable
(re-running skips files that are already complete), and gentle on the host
(serial downloads with a configurable delay, retries with backoff).

Usage:
  python3 podcast_mirror.py FEED_URL TARGET_DIR [options]

Examples:
  python3 podcast_mirror.py https://example.com/feed.xml ./podcast-backup
  python3 podcast_mirror.py https://example.com/feed.xml ./backup --limit 3 --dry-run

Options:
  --limit N       Only process the first N episodes (newest first; for testing).
  --dry-run       Parse the feed and report what would be downloaded, download nothing.
  --delay S       Seconds to sleep between downloads (default 0.5).
  --retries N     Retry attempts per file (default 4, exponential backoff).
  --timeout S     Per-request timeout in seconds (default 60).
  --force         Re-download files even if they already exist with the right size.
"""

import argparse
import email.utils
import json
import os
import re
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

USER_AGENT = "podcast-mirror/1.0 (feed backup; +https://github.com/rulingAnts/mac-audio-player-loader)"

NS = {
    "atom": "http://www.w3.org/2005/Atom",
    "itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd",
    "podcast": "https://podcastindex.org/namespace/1.0",
    "media": "http://search.yahoo.com/mrss/",
}

AUDIO_EXT_BY_MIME = {
    "audio/mpeg": ".mp3",
    "audio/mp3": ".mp3",
    "audio/mp4": ".m4a",
    "audio/x-m4a": ".m4a",
    "audio/aac": ".aac",
    "audio/ogg": ".ogg",
    "audio/opus": ".opus",
    "audio/wav": ".wav",
    "audio/x-wav": ".wav",
    "audio/flac": ".flac",
    "video/mp4": ".mp4",
    "video/quicktime": ".mov",
    "application/pdf": ".pdf",
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/gif": ".gif",
    "image/webp": ".webp",
    "text/vtt": ".vtt",
    "application/x-subrip": ".srt",
    "application/srt": ".srt",
    "application/json": ".json",
    "text/html": ".html",
    "text/plain": ".txt",
}


def log(msg):
    print(msg, flush=True)


def slugify(text, max_len=80):
    """Filesystem-safe slug that keeps titles readable."""
    text = unicodedata.normalize("NFKD", text)
    text = text.encode("ascii", "ignore").decode("ascii")
    text = re.sub(r"[^\w\s.-]", "", text).strip()
    text = re.sub(r"[\s]+", "_", text)
    text = text.strip("._-")
    return text[:max_len] or "untitled"


def http_open(url, timeout):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def download(url, dest, opts, expected_size=None):
    """Download url -> dest atomically. Returns (status, bytes_written).

    status is one of: "downloaded", "skipped", "failed".
    Skips when dest exists and matches expected_size (or any nonzero size if
    the feed didn't declare one), unless --force.
    """
    if os.path.exists(dest) and not opts.force:
        have = os.path.getsize(dest)
        if (expected_size and have == expected_size) or (not expected_size and have > 0):
            return "skipped", have

    if opts.dry_run:
        return "downloaded", 0

    tmp = dest + ".part"
    last_err = None
    for attempt in range(1, opts.retries + 1):
        try:
            with http_open(url, opts.timeout) as resp, open(tmp, "wb") as fh:
                while True:
                    chunk = resp.read(1024 * 256)
                    if not chunk:
                        break
                    fh.write(chunk)
            os.replace(tmp, dest)
            return "downloaded", os.path.getsize(dest)
        except Exception as exc:  # noqa: BLE001 - report every failure kind the same way
            last_err = exc
            if os.path.exists(tmp):
                os.remove(tmp)
            if attempt < opts.retries:
                wait = 2 ** attempt
                log(f"    retry {attempt}/{opts.retries - 1} in {wait}s ({exc})")
                time.sleep(wait)
    log(f"    FAILED: {url} ({last_err})")
    return "failed", 0


def fetch_feed_pages(feed_url, opts):
    """Fetch the feed and any rel=next pages. Returns list of (url, bytes)."""
    pages = []
    seen = set()
    url = feed_url
    while url and url not in seen:
        seen.add(url)
        log(f"Fetching feed: {url}")
        with http_open(url, opts.timeout) as resp:
            data = resp.read()
        pages.append((url, data))
        try:
            root = ET.fromstring(data)
        except ET.ParseError as exc:
            sys.exit(f"error: could not parse feed XML from {url}: {exc}")
        nxt = None
        for link in root.iter(f"{{{NS['atom']}}}link"):
            if link.get("rel") == "next" and link.get("href"):
                nxt = urllib.parse.urljoin(url, link.get("href"))
                break
        url = nxt
    return pages


def text_of(elem, path):
    node = elem.find(path, NS)
    return node.text.strip() if node is not None and node.text else None


def ext_for(url, mime=None):
    path = urllib.parse.urlparse(url).path
    ext = os.path.splitext(path)[1].lower()
    if ext and len(ext) <= 5:
        return ext
    if mime:
        return AUDIO_EXT_BY_MIME.get(mime.split(";")[0].strip().lower(), "")
    return ""


def collect_episode_assets(item):
    """Return dict describing one episode and every URL it references."""
    ep = {
        "title": text_of(item, "title") or "untitled",
        "guid": text_of(item, "guid"),
        "pubdate": text_of(item, "pubDate"),
        "assets": [],  # list of {kind, url, mime, size}
    }

    enclosure = item.find("enclosure")
    if enclosure is not None and enclosure.get("url"):
        size = enclosure.get("length")
        ep["assets"].append({
            "kind": "media",
            "url": enclosure.get("url"),
            "mime": enclosure.get("type"),
            "size": int(size) if size and size.isdigit() and int(size) > 0 else None,
        })

    # media:content is used by some hosts instead of / in addition to enclosure
    for mc in item.findall("media:content", NS):
        murl = mc.get("url")
        if murl and not any(a["url"] == murl for a in ep["assets"]):
            ep["assets"].append({"kind": "media", "url": murl,
                                 "mime": mc.get("type"), "size": None})

    img = item.find("itunes:image", NS)
    if img is not None and img.get("href"):
        ep["assets"].append({"kind": "image", "url": img.get("href"),
                             "mime": None, "size": None})

    for tr in item.findall("podcast:transcript", NS):
        if tr.get("url"):
            ep["assets"].append({"kind": "transcript", "url": tr.get("url"),
                                 "mime": tr.get("type"), "size": None})

    ch = item.find("podcast:chapters", NS)
    if ch is not None and ch.get("url"):
        ep["assets"].append({"kind": "chapters", "url": ch.get("url"),
                             "mime": ch.get("type"), "size": None})

    return ep


def collect_channel_assets(channel):
    assets = []
    img = channel.find("itunes:image", NS)
    if img is not None and img.get("href"):
        assets.append({"kind": "cover", "url": img.get("href"), "mime": None, "size": None})
    url = text_of(channel, "image/url")
    if url and not any(a["url"] == url for a in assets):
        assets.append({"kind": "cover", "url": url, "mime": None, "size": None})
    return assets


def unique_name(base, taken):
    """Avoid collisions when two episodes slug to the same filename."""
    if base not in taken:
        taken.add(base)
        return base
    stem, ext = os.path.splitext(base)
    n = 2
    while f"{stem}_{n}{ext}" in taken:
        n += 1
    name = f"{stem}_{n}{ext}"
    taken.add(name)
    return name


def main():
    ap = argparse.ArgumentParser(description="Mirror a podcast feed and all its media to a folder.")
    ap.add_argument("feed_url", help="URL of the podcast RSS feed")
    ap.add_argument("target", help="Target folder for the mirror")
    ap.add_argument("--limit", type=int, default=None, help="only process first N episodes")
    ap.add_argument("--dry-run", action="store_true", help="report what would be downloaded")
    ap.add_argument("--delay", type=float, default=0.5, help="seconds between downloads")
    ap.add_argument("--retries", type=int, default=4, help="retry attempts per file")
    ap.add_argument("--timeout", type=float, default=60, help="per-request timeout seconds")
    ap.add_argument("--force", action="store_true", help="re-download existing files")
    opts = ap.parse_args()

    target = os.path.abspath(opts.target)
    episodes_dir = os.path.join(target, "episodes")
    images_dir = os.path.join(target, "images")
    extras_dir = os.path.join(target, "extras")
    if not opts.dry_run:
        for d in (target, episodes_dir, images_dir, extras_dir):
            os.makedirs(d, exist_ok=True)

    pages = fetch_feed_pages(opts.feed_url, opts)
    if not opts.dry_run:
        for i, (_url, data) in enumerate(pages):
            name = "feed.xml" if i == 0 else f"feed_page{i + 1}.xml"
            with open(os.path.join(target, name), "wb") as fh:
                fh.write(data)
            log(f"Saved {name} ({len(data):,} bytes)")

    # Parse all pages, collect channel + episodes
    channel_title = None
    channel_assets = []
    episodes = []
    for _url, data in pages:
        root = ET.fromstring(data)
        channel = root.find("channel")
        if channel is None:
            sys.exit("error: feed is not RSS 2.0 (no <channel>); Atom-only feeds are not supported")
        if channel_title is None:
            channel_title = text_of(channel, "title") or "podcast"
            channel_assets = collect_channel_assets(channel)
        for item in channel.findall("item"):
            episodes.append(collect_episode_assets(item))

    log(f'Podcast: "{channel_title}" — {len(episodes)} episode(s) in feed')
    if opts.limit:
        episodes = episodes[: opts.limit]
        log(f"Limiting to first {len(episodes)} episode(s)")

    manifest = {
        "feed_url": opts.feed_url,
        "title": channel_title,
        "feed_pages": [u for u, _ in pages],
        "channel_assets": [],
        "episodes": [],
    }
    counts = {"downloaded": 0, "skipped": 0, "failed": 0}
    taken_names = set()

    def grab(asset, directory, filename):
        dest = os.path.join(directory, filename)
        status, _size = download(asset["url"], dest, opts, expected_size=asset.get("size"))
        counts[status] += 1
        rel = os.path.relpath(dest, target)
        tag = {"downloaded": "  + ", "skipped": "  = ", "failed": "  ! "}[status]
        log(f"{tag}{rel}" + (" (dry run)" if opts.dry_run and status == "downloaded" else ""))
        if status != "failed" and not opts.dry_run:
            time.sleep(opts.delay)
        return {"file": rel, "url": asset["url"], "kind": asset["kind"], "status": status}

    for asset in channel_assets:
        ext = ext_for(asset["url"]) or ".jpg"
        name = unique_name(f"cover{ext}", taken_names)
        manifest["channel_assets"].append(grab(asset, images_dir, name))

    for idx, ep in enumerate(episodes, 1):
        log(f'[{idx}/{len(episodes)}] {ep["title"]}')
        base = f'{date_prefix_from(ep)}_{slugify(ep["title"])}'
        ep_record = {"title": ep["title"], "guid": ep["guid"],
                     "pubdate": ep["pubdate"], "files": []}
        for asset in ep["assets"]:
            ext = ext_for(asset["url"], asset.get("mime"))
            if asset["kind"] == "media":
                directory, suffix = episodes_dir, ext or ".mp3"
                name = unique_name(base + suffix, taken_names)
            elif asset["kind"] == "image":
                directory, suffix = images_dir, ext or ".jpg"
                name = unique_name(base + suffix, taken_names)
            else:
                directory = extras_dir
                suffix = ext or (".json" if asset["kind"] == "chapters" else ".txt")
                name = unique_name(f'{base}_{asset["kind"]}{suffix}', taken_names)
            ep_record["files"].append(grab(asset, directory, name))
        if not ep["assets"]:
            log("    (no downloadable assets in this item)")
        manifest["episodes"].append(ep_record)

    if not opts.dry_run:
        with open(os.path.join(target, "manifest.json"), "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=2, ensure_ascii=False)
        log("Saved manifest.json")

    log(f"Done: {counts['downloaded']} downloaded, {counts['skipped']} already present, "
        f"{counts['failed']} failed.")
    if counts["failed"]:
        sys.exit(1)


def date_prefix_from(ep):
    raw = ep.get("pubdate")
    if raw:
        try:
            return email.utils.parsedate_to_datetime(raw).strftime("%Y-%m-%d")
        except (TypeError, ValueError):
            pass
    return "0000-00-00"


if __name__ == "__main__":
    main()
