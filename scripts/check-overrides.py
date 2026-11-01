#!/usr/bin/env python3
"""Checks overrides/community-overrides.json: the shape, the IDs, and that every feed is real.

Usage: python3 scripts/check-overrides.py overrides/community-overrides.json

Runs in CI on every change to the file (.github/workflows/overrides.yml). Exits non-zero with a
plain list of problems. Uses only the standard library; set GH_TOKEN to lift GitHub's rate limit.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

BUNDLE_ID = re.compile(r"^[A-Za-z0-9-]+(\.[A-Za-z0-9_-]+)+$")
CASK_TOKEN = re.compile(r"^[a-z0-9][a-z0-9+.@-]*$")
GITHUB_REPO = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
USER_AGENT = "Burnish-community-check (+https://github.com/EnigmaticZee/Burnish)"


def fetch(url, headers=None):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, **(headers or {})})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.status, response.read(200_000)


def check(path):
    problems = []
    try:
        data = json.loads(open(path, encoding="utf-8").read())
    except (OSError, ValueError) as error:
        return [f"not valid JSON: {error}"]
    if data.get("schema") != 1:
        problems.append('"schema" must be 1')

    overrides = data.get("overrides", {})
    if not isinstance(overrides, dict):
        problems.append('"overrides" must be an object')
        overrides = {}
    for bundle_id, token in overrides.items():
        if not BUNDLE_ID.match(bundle_id):
            problems.append(f"{bundle_id}: not a bundle ID")
        if token is not None and not (isinstance(token, str) and CASK_TOKEN.match(token)):
            problems.append(f"{bundle_id}: cask token must be lowercase like `some-app`, or null")

    feeds = data.get("feeds", {})
    if not isinstance(feeds, dict):
        problems.append('"feeds" must be an object')
        feeds = {}
    for bundle_id, feed in feeds.items():
        if not BUNDLE_ID.match(bundle_id):
            problems.append(f"{bundle_id}: not a bundle ID")
        if not isinstance(feed, dict) or set(feed) - {"sparkle", "github"} or len(feed) != 1:
            problems.append(f'{bundle_id}: a feed is exactly one of {{"sparkle": url}} or {{"github": "owner/name"}}')
            continue
        if "sparkle" in feed:
            problems += check_sparkle(bundle_id, feed["sparkle"])
        else:
            problems += check_github(bundle_id, feed["github"])
    return problems


def check_sparkle(bundle_id, url):
    if not isinstance(url, str) or not url.startswith("https://"):
        return [f"{bundle_id}: a Sparkle feed must be an https:// address"]
    try:
        status, body = fetch(url)
    except (urllib.error.URLError, OSError) as error:
        return [f"{bundle_id}: {url} couldn't be fetched ({error})"]
    text = body.decode("utf-8", "replace")
    if SPARKLE_NS not in text:
        return [f"{bundle_id}: {url} isn't a Sparkle appcast (no sparkle namespace)"]
    if "<item" not in text:
        return [f"{bundle_id}: {url} lists no items"]
    return []


def check_github(bundle_id, repo):
    if not isinstance(repo, str) or not GITHUB_REPO.match(repo):
        return [f'{bundle_id}: a GitHub feed is "owner/name"']
    headers = {"Accept": "application/vnd.github+json"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GH_TOKEN']}"
    try:
        fetch(f"https://api.github.com/repos/{repo}", headers)
    except urllib.error.HTTPError as error:
        return [f"{bundle_id}: github.com/{repo} answered {error.code}"]
    except (urllib.error.URLError, OSError) as error:
        return [f"{bundle_id}: github.com/{repo} couldn't be reached ({error})"]
    return []


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    found = check(sys.argv[1])
    for problem in found:
        print(f"- {problem}")
    if found:
        sys.exit(1)
    print("Community file looks good")
