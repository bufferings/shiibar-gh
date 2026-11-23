"""The `screenshots` set of make-data.py: a small, tidy data set for the
README's pictures, in the sandbox (scripts/sandbox-env.sh).

One account `example-user` with the organization `example-org` and five
repositories. Review has a card in each of Inbox, Doing, Waiting and Done,
Mine has your own PRs in Doing, Waiting and Done (one merged), and All adds
a mention and a team mention on PRs that are in neither tab. Four merged
or closed PRs of three repositories are dismissed (the Dismissed list). The rows
happen from minutes to a day before the data is loaded; the older ones are
read. Every login is made up and starts with `example-`. The avatars are
generated patterns (avatars.py) in the state directory.
"""

import os
import time

from avatars import avatar

ACCOUNT_ID = "1000001"
ME = "example-user"
OWNER = "example-org"
OWNER_ID = 200001
TEAM = f"@{OWNER}/backend"
PEOPLE = {
    # login: the avatar's color
    ME: (88, 166, 255),
    "example-ana": (219, 97, 162),
    "example-ben": (63, 185, 80),
    "example-chen": (210, 153, 34),
    "example-dana": (163, 113, 247),
    "example-eli": (248, 81, 73),
}
LABELS = {
    "bug": "d73a4a",
    "enhancement": "a2eeef",
    "dependencies": "0366d6",
    "documentation": "0075ca",
    "performance": "fbca04",
}

MINUTE = 60
HOUR = 60 * MINUTE
DAY = 24 * HOUR
# Every event happens within this time before the data is loaded.
SPAN = 2 * DAY


def pull(repo, number, title, author, at, **extra):
    url = f"https://github.example/{OWNER}/{repo}/pull/{number}"
    value = {
        "id": f"PR_{repo}_{number}", "owner": OWNER, "repo": repo, "number": number, "url": url, "title": title,
        "author": author, "author_avatar_url": None, "base": "main", "head": f"{author}/{repo}-{number}",
        "state": "open", "is_draft": False, "review": "review_required", "checks": "passed",
        "base_status": "up_to_date", "mergeable": False, "failed_check": None, "changes_requested_by": None,
        "updated_at": at, "created_at": at - 2 * DAY, "is_private": False, "requested_me": False,
        "assignees": [], "labels": [],
        "links": {"review": url + "/files", "checks": url + "/checks", "base": url},
    }
    labels = extra.pop("labels", [])
    value["labels"] = [{"name": name, "color": LABELS[name]} for name in labels]
    value.update(extra)
    return value


def rows_of(pr, rows):
    """The events of `pr`: (kind, actor, minutes before now, text)."""
    return [
        {"id": f"E_{pr['id']}_{j}", "pr_id": pr["id"], "kind": kind, "occurred_at": pr["updated_at"] - ago,
         "url": f"{pr['url']}#event-{j}", "actor": actor, "text": text, "comment_id": None, "actor_avatar_url": None}
        for j, (kind, actor, ago, text) in enumerate(rows)
    ]


