"""Cherry's release tooling (docs/releasing.md): versions, build stamps, release
notes and the Sparkle appcast. Scripts/cherry-release is its command line, and
the release scripts (release-plan, publish-appcast, promote-release, ...) call
that, never this module. Stdlib only, Python 3.9 or later, on macOS and Linux;
only `appcast item` needs macOS (sign_update and Scripts/sparkle-key.swift).

Versions are YYYY.MM.DD.N (the UTC day, N counting that day's releases), tags
vV-pre and vV, and a build is <YYYYMMDDHHMMSS>.<rev7>: CFBundleVersion, which
Sparkle (sparkle:version) and cherry-host's handover order builds by.

The appcast is one RSS feed with pre-release items (<sparkle:channel>
prerelease</sparkle:channel>) and stable items (no channel), one item per
version, newest first, and the builds taken out of it in <cherry:pulled
version="V">BUILD</cherry:pulled> entries, which Sparkle ignores and Cherry's
StagedUpdateWatch reads. Every writer rebuilds the feed from its items, so the
output depends only on what the feed holds, never on the order of the merges.
"""

import argparse
import base64
import calendar
import datetime
import email.utils
import html
import json
import os
import plistlib
import re
import subprocess
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPOSITORY = SCRIPTS.parent

PRE_TAG = r'^v(\d{4})\.(\d{2})\.(\d{2})\.([1-9]\d*)-pre$'
STABLE_TAG = r'^v(\d{4})\.(\d{2})\.(\d{2})\.([1-9]\d*)$'
BUILD = r'^\d{14}\.[0-9a-f]{7}$'
VERSION = r'^(\d{4})\.(\d{2})\.(\d{2})\.([1-9]\d*)$'
DAY = r'^(\d{4})\.(\d{2})\.(\d{2})$'
REPO = r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CHERRY_NS = "https://updates.cherry.patrick.wtf/xmlns/appcast"
NAMESPACES = (("cherry", CHERRY_NS), ("sparkle", SPARKLE_NS))
for _prefix, _uri in NAMESPACES:
    ET.register_namespace(_prefix, _uri)

PRERELEASE_CHANNEL = "prerelease"
# What XML 1.0 has no place for: C0 controls besides tab, newline and carriage
# return, surrogates (undecodable bytes), U+FFFE and U+FFFF. ElementTree
# writes them as they are, and no parser reads the result back.
XML_INVALID = re.compile(r'[^\t\n\r\x20-\ud7ff\ue000-\ufffd\U00010000-\U0010ffff]')
NOTES_HTML_CAP = 50
NOTES_MARKDOWN_CAP = 100
MINIMUM_MACOS_TEXT = "requires macOS 26 or later"


class ReleaseError(Exception):
    """A refusal with its message; `status` is the exit status (2: usage)."""

    def __init__(self, message, status=1):
        super().__init__(message)
        self.status = status


def warn(message):
    print(f"warning: {message}", file=sys.stderr)


# -- Configuration -------------------------------------------------------------

CONF_LINE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')


def conf_path(path=None):
    if path:
        return Path(path)
    override = os.environ.get("CHERRY_RELEASE_CONF")
    return Path(override) if override else REPOSITORY / "Packaging" / "release.conf"


def read_conf(path=None):
    """Packaging/release.conf (or CHERRY_RELEASE_CONF) as a dict. Like the
    shell scripts' `sed -n "s/^KEY=//p" | tail -n 1`: KEY=value lines, the
    last one of a key wins, anything else is ignored."""
    location = conf_path(path)
    try:
        text = location.read_text(encoding="utf-8")
    except OSError as error:
        raise ReleaseError(f"cannot read the release configuration {location}: {error.strerror}")
    values = {}
    for line in text.splitlines():
        match = CONF_LINE.match(line.rstrip("\r"))
        if match:
            values[match.group(1)] = match.group(2)
    return values


def conf_value(conf, key, default=None):
    value = conf.get(key, "")
    if value:
        return value
    if default is not None:
        return default
    raise ReleaseError(f"{conf_path()} has no {key}")


def conf_int(conf, key, default):
    value = conf.get(key, "")
    if not value:
        return default
    if not re.match(r'^\d+$', value):
        raise ReleaseError(f"{key}={value} in {conf_path()} is not a number")
    return int(value)


# -- Versions, tags and builds -------------------------------------------------

def _date_parts(year, month, day):
    try:
        datetime.date(int(year), int(month), int(day))
    except ValueError:
        return None
    return int(year), int(month), int(day)


def parse_version(text):
    """(year, month, day, n) of a version YYYY.MM.DD.N, else None."""
    match = re.match(VERSION, text or "")
    if not match or not _date_parts(*match.group(1, 2, 3)):
        return None
    return tuple(int(part) for part in match.groups())


def parse_tag(tag, kind):
    """(year, month, day, n) of a `kind` ("prerelease" or "stable") tag, else None."""
    match = re.match(PRE_TAG if kind == "prerelease" else STABLE_TAG, tag or "")
    if not match or not _date_parts(*match.group(1, 2, 3)):
        return None
    return tuple(int(part) for part in match.groups())


