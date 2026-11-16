#!/usr/bin/env python3
"""Load the measurement data of docs/tasks/M7.md ("Speed of operation") into a
sandbox state directory, through a `dev-ingest` build of shiibar-ghd.

The data: one account `me` (id 1001, no token) with the owner `org` and
Public; 200 PRs that are not dismissed, 3 rows each (a mention with a body
long enough for 3 lines on a third of them), spread over 20 repositories so
every All group (Group by Repository) folds into "+ N more PRs"; Review and
Mine with Doing, Todo, Waiting and Done, and the cards of one muted user. For
the Filter the PRs have the four statuses (open, draft, merged,
closed), and a quarter of the cards are read (the rest have unread rows).
30 more PRs are dismissed, for the Dismissed list by repository; they are not
among the 200.
The avatars are PNG files in the state directory, referenced by file:// URLs.

No token is ever passed (a dev-ingest daemon without SHIIBAR_GH_DEV_KEYCHAIN
has no Keychain at all) and nothing reaches GitHub (no
SHIIBAR_GH_DEV_GITHUB_URL). The script refuses a state directory that is
not empty, so it never touches a real one.

Usage: make-data.py <shiibar-ghd built with --features dev-ingest> <empty dir> [--demo]

--demo loads the data of the demo mode (scripts/perf/demo.sh) instead: about
200 cards over All, Review and Mine (each with Doing, Todo, Waiting, Done and
cards to `Dismiss all` in Done), dismissed cards of several repositories (the
Dismissed list by repository), the account `me` with the color None and a
second account with the color Blue (the dot before the name), many
repositories, a muted repository and a muted user, merged and closed cards
(in Done when placed), drafts, read cards and cards with unread rows (blue,
and gray on the muted cards: what the Filter sorts out), and
rows with bodies of every length (unread mentions of 1, 3, 6 and 12 and more
lines, read rows, long single lines, team mentions, cards with more than
three rows), an own PR in the muted repository, a PR of it taken out of Mute
by itself (Unmute), and team mentions on the muted user's cards. It needs a
0.6 daemon or later (the working tree's: Mine's sections).
"""

import json
import os
import socket
import struct
import subprocess
import sys
import time
import zlib

ACCOUNT_ID = "1001"
ME = "me"
OWNER = "org"
REPOS = [f"repo-{i:02d}" for i in range(1, 21)]
USERS = [f"user{i:02d}" for i in range(1, 12)]
MUTED_USER = "example-bot"
# 200 for the measurement of docs/tasks/M7.md; SHIIBAR_GH_PERF_CARDS for a
# smaller run.
CARDS = int(os.environ.get("SHIIBAR_GH_PERF_CARDS", "200"))
# Dismissed PRs on top of them (the Dismissed list by repository).
DISMISSED = 30
MENTION_BODY = (
    "@me could you take a look at the migration plan before Friday? "
    "The second step rewrites the index of the events table and I am not sure "
    "whether we want to keep the old column around for one more release, "
    "because the CLI of 0.4 still reads it when it lists the rows of a PR. "
    "If we drop it now, the CLI needs a new release at the same time."
)


def png(path, rgb):
    """A 32x32 PNG of one color, written without third-party modules."""
    width = height = 32
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