def data(now):
    """The PRs, their events, where they are placed, and the rows read."""
    prs, events, places, read, dismissed = [], [], [], [], []

    def add(pr, rows, place=None, read_from=None, dismiss=None):
        prs.append(pr)
        made = rows_of(pr, rows)
        events.extend(made)
        key = f"{OWNER}/{pr['repo']}#{pr['number']}"
        if place:
            places.append((key,) + place)
        if read_from is not None:
            read.extend(e["id"] for e in made[read_from:])
        if dismiss:
            # Seen open first (the core takes no PR it first sees merged or
            # closed without a row), then finished, then dismissed.
            dismissed.append((key, dict(pr, state=dismiss)))

    # Review: Inbox.
    add(pull("web-app", 482, "Add keyboard shortcuts to the search page", "example-ana", now - 12 * MINUTE,
             requested_me=True, labels=["enhancement"], checks="in_progress"),
        [("review_requested", "example-ana", 0, None)])
    add(pull("api-server", 1290, "Retry webhook deliveries with exponential backoff", "example-ben", now - 38 * MINUTE,
             requested_me=True, labels=["enhancement"]),
        [("comment_other", "example-chen", 0, "The backoff caps at ten minutes, which matches what the "
          "partners asked for. The flaky test is fixed in #1288."),
         ("review_requested", "example-ben", 25 * MINUTE, None)])
    # Review: Doing.
    add(pull("mobile", 311, "Cache profile images on disk", "example-chen", now - 2 * HOUR,
             requested_me=True, labels=["performance"], base_status="behind"),
        [("mentioned", "example-chen", 0, f"@{ME} could you check the eviction policy? It keeps the 200 newest "
          "images and drops the rest when the app starts."),
         ("review_requested", "example-chen", 3 * HOUR, None)],
        place=("review", "doing"), read_from=1)
    # Review: Waiting (changes requested, then a reply).
    add(pull("infra", 77, "Move the staging cluster to the new region", "example-dana", now - 55 * MINUTE,
             review="changes_requested", my_review="changes_requested", my_review_at=now - 5 * HOUR),
        [("reply", "example-dana", 0, "Thanks, I split the DNS change into #78 so this one can go first."),
         ("my_review_changes_requested", ME, 4 * HOUR, None),
         ("review_requested", "example-dana", 1 * DAY, None)],
        place=("review", "waiting"), read_from=1)
    # Review: Done (approved).
    add(pull("web-app", 475, "Upgrade the date picker", "example-eli", now - 6 * HOUR,
             review="approved", my_review="approved", my_review_at=now - 6 * HOUR, labels=["dependencies"]),
        [("my_review_approved", ME, 0, None), ("review_requested", "example-eli", 1 * DAY, None)],
        place=("review", "done"), read_from=0)

    # Mine: Doing (a draft).
    add(pull("api-server", 1284, "Remove the legacy v1 endpoints", ME, now - 3 * HOUR, is_draft=True,
             checks="failed", review="none"),
        [("comment_other", "example-ben", 0, "The mobile app of last year still calls /v1/profile. "
          "Can we keep that one until the next release?")],
        place=("mine", "doing"))
    # Mine: Waiting (approved).
    add(pull("web-app", 480, "Show unread counts in the sidebar", ME, now - 25 * MINUTE,
             review="approved", labels=["enhancement"]),
        [("approved", "example-ana", 0, None),
         ("comment_other", "example-chen", 2 * HOUR, "Works well with 500 unread items here.")],
        place=("mine", "waiting"), read_from=1)
    add(pull("mobile", 305, "Fix a crash when rotating the settings screen", ME, now - 4 * HOUR,
             labels=["bug"], checks="in_progress"),
        [("comment_other", "example-dana", 0, "Looks good once the checks pass.")],
        place=("mine", "waiting"), read_from=0)

    # All only: a mention and a team mention.
    add(pull("docs", 58, "Document the new rate limits", "example-ben", now - 70 * MINUTE,
             labels=["documentation"]),
        [("mentioned", "example-ben", 0, f"@{ME} is 5,000 requests an hour still right for the search API?")])
    add(pull("api-server", 1292, "Rate limit the export endpoint", "example-eli", now - 5 * HOUR),
        [("team_mentioned", "example-eli", 0, f"{TEAM} this changes the limits of the export jobs; "
          "please check the numbers in the description.")],
        read_from=0)

    # Dismissed: finished PRs you are done with, in three repositories.
    add(pull("web-app", 468, "Remove the old onboarding flow", "example-ana", now - 26 * HOUR, review="approved"),
        [("review_requested", "example-ana", 0, None)], read_from=0, dismiss="merged")
    add(pull("web-app", 471, "Translate the settings page", "example-eli", now - 30 * HOUR,
             labels=["enhancement"]),
        [("mentioned", "example-eli", 0, f"@{ME} the strings are in the new catalog now.")], read_from=0, dismiss="closed")
    add(pull("api-server", 1279, "Bump the HTTP client to the latest minor version", "example-ben", now - 33 * HOUR,
             labels=["dependencies"]),
        [("review_requested", "example-ben", 0, None)], read_from=0, dismiss="merged")
    add(pull("docs", 55, "Fix broken links in the API guide", "example-dana", now - 40 * HOUR,
             labels=["documentation"]),
        [("comment_other", "example-chen", 0, "Thanks, all links work now.")], read_from=0, dismiss="merged")

    # Mine: Done (merged): seen open first, then merged.
    merged = pull("infra", 74, "Pin the base image of the build runners", ME, now - 20 * HOUR, review="approved")
    return prs, events, places, read, dismissed, merged