def parse_versionish(text):
    """A version given as V, vV or vV-pre, as (year, month, day, n), else None."""
    match = re.match(r'^v?(\d{4}\.\d{2}\.\d{2}\.[1-9]\d*)(?:-pre)?$', (text or "").strip())
    return parse_version(match.group(1)) if match else None


def build_time(build):
    """The epoch seconds of a build's stamp, else None."""
    if not re.match(BUILD, build or ""):
        return None
    try:
        moment = datetime.datetime.strptime(build[:14], "%Y%m%d%H%M%S")
    except ValueError:
        return None
    return calendar.timegm(moment.timetuple())


def build_key(build):
    """Sort key: the stamp, then the build string (newest is largest)."""
    return (build[:14], build)


def version_next(day, tags):
    """YYYY.MM.DD.N for `day`: 1 + the largest N of that day's vDAY.N-pre and
    vDAY.N tags, so a gap (a deleted draft, a stray tag) is never reused."""
    match = re.match(DAY, day or "")
    if not match or not _date_parts(*match.groups()):
        raise ReleaseError(f"--date {day!r} is not YYYY.MM.DD", status=2)
    wanted = tuple(int(part) for part in match.groups())
    largest = 0
    for tag in tags:
        tag = tag.strip()
        for kind in ("prerelease", "stable"):
            parts = parse_tag(tag, kind)
            if parts and parts[:3] == wanted:
                largest = max(largest, parts[3])
    return f"{day}.{largest + 1}"


def version_newest(kind, tags):
    """The newest `kind` tag (by year, month, day, N) among `tags`, or ""."""
    best = None
    for tag in tags:
        tag = tag.strip()
        parts = parse_tag(tag, kind)
        if parts and (best is None or parts > best[0]):
            best = (parts, tag)
    return best[1] if best else ""


def version_compare(first, second):
    a, b = parse_versionish(first), parse_versionish(second)
    for text, parts in ((first, a), (second, b)):
        if parts is None:
            raise ReleaseError(f"{text!r} is not YYYY.MM.DD.N (or vYYYY.MM.DD.N[-pre])", status=2)
    return (a > b) - (a < b)


def stamp(sha, now, prev_build=None):
    """(build_id, day): stamp = max(now, previous build's stamp + 1 s), in UTC,
    so builds never go backwards; the rev is the SHA's first 7 characters."""
    sha = (sha or "").strip().lower()
    if not re.match(r'^[0-9a-f]{7,64}$', sha):
        raise ReleaseError(f"--sha {sha!r} is not a commit SHA", status=2)
    if not re.match(r'^\d+$', str(now).strip()):
        raise ReleaseError(f"--now {now!r} is not epoch seconds", status=2)
    moment = int(str(now).strip())
    if prev_build:
        previous = build_time(prev_build.strip())
        if previous is None:
            warn(f"ignoring the previous build {prev_build!r}: not <YYYYMMDDHHMMSS>.<rev7>")
        else:
            moment = max(moment, previous + 1)
    when = datetime.datetime.fromtimestamp(moment, datetime.timezone.utc)
    return f"{when.strftime('%Y%m%d%H%M%S')}.{sha[:7]}", when.strftime("%Y.%m.%d")


# -- Release notes -------------------------------------------------------------

def xml_text(text):
    """`text` without the characters XML 1.0 does not allow."""
    return XML_INVALID.sub("", text)


def parse_log(text):
    """[(sha, subject)] from `git log --format='%H%x09%s'`. git prints a
    subject as it was written, so one can hold control characters (an ESC
    pasted from a terminal); they are dropped, so the appcast item stays
    well-formed."""
    entries = []
    for line in text.splitlines():
        sha, separator, subject = line.partition("\t")
        sha = sha.strip()
        if separator and re.match(r'^[0-9a-fA-F]{7,64}$', sha):
            entries.append((sha.lower(), xml_text(subject).strip()))
    return entries


def notes_html(repo, entries):
    """The appcast item's description: a list of the commits, at most 50."""
    if not entries:
        return "<p>No changes besides merges.</p>"
    rows = []
    for sha, subject in entries[:NOTES_HTML_CAP]:
        link = f'<a href="https://github.com/{repo}/commit/{sha}">{sha[:7]}</a>'
        rows.append(f"<li>{html.escape(subject, quote=True)} ({link})</li>")
    text = "<ul>" + "".join(rows) + "</ul>"
    if len(entries) > NOTES_HTML_CAP:
        text += f"<p>…and {len(entries) - NOTES_HTML_CAP} more changes.</p>"
    return text


def _markdown_text(subject):
    # A subject is shown as written (code spans and emphasis included), but
    # never as raw HTML: GitHub would drop "<Tag>" from the page.
    return subject.replace("\\", "\\\\").replace("<", "\\<")


