#!/usr/bin/env python3
"""Load the measurement data of docs/tasks/M7.md ("Speed of operation") into a
sandbox state directory, through a `dev-ingest` build of shiibar-ghd.

The data: one account `me` (id 1001, no token) with the owner `org` and
Public; 200 PRs that are not dismissed, 3 rows each (a mention with a body
long enough for 3 lines on a third of them), spread over 20 repositories so
every All group (Group by Repository) folds into "+ N more PRs"; Review and
Mine with Inbox, Doing, Waiting and Done, and the cards of one muted user. For
the Filter the PRs have the four statuses (open, draft, merged,
closed), and a quarter of the cards are read (the rest have unread rows).
30 more PRs are dismissed, for the Dismissed list by repository; they are not
among the 200.
The avatars are PNG files in the state directory, referenced by file:// URLs:
the authors' and the rows' actors' (every fourth row has no avatar URL, as
a row saved before 0.7, and one actor has a long login). Some cards have
GitHub labels, a part of them enough to wrap to a second line.

No token is ever passed (a dev-ingest daemon without SHIIBAR_GH_DEV_KEYCHAIN
has no Keychain at all) and nothing reaches GitHub (no
SHIIBAR_GH_DEV_GITHUB_URL). The script refuses a state directory that is
not empty, so it never touches a real one.

Usage: make-data.py <shiibar-ghd built with --features dev-ingest> <empty dir> [--demo]

--demo loads the data of the demo mode (scripts/perf/demo.sh) instead: about
200 cards over All, Review and Mine (each with Inbox, Doing, Waiting, Done and
cards to `Dismiss all` in Done), dismissed cards of several repositories (the
Dismissed list by repository), the account `me` with the color None and a
second account with the color Blue (the dot before the name), many
repositories, a muted repository and a muted user, merged and closed cards
(in Done when placed), drafts, read cards and cards with unread rows (blue,
and gray on the muted cards: what the Filter sorts out), and
rows with bodies of every length (unread mentions of 1, 3, 6 and 12 and more
lines, read rows, long single lines, team mentions, cards with more than
three rows), an own PR in the muted repository, a PR of it taken out of Mute
by itself (Unmute), and team mentions on the muted user's cards. The rows
show their actors' avatars, some without one and some with a long login; the
account's own merges, closes and merge queue additions are read rows, a
removal by the merge queue an unread one, and approvals of your PRs carry no
body. Cards carry GitHub labels (none on most, one or a few on many,
enough to wrap on some, more than 20 with `+N` on one, colors close to
white and to black, a yellow, upper-case colors and one invalid color);
Ready for review and Converted to draft rows (some by the account itself,
read); a dismissed card with a long branch and a long login; the My
review mark in its three states (waiting for your review, a team's request
included; approved; changes requested), a card approved and asked again,
My review rows of both verdicts, and the second account without an avatar.
It needs a 0.8 daemon (the working tree's: the labels, the row kinds and the
My review mark).
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
# An actor whose login does not fit line 1 of a row: it is cut with "…".
LONG_USER = "a-contributor-with-a-really-long-login-name"
MERGE_QUEUE = "github-merge-queue"
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


# GitHub labels, `(name, color)`: GitHub's own defaults, colors close to
# white and to black, a yellow, upper-case colors and long names.
LABEL_SET = [
    ("bug", "d73a4a"), ("documentation", "0075ca"), ("duplicate", "cfd3d7"),
    ("enhancement", "a2eeef"), ("good first issue", "7057ff"), ("help wanted", "008672"),
    ("invalid", "e4e669"), ("question", "d876e3"), ("wontfix", "ffffff"),
    ("needs triage", "FBCA04"), ("blocked", "000000"), ("security", "1B1F23"),
    ("area: cache and storage", "BFD4F2"), ("priority: high", "B60205"),
    ("size: XL", "fef2c0"), ("dependencies", "0366d6"),
    ("breaking change for the public command line interface", "5319e7"),
]


def labels_of(n, wrap):
    """The labels of PR `n`, by name: none on most, one to three on many,
    and, with `wrap`, enough long ones to wrap to a second line."""
    if wrap:
        picked = LABEL_SET[9:17]
    elif n % 3 == 0:
        picked = []
    else:
        picked = [LABEL_SET[(n * k) % len(LABEL_SET)] for k in range(1, 1 + n % 4)]
    unique = {name: color for name, color in picked}
    return [{"name": name, "color": unique[name]} for name in sorted(unique, key=str.lower)]


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


def demo_labels(n):
    """The labels of demo PR `n`: more than 20 on PR 2 (with `+5`), every
    color of the set over the others, an invalid color on PR 4."""
    if n == 2:
        names = [(f"area-{i:02d}", LABEL_SET[i % len(LABEL_SET)][1]) for i in range(20)]
        return [{"name": name, "color": color} for name, color in names]
    if n == 4:
        return [{"name": "color not hexadecimal", "color": "not-a-color"}]
    return labels_of(n, n % 10 == 7)


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
            # A team's request, waiting for your review like your own.
            "requested_team": author != ME and not requested and n % 10 == 5,
            "labels": demo_labels(n), "labels_more": 5 if n == 2 else 0,
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
        if author == ME and n % 4 == 0:
            # An approval of your PR: the approver on line 1, no body.
            kinds.append(("approved", None))
        rows = [(kind, text, LONG_USER if n % 8 == 1 and j == 0 else actor) for j, (kind, text) in enumerate(kinds)]
        if author == ME and (merged or closed):
            # Your own merge or close, after your addition to the merge queue:
            # read rows, without a notification.
            rows = [("merged" if merged else "closed", None, ME), ("merge_queue_added", None, ME)] + rows
        elif author == ME and n % 12 == 6:
            # The queue removed your PR: an unread row by the queue.
            rows = [("merge_queue_removed", f"Checks failed · added by {ME}", MERGE_QUEUE), ("merge_queue_added", None, ME)] + rows
        if n % 7 == 3 and not (merged or closed):
            # The draft ended (unread), after it was made a draft; on your
            # own PR both are yours (read rows).
            who = ME if author == ME else actor
            rows = [("ready_for_review", None, who), ("converted_to_draft", None, who)] + rows
        elif n % 11 == 0:
            # Made a draft again.
            rows = [("converted_to_draft", None, ME if author == ME else actor)] + rows
        # Your newest verdict (the My review mark) and the row of that review:
        # approved or changes requested, and approved then asked again (the
        # mark waits for your review again, the row stays).
        verdict = None
        if author != ME and not (merged or closed):
            if n % 5 == 2:
                verdict = "approved"
            elif n % 5 == 4 and not requested:
                verdict = "changes_requested"
        if verdict:
            rows.append((f"my_review_{verdict}", None, ME))
            prs[-1]["my_review"] = verdict
            prs[-1]["my_review_at"] = updated - (len(rows) - 1) * 30
        for j, (kind, text, who) in enumerate(rows):
            events.append({
                "id": f"E_{n}_{j}", "pr_id": pr_id, "kind": kind, "occurred_at": updated - j * 30,
                "url": f"https://github.example/{OWNER}/{repo}/pull/{n}#e{j}",
                "actor": who, "text": text, "comment_id": None,
                # Every fourth row without an avatar, as a row saved before 0.7.
                "actor_avatar_url": None if (n + j) % 4 == 3 else colors.get(who),
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

    # A dismissed card whose branches and author do not fit its third line.
    long_one = prs[8]
    assert f"{OWNER}/{long_one['repo']}#9" in dismissed
    long_one.update({
        "author": LONG_USER, "author_avatar_url": colors[LONG_USER],
        "base": "release/2027-spring-maintenance-branch",
        "head": f"{LONG_USER}/rework-the-retry-path-of-the-status-fetch",
    })

    # Your merged and closed PRs were seen open first, so their merge or
    # close makes a row.
    finished_own = [dict(p, state="open") for p in prs if p["author"] == ME and p["state"] != "open"]
    daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {"prs": finished_own, "events": []}})
    for i in range(0, len(prs), 40):
        ids = {p["id"] for p in prs[i:i + 40]}
        daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {
            "prs": prs[i:i + 40], "events": [e for e in events if e["pr_id"] in ids],
        }})
    for index, pr in enumerate(review):
        if pr in done:
            continue
        section = ["doing", "inbox", "waiting", "inbox"][index % 4]
        if section != "inbox":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": section})
    for pr in done:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": "done"})
    for pr in mine_done:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": "done"})
    # Mine: your own open PRs came to Inbox; spread them over the sections
    # (an open one in Done too), and add assigned PRs (`Add to Mine`).
    for index, pr in enumerate(mine_open):
        section = ["doing", "inbox", "waiting", "inbox", "done", "inbox"][index % 6]
        if section != "inbox":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": section})
    for pr in assigned:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "mine", "section": "inbox"})
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
    for i, user in enumerate(USERS + [MUTED_USER, ME, LONG_USER, MERGE_QUEUE]):
        path = os.path.join(avatars, user + ".png")
        png(path, ((i * 47) % 256, (i * 91 + 60) % 256, (i * 23 + 120) % 256))
        colors[user] = "file://" + path

    # The rows happen in the hour before the data is loaded; the daemon that
    # loads them runs at the start of that hour.
    start = int(time.time()) - 3600
    daemon = Daemon(binary, state, start)
    # `me` with its own avatar (the My review mark); `me-two` of the demo
    # without one.
    daemon.ok({"cmd": "dev_account_add", "id": ACCOUNT_ID, "login": ME, "avatar_url": colors[ME]})
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
            # Labels on some cards, wrapping to a second line on a part.
            "labels": labels_of(n, n % 10 == 5),
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
            who = LONG_USER if n % 8 == 1 and j == 0 else actor
            events.append({
                "id": f"E_{n}_{j}", "pr_id": pr_id, "kind": kind, "occurred_at": updated - j * 5,
                "url": f"https://github.example/{OWNER}/{repo}/pull/{n}#e{j}",
                "actor": who, "text": text, "comment_id": None,
                # Every fourth row without an avatar, as a row saved before 0.7.
                "actor_avatar_url": None if (n + j) % 4 == 3 else colors[who],
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

    # Review: the requested PRs went to Inbox; spread some over the other
    # sections. Mine likewise: your own PRs came to its Inbox.
    for index, pr in enumerate(review):
        section = ["doing", "inbox", "waiting", "inbox", "done"][index % 5]
        if section != "inbox":
            daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": "review", "section": section})
    for index, pr in enumerate(own):
        section = ["doing", "inbox", "waiting", "inbox", "done"][index % 5]
        if section != "inbox":
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
