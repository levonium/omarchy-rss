#!/usr/bin/env python3
"""RSS/Atom helper for the levonium.rss shell plugin. Stdlib only.

Owns ~/.local/share/levonium-rss/state.json; the QML panel just reads it.

  feeds.py refresh [FEED_ID]        fetch feeds, merge items, notify on new
  feeds.py add URL [NAME]           validate + add a feed (discovers from HTML)
  feeds.py edit FEED_ID NAME URL    rename / re-point a feed
  feeds.py remove FEED_ID
  feeds.py read ITEM_ID|all [FEED_ID]
"""
import contextlib
import email.utils
import fcntl
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from html.parser import HTMLParser

DATA_HOME = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
DIR = os.path.join(DATA_HOME, "levonium-rss")
STATE = os.path.join(DIR, "state.json")
# The one cap: each feed stores (and the panel shows) only its newest N items.
# A newly added feed therefore starts with N unread.
MAX_ITEMS_PER_FEED = 10
# Subscribed to on first run only (when state.json doesn't exist yet), so
# removing one is permanent.
DEFAULT_FEEDS = [("Omarchy News", "https://omarchy.org/news/rss.xml")]
UA = "Mozilla/5.0 (compatible; levonium-rss/1.0)"


def initial_state():
    # Ids are deterministic so concurrent first runs seed identical feeds.
    return {
        "feeds": [{"id": hid("default", url), "name": name, "url": url, "fetched": 0, "error": ""}
                  for name, url in DEFAULT_FEEDS],
        "items": [],
    }


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return initial_state()
    except (OSError, ValueError):
        return {"feeds": [], "items": []}