def notes_markdown(repo, tag, prev_tag, build, entries):
    """The GitHub release body: the commits (at most 100), the compare link
    when there is a previous tag, then the build."""
    parts = []
    if entries:
        lines = [f"- {_markdown_text(subject)} ([{sha[:7]}](https://github.com/{repo}/commit/{sha}))"
                 for sha, subject in entries[:NOTES_MARKDOWN_CAP]]
        parts.append("\n".join(lines))
        if len(entries) > NOTES_MARKDOWN_CAP:
            parts.append(f"…and {len(entries) - NOTES_MARKDOWN_CAP} more changes.")
    else:
        parts.append("No changes besides merges.")
    if prev_tag:
        parts.append(f"**Full changes:** [{prev_tag}...{tag}](https://github.com/{repo}/compare/{prev_tag}...{tag})")
    parts.append(f"Build `{build}` · {MINIMUM_MACOS_TEXT}")
    return "\n\n".join(parts) + "\n"


# -- Appcast XML ---------------------------------------------------------------

def sparkle(name):
    return f"{{{SPARKLE_NS}}}{name}"


def cherry(name):
    return f"{{{CHERRY_NS}}}{name}"


def parse_xml(data, what):
    try:
        return ET.fromstring(data)
    except ET.ParseError as error:
        raise ReleaseError(f"{what} is not well-formed XML: {error}")


def read_input(path, what):
    """Bytes of `path`, or of standard input for "-"."""
    if path == "-":
        return sys.stdin.buffer.read()
    try:
        return Path(path).read_bytes()
    except OSError as error:
        raise ReleaseError(f"cannot read {what} {path}: {error.strerror}")


def serialize(root):
    """Deterministic bytes: two-space indentation, an XML declaration, and on
    a feed both namespaces declared on <rss>, in prefix order, whether used
    or not."""
    ET.indent(root, space="  ")
    body = ET.tostring(root, encoding="unicode")
    if root.tag == "rss":
        end = body.index(">")
        start_tag, rest = body[:end], body[end:]
        declared = dict(re.findall(r' xmlns:([A-Za-z_][\w.-]*)="([^"]*)"', start_tag))
        start_tag = re.sub(r' xmlns:[A-Za-z_][\w.-]*="[^"]*"', "", start_tag)
        declared.update(dict(NAMESPACES))
        declarations = "".join(f' xmlns:{prefix}="{uri}"' for prefix, uri in sorted(declared.items()))
        body = "<rss" + declarations + start_tag[len("<rss"):] + rest
    return ('<?xml version="1.0" encoding="utf-8"?>\n' + body + "\n").encode("utf-8")


def write_output(path, data):
    path = Path(path)
    if str(path) == "-":
        sys.stdout.buffer.write(data)
        return
    partial = path.with_name(f".{path.name}.partial-{os.getpid()}")
    try:
        partial.write_bytes(data)
        os.replace(partial, path)
    except OSError as error:
        try:
            partial.unlink()
        except OSError:
            pass
        raise ReleaseError(f"cannot write {path}: {error.strerror}")


def _text(element, tag):
    child = element.find(tag)
    if child is None or child.text is None:
        return ""
    return child.text.strip()


class Item:
    """One <item>: its build (sparkle:version), version (shortVersionString),
    channel and enclosure."""

    def __init__(self, element):
        self.element = element
        enclosure = element.find("enclosure")
        self.enclosure = enclosure
        attributes = enclosure.attrib if enclosure is not None else {}
        self.build = _text(element, sparkle("version")) or attributes.get(sparkle("version"), "").strip()
        self.version = (_text(element, sparkle("shortVersionString"))
                        or attributes.get(sparkle("shortVersionString"), "").strip())
        self.channel = _text(element, sparkle("channel"))
        self.url = attributes.get("url", "").strip()
        self.length = attributes.get("length", "").strip()
        self.signature = attributes.get(sparkle("edSignature"), "").strip()

    @property
    def is_stable(self):
        return not self.channel

    @property
    def key(self):
        return build_key(self.build)

    def problems(self):
        found = []
        if not re.match(BUILD, self.build):
            found.append(f"sparkle:version {self.build!r} is not <YYYYMMDDHHMMSS>.<rev7>")
        if parse_version(self.version) is None:
            found.append(f"sparkle:shortVersionString {self.version!r} is not YYYY.MM.DD.N")
        if self.channel not in ("", PRERELEASE_CHANNEL):
            found.append(f"sparkle:channel {self.channel!r} is neither empty nor {PRERELEASE_CHANNEL}")
        if self.enclosure is None:
            found.append("there is no enclosure")
            return found
        if not self.url.startswith("https://"):
            found.append(f"the enclosure url {self.url!r} is not https")
        if not re.match(r'^[1-9]\d*$', self.length):
            found.append(f"the enclosure length {self.length!r} is not a positive number")
        try:
            signature = base64.b64decode(self.signature, validate=True)
        except ValueError:
            signature = b""
        if len(signature) != 64:
            found.append("the enclosure has no sparkle:edSignature (64 bytes of base64)")
        return found

    def describe(self):
        return f"{self.version or '?'} ({self.build or '?'})"

    def same_release(self, other):
        return self.build == other.build or self.version == other.version