class Daemon:
    def __init__(self, binary, state, now):
        env = dict(os.environ)
        env.pop("SHIIBAR_GH_DEV_KEYCHAIN", None)
        env.pop("SHIIBAR_GH_DEV_GITHUB_URL", None)
        env["SHIIBAR_GH_STATE_DIR"] = state
        env["SHIIBAR_GH_LOG"] = "error"
        env["SHIIBAR_GH_DEV_NOW"] = str(now)
        env["SHIIBAR_GH_DEV_TZ"] = "UTC"
        self.socket = os.path.join(state, "shiibar-ghd.sock")
        self.child = subprocess.Popen(
            [binary, "--foreground"], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL
        )
        deadline = time.time() + 30
        while True:
            try:
                self.request({"cmd": "info"})
                return
            except OSError:
                if self.child.poll() is not None or time.time() > deadline:
                    raise SystemExit("the daemon did not start")
                time.sleep(0.05)

    def request(self, value):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(60)
            s.connect(self.socket)
            s.sendall((json.dumps(value) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                part = s.recv(65536)
                if not part:
                    break
                data += part
        return json.loads(data)

    def ok(self, value):
        answer = self.request(value)
        if answer.get("ok") is not True:
            raise SystemExit(f"{value.get('cmd')} failed: {answer}")
        return answer

    def stop(self):
        self.ok({"cmd": "shutdown"})
        self.child.wait(timeout=30)


SENTENCES = [
    "Could you take a look at the migration plan before Friday?",
    "The second step rewrites the index of the events table.",
    "I am not sure whether we want to keep the old column around for one more release,",
    "because the CLI of 0.4 still reads it when it lists the rows of a PR.",
    "If we drop it now, the CLI needs a new release at the same time.",
    "The retry path also needs a look: it waits a whole minute after a 502.",
    "Maybe we can split this change into the schema part and the reader part.",
    "I ran the benchmark again and the numbers are in the description.",
]


def body(lines):
    """A comment of about `lines` lines at the list's width (about 60
    characters a line), the longest ones in paragraphs."""
    words = " ".join(SENTENCES[i % len(SENTENCES)] for i in range(max(1, lines * 60 // 55)))
    text = words[: lines * 60]
    if lines >= 12:
        half = len(text) // 2
        text = text[:half] + "\n\n" + text[half:]
    return text


def demo(daemon, colors, start):
    """The demo data (see the module's docstring)."""
    repos = [f"repo-{i:02d}" for i in range(1, 25)]
    muted_repo = "repo-24"
    prs, events, review, done, mine_done, mine_open, assigned, dismissed = [], [], [], [], [], [], [], []
    for n in range(1, 201):
        repo = repos[(n * 7) % len(repos)]
        # 41 is an own PR in the muted repository (repo-24).
        author = ME if n % 6 == 0 or n == 41 else MUTED_USER if n % 17 == 4 else USERS[n % len(USERS)]
        requested = author != ME and n % 3 == 1
        merged = n % 19 == 0
        closed = not merged and n % 23 == 0
        pr_id = f"PR_{n}"
        updated = start + 60 + n * 15
        prs.append({
            "id": pr_id, "owner": OWNER, "repo": repo, "number": n,
            "url": f"https://github.example/{OWNER}/{repo}/pull/{n}",
            "title": [f"Fix {repo} retries", f"Change {n}: update the {repo} handling of rows, events and the cache",
                      f"Add a setting for the {repo} sync interval"][n % 3],
            "author": author, "author_avatar_url": colors[author],
            "base": "main", "head": f"topic/change-{n}" if n % 5 else f"feature/a-much-longer-branch-name-for-change-{n}",
            "state": "merged" if merged else "closed" if closed else "open", "is_draft": n % 11 == 0,
            "review": ["approved", "review_required", "changes_requested", "none"][n % 4],
            "checks": ["passed", "in_progress", "failed", "none"][n % 4],
            "base_status": ["up_to_date", "behind", "conflicts", "none"][n % 4],
            "mergeable": False, "failed_check": None, "changes_requested_by": None,
            "updated_at": updated, "created_at": updated - 86_400 * (1 + n % 9),
            "is_private": False, "requested_me": requested, "assignees": [ME] if n % 13 == 0 else [],
            "links": {
                "review": f"https://github.example/{OWNER}/{repo}/pull/{n}/files",
                "checks": f"https://github.example/{OWNER}/{repo}/pull/{n}/checks",
                "base": f"https://github.example/{OWNER}/{repo}/pull/{n}",
            },
        })
        actor = USERS[(n + 3) % len(USERS)]
        lines = [1, 3, 6, 12, 16][n % 5]
        kinds = []
        if requested:
            kinds.append(("review_requested", f"{actor} requested your review"))
        if n % 4 == 0:
            kinds.append(("mentioned", body(lines)))
        if n % 9 == 2 or author == MUTED_USER:
            # Team mentions, on the muted user's cards too.
            kinds.append(("team_mentioned", "@org/platform " + body(3)))
        if n % 10 == 5:
            kinds.append(("team_review_requested", "for the platform team"))
        kinds.append(("comment_other", "A single long line: " + " ".join(SENTENCES)))
        kinds.append(("reply", body(2)))
        if n % 3 == 0:
            # More than three rows: "+ N more".
            kinds += [("comment_other", f"Follow-up {k}: " + SENTENCES[k % len(SENTENCES)]) for k in range(1, 4)]
        for j, (kind, text) in enumerate(kinds):
            events.append({
                "id": f"E_{n}_{j}", "pr_id": pr_id, "kind": kind, "occurred_at": updated - j * 30,
                "url": f"https://github.example/{OWNER}/{repo}/pull/{n}#e{j}",
                "actor": actor, "text": text, "comment_id": None,
            })
        key = f"{OWNER}/{repo}#{n}"
        if requested:
            review.append(key)
        if (merged or closed) and author == ME:
            mine_done.append(key)
        elif (merged or closed) and requested:
            done.append(key)
        elif author == ME:
            mine_open.append(key)
        elif n % 13 == 0 and not requested:
            assigned.append(key)
        # The Dismissed list: five PRs in each of three repositories (n and
        # n + 24 share one) and a few alone.
        if not requested and author != ME and (n % 24 in (7, 9, 14) and n <= 120 or n in (151, 163)):
            dismissed.append(key)

    for i in range(0, len(prs), 40):
        ids = {p["id"] for p in prs[i:i + 40]}
        daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {
            "prs": prs[i:i + 40], "events": [e for e in events if e["pr_id"] in ids],
        }})
    for index, pr in enumerate(review):
        if pr in done:
            continue
        section = ["doing", "todo", "waiting", "todo"][index % 4]
        if section != "todo":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": section})
    for pr in done:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": "done"})
    for pr in mine_done:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": "done"})
    # Mine: your own open PRs came to Todo; spread them over the sections
    # (an open one in Done too), and add assigned PRs (`Add to Mine`).
    for index, pr in enumerate(mine_open):
        section = ["doing", "todo", "waiting", "todo", "done", "todo"][index % 6]
        if section != "todo":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": section})
    for pr in assigned:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": "todo"})
    for pr in dismissed:
        daemon.ok({"cmd": "dismiss", "account": ME, "pr": pr})
    # `me` without a color (no dot before its name), a second account with
    # Blue (the dot).
    daemon.ok({"cmd": "account_color", "account": ME, "color": "none"})
    daemon.ok({"cmd": "dev_account_add", "id": "1002", "login": "me-two"})
    daemon.ok({"cmd": "dev_owner_add", "account": "me-two", "owner": "public", "kind": "public"})
    daemon.ok({"cmd": "account_color", "account": "me-two", "color": "blue"})
    daemon.ok({"cmd": "mute", "account": ME, "kind": "user", "name": MUTED_USER})
    daemon.ok({"cmd": "mute", "account": ME, "kind": "repo", "name": f"{OWNER}/{muted_repo}"})
    # A PR of the muted repository taken out of Mute by itself (its own
    # setting becomes Unmute).
    daemon.ok({"cmd": "unmute", "account": ME, "kind": "pr", "name": f"{OWNER}/{muted_repo}#65"})
    # Read rows: every other card's first two rows, and every row of every
    # fifth card (read cards for the Filter's `Unread only`).
    cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
    read = [row["id"] for index, card in enumerate(cards) if index % 2 == 0 or index % 5 == 1
            for row in (card["rows"] if index % 5 == 1 else card["rows"][:2])]
    for i in range(0, len(read), 200):
        daemon.ok({"cmd": "read", "row_ids": read[i:i + 200]})


def main():
    args = [a for a in sys.argv[1:] if a != "--demo"]
    demo_data = "--demo" in sys.argv[1:]
    if len(args) != 2:
        raise SystemExit(__doc__)
    binary, state = args[0], os.path.abspath(args[1])
    os.makedirs(state, mode=0o700, exist_ok=True)
    if os.listdir(state):
        raise SystemExit(f"{state} is not empty; give a new empty directory")

    avatars = os.path.join(state, "avatars")
    os.makedirs(avatars)
    colors = {}
    for i, user in enumerate(USERS + [MUTED_USER, ME]):
        path = os.path.join(avatars, user + ".png")
        png(path, ((i * 47) % 256, (i * 91 + 60) % 256, (i * 23 + 120) % 256))
        colors[user] = "file://" + path

    # The rows happen in the hour before the data is loaded; the daemon that
    # loads them runs at the start of that hour.
    start = int(time.time()) - 3600
    daemon = Daemon(binary, state, start)
    daemon.ok({"cmd": "dev_account_add", "id": ACCOUNT_ID, "login": ME})
    daemon.ok({"cmd": "dev_owner_add", "account": ME, "owner": OWNER, "kind": "org", "github_id": 100})
    daemon.ok({"cmd": "dev_owner_add", "account": ME, "owner": "public", "kind": "public"})

    if demo_data:
        demo(daemon, colors, start)
        cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
        daemon.stop()
        shown = [c for c in cards if c.get("dismissed_at") is None]
        print(json.dumps({"state_dir": state, "cards": len(shown), "rows": sum(len(c["rows"]) for c in shown)}, sort_keys=True))
        return

    prs, events, review, muted, own = [], [], [], [], []
    for n in range(1, CARDS + DISMISSED + 1):
        repo = REPOS[(n - 1) % len(REPOS)]
        if n % 7 == 0:
            author = ME
        elif n % 10 == 3:
            author = MUTED_USER
        else:
            author = USERS[n % len(USERS)]
        requested = author != ME and n % 3 == 1
        pr_id = f"PR_{n}"
        updated = start + 60 + n * 10
        prs.append({
            "id": pr_id, "owner": OWNER, "repo": repo, "number": n,
            "url": f"https://github.example/{OWNER}/{repo}/pull/{n}",
            "title": f"Change {n}: update the {repo} handling of rows, events and the cache",
            "author": author, "author_avatar_url": colors[author],
            "base": "main", "head": f"topic/change-{n}",
            # The four statuses for the Filter: merged and closed ones too.
            "state": "merged" if n % 17 == 0 else "closed" if n % 29 == 0 else "open", "is_draft": n % 11 == 0,
            "review": ["approved", "review_required", "changes_requested", "none"][n % 4],
            "checks": ["passed", "in_progress", "failed", "none"][n % 4],
            "base_status": ["up_to_date", "behind", "conflicts", "none"][n % 4],
            "mergeable": False, "failed_check": None, "changes_requested_by": None,
            "updated_at": updated, "created_at": updated - 86_400 * (1 + n % 9),
            "is_private": False, "requested_me": requested, "assignees": [ME] if n % 13 == 0 else [],
            "links": {
                "review": f"https://github.example/{OWNER}/{repo}/pull/{n}/files",
                "checks": f"https://github.example/{OWNER}/{repo}/pull/{n}/checks",
                "base": f"https://github.example/{OWNER}/{repo}/pull/{n}",
            },
        })
        actor = USERS[(n + 3) % len(USERS)]
        first = (
            ("review_requested", f"{actor} requested your review")
            if requested
            else ("mentioned", MENTION_BODY) if n % 3 == 0 else ("comment_other", f"Looks good to me after the rename in {repo}.")
        )
        kinds = [first, ("comment_other", f"Rebased on main; the failing check in {repo} is unrelated."),
                 ("reply", "Agreed, let us keep the old column for one more release.")]
        if prs[-1]["state"] != "open":
            # The daemon keeps no `comment_other` row on a merged or closed
            # PR: replies instead, so every card still has 3 rows.
            kinds = [("reply", text) if kind == "comment_other" else (kind, text) for kind, text in kinds]
            if requested or author == ME:
                # No reply after the merge or close (requests, or reopens of
                # your own PR), so the card in Done has `Dismissed in N days`
                # (DESIGN.md, "Dismiss"; the consistency scene of a Done card
                # moved to an empty Waiting).
                kinds = [first] * 3 if requested else [("reopened", f"{actor} reopened it")] * 3
        for j, (kind, text) in enumerate(kinds):
            events.append({
                "id": f"E_{n}_{j}", "pr_id": pr_id, "kind": kind, "occurred_at": updated - j * 5,
                "url": f"https://github.example/{OWNER}/{repo}/pull/{n}#e{j}",
                "actor": actor, "text": text, "comment_id": None,
            })
        if requested:
            review.append(f"{OWNER}/{repo}#{n}")
        if author == ME and n <= CARDS and prs[-1]["state"] == "open":
            own.append(f"{OWNER}/{repo}#{n}")
        if author == MUTED_USER:
            muted.append(n)

    # In batches, so no single request is large.
    for i in range(0, len(prs), 50):
        ids = {p["id"] for p in prs[i:i + 50]}
        daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {
            "prs": prs[i:i + 50], "events": [e for e in events if e["pr_id"] in ids],
        }})

    # Review: the requested PRs went to Todo; spread some over the other
    # sections. Mine likewise: your own PRs came to its Todo.
    for index, pr in enumerate(review):
        section = ["doing", "todo", "waiting", "todo", "done"][index % 5]
        if section != "todo":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": section})
    for index, pr in enumerate(own):
        section = ["doing", "todo", "waiting", "todo", "done"][index % 5]
        if section != "todo":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": section})
    daemon.ok({"cmd": "mute", "account": ME, "kind": "user", "name": MUTED_USER})
    # The PRs past the 200: dismissed (the Dismissed list).
    for p in prs[CARDS:]:
        daemon.ok({"cmd": "dismiss", "account": ME, "pr": f"{OWNER}/{p['repo']}#{p['number']}"})
    # A quarter of the cards read (for the Filter's `Unread only`).
    cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
    read = [row["id"] for index, card in enumerate(cards) if index % 4 == 0 for row in card["rows"]]
    for i in range(0, len(read), 200):
        daemon.ok({"cmd": "read", "row_ids": read[i:i + 200]})

    cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
    daemon.stop()
    shown = [c for c in cards if c.get("dismissed_at") is None]
    rows = sum(len(c["rows"]) for c in shown)
    placed = {}
    for c in shown:
        p = c.get("placement")
        key = f"{p['tab']}/{p['section']}" if p else "none"
        placed[key] = placed.get(key, 0) + 1
    print(json.dumps({
        "state_dir": state, "cards": len(shown), "rows": rows, "muted_cards": len([c for c in shown if c["muted"]]),
        "placements": placed,
    }, indent=1, sort_keys=True))


if __name__ == "__main__":
    main()