@contextlib.contextmanager
def locked():
    """Serialise load-modify-save across concurrent helper runs."""
    os.makedirs(DIR, exist_ok=True)
    with open(os.path.join(DIR, ".lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def save(state):
    os.makedirs(DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=DIR)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.read()


def hid(*parts):
    return hashlib.sha1("|".join(parts).encode()).hexdigest()[:12]


class _Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.out = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        elif tag in ("p", "br", "li", "div"):
            self.out.append(" ")

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.out.append(data)


def plain(s, limit=600):
    if not s:
        return ""
    p = _Text()
    try:
        p.feed(html.unescape(s) if "&lt;" in s else s)
    except Exception:
        return re.sub(r"<[^>]+>", " ", s)[:limit]
    text = re.sub(r"\s+", " ", "".join(p.out)).strip()
    return text[:limit]


def local(tag):
    return tag.rsplit("}", 1)[-1]


def child(el, name):
    for c in el:
        if local(c.tag) == name:
            return c
    return None


def child_text(el, *names):
    for n in names:
        c = child(el, n)
        if c is not None and (c.text or "").strip():
            return c.text.strip()
    return ""


def safe_link(url):
    """Item links are opened with xdg-open, so never pass on non-web schemes."""
    return url if re.match(r"^https?://", url or "", re.I) else ""


def parse_date(s):
    if not s:
        return 0
    try:
        return int(email.utils.parsedate_to_datetime(s).timestamp())
    except (TypeError, ValueError):
        pass
    try:
        return int(datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def parse_feed(data):
    """Return (title, [item dicts]) or raise ValueError."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise ValueError("not a feed (%s)" % e)
    kind = local(root.tag)
    items = []
    if kind == "feed":  # Atom
        title = child_text(root, "title")
        for e in root:
            if local(e.tag) != "entry":
                continue
            link = ""
            for l in e:
                if local(l.tag) == "link" and l.get("rel", "alternate") == "alternate":
                    link = l.get("href", "")
                    break
            items.append({
                "guid": child_text(e, "id") or link,
                "title": plain(child_text(e, "title"), 300) or "(untitled)",
                "link": safe_link(link),
                "date": parse_date(child_text(e, "published", "updated")),
                "summary": plain(child_text(e, "summary", "content")),
            })
    elif kind in ("rss", "RDF"):
        ch = child(root, "channel") if kind == "rss" else root
        if ch is None:
            raise ValueError("empty rss")
        title = child_text(ch, "title")
        for e in ch.iter():
            if local(e.tag) != "item":
                continue
            link = child_text(e, "link")
            items.append({
                "guid": child_text(e, "guid") or link,
                "title": plain(child_text(e, "title"), 300) or "(untitled)",
                "link": safe_link(link),
                "date": parse_date(child_text(e, "pubDate", "date")),
                "summary": plain(child_text(e, "description", "encoded")),
            })
    else:
        raise ValueError("not a feed")
    return plain(title, 120), items


def discover(url, data):
    """If url served HTML, find its advertised feed URL."""
    text = data[:200000].decode("utf-8", "replace")
    for m in re.finditer(r"<link\b[^>]*>", text, re.I):
        tag = m.group(0)
        if re.search(r"type=[\"']application/(rss|atom)\+xml", tag, re.I):
            h = re.search(r"href=[\"']([^\"']+)", tag, re.I)
            if h:
                return urllib.request.urljoin(url, html.unescape(h.group(1)))
    return None


def fetch_feed(url):
    data = fetch(url)
    try:
        return url, *parse_feed(data)
    except ValueError:
        found = discover(url, data)
        if not found:
            raise
        return found, *parse_feed(fetch(found))


def merge(state, feed, items):
    """Merge fetched items into state; return list of new items."""
    known = {i["id"]: i for i in state["items"] if i["feed"] == feed["id"]}
    first = not feed.get("fetched")
    new = []
    # Only ever consider the newest MAX_ITEMS_PER_FEED. Otherwise items beyond
    # the cap are forgotten by the trim below and look "new" on every refresh.
    # (sorted() is stable, so undated feeds keep their own order.)
    items = sorted(items, key=lambda i: -i["date"])[:MAX_ITEMS_PER_FEED]
    for it in items:
        iid = hid(feed["id"], it["guid"] or it["link"] or it["title"])
        if iid in known:
            continue
        rec = {"id": iid, "feed": feed["id"], "title": it["title"], "link": it["link"],
               "date": it["date"] or int(time.time()), "summary": it["summary"], "read": False}
        state["items"].append(rec)
        new.append(rec)
    mine = sorted((i for i in state["items"] if i["feed"] == feed["id"]), key=lambda i: -i["date"])
    drop = {i["id"] for i in mine[MAX_ITEMS_PER_FEED:]}
    state["items"] = [i for i in state["items"] if i["id"] not in drop]
    feed["fetched"] = int(time.time())
    feed["error"] = ""
    return [] if first else new


def cmd_refresh(only=None):
    # Network phase happens outside the lock so a slow feed never blocks
    # "mark read" / edits from the panel.
    fetched = {}
    for feed in load()["feeds"]:
        if only and feed["id"] != only:
            continue
        try:
            fetched[feed["id"]] = (fetch_feed(feed["url"])[2], "")
        except Exception as e:
            fetched[feed["id"]] = (None, str(e)[:120])
    notify = []
    with locked():
        state = load()
        for feed in state["feeds"]:
            if feed["id"] not in fetched:
                continue
            items, err = fetched[feed["id"]]
            if items is None:
                feed["error"] = err
            else:
                notify += [(feed, i) for i in merge(state, feed, items)]
        save(state)
    if notify:
        n = len(notify)
        body = "\n".join("%s: %s" % (f["name"], i["title"]) for f, i in notify[:3])
        if n > 3:
            body += "\n…and %d more" % (n - 3)
        title = "%d new item%s" % (n, "" if n == 1 else "s")
        subprocess.run(["notify-send", "-a", "Feeds", title, body])


def cmd_add(url, name=""):
    if not re.match(r"^https?://", url):
        url = "https://" + url
    real, title, items = fetch_feed(url)
    with locked():
        state = load()
        if any(f["url"] == real for f in state["feeds"]):
            raise ValueError("already subscribed")
        feed = {"id": hid(real, str(time.time())), "name": name or title or real, "url": real,
                "fetched": 0, "error": ""}
        state["feeds"].append(feed)
        merge(state, feed, items)
        save(state)


def cmd_edit(fid, name, url):
    if not re.match(r"^https?://", url):
        url = "https://" + url
    cur = next((f for f in load()["feeds"] if f["id"] == fid), None)
    if cur is None:
        raise ValueError("feed no longer exists")
    if url != cur["url"]:
        url = fetch_feed(url)[0]  # validate before committing
    with locked():
        state = load()
        for f in state["feeds"]:
            if f["id"] == fid:
                f["url"] = url
                f["name"] = name or f["name"]
        save(state)


def cmd_remove(fid):
    with locked():
        state = load()
        state["feeds"] = [f for f in state["feeds"] if f["id"] != fid]
        state["items"] = [i for i in state["items"] if i["feed"] != fid]
        save(state)


def cmd_read(target, fid=None):
    with locked():
        state = load()
        for i in state["items"]:
            if (target == "all" and (not fid or i["feed"] == fid)) or i["id"] == target:
                i["read"] = True
        save(state)


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    cmd, args = argv[0], argv[1:]
    try:
        {"refresh": cmd_refresh, "add": cmd_add, "edit": cmd_edit,
         "remove": cmd_remove, "read": cmd_read}[cmd](*args)
    except (ValueError, KeyError, TypeError) as e:
        print("error: %s" % e)
        return 1
    except Exception as e:
        print("error: %s" % str(e)[:200])
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