def load_item(path):
    """The <item> of an item file (a bare <item>, or a feed holding one)."""
    root = parse_xml(read_input(path, "the item"), f"the item {path}")
    if root.tag == "item":
        element = root
    else:
        found = root.findall("./channel/item")
        if len(found) != 1:
            raise ReleaseError(f"{path} holds {len(found)} items, not one")
        element = found[0]
    item = Item(element)
    problems = item.problems()
    if problems:
        raise ReleaseError(f"the item {path} is not a release item: " + "; ".join(problems))
    return item


class Feed:
    """An appcast: the channel's own elements (title, link, ...), the pulled
    entries and the items."""

    def __init__(self, root, what="the appcast"):
        if root.tag != "rss" or root.find("channel") is None:
            raise ReleaseError(f"{what} is not an RSS feed with a <channel>")
        self.root = root
        self.channel = root.find("channel")
        self.header = [child for child in self.channel if child.tag not in ("item", cherry("pulled"))]
        self.pulled = [child for child in self.channel if child.tag == cherry("pulled")]
        self.items = [Item(child) for child in self.channel if child.tag == "item"]

    @classmethod
    def load(cls, path, what="the appcast"):
        return cls(parse_xml(read_input(path, what), f"{what} {path}"), what)

    @classmethod
    def empty(cls, repo, title="Cherry"):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        for tag, text in (("title", title), ("link", f"https://github.com/{repo}"),
                          ("description", f"{title} updates"), ("language", "en")):
            ET.SubElement(channel, tag).text = text
        return cls(root)

    def pulled_builds(self):
        return {(entry.text or "").strip() for entry in self.pulled}

    def is_pulled(self, build_or_version):
        return any((entry.text or "").strip() == build_or_version
                   or entry.get("version", "") == build_or_version for entry in self.pulled)

    def add_pulled(self, build, version=""):
        if build in self.pulled_builds():
            return
        entry = ET.Element(cherry("pulled"))
        if version:
            entry.set("version", version)
        entry.text = build
        self.pulled.append(entry)

    def serialize(self):
        """The feed rebuilt: its own elements, the pulled entries by build,
        then the items newest first (by stamp, ties by the build string)."""
        for child in list(self.channel):
            self.channel.remove(child)
        for child in self.header:
            self.channel.append(child)
        for entry in sorted(self.pulled, key=lambda e: ((e.text or "").strip(), e.get("version", ""))):
            self.channel.append(entry)
        for item in sorted(self.items, key=lambda i: i.key, reverse=True):
            self.channel.append(item.element)
        return serialize(self.root)

    def check_items(self):
        problems = []
        for item in self.items:
            problems += [f"item {item.describe()}: {problem}" for problem in item.problems()]
        return problems


def merge(feed, item, keep_prereleases, keep_stable):
    """Add `item` to `feed` (in place). One item per version: a stable item
    takes the place of the pre-release item of its build or version; a
    pre-release item never replaces a stable one and otherwise replaces the
    pre-release item of its version (of two different builds of one version,
    the newer stays). A pulled build is never added. Then each channel is
    pruned to its newest items. Returns False when `item` was refused."""
    problems = feed.check_items()
    if problems:
        raise ReleaseError("the appcast has malformed items: " + "; ".join(problems))
    if feed.is_pulled(item.build):
        warn(f"{item.describe()} was pulled from the appcast; not adding it "
             "(Actions › Appcast › restore lets it back in)")
        return False

    def rank(candidate):
        return (candidate.is_stable, candidate.key)

    rivals = [existing for existing in feed.items if existing.same_release(item)]
    if any(rank(existing) > rank(item) for existing in rivals):
        winner = max(rivals, key=rank)
        if not winner.is_stable or item.is_stable:
            warn(f"{item.describe()} is older than {winner.describe()} in the appcast; not adding it")
        else:
            print(f"note: {item.describe()} is already a stable item; the pre-release item is not added",
                  file=sys.stderr)
    else:
        feed.items = [existing for existing in feed.items if not existing.same_release(item)] + [item]
    prereleases = sorted((i for i in feed.items if not i.is_stable), key=lambda i: i.key, reverse=True)
    stable = sorted((i for i in feed.items if i.is_stable), key=lambda i: i.key, reverse=True)
    feed.items = prereleases[:keep_prereleases] + stable[:keep_stable]
    return True


def classify_argument(text):
    text = (text or "").strip()
    if re.match(BUILD, text):
        return "build", text
    if parse_version(text):
        return "version", text
    raise ReleaseError(f"{text!r} is neither a version (YYYY.MM.DD.N) nor a build (<YYYYMMDDHHMMSS>.<rev7>)",
                       status=2)


def remove(feed, argument):
    """Take every item of a version or build out of `feed` and keep its build
    out (<cherry:pulled>). A build no item has is pulled anyway; a version no
    item has is refused unless it is pulled already."""
    kind, value = classify_argument(argument)
    matched = [item for item in feed.items if item.build == value or item.version == value]
    if not matched:
        if kind == "build":
            feed.add_pulled(value)
            return
        if feed.is_pulled(value):
            print(f"note: {value} is already pulled", file=sys.stderr)
            return
        raise ReleaseError(f"the appcast has no item of version {value}")
    feed.items = [item for item in feed.items if item not in matched]
    for item in matched:
        feed.add_pulled(item.build, item.version)