def load(daemon, state, now, token):
    """Loads the set; returns the logins of its accounts."""
    avatars = os.path.join(state, "avatars")
    os.makedirs(avatars)
    urls = {}
    for seed, (login, rgb) in enumerate(PEOPLE.items(), start=7):
        path = os.path.join(avatars, login + ".png")
        avatar(path, rgb, seed)
        urls[login] = "file://" + path

    daemon.ok({"cmd": "dev_account_add", "id": ACCOUNT_ID, "login": ME, "token": token, "avatar_url": urls[ME]})
    daemon.ok({"cmd": "dev_owner_add", "account": ME, "owner": OWNER, "kind": "org", "github_id": OWNER_ID})

    prs, events, places, read, dismissed, merged = data(now)
    for pr in prs:
        pr["author_avatar_url"] = urls[pr["author"]]
    for event in events:
        event["actor_avatar_url"] = urls[event["actor"]]
    merged["author_avatar_url"] = urls[ME]
    merged_events = rows_of(merged, [("approved", "example-dana", HOUR, None)])
    for event in merged_events:
        event["actor_avatar_url"] = urls[event["actor"]]
    daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {"prs": [merged], "events": merged_events}})
    daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {
        "prs": prs + [dict(merged, state="merged")], "events": [],
    }})
    daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {"prs": prs, "events": events}})
    for pr, tab, section in places:
        daemon.ok({"cmd": "place", "account": ME, "pr": pr, "tab": tab, "section": section})
    daemon.ok({"cmd": "place", "account": ME, "pr": f"{OWNER}/infra#74", "tab": "mine", "section": "done"})

    wanted = {f"{ACCOUNT_ID}:{event_id}" for event_id in read}
    cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
    row_ids = [row["id"] for card in cards for row in card["rows"]]
    merged_rows = [row["id"] for card in cards if card["pr"] == f"{OWNER}/infra#74" for row in card["rows"]]
    daemon.ok({"cmd": "read", "row_ids": [r for r in row_ids if r in wanted] + merged_rows})
    # Each finished a little after its last event (the merge or close row
    # takes the daemon's time), read, then dismissed.
    for _, finished in dismissed:
        finished["author_avatar_url"] = urls[finished["author"]]
        daemon.ok({"cmd": "dev_clock_set", "now": finished["updated_at"] + 20 * MINUTE, "tz": "UTC"})
        daemon.ok({"cmd": "dev_ingest", "account": ME, "ingest": {"prs": [finished], "events": []}})
    keys = {key for key, _ in dismissed}
    cards = daemon.ok({"cmd": "list", "account": ME})["cards"]
    daemon.ok({"cmd": "read", "row_ids": [row["id"] for card in cards if card["pr"] in keys for row in card["rows"]]})
    for key in keys:
        daemon.ok({"cmd": "dismiss", "account": ME, "pr": key})
    return [ME]


def notification(state):
    """The request that makes one notification: a new mention by
    example-chen on mobile#311."""
    now = int(time.time())

    def url(login):
        return "file://" + os.path.join(state, "avatars", login + ".png")

    pr = pull("mobile", 311, "Cache profile images on disk", "example-chen", now,
              requested_me=True, labels=["performance"], base_status="behind")
    pr["author_avatar_url"] = url("example-chen")
    event = rows_of(pr, [("mentioned", "example-chen", 0, f"@{ME} the eviction policy is in place, "
                          "could you take another look?")])[0]
    event["id"] = f"E_notify_{now}"
    event["actor_avatar_url"] = url("example-chen")
    return {"cmd": "dev_ingest", "account": ME, "ingest": {"prs": [pr], "events": [event]}}