def restore(feed, argument):
    """Let a pulled version or build back in: remove its <cherry:pulled>
    entry. It does not add the item back; the next merge of it does."""
    _, value = classify_argument(argument)
    kept = [entry for entry in feed.pulled
            if (entry.text or "").strip() != value and entry.get("version", "") != value]
    if len(kept) == len(feed.pulled):
        raise ReleaseError(f"{value} is not pulled in the appcast")
    feed.pulled = kept


def check(feed):
    """Every problem of a feed, as text; empty when it is well-formed."""
    problems = feed.check_items()
    builds, versions = set(), set()
    for item in feed.items:
        if item.build in builds:
            problems.append(f"build {item.build} has more than one item")
        if item.version in versions:
            problems.append(f"version {item.version} has more than one item")
        builds.add(item.build)
        versions.add(item.version)
    keys = [item.key for item in feed.items if re.match(BUILD, item.build)]
    if keys != sorted(keys, reverse=True):
        problems.append("the items are not newest first")
    for entry in feed.pulled:
        build = (entry.text or "").strip()
        version = entry.get("version")
        if not re.match(BUILD, build):
            problems.append(f"the pulled entry {build!r} is not a build")
        if version is not None and parse_version(version) is None:
            problems.append(f"the pulled entry {build} has the version {version!r}, not YYYY.MM.DD.N")
        if build in builds:
            problems.append(f"the pulled build {build} still has an item")
    return problems


# -- Appcast items -------------------------------------------------------------

def release_url(repo, tag):
    return f"https://github.com/{repo}/releases/tag/{tag}"


def download_url(repo, tag, name):
    return f"https://github.com/{repo}/releases/download/{tag}/{name}"


def rfc2822(moment):
    return email.utils.format_datetime(moment.astimezone(datetime.timezone.utc))


def parse_pub_date(text):
    try:
        moment = email.utils.parsedate_to_datetime(text)
    except (TypeError, ValueError):
        moment = None
    if moment is None:
        raise ReleaseError(f"--pub-date {text!r} is not an RFC 2822 date", status=2)
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=datetime.timezone.utc)
    return moment


def check_tag(tag, channel, version):
    expected = f"v{version}-pre" if channel == PRERELEASE_CHANNEL else f"v{version}"
    if tag != expected:
        raise ReleaseError(f"the {channel} tag of {version} is {expected}, not {tag}")


def zip_info_plist(zip_path, app_name):
    name = f"{app_name}.app/Contents/Info.plist"
    try:
        with zipfile.ZipFile(zip_path) as archive:
            data = archive.read(name)
    except KeyError:
        raise ReleaseError(f"{zip_path} has no {name}")
    except (OSError, zipfile.BadZipFile) as error:
        raise ReleaseError(f"cannot read {zip_path}: {error}")
    try:
        info = plistlib.loads(data)
    except Exception as error:  # plistlib raises several types for bad input
        raise ReleaseError(f"{name} in {zip_path} is not a property list: {error}")
    if not isinstance(info, dict):
        raise ReleaseError(f"{name} in {zip_path} is not a dictionary")
    return info


def default_sign_update():
    found = sorted(REPOSITORY.glob(".build/artifacts/*/Sparkle/bin/sign_update"))
    if not found:
        raise ReleaseError("no .build/artifacts/*/Sparkle/bin/sign_update: run `swift package resolve` "
                           "(Sparkle's artifact bundle) or pass --sign-update")
    return str(found[0])


def sign_update(tool, key, path):
    """Sparkle's EdDSA signature of `path`; the key goes on standard input."""
    try:
        result = subprocess.run([tool, "--ed-key-file", "-", "-p", str(path)], input=key + "\n",
                                capture_output=True, text=True)
    except OSError as error:
        raise ReleaseError(f"cannot run {tool}: {error.strerror}")
    output = (result.stdout + result.stderr).replace(key, "<SPARKLE_ED_PRIVATE_KEY>").strip()
    if result.returncode != 0:
        raise ReleaseError(f"sign_update failed ({result.returncode}): {output}")
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    signature = lines[-1] if lines else ""
    try:
        valid = len(base64.b64decode(signature, validate=True)) == 64
    except ValueError:
        valid = False
    if not valid:
        raise ReleaseError(f"sign_update printed no signature: {output}")
    return signature


def verify_signature(public_key, path, signature):
    """Scripts/sparkle-key.swift verify: the signature against the zip's own
    SUPublicEDKey, so a key that does not belong to the app is never shipped."""
    command = ["xcrun", "swift", str(SCRIPTS / "sparkle-key.swift"), "verify", public_key, str(path), signature]
    try:
        result = subprocess.run(command, capture_output=True, text=True)
    except OSError as error:
        raise ReleaseError(f"cannot run xcrun ({error.strerror}): `appcast item` runs on macOS")
    if result.returncode != 0:
        detail = result.stderr.strip()
        raise ReleaseError("SPARKLE_ED_PRIVATE_KEY does not sign for this app's SUPublicEDKey"
                           + (f" ({detail})" if detail else ""))


def make_item(manifest_path, channel, tag, repo, notes_path, conf, sign_tool=None, pub_date=None):
    """The appcast item of a release.json (Scripts/package-release finish):
    checks the zip, signs it with SPARKLE_ED_PRIVATE_KEY and verifies the
    signature against the zip's own SUPublicEDKey."""
    manifest_path = Path(manifest_path)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ReleaseError(f"cannot read the manifest {manifest_path}: {error}")
    if not isinstance(manifest, dict):
        raise ReleaseError(f"{manifest_path} is not a JSON object")
    version = str(manifest.get("version", ""))
    build = str(manifest.get("build", ""))
    zip_name = str(manifest.get("zip", ""))
    zip_length = manifest.get("zip_length")
    minimum = str(manifest.get("minimum_system_version", ""))
    if parse_version(version) is None:
        raise ReleaseError(f"the manifest's version {version!r} is not YYYY.MM.DD.N")
    if not re.match(BUILD, build):
        raise ReleaseError(f"the manifest's build {build!r} is not <YYYYMMDDHHMMSS>.<rev7>")
    if not re.match(r'^[A-Za-z0-9._-]+\.zip$', zip_name):
        raise ReleaseError(f"the manifest's zip {zip_name!r} is not a zip file name")
    if not isinstance(zip_length, int) or isinstance(zip_length, bool) or zip_length <= 0:
        raise ReleaseError(f"the manifest's zip_length {zip_length!r} is not a positive number")
    if not re.match(r'^\d+(\.\d+){0,2}$', minimum):
        raise ReleaseError(f"the manifest's minimum_system_version {minimum!r} is not a macOS version")
    if channel not in (PRERELEASE_CHANNEL, "stable"):
        raise ReleaseError(f"--channel {channel!r} is neither prerelease nor stable", status=2)
    check_tag(tag, channel, version)
    if not re.match(REPO, repo or ""):
        raise ReleaseError(f"--repo {repo!r} is not OWNER/NAME", status=2)

    zip_path = manifest_path.parent / zip_name
    try:
        size = zip_path.stat().st_size
    except OSError as error:
        raise ReleaseError(f"cannot read {zip_path}: {error.strerror}")
    if size != zip_length:
        raise ReleaseError(f"{zip_path} is {size} bytes, but the manifest says {zip_length}")
    app_name = conf_value(conf, "RELEASE_APP_NAME", "Cherry")
    info = zip_info_plist(zip_path, app_name)
    if str(info.get("CFBundleVersion", "")) != build:
        raise ReleaseError(f"the zip's CFBundleVersion is {info.get('CFBundleVersion')!r}, "
                           f"but the manifest's build is {build}")
    if str(info.get("CFBundleShortVersionString", "")) != version:
        raise ReleaseError(f"the zip's CFBundleShortVersionString is "
                           f"{info.get('CFBundleShortVersionString')!r}, but the manifest's version is {version}")
    bundle_id = manifest.get("bundle_identifier")
    if bundle_id and info.get("CFBundleIdentifier") != bundle_id:
        raise ReleaseError(f"the zip's CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, "
                           f"but the manifest says {bundle_id}")
    public_key = str(info.get("SUPublicEDKey", "")).strip()
    if not public_key:
        raise ReleaseError("the zip's Info.plist has no SUPublicEDKey: this build cannot verify updates")

    key = os.environ.get("SPARKLE_ED_PRIVATE_KEY", "").strip()
    if not key:
        raise ReleaseError("SPARKLE_ED_PRIVATE_KEY is not set")
    signature = sign_update(sign_tool or default_sign_update(), key, zip_path)
    verify_signature(public_key, zip_path, signature)

    try:
        notes = Path(notes_path).read_text(encoding="utf-8", errors="replace") if notes_path else ""
    except OSError as error:
        raise ReleaseError(f"cannot read the notes {notes_path}: {error.strerror}")
    notes = xml_text(notes).strip()
    moment = parse_pub_date(pub_date) if pub_date else datetime.datetime.now(datetime.timezone.utc)

    page = release_url(repo, tag)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{app_name} {version}"
    ET.SubElement(item, "link").text = page
    ET.SubElement(item, sparkle("version")).text = build
    ET.SubElement(item, sparkle("shortVersionString")).text = version
    ET.SubElement(item, "pubDate").text = rfc2822(moment)
    ET.SubElement(item, sparkle("minimumSystemVersion")).text = minimum
    if channel == PRERELEASE_CHANNEL:
        ET.SubElement(item, sparkle("channel")).text = PRERELEASE_CHANNEL
    ET.SubElement(item, sparkle("fullReleaseNotesLink")).text = page
    if notes:
        ET.SubElement(item, "description").text = notes
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", download_url(repo, tag, zip_name))
    enclosure.set("length", str(size))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(sparkle("edSignature"), signature)
    return item


def promote_item(item, tag, repo, zip_path=None, now=None):
    """The stable item of a pre-release item: no channel, the links and the
    enclosure on the stable tag, a new pubDate; the same signature and length
    (the same bytes)."""
    if item.is_stable:
        raise ReleaseError(f"{item.describe()} is not a pre-release item")
    if tag != f"v{item.version}":
        raise ReleaseError(f"{tag} is not the stable tag of {item.version} (v{item.version})")
    if not re.match(REPO, repo or ""):
        raise ReleaseError(f"--repo {repo!r} is not OWNER/NAME", status=2)
    if zip_path is not None:
        try:
            size = Path(zip_path).stat().st_size
        except OSError as error:
            raise ReleaseError(f"cannot read {zip_path}: {error.strerror}")
        if str(size) != item.length:
            raise ReleaseError(f"{zip_path} is {size} bytes, but the item's enclosure says {item.length}")
    element = item.element
    for channel in element.findall(sparkle("channel")):
        element.remove(channel)
    page = release_url(repo, tag)
    for tag_name in ("link", sparkle("fullReleaseNotesLink")):
        for child in element.findall(tag_name):
            child.text = page
    name = item.url.rstrip("/").rsplit("/", 1)[-1]
    item.enclosure.set("url", download_url(repo, tag, name))
    moment = now or datetime.datetime.now(datetime.timezone.utc)
    dates = element.findall("pubDate") or [ET.SubElement(element, "pubDate")]
    for date in dates:
        date.text = rfc2822(moment)
    return element


def item_field(item, field):
    return {"version": item.build, "short-version": item.version, "url": item.url,
            "length": item.length, "channel": item.channel}[field]


# -- Command line --------------------------------------------------------------

def read_tags():
    return [line.strip() for line in sys.stdin.read().splitlines() if line.strip()]


def run_version(arguments):
    if arguments.action == "next":
        print(version_next(arguments.date, read_tags()))
    elif arguments.action == "newest":
        print(version_newest(arguments.kind, read_tags()))
    elif arguments.action == "check":
        return 0 if parse_version(arguments.version) else 1
    elif arguments.action == "compare":
        print(version_compare(arguments.first, arguments.second))
    return 0


def readable_item(data):
    """`data` once it parses back as a release item: an item nothing can read
    fails here, before anything is published."""
    problems = Item(parse_xml(data, "the item made")).problems()
    if problems:
        raise ReleaseError("the item made is not a release item: " + "; ".join(problems))
    return data


def run_appcast(arguments):
    conf = read_conf()
    action = arguments.action
    if action == "empty":
        repo = arguments.repo or conf_value(conf, "GITHUB_REPOSITORY")
        write_output(arguments.output, Feed.empty(repo, conf_value(conf, "RELEASE_APP_NAME", "Cherry")).serialize())
    elif action == "item":
        item = make_item(arguments.manifest, arguments.channel, arguments.tag, arguments.repo, arguments.notes,
                         conf, sign_tool=arguments.sign_update, pub_date=arguments.pub_date)
        write_output(arguments.output, readable_item(serialize(item)))
    elif action == "promote":
        element = promote_item(load_item(arguments.item), arguments.tag, arguments.repo, arguments.zip)
        write_output(arguments.output, readable_item(serialize(element)))
    elif action == "merge":
        if arguments.feed == "-":
            feed = Feed.empty(conf_value(conf, "GITHUB_REPOSITORY"), conf_value(conf, "RELEASE_APP_NAME", "Cherry"))
            original = None
        else:
            original = read_input(arguments.feed, "the appcast")
            feed = Feed(parse_xml(original, f"the appcast {arguments.feed}"))
        keep_prereleases = arguments.keep_prereleases
        if keep_prereleases is None:
            keep_prereleases = conf_int(conf, "APPCAST_KEEP_PRERELEASES", 20)
        keep_stable = arguments.keep_stable
        if keep_stable is None:
            keep_stable = conf_int(conf, "APPCAST_KEEP_STABLE", 10)
        if keep_prereleases < 0 or keep_stable < 0:
            raise ReleaseError("--keep-prereleases and --keep-stable cannot be negative", status=2)
        added = merge(feed, load_item(arguments.item), keep_prereleases, keep_stable)
        # A refused (pulled) build leaves the feed exactly as it was.
        write_output(arguments.output, feed.serialize() if added or original is None else original)
    elif action in ("remove", "restore"):
        feed = Feed.load(arguments.feed)
        (remove if action == "remove" else restore)(feed, arguments.target)
        write_output(arguments.output, feed.serialize())
    elif action == "check":
        problems = check(Feed.load(arguments.feed))
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1 if problems else 0
    elif action == "is-pulled":
        try:
            feed = Feed.load(arguments.feed)
        except ReleaseError as error:
            raise ReleaseError(str(error), status=2)
        return 0 if feed.is_pulled(arguments.build.strip()) else 1
    elif action == "field":
        print(item_field(load_item(arguments.item), arguments.field))
    return 0


def run_notes(arguments):
    if not re.match(REPO, arguments.repo or ""):
        raise ReleaseError(f"--repo {arguments.repo!r} is not OWNER/NAME", status=2)
    # Bytes git prints that are not UTF-8 become U+FFFD, never an error.
    entries = parse_log(sys.stdin.buffer.read().decode("utf-8", errors="replace"))
    write_output(arguments.md, notes_markdown(arguments.repo, arguments.tag, arguments.prev_tag,
                                              arguments.build, entries).encode("utf-8"))
    write_output(arguments.html, (notes_html(arguments.repo, entries) + "\n").encode("utf-8"))
    return 0


def parser():
    top = argparse.ArgumentParser(prog="cherry-release", description="Cherry's release tooling (docs/releasing.md).")
    commands = top.add_subparsers(dest="command", metavar="COMMAND")
    commands.required = True

    conf = commands.add_parser("conf", help="print a value of Packaging/release.conf")
    conf.add_argument("key")

    version = commands.add_parser("version", help="versions and tags")
    actions = version.add_subparsers(dest="action", metavar="ACTION")
    actions.required = True
    action = actions.add_parser("next", help="tags on stdin: the next YYYY.MM.DD.N of a day")
    action.add_argument("--date", required=True)
    action = actions.add_parser("newest", help="tags on stdin: the newest tag of a kind, or an empty line")
    action.add_argument("--kind", required=True, choices=("prerelease", "stable"))
    action = actions.add_parser("check", help="exit 0 when VERSION is YYYY.MM.DD.N")
    action.add_argument("version")
    action = actions.add_parser("compare", help="print -1, 0 or 1")
    action.add_argument("first")
    action.add_argument("second")

    command = commands.add_parser("stamp", help="the build id of a commit")
    command.add_argument("--sha", required=True)
    command.add_argument("--now", required=True)
    command.add_argument("--prev-build")

    command = commands.add_parser("notes", help="`git log --no-merges --format='%%H%%x09%%s'` on stdin: release notes")
    command.add_argument("--repo", required=True)
    command.add_argument("--tag", required=True)
    command.add_argument("--prev-tag")
    command.add_argument("--build", required=True)
    command.add_argument("--md", required=True)
    command.add_argument("--html", required=True)

    appcast = commands.add_parser("appcast", help="the Sparkle appcast")
    actions = appcast.add_subparsers(dest="action", metavar="ACTION")
    actions.required = True
    action = actions.add_parser("empty", help="a feed with no items")
    action.add_argument("--repo")
    action.add_argument("--output", required=True)
    action = actions.add_parser("item", help="the signed item of a release (key in $SPARKLE_ED_PRIVATE_KEY)")
    action.add_argument("--manifest", required=True)
    action.add_argument("--channel", required=True, choices=(PRERELEASE_CHANNEL, "stable"))
    action.add_argument("--tag", required=True)
    action.add_argument("--repo", required=True)
    action.add_argument("--notes", required=True)
    action.add_argument("--sign-update")
    action.add_argument("--pub-date")
    action.add_argument("--output", required=True)
    action = actions.add_parser("promote", help="the stable item of a pre-release item")
    action.add_argument("item")
    action.add_argument("--tag", required=True)
    action.add_argument("--repo", required=True)
    action.add_argument("--zip")
    action.add_argument("--output", required=True)
    action = actions.add_parser("merge", help="add an item to a feed (FEED - starts from an empty feed)")
    action.add_argument("feed")
    action.add_argument("item")
    action.add_argument("--output", required=True)
    action.add_argument("--keep-prereleases", type=int)
    action.add_argument("--keep-stable", type=int)
    for name, text in (("remove", "take a version or build out and keep it out"),
                       ("restore", "let a pulled version or build back in")):
        action = actions.add_parser(name, help=text)
        action.add_argument("feed")
        action.add_argument("target", metavar="VERSION|BUILD")
        action.add_argument("--output", required=True)
    action = actions.add_parser("check", help="exit 1 naming each problem of a feed")
    action.add_argument("feed")
    action = actions.add_parser("is-pulled", help="exit 0 when a build is pulled (FEED - reads stdin)")
    action.add_argument("feed")
    action.add_argument("build")
    action = actions.add_parser("field", help="print a field of an item")
    action.add_argument("item")
    action.add_argument("field", choices=("version", "short-version", "url", "length", "channel"))
    return top


def main(argv=None):
    arguments = parser().parse_args(argv)
    try:
        if arguments.command == "conf":
            conf = read_conf()
            if arguments.key not in conf:
                raise ReleaseError(f"{conf_path()} has no {arguments.key}")
            print(conf[arguments.key])
            return 0
        if arguments.command == "version":
            return run_version(arguments)
        if arguments.command == "stamp":
            build_id, day = stamp(arguments.sha, arguments.now, arguments.prev_build)
            print(f"build_id={build_id}")
            print(f"day={day}")
            return 0
        if arguments.command == "notes":
            return run_notes(arguments)
        return run_appcast(arguments)
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return error.status
