"""Tests for Cherry's release tooling (docs/releasing.md): Scripts/cherry-release
(cherry_release.py), Scripts/sparkle-key.swift, Scripts/sign-app and the
release shell scripts, Scripts/release-setup included.

Nothing here reaches the network, GitHub, R2 or a keychain: the scripts run
with fake gh, curl, aws, sign_update, xcrun, security, xcode-select, codesign,
xattr and generate_keys (small Python scripts written into a temporary bin
directory first on PATH, generate_keys into a copy of the repository's
.build/artifacts) that answer from a JSON state file and record every call.
Every test runs on Linux as well as macOS, except
SparkleKeyTests, which need macOS (xcrun swift, CryptoKit). The fake gh
evaluates --jq with jq, which macOS 15 and later and GitHub's runners have.
Run: python3 Scripts/test_cherry_release.py
"""

import base64
import contextlib
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cherry_release as release  # noqa: E402

REPOSITORY = Path(__file__).resolve().parent.parent
SCRIPTS = REPOSITORY / "Scripts"
CLI = SCRIPTS / "cherry-release"
REPO = "patrick91/cherry"
FEED_URL = "https://updates.cherry.patrick.wtf/appcast.xml"

FIXTURE_CONF = """\
# A test copy of Packaging/release.conf.
RELEASE_BUNDLE_ID=dev.patrick.cherry
RELEASE_APP_NAME=Cherry
TEAM_ID=Z7Q27G3R62
GITHUB_REPOSITORY=patrick91/cherry
SPARKLE_FEED_URL=https://updates.cherry.patrick.wtf/appcast.xml
SPARKLE_PUBLIC_ED_KEY={public_key}
SPARKLE_KEYCHAIN_ACCOUNT=dev.patrick.cherry
R2_BUCKET=cherry-updates
APPCAST_KEEP_PRERELEASES=20
APPCAST_KEEP_STABLE=10
"""

# Variables a CI step or the developer's shell may carry that must never
# reach a script under test.
SCRUBBED_PREFIXES = ("GITHUB_", "GH_", "AWS_", "CLOUDFLARE_", "R2_", "SPARKLE_", "DEVELOPER_ID_", "NOTARY_",
                     "CHERRY_", "RUNNER_", "GIT_")
SCRUBBED = {"RELEASES_PAUSED", "DRY_RUN", "APPCAST_SECRETS", "ACTIONS_RUNTIME_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_TOKEN"}


def fake_public(key):
    """The fake key pair: a "public key" is base64 of 32 bytes, as Sparkle's."""
    return base64.b64encode(hashlib.sha256(key.encode()).digest()).decode()


def fake_signature(public, data):
    return base64.b64encode(hashlib.sha512(public.encode() + data).digest()).decode()


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# -- Fakes ---------------------------------------------------------------------

FAKES = r'''
import base64, fnmatch, hashlib, json, os, re, shutil, subprocess, sys
from pathlib import Path

STATE = Path(os.environ["FAKE_STATE"])
LOG = Path(os.environ["FAKE_LOG"])


def load():
    return json.loads(STATE.read_text())


def save(state):
    STATE.write_text(json.dumps(state, indent=1))


def log(entry):
    with LOG.open("a") as handle:
        handle.write(json.dumps(entry) + "\n")


def die(message, status=1):
    sys.stderr.write(message + "\n")
    sys.exit(status)


def fake_public(key):
    return base64.b64encode(hashlib.sha256(key.encode()).digest()).decode()


def fake_signature(public, data):
    return base64.b64encode(hashlib.sha512(public.encode() + data).digest()).decode()


# gh ---------------------------------------------------------------------------

def typed(value):
    if value in ("true", "false"):
        return value == "true"
    if re.match(r"^-?\d+$", value):
        return int(value)
    if value.startswith("@"):
        return Path(value[1:]).read_text()
    return value


def emit(data, jq, raw=False):
    if raw:
        sys.stdout.write(data)
        return
    text = json.dumps(data)
    if jq is None:
        sys.stdout.write(text + "\n")
        return
    if not shutil.which("jq"):
        die("fake gh: --jq needs jq on PATH", 99)
    result = subprocess.run(["jq", "-r", jq], input=text, capture_output=True, text=True)
    if result.returncode != 0:
        die("fake gh: jq failed on " + jq + ": " + result.stderr, 99)
    sys.stdout.write(result.stdout)


def not_found():
    die("gh: Not Found (HTTP 404)")


def public_release(release):
    return {key: value for key, value in release.items() if key != "assets"}


def release_by_tag(state, tag, published_only=True):
    for release in state["releases"]:
        if release["tag_name"] == tag and (not published_only or not release["draft"]):
            return release
    return None


def gh_api(args):
    method, headers, fields, jq, endpoint = None, [], {}, None, None
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("-X", "--method"):
            method = args[index + 1]; index += 2
        elif arg in ("-H", "--header"):
            headers.append(args[index + 1]); index += 2
        elif arg in ("-f", "--raw-field"):
            key, _, value = args[index + 1].partition("="); fields[key] = value; index += 2
        elif arg in ("-F", "--field"):
            key, _, value = args[index + 1].partition("="); fields[key] = typed(value); index += 2
        elif arg in ("--jq", "-q"):
            jq = args[index + 1]; index += 2
        elif arg == "--paginate":
            index += 1
        elif arg.startswith("-"):
            die("fake gh api: unknown flag " + arg, 99)
        else:
            endpoint = arg; index += 1
    method = method or ("POST" if fields else "GET")
    path = endpoint.partition("?")[0]
    if path == "user" and method == "GET":
        state = load()
        if not state.get("logged_in", True):
            die("HTTP 401: Bad credentials (https://api.github.com/user)", 1)
        return emit({"login": "release-tester"}, jq)
    match = re.match(r"^repos/([^/]+/[^/]+)(?:/(.*))?$", path)
    if not match:
        die("fake gh api: no route for " + endpoint, 99)
    repo, rest = match.group(1), match.group(2) or ""
    state = load()
    log({"tool": "gh", "method": method, "path": path, "fields": fields, "headers": headers})
    releases = state["releases"]

    if rest == "" and method == "GET":
        return emit({"full_name": repo, "permissions": {"admin": state.get("admin", True)}}, jq)
    match = re.match(r"^environments/([^/]+)$", rest)
    if match and method == "PUT":
        environments = state.setdefault("environments", {})
        environments.setdefault(match.group(1), {"policies": []})["settings"] = fields
        save(state)
        return emit({"name": match.group(1)}, jq)
    match = re.match(r"^environments/([^/]+)/deployment-branch-policies$", rest)
    if match:
        environment = state.setdefault("environments", {}).get(match.group(1))
        if environment is None:
            return not_found()
        if method == "GET":
            return emit({"total_count": len(environment["policies"]), "branch_policies": environment["policies"]}, jq)
        if method == "POST":
            environment["policies"].append({"name": fields["name"], "type": fields.get("type", "branch")})
            save(state)
            return emit(environment["policies"][-1], jq)

    if rest == "releases" and method == "GET":
        return emit([public_release(r) for r in sorted(releases, key=lambda r: -r["id"])], jq)
    if rest == "releases" and method == "POST":
        identifier = state["next_id"]
        state["next_id"] += 1
        release = {"id": identifier, "tag_name": fields["tag_name"], "target_commitish": fields["target_commitish"],
                   "name": fields["name"], "draft": fields["draft"], "prerelease": fields["prerelease"],
                   "body": fields.get("body", ""), "make_latest": None,
                   "html_url": "https://github.com/%s/releases/tag/%s" % (repo, fields["tag_name"]),
                   "assets": []}
        releases.append(release)
        save(state)
        return emit(public_release(release), jq)
    match = re.match(r"^releases/tags/(.+)$", rest)
    if match and method == "GET":
        release = release_by_tag(state, match.group(1))
        return emit(public_release(release), jq) if release else not_found()
    if rest == "releases/latest" and method == "GET":
        release = release_by_tag(state, state.get("latest") or "")
        return emit(public_release(release), jq) if release else not_found()
    match = re.match(r"^releases/(\d+)$", rest)
    if match:
        release = next((r for r in releases if r["id"] == int(match.group(1))), None)
        if release is None:
            return not_found()
        if method == "GET":
            return emit(public_release(release), jq)
        if method == "DELETE":
            releases.remove(release)
            save(state)
            return
        if method == "PATCH":
            for key in ("draft", "prerelease"):
                if key in fields:
                    release[key] = fields[key]
            if "make_latest" in fields:
                release["make_latest"] = fields["make_latest"]
                if fields["make_latest"] == "true":
                    state["latest"] = release["tag_name"]
            if not release["draft"] and release["tag_name"] not in state["tags"]:
                state["tags"][release["tag_name"]] = release["target_commitish"]
            save(state)
            return emit(public_release(release), jq)
    match = re.match(r"^releases/(\d+)/assets$", rest)
    if match and method == "GET":
        release = next((r for r in releases if r["id"] == int(match.group(1))), None)
        if release is None:
            return not_found()
        assets = []
        for asset in release["assets"]:
            shown = {"name": asset["name"], "state": asset.get("state", "uploaded"), "size": asset["size"]}
            if asset.get("digest"):
                shown["digest"] = asset["digest"]
            assets.append(shown)
        return emit(assets, jq)
    match = re.match(r"^git/ref/tags/(.+)$", rest)
    if match and method == "GET":
        tag = match.group(1)
        if tag not in state["tags"]:
            return not_found()
        return emit({"ref": "refs/tags/" + tag, "object": {"sha": state["tags"][tag], "type": "commit"}}, jq)
    match = re.match(r"^commits/tags/(.+)$", rest)
    if match and method == "GET":
        tag = match.group(1)
        if tag not in state["tags"]:
            die("gh: No commit found for SHA: tags/%s (HTTP 422)" % tag)
        if "Accept: application/vnd.github.sha" in headers:
            return emit(state["tags"][tag], None, raw=True)
        return emit({"sha": state["tags"][tag]}, jq)
    if rest == "git/tags" and method == "POST":
        identifier = "%040x" % (0xabc000 + len(state["tag_objects"]))
        state["tag_objects"][identifier] = {"tag": fields["tag"], "object": fields["object"],
                                            "message": fields["message"], "type": fields["type"]}
        save(state)
        return emit({"sha": identifier}, jq)
    if rest == "git/refs" and method == "POST":
        name = fields["ref"][len("refs/tags/"):]
        if name in state["tags"]:
            die("gh: Reference already exists (HTTP 422)")
        state["tags"][name] = state["tag_objects"][fields["sha"]]["object"]
        save(state)
        return emit({"ref": fields["ref"]}, jq)
    die("fake gh api: no route for %s %s" % (method, endpoint), 99)


def gh_release_download(args):
    tag, patterns, directory = None, [], "."
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in ("-p", "--pattern"):
            patterns.append(args[index + 1]); index += 2
        elif arg in ("-D", "--dir"):
            directory = args[index + 1]; index += 2
        elif arg in ("-R", "--repo"):
            index += 2
        elif arg.startswith("-"):
            die("fake gh release download: unknown flag " + arg, 99)
        else:
            tag = arg; index += 1
    state = load()
    log({"tool": "gh", "method": "DOWNLOAD", "path": tag, "fields": {"patterns": patterns}, "headers": []})
    release = release_by_tag(state, tag)
    if release is None:
        die("release not found")
    chosen = [a for a in release["assets"] if any(fnmatch.fnmatch(a["name"], p) for p in patterns)]
    if not chosen:
        die("no assets match the file pattern")
    Path(directory).mkdir(parents=True, exist_ok=True)
    for asset in chosen:
        shutil.copyfile(asset["path"], str(Path(directory) / asset["name"]))


def gh_set(kind, args):
    """gh variable set NAME --body V / gh secret set NAME --env E [--body V]
    (else the value on stdin). The call log never holds the value."""
    name, options = args[0], {}
    index = 1
    while index < len(args):
        if args[index] not in ("--body", "-b", "--env", "-e", "--repo", "-R"):
            die("fake gh %s set: unknown flag %s" % (kind, args[index]), 99)
        options[args[index].lstrip("-")[:1]] = args[index + 1]
        index += 2
    value = options["b"] if "b" in options else sys.stdin.read()
    state = load()
    if kind == "variable":
        state.setdefault("variables", {})[name] = value
        path = "variables/" + name
    else:
        state.setdefault("secrets", {}).setdefault(options.get("e", ""), {})[name] = value
        path = "environments/%s/secrets/%s" % (options.get("e", ""), name)
    save(state)
    log({"tool": "gh", "method": "SET", "path": path, "fields": {}, "headers": []})


def gh(args):
    if args[:1] == ["api"]:
        return gh_api(args[1:])
    if args[:2] == ["release", "download"]:
        return gh_release_download(args[2:])
    if args[:2] == ["auth", "status"]:
        return
    if args[:2] in (["variable", "set"], ["secret", "set"]):
        return gh_set(args[0], args[2:])
    die("fake gh: unsupported command " + " ".join(args), 99)


# curl -------------------------------------------------------------------------

def curl(args):
    headers, data, method, output, url, letters, fail_with_body = [], None, None, None, None, set(), False
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "-H":
            headers.append(args[index + 1]); index += 2
        elif arg == "-X":
            method = args[index + 1]; index += 2
        elif arg == "--data-binary":
            data = args[index + 1]; index += 2
        elif arg == "-o":
            output = args[index + 1]; index += 2
        elif arg == "--fail-with-body":
            fail_with_body = True; index += 1
        elif arg.startswith("--"):
            die("fake curl: unknown flag " + arg, 99)
        elif arg.startswith("-") and len(arg) > 1:
            letters.update(arg[1:]); index += 1
        else:
            url = arg; index += 1
    if fail_with_body and "f" in letters:
        die("curl: option --fail-with-body: is badly used here", 2)
    state = load()
    fail = "f" in letters or fail_with_body
    shown_headers = [h for h in headers if not h.lower().startswith("authorization:")]
    match = re.match(r"^https://uploads\.github\.com/repos/[^/]+/[^/]+/releases/(\d+)/assets\?name=(.+)$", url or "")
    if match:
        log({"tool": "curl", "method": method or "POST", "url": url, "headers": shown_headers,
             "authorized": any(h == "Authorization: Bearer " + os.environ.get("GH_TOKEN", "")
                               for h in headers)})
        release = next((r for r in state["releases"] if r["id"] == int(match.group(1))), None)
        if release is None:
            sys.stdout.write('{"message": "Not Found"}')
            die("curl: (22) The requested URL returned error: 404", 22)
        source = Path(data[1:])
        name = match.group(2)
        stored = STATE.parent / "assets" / str(release["id"]) / name
        stored.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(str(source), str(stored))
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if name in state.get("corrupt_digest", []):
            digest = "0" * 64
        release["assets"].append({"name": name, "path": str(stored), "size": source.stat().st_size,
                                  "state": "uploaded", "digest": "sha256:" + digest})
        save(state)
        sys.stdout.write(json.dumps({"name": name}))
        return
    if "I" in letters:
        log({"tool": "curl", "method": "HEAD", "url": url, "headers": shown_headers})
        answer = state.get("heads", {}).get(url, {"status": 404, "length": 9})
        sys.stdout.write("HTTP/2 302\r\ncontent-length: 0\r\nlocation: https://objects.example/x\r\n\r\n")
        sys.stdout.write("HTTP/2 %d\r\ncontent-length: %d\r\n\r\n" % (answer["status"], answer["length"]))
        if answer["status"] >= 400 and fail:
            die("curl: (22) The requested URL returned error: %d" % answer["status"], 22)
        return
    log({"tool": "curl", "method": "GET", "url": url, "headers": shown_headers})
    body = state.get("public_feed")
    if body is None and "appcast.xml" in state.get("objects", {}):
        body = state["objects"]["appcast.xml"]["body"]
    if body is None:
        die("curl: (22) The requested URL returned error: 404", 22)
    if output:
        Path(output).write_text(body)
    else:
        sys.stdout.write(body)


# aws --------------------------------------------------------------------------

VALUE_OPTIONS = {"--bucket", "--key", "--body", "--query", "--output", "--endpoint-url", "--content-type",
                 "--cache-control", "--if-match", "--if-none-match", "--max-keys"}


def aws(args):
    if args[:1] != ["s3api"]:
        die("fake aws: unsupported command " + " ".join(args), 99)
    operation = args[1]
    options, positional = {}, []
    index = 2
    while index < len(args):
        arg = args[index]
        if arg in VALUE_OPTIONS:
            options[arg] = args[index + 1]; index += 2
        elif arg.startswith("--"):
            die("fake aws: unknown option " + arg, 99)
        else:
            positional.append(arg); index += 1
    environment = {name: os.environ.get(name) for name in (
        "AWS_DEFAULT_REGION", "AWS_PAGER", "AWS_REQUEST_CHECKSUM_CALCULATION", "AWS_RESPONSE_CHECKSUM_VALIDATION")}
    log({"tool": "aws", "operation": operation, "options": options, "environment": environment})
    state = load()
    objects = state.setdefault("objects", {})
    key = options.get("--key")
    if operation == "get-object":
        if key not in objects:
            die("\nAn error occurred (NoSuchKey) when calling the GetObject operation: "
                "The specified key does not exist.", 254)
        Path(positional[0]).write_text(objects[key]["body"])
        if options.get("--query") == "ETag" and options.get("--output") == "text":
            sys.stdout.write(objects[key]["etag"] + "\n")
        else:
            sys.stdout.write(json.dumps({"ETag": objects[key]["etag"]}) + "\n")
        return
    if operation == "put-object":
        failed = state.get("put_failures", 0) > 0
        if failed:
            state["put_failures"] -= 1
            save(state)
        current = objects.get(key)
        if "--if-match" in options and (current is None or current["etag"] != options["--if-match"]):
            failed = True
        if options.get("--if-none-match") == "*" and current is not None:
            failed = True
        if failed:
            die("\nAn error occurred (PreconditionFailed) when calling the PutObject operation: "
                "At least one of the pre-conditions you specified did not hold", 254)
        body = Path(options["--body"]).read_text()
        etag = '"%s"' % hashlib.md5(body.encode()).hexdigest()
        objects[key] = {"body": body, "etag": etag, "content_type": options.get("--content-type"),
                        "cache_control": options.get("--cache-control")}
        save(state)
        sys.stdout.write(json.dumps({"ETag": etag}) + "\n")
        return
    die("fake aws: unsupported operation " + operation, 99)


# sign_update and xcrun ----------------------------------------------------------

def sign_update(args):
    if args[:3] != ["--ed-key-file", "-", "-p"] or len(args) != 4:
        die("fake sign_update: unexpected arguments " + " ".join(args), 99)
    key = sys.stdin.readline().strip()
    log({"tool": "sign_update", "file": args[3]})
    sys.stdout.write(fake_signature(fake_public(key), Path(args[3]).read_bytes()) + "\n")


def xcrun(args):
    if args[:1] != ["swift"] or not args[1].endswith("sparkle-key.swift"):
        die("fake xcrun: unsupported command " + " ".join(args), 99)
    command = args[2:]
    log({"tool": "xcrun", "command": command[:1]})
    if command == ["derive"]:
        key = sys.stdin.read().strip()
        if not key:
            die("sparkle-key: the private key on standard input is not base64", 2)
        sys.stdout.write(fake_public(key) + "\n")
        return
    if command[:1] == ["verify"] and len(command) == 4:
        public, path, signature = command[1:]
        if fake_signature(public, Path(path).read_bytes()) != signature:
            die("sparkle-key: the signature does not match " + path, 1)
        return
    die("fake xcrun: unsupported sparkle-key command", 99)


# security, xcode-select and generate_keys (Scripts/release-setup) ---------------

def security(args):
    if args[:1] != ["find-generic-password"] or "-w" not in args:
        die("fake security: unsupported command " + " ".join(args), 99)
    account = args[args.index("-a") + 1]
    service = args[args.index("-s") + 1]
    log({"tool": "security", "command": args[0], "service": service, "account": account})
    key = load().get("keychain", {}).get(account) if service == "https://sparkle-project.org" else None
    if key is None:
        die("security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.", 44)
    sys.stdout.write(key + "\n")


def xcode_select(args):
    if args != ["-p"]:
        die("fake xcode-select: unsupported command " + " ".join(args), 99)
    sys.stdout.write("/Library/Developer/CommandLineTools\n")


def generate_keys(args):
    """Sparkle's generate_keys: -p prints the account's public key, or fails
    as Sparkle's does with no key; no option makes a key unless one exists."""
    account = args[args.index("--account") + 1] if "--account" in args else "ed25519"
    state = load()
    keychain = state.setdefault("keychain", {})
    if "-p" in args:
        log({"tool": "generate_keys", "action": "print", "account": account})
        if account not in keychain:
            die("ERROR! No existing signing key found!")
        sys.stdout.write(fake_public(keychain[account]) + "\n")
        return
    if "-f" in args or "-x" in args:
        die("fake generate_keys: -f and -x are not faked", 99)
    log({"tool": "generate_keys", "action": "generate", "account": account})
    if account not in keychain:
        keychain[account] = "generated-seed-%d" % len(state.setdefault("generated", []))
        state["generated"].append(keychain[account])
        save(state)
    sys.stdout.write("A key was generated.\n")


# codesign and xattr (Scripts/sign-app) --------------------------------------------

def codesign(args):
    """Records each signature's identity; -dv shows the Team ID the state's
    codesign_team names for a certificate (none: "not set", as for ad hoc or a
    self-signed certificate)."""
    state = load()
    log({"tool": "codesign", "args": args})
    signatures = state.setdefault("signatures", {})
    if args[:1] == ["-dv"]:
        identity = signatures.get(args[-1])
        if identity is None:
            die(args[-1] + ": code object is not signed at all")
        team = state.get("codesign_team") if identity != "-" else None
        sys.stderr.write("Executable=%s\nTeamIdentifier=%s\n" % (args[-1], team or "not set"))
        return
    if args[:1] == ["--verify"]:
        return
    if "--sign" not in args:
        die("fake codesign: unsupported command " + " ".join(args), 99)
    signatures[args[-1]] = args[args.index("--sign") + 1]
    save(state)


def xattr(args):
    log({"tool": "xattr", "args": args})


TOOLS = {"gh": gh, "curl": curl, "aws": aws, "sign_update": sign_update, "xcrun": xcrun, "security": security,
         "xcode-select": xcode_select, "generate_keys": generate_keys, "codesign": codesign, "xattr": xattr}
'''

WRAPPER = """#!{python} -I
import sys
sys.dont_write_bytecode = True
sys.path.insert(0, {directory!r})
import fakes
fakes.TOOLS[{tool!r}](sys.argv[1:])
"""


class Sandbox:
    """A temporary directory with the fake tools first on PATH, their state,
    their call log and a release.conf."""

    def __init__(self, test, public_key=""):
        self.root = Path(tempfile.mkdtemp(prefix="cherry-release-test-")).resolve()
        test.addCleanup(shutil.rmtree, self.root, True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "fakes.py").write_text(FAKES)
        for tool in ("gh", "curl", "aws", "sign_update", "xcrun", "security", "xcode-select", "codesign", "xattr"):
            wrapper = self.bin / tool
            wrapper.write_text(WRAPPER.format(python=sys.executable, directory=str(self.bin), tool=tool))
            wrapper.chmod(0o755)
        self.state_path = self.root / "state" / "state.json"
        self.state_path.parent.mkdir()
        self.log_path = self.root / "state" / "calls.jsonl"
        self.log_path.write_text("")
        self.conf = self.root / "release.conf"
        self.conf.write_text(FIXTURE_CONF.format(public_key=public_key))
        self.summary = self.root / "summary.md"
        self.home = self.root / "home"
        self.home.mkdir()
        self.save({"releases": [], "next_id": 100, "tags": {}, "tag_objects": {}, "latest": None, "objects": {}})

    def environment(self, **extra):
        environment = {name: value for name, value in os.environ.items()
                       if not name.startswith(SCRUBBED_PREFIXES) and name not in SCRUBBED}
        environment.update({
            "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '/usr/bin:/bin')}",
            "HOME": str(self.home),
            "FAKE_STATE": str(self.state_path),
            "FAKE_LOG": str(self.log_path),
            "CHERRY_RELEASE_CONF": str(self.conf),
            "GITHUB_STEP_SUMMARY": str(self.summary),
            "GH_REPO": REPO,
            "GH_TOKEN": "fake-token",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "LC_ALL": "C",
        })
        environment.update({key: str(value) for key, value in extra.items()})
        return environment

    def run(self, command, *arguments, cwd=None, stdin=None, **extra):
        program = str(SCRIPTS / command) if not os.path.isabs(command) else command
        return subprocess.run([program, *map(str, arguments)], capture_output=True, text=True, timeout=120,
                              cwd=str(cwd or self.root), input=stdin, env=self.environment(**extra))

    def state(self):
        return json.loads(self.state_path.read_text())

    def save(self, state):
        self.state_path.write_text(json.dumps(state, indent=1))

    def update(self, **values):
        state = self.state()
        state.update(values)
        self.save(state)

    def calls(self, tool=None):
        entries = [json.loads(line) for line in self.log_path.read_text().splitlines() if line.strip()]
        return [entry for entry in entries if tool is None or entry["tool"] == tool]

    def writes(self):
        """GitHub writes (POST, PATCH, PUT, DELETE), curl uploads and R2 puts."""
        return [call for call in self.calls()
                if (call["tool"] == "gh" and call["method"] in ("POST", "PATCH", "PUT", "DELETE"))
                or (call["tool"] == "curl" and call["method"] == "POST")
                or (call["tool"] == "aws" and call["operation"] == "put-object")]

    def asset(self, name, data):
        path = self.root / "assets-src" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"name": name, "path": str(path), "size": len(data), "state": "uploaded",
                "digest": "sha256:" + hashlib.sha256(data).hexdigest()}

    def add_release(self, tag, draft=False, prerelease=True, assets=(), body="", commit=None, latest=False):
        state = self.state()
        identifier = state["next_id"]
        state["next_id"] += 1
        state["releases"].append({
            "id": identifier, "tag_name": tag, "target_commitish": commit or "0" * 40, "name": tag,
            "draft": draft, "prerelease": prerelease, "body": body, "make_latest": None,
            "html_url": f"https://github.com/{REPO}/releases/tag/{tag}", "assets": list(assets)})
        if commit and not draft:
            state["tags"][tag] = commit
        if latest:
            state["latest"] = tag
        self.save(state)
        return identifier


def outputs(text):
    """key=value lines of a script's stdout."""
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


# -- Item and feed builders --------------------------------------------------------

def item_element(version, build, channel="prerelease", length=1234, signature=None, repo=REPO, zip_name=None):
    tag = f"v{version}-pre" if channel == "prerelease" else f"v{version}"
    page = release.release_url(repo, tag)
    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"Cherry {version}"
    ET.SubElement(item, "link").text = page
    ET.SubElement(item, release.sparkle("version")).text = build
    ET.SubElement(item, release.sparkle("shortVersionString")).text = version
    ET.SubElement(item, "pubDate").text = "Sun, 11 Oct 2026 12:00:00 +0000"
    ET.SubElement(item, release.sparkle("minimumSystemVersion")).text = "26.0.0"
    if channel == "prerelease":
        ET.SubElement(item, release.sparkle("channel")).text = "prerelease"
    ET.SubElement(item, release.sparkle("fullReleaseNotesLink")).text = page
    ET.SubElement(item, "description").text = "<ul><li>A &amp; B</li></ul>"
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", release.download_url(repo, tag, zip_name or f"Cherry-{version}.zip"))
    enclosure.set("length", str(length))
    enclosure.set("type", "application/octet-stream")
    enclosure.set(release.sparkle("edSignature"),
                  signature or base64.b64encode(hashlib.sha512(build.encode()).digest()).decode())
    return item


def item_bytes(*arguments, **keywords):
    return release.serialize(item_element(*arguments, **keywords))


def item(*arguments, **keywords):
    return release.Item(ET.fromstring(item_bytes(*arguments, **keywords)))


def empty_feed():
    return release.Feed.empty(REPO)


def quiet():
    """Swallows the notes and warnings the module prints to stderr."""
    return contextlib.redirect_stderr(io.StringIO())


def merged(items, keep_prereleases=20, keep_stable=10, feed=None):
    feed = feed or empty_feed()
    with quiet():
        for entry in items:
            release.merge(feed, entry, keep_prereleases, keep_stable)
    return feed.serialize()


def reload(data):
    return release.Feed(ET.fromstring(data))


def build_of(day, minute=0, rev=1):
    return f"202610{day:02d}00{minute:02d}00.{rev:07x}"


# -- Pure functions ------------------------------------------------------------------

class VersionTests(unittest.TestCase):
    def test_the_first_release_of_a_day_is_1(self):
        self.assertEqual(release.version_next("2026.10.11", []), "2026.10.11.1")
        self.assertEqual(release.version_next("2026.10.11", ["v2026.10.10.4-pre", "v2026.10.10.2"]), "2026.10.11.1")

    def test_n_goes_past_gaps_and_counts_stable_tags(self):
        tags = ["v2026.10.11.1-pre", "v2026.10.11.4-pre", "v2026.10.11.6"]
        self.assertEqual(release.version_next("2026.10.11", tags), "2026.10.11.7")

    def test_malformed_tags_are_ignored(self):
        tags = ["v2026.10.11.0-pre", "v2026.10.11.05-pre", "2026.10.11.9", "v2026.10.11.8-beta", "x",
                "v2026.10.11.3-pre-pre", " v2026.10.11.2-pre "]
        self.assertEqual(release.version_next("2026.10.11", tags), "2026.10.11.3")

    def test_ten_is_newer_than_nine(self):
        self.assertEqual(release.version_next("2026.10.11", ["v2026.10.11.9-pre", "v2026.10.11.10-pre"]),
                         "2026.10.11.11")
        self.assertEqual(release.version_newest("prerelease", ["v2026.10.11.9-pre", "v2026.10.11.10-pre"]),
                         "v2026.10.11.10-pre")
        self.assertEqual(release.version_compare("2026.10.11.10", "v2026.10.11.9"), 1)

    def test_newest_by_kind(self):
        tags = ["v2026.10.11.2", "v2026.10.12.1-pre", "v2026.09.30.7-pre", "v2026.10.11.1"]
        self.assertEqual(release.version_newest("prerelease", tags), "v2026.10.12.1-pre")
        self.assertEqual(release.version_newest("stable", tags), "v2026.10.11.2")
        self.assertEqual(release.version_newest("stable", ["v2026.10.12.1-pre"]), "")

    def test_check(self):
        for good in ("2026.10.11.1", "2026.01.31.12"):
            self.assertIsNotNone(release.parse_version(good), good)
        for bad in ("2026.10.11", "2026.10.11.0", "2026.10.11.01", "v2026.10.11.1", "2026.13.01.1",
                    "2026.02.30.1", "26.10.11.1", "2026.10.11.1-pre", ""):
            self.assertIsNone(release.parse_version(bad), bad)

    def test_compare(self):
        self.assertEqual(release.version_compare("2026.10.11.1", "2026.10.11.1"), 0)
        self.assertEqual(release.version_compare("v2026.10.11.1", "v2026.10.12.1-pre"), -1)
        self.assertEqual(release.version_compare("2026.11.01.1", "2026.10.31.9"), 1)
        with self.assertRaises(release.ReleaseError):
            release.version_compare("2026.10.11", "2026.10.11.1")

    def test_the_command_line(self):
        sandbox = Sandbox(self)
        result = sandbox.run(CLI, "version", "next", "--date", "2026.10.11",
                             stdin="v2026.10.11.1-pre\nv2026.10.11.2-pre\n")
        self.assertEqual((result.returncode, result.stdout), (0, "2026.10.11.3\n"), result.stderr)
        self.assertEqual(sandbox.run(CLI, "version", "check", "2026.10.11.3").returncode, 0)
        self.assertEqual(sandbox.run(CLI, "version", "check", "2026.10.11").returncode, 1)
        self.assertEqual(sandbox.run(CLI, "version", "compare", "v2026.10.11.10", "2026.10.11.9").stdout, "1\n")
        self.assertEqual(sandbox.run(CLI, "version", "newest", "--kind", "stable", stdin="v2026.10.11.1-pre\n").stdout,
                         "\n")
        self.assertEqual(sandbox.run(CLI, "version", "next", "--date", "2026.10.32", stdin="").returncode, 2)


class StampTests(unittest.TestCase):
    SHA = "4bee6df0123456789abcdef0123456789abcdef0"
    NOON = 1791720000  # 2026-10-11 12:00:00 UTC

    def test_the_stamp_is_now(self):
        self.assertEqual(release.stamp(self.SHA, self.NOON), ("20261011120000.4bee6df", "2026.10.11"))

    def test_a_previous_build_at_or_after_now_gives_one_second_more(self):
        self.assertEqual(release.stamp(self.SHA, self.NOON, "20261011120000.aaaaaaa")[0], "20261011120001.4bee6df")
        self.assertEqual(release.stamp(self.SHA, self.NOON, "20261011130000.aaaaaaa")[0], "20261011130001.4bee6df")
        self.assertEqual(release.stamp(self.SHA, self.NOON, "20261011115959.aaaaaaa")[0], "20261011120000.4bee6df")

    def test_across_midnight_the_day_follows_the_stamp(self):
        before_midnight = 1791763199  # 2026-10-11 23:59:59 UTC
        self.assertEqual(release.stamp(self.SHA, before_midnight - 10, "20261011235959.aaaaaaa"),
                         ("20261012000000.4bee6df", "2026.10.12"))

    def test_a_malformed_previous_build_is_ignored(self):
        for previous in ("2026101112000.aaaaaaa", "20261311120000.aaaaaaa", "20261011120000.AAAAAAA", "x"):
            with quiet() as stderr:
                self.assertEqual(release.stamp(self.SHA, self.NOON, previous)[0], "20261011120000.4bee6df", previous)
            self.assertIn("ignoring the previous build", stderr.getvalue())

    def test_the_rev_is_the_shas_first_seven_characters(self):
        self.assertTrue(release.stamp("ABCDEF1234", self.NOON)[0].endswith(".abcdef1"))
        with self.assertRaises(release.ReleaseError):
            release.stamp("xyz", self.NOON)

    def test_the_command_line(self):
        sandbox = Sandbox(self)
        result = sandbox.run(CLI, "stamp", "--sha", self.SHA, "--now", self.NOON, "--prev-build",
                             "20261011120000.aaaaaaa")
        self.assertEqual(result.stdout, "build_id=20261011120001.4bee6df\nday=2026.10.11\n", result.stderr)


class NotesTests(unittest.TestCase):
    def entries(self, count):
        return [(f"{index:040x}", f"Change {index}") for index in range(count)]

    def test_escapes_html(self):
        text = release.notes_html(REPO, [("a" * 40, 'Use <Tab> & "quotes"')])
        self.assertIn("Use &lt;Tab&gt; &amp; &quot;quotes&quot;", text)
        self.assertIn(f'<a href="https://github.com/{REPO}/commit/{"a" * 40}">aaaaaaa</a>', text)
        self.assertTrue(text.startswith("<ul><li>") and text.endswith("</li></ul>"))

    def test_caps_at_50_and_100(self):
        text = release.notes_html(REPO, self.entries(120))
        self.assertEqual(text.count("<li>"), 50)
        self.assertIn("…and 70 more changes.", text)
        markdown = release.notes_markdown(REPO, "v2026.10.11.2-pre", None, "20261011120000.abcdef0",
                                          self.entries(120))
        self.assertEqual(sum(1 for line in markdown.splitlines() if line.startswith("- ")), 100)
        self.assertIn("…and 20 more changes.", markdown)
        self.assertNotIn("more changes", release.notes_html(REPO, self.entries(50)))

    def test_an_empty_range(self):
        self.assertEqual(release.notes_html(REPO, []), "<p>No changes besides merges.</p>")
        markdown = release.notes_markdown(REPO, "v2026.10.11.1-pre", None, "20261011120000.abcdef0", [])
        self.assertTrue(markdown.startswith("No changes besides merges."))
        self.assertIn("Build `20261011120000.abcdef0` · requires macOS 26 or later", markdown)

    def test_the_compare_link(self):
        markdown = release.notes_markdown(REPO, "v2026.10.11.2-pre", "v2026.10.11.1-pre", "20261011120000.abcdef0",
                                          self.entries(2))
        self.assertIn(f"https://github.com/{REPO}/compare/v2026.10.11.1-pre...v2026.10.11.2-pre", markdown)
        self.assertNotIn("compare", release.notes_markdown(REPO, "v2026.10.11.1-pre", None, "x", self.entries(2)))
        self.assertTrue(markdown.rstrip().endswith("requires macOS 26 or later"))

    def test_the_command_line_reads_git_log(self):
        sandbox = Sandbox(self)
        log = f"{'b' * 40}\tFix <this>\n{'c' * 40}\tAdd that\n"
        result = sandbox.run(CLI, "notes", "--repo", REPO, "--tag", "v2026.10.11.2-pre", "--prev-tag",
                             "v2026.10.11.1-pre", "--build", "20261011120000.bbbbbbb", "--md",
                             sandbox.root / "notes.md", "--html", sandbox.root / "notes.html", stdin=log)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Fix &lt;this&gt;", (sandbox.root / "notes.html").read_text())
        self.assertIn("- Fix \\<this> ([bbbbbbb]", (sandbox.root / "notes.md").read_text())

    def test_characters_xml_cannot_hold_are_dropped(self):
        entries = release.parse_log(f"{'a' * 40}\tFix \x1b[K redraw\x00 \ud800\ufffe\t\U0001F352")
        self.assertEqual(entries, [("a" * 40, "Fix [K redraw \t\U0001F352")])
        item = ET.Element("item")
        ET.SubElement(item, "description").text = release.notes_html(REPO, entries)
        self.assertIn("Fix [K redraw", ET.fromstring(release.serialize(item)).findtext("description"))

    def test_the_command_line_reads_control_characters_and_bytes_that_are_not_utf8(self):
        sandbox = Sandbox(self)
        log = b"b" * 40 + b"\tFix \x1b[K redraw\n" + b"c" * 40 + b"\tCaf\xe9 \xff\n"
        result = subprocess.run(
            [str(CLI), "notes", "--repo", REPO, "--tag", "v2026.10.11.2-pre", "--build", "20261011120000.bbbbbbb",
             "--md", str(sandbox.root / "notes.md"), "--html", str(sandbox.root / "notes.html")],
            input=log, capture_output=True, timeout=120, cwd=str(sandbox.root), env=sandbox.environment())
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        notes = (sandbox.root / "notes.html").read_text(encoding="utf-8")
        self.assertNotIn("\x1b", notes)
        self.assertIn("Fix [K redraw", notes)
        self.assertIn("Caf\ufffd \ufffd", notes)
        self.assertIn("- Caf\ufffd \ufffd ([ccccccc]", (sandbox.root / "notes.md").read_text(encoding="utf-8"))
        item = ET.Element("item")
        ET.SubElement(item, "description").text = notes.strip()
        ET.fromstring(release.serialize(item))


# -- Appcast ---------------------------------------------------------------------------

class ItemTests(unittest.TestCase):
    KEY = "the-private-key"
    VERSION = "2026.10.11.1"
    BUILD = "20261011120000.abcdef0"

    def setUp(self):
        self.sandbox = Sandbox(self)
        self.out = self.sandbox.root / "out"
        self.out.mkdir()
        self.notes = self.sandbox.root / "notes.html"
        self.notes.write_text('<ul><li>Fix &lt;x&gt; (<a href="https://github.com/x">abc</a>)</li></ul>\n')

    def make_zip(self, build=None, public_key=None, version=None):
        info = {"CFBundleIdentifier": "dev.patrick.cherry", "CFBundleVersion": build or self.BUILD,
                "CFBundleShortVersionString": version or self.VERSION, "SUPublicEDKey": fake_public(self.KEY)}
        if public_key is not None:
            info["SUPublicEDKey"] = public_key
        path = self.out / f"Cherry-{self.VERSION}.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("Cherry.app/Contents/Info.plist", plistlib.dumps(info))
            archive.writestr("Cherry.app/Contents/MacOS/CherryApp", b"\0" * 4096)
        return path

    def make_manifest(self, zip_path, **overrides):
        manifest = {"version": self.VERSION, "build": self.BUILD, "bundle_identifier": "dev.patrick.cherry",
                    "minimum_system_version": "26.0.0", "zip": zip_path.name, "zip_length": zip_path.stat().st_size,
                    "zip_sha256": sha256_file(zip_path), "dmg": f"Cherry-{self.VERSION}.dmg", "dmg_sha256": "0" * 64}
        manifest.update(overrides)
        path = self.out / "release.json"
        path.write_text(json.dumps(manifest))
        return path

    def run_item(self, manifest, channel="prerelease", tag=None, key=KEY):
        tag = tag or (f"v{self.VERSION}-pre" if channel == "prerelease" else f"v{self.VERSION}")
        output = self.out / "appcast-item.xml"
        result = self.sandbox.run(
            CLI, "appcast", "item", "--manifest", manifest, "--channel", channel, "--tag", tag, "--repo", REPO,
            "--notes", self.notes, "--sign-update", self.sandbox.bin / "sign_update",
            "--pub-date", "Sun, 11 Oct 2026 14:00:00 +0200", "--output", output, SPARKLE_ED_PRIVATE_KEY=key)
        return result, output

    def test_a_prerelease_item_has_every_element_and_its_channel(self):
        zip_path = self.make_zip()
        result, output = self.run_item(self.make_manifest(zip_path))
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.fromstring(output.read_bytes())
        self.assertEqual(root.tag, "item")
        page = f"https://github.com/{REPO}/releases/tag/v{self.VERSION}-pre"
        self.assertEqual(root.findtext("title"), f"Cherry {self.VERSION}")
        self.assertEqual(root.findtext("link"), page)
        self.assertEqual(root.findtext(release.sparkle("fullReleaseNotesLink")), page)
        self.assertEqual(root.findtext(release.sparkle("version")), self.BUILD)
        self.assertEqual(root.findtext(release.sparkle("shortVersionString")), self.VERSION)
        self.assertEqual(root.findtext(release.sparkle("minimumSystemVersion")), "26.0.0")
        self.assertEqual(root.findtext(release.sparkle("channel")), "prerelease")
        self.assertEqual(root.findtext("pubDate"), "Sun, 11 Oct 2026 12:00:00 +0000")
        self.assertEqual(root.findtext("description"), self.notes.read_text().strip())
        self.assertIn(b"&lt;ul&gt;", output.read_bytes())
        enclosure = root.find("enclosure")
        self.assertEqual(enclosure.get("url"),
                         f"https://github.com/{REPO}/releases/download/v{self.VERSION}-pre/{zip_path.name}")
        self.assertEqual(enclosure.get("length"), str(zip_path.stat().st_size))
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(release.sparkle("edSignature")),
                         fake_signature(fake_public(self.KEY), zip_path.read_bytes()))
        self.assertEqual(release.load_item(str(output)).problems(), [])
        self.assertNotIn(self.KEY, result.stdout + result.stderr)

    def test_notes_with_characters_xml_cannot_hold_still_make_a_readable_item(self):
        self.notes.write_text("<ul><li>Fix \x1b[K redraw\x07</li></ul>\n")
        result, output = self.run_item(self.make_manifest(self.make_zip()))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(ET.fromstring(output.read_bytes()).findtext("description"),
                         "<ul><li>Fix [K redraw</li></ul>")
        self.assertEqual(release.load_item(str(output)).problems(), [])
        with self.assertRaises(release.ReleaseError):
            release.readable_item(b"<item><title>\x1b</title></item>")

    def test_a_stable_item_has_no_channel(self):
        result, output = self.run_item(self.make_manifest(self.make_zip()), channel="stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        root = ET.fromstring(output.read_bytes())
        self.assertIsNone(root.find(release.sparkle("channel")))
        self.assertIn(f"/download/v{self.VERSION}/", root.find("enclosure").get("url"))

    def test_a_length_that_differs_from_the_manifest_is_refused(self):
        zip_path = self.make_zip()
        result, output = self.run_item(self.make_manifest(zip_path, zip_length=zip_path.stat().st_size + 1))
        self.assertEqual(result.returncode, 1)
        self.assertIn("but the manifest says", result.stderr)
        self.assertFalse(output.exists())

    def test_a_zip_whose_build_differs_from_the_manifest_is_refused(self):
        result, output = self.run_item(self.make_manifest(self.make_zip(build="20261011115959.abcdef0")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("CFBundleVersion", result.stderr)
        self.assertFalse(output.exists())

    def test_a_key_that_does_not_sign_for_the_zips_public_key_is_refused(self):
        result, output = self.run_item(self.make_manifest(self.make_zip(public_key=fake_public("another key"))))
        self.assertEqual(result.returncode, 1)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY does not sign for this app's SUPublicEDKey", result.stderr)
        self.assertFalse(output.exists())
        self.assertNotIn(self.KEY, result.stdout + result.stderr)

    def test_a_zip_without_a_public_key_or_a_missing_key_is_refused(self):
        result, _ = self.run_item(self.make_manifest(self.make_zip(public_key="")))
        self.assertEqual(result.returncode, 1)
        self.assertIn("no SUPublicEDKey", result.stderr)
        result, _ = self.run_item(self.make_manifest(self.make_zip()), key="")
        self.assertEqual(result.returncode, 1)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY is not set", result.stderr)

    def test_bad_formats_are_refused(self):
        zip_path = self.make_zip()
        cases = {
            "version": dict(version="2026.10.11"),
            "build": dict(build="20261011120000"),
            "zip_length": dict(zip_length="12"),
            "zip": dict(zip="../Cherry.zip"),
            "minimum_system_version": dict(minimum_system_version="twenty-six"),
        }
        for name, overrides in cases.items():
            with self.subTest(name):
                result, _ = self.run_item(self.make_manifest(zip_path, **overrides))
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(name, result.stderr)
        result, _ = self.run_item(self.make_manifest(zip_path), tag=f"v{self.VERSION}")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"v{self.VERSION}-pre", result.stderr)
        self.assertEqual(self.sandbox.calls("sign_update"), [])


class MergeTests(unittest.TestCase):
    def test_an_empty_feed(self):
        data = release.Feed.empty(REPO).serialize()
        self.assertTrue(data.startswith(b'<?xml version="1.0" encoding="utf-8"?>\n<rss xmlns:cherry='))
        root = ET.fromstring(data)
        channel = root.find("channel")
        self.assertEqual([channel.findtext(t) for t in ("title", "link", "description", "language")],
                         ["Cherry", f"https://github.com/{REPO}", "Cherry updates", "en"])
        self.assertIn(f'xmlns:sparkle="{release.SPARKLE_NS}"'.encode(), data)
        self.assertIn(f'xmlns:cherry="{release.CHERRY_NS}"'.encode(), data)
        self.assertEqual(release.check(reload(data)), [])
        sandbox = Sandbox(self)
        result = sandbox.run(CLI, "appcast", "empty", "--output", sandbox.root / "empty.xml")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((sandbox.root / "empty.xml").read_bytes(), data)
        feed = reload(merged([item("2026.10.11.1", build_of(11))]))
        self.assertEqual([i.build for i in feed.items], [build_of(11)])
        self.assertEqual(release.check(feed), [])

    def test_newest_first(self):
        builds = [build_of(12), build_of(10), build_of(11, minute=5), build_of(11)]
        feed = reload(merged([item(f"2026.10.{b[6:8]}.{n + 1}", b) for n, b in enumerate(builds)]))
        self.assertEqual([i.build for i in feed.items], sorted(builds, reverse=True))

    def test_a_stable_item_replaces_the_prerelease_item(self):
        pre = item("2026.10.11.1", build_of(11))
        stable = item("2026.10.11.1", build_of(11), channel="")
        other = item("2026.10.11.2", build_of(11, minute=1))
        feed = reload(merged([pre, other, stable]))
        self.assertEqual([(i.version, i.channel) for i in feed.items],
                         [("2026.10.11.2", "prerelease"), ("2026.10.11.1", "")])

    def test_a_prerelease_item_never_replaces_a_stable_one(self):
        stable = item("2026.10.11.1", build_of(11), channel="")
        first = merged([stable])
        again = merged([item("2026.10.11.1", build_of(11))], feed=reload(first))
        self.assertEqual(first, again)

    def test_identical_bytes_when_repeated(self):
        items = [item("2026.10.11.1", build_of(11)), item("2026.10.11.2", build_of(11, minute=1))]
        once = merged(items)
        twice = merged([item("2026.10.11.2", build_of(11, minute=1))], feed=reload(once))
        self.assertEqual(once, twice)

    def test_the_order_of_merges_does_not_matter(self):
        def items():
            return [item("2026.10.11.1", build_of(11)), item("2026.10.11.2", build_of(11, minute=1)),
                    item("2026.10.11.1", build_of(11), channel=""), item("2026.10.10.1", build_of(10))]
        expected = merged(items())
        for order in ((1, 0, 3, 2), (3, 2, 1, 0), (2, 0, 1, 3)):
            entries = items()
            self.assertEqual(merged([entries[i] for i in order]), expected, order)
        first, second = items()[:2]
        self.assertEqual(merged([first, second], keep_prereleases=1), merged([second, first], keep_prereleases=1))

    def test_prunes_25_prereleases_and_12_stable_to_20_and_10_keeping_stable_items(self):
        stable = [item(f"2026.10.{day:02d}.1", build_of(day, rev=day), channel="") for day in range(1, 13)]
        pre = [item(f"2026.10.20.{n}", build_of(20, minute=n, rev=100 + n)) for n in range(1, 26)]
        feed = reload(merged(stable + pre))
        kept_pre = [i.version for i in feed.items if not i.is_stable]
        kept_stable = [i.version for i in feed.items if i.is_stable]
        self.assertEqual(kept_pre, [f"2026.10.20.{n}" for n in range(25, 5, -1)])
        self.assertEqual(kept_stable, [f"2026.10.{day:02d}.1" for day in range(12, 2, -1)])
        self.assertEqual(release.check(feed), [])

    def test_remove_by_version_and_by_build_keeps_the_build_out(self):
        base = merged([item("2026.10.11.1", build_of(11)), item("2026.10.11.2", build_of(11, minute=1))])
        by_version = reload(base)
        release.remove(by_version, "2026.10.11.1")
        data = by_version.serialize()
        feed = reload(data)
        self.assertEqual([i.version for i in feed.items], ["2026.10.11.2"])
        self.assertIn(f'<cherry:pulled version="2026.10.11.1">{build_of(11)}</cherry:pulled>'.encode(), data)
        self.assertEqual(release.check(feed), [])

        by_build = reload(base)
        release.remove(by_build, build_of(11, minute=1))
        self.assertEqual([i.version for i in by_build.items], ["2026.10.11.1"])
        self.assertTrue(by_build.is_pulled(build_of(11, minute=1)))

        unknown = reload(base)
        release.remove(unknown, build_of(9))
        self.assertTrue(unknown.is_pulled(build_of(9)))
        with self.assertRaises(release.ReleaseError):
            release.remove(reload(base), "2026.10.9.1")
        with self.assertRaises(release.ReleaseError):
            release.remove(reload(base), "2026.10.09.1")

    def test_a_pulled_build_is_never_added_again(self):
        sandbox = Sandbox(self)
        pre = sandbox.root / "pre.xml"
        pre.write_bytes(item_bytes("2026.10.11.1", build_of(11)))
        stable = sandbox.root / "stable.xml"
        stable.write_bytes(item_bytes("2026.10.11.1", build_of(11), channel=""))
        feed = sandbox.root / "feed.xml"
        self.assertEqual(sandbox.run(CLI, "appcast", "merge", "-", pre, "--output", feed).returncode, 0)
        removed = sandbox.root / "removed.xml"
        result = sandbox.run(CLI, "appcast", "remove", feed, "2026.10.11.1", "--output", removed)
        self.assertEqual(result.returncode, 0, result.stderr)
        for entry in (pre, stable):
            again = sandbox.root / "again.xml"
            result = sandbox.run(CLI, "appcast", "merge", removed, entry, "--output", again)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("pulled", result.stderr)
            self.assertEqual(again.read_bytes(), removed.read_bytes())
        self.assertEqual(sandbox.run(CLI, "appcast", "is-pulled", removed, build_of(11)).returncode, 0)
        self.assertEqual(sandbox.run(CLI, "appcast", "is-pulled", "-", build_of(11),
                                     stdin=removed.read_text()).returncode, 0)
        self.assertEqual(sandbox.run(CLI, "appcast", "is-pulled", feed, build_of(11)).returncode, 1)
        self.assertEqual(sandbox.run(CLI, "appcast", "is-pulled", "-", build_of(11), stdin="<html>").returncode, 2)

    def test_restore_removes_the_pulled_entry_only(self):
        feed = reload(merged([item("2026.10.11.1", build_of(11)), item("2026.10.11.2", build_of(11, minute=1))]))
        release.remove(feed, "2026.10.11.1")
        restored = reload(feed.serialize())
        release.restore(restored, build_of(11))
        self.assertFalse(restored.is_pulled(build_of(11)))
        self.assertEqual([i.version for i in restored.items], ["2026.10.11.2"])
        again = reload(restored.serialize())
        with quiet():
            release.merge(again, item("2026.10.11.1", build_of(11)), 20, 10)
        self.assertEqual([i.version for i in again.items], ["2026.10.11.2", "2026.10.11.1"])
        with self.assertRaises(release.ReleaseError):
            release.restore(again, "2026.10.11.1")

    def test_check_failures(self):
        good = merged([item("2026.10.11.1", build_of(11)), item("2026.10.11.2", build_of(11, minute=1))])
        self.assertEqual(release.check(reload(good)), [])

        def broken(edit):
            root = ET.fromstring(good)
            edit(root.find("channel"))
            return release.check(release.Feed(root))

        items = lambda channel: channel.findall("item")  # noqa: E731
        self.assertIn("the items are not newest first",
                      broken(lambda c: (c.remove(items(c)[0]), c.append(ET.fromstring(
                          item_bytes("2026.10.11.2", build_of(11, minute=1)))))))
        self.assertTrue(any("more than one item" in p for p in broken(lambda c: c.append(ET.fromstring(
            item_bytes("2026.10.11.2", build_of(10)))))))
        self.assertTrue(any("edSignature" in p for p in broken(
            lambda c: items(c)[0].find("enclosure").attrib.pop(release.sparkle("edSignature")))))
        self.assertTrue(any("sparkle:version" in p for p in broken(
            lambda c: setattr(items(c)[0].find(release.sparkle("version")), "text", "1.0"))))
        self.assertTrue(any("pulled entry" in p for p in broken(
            lambda c: ET.SubElement(c, release.cherry("pulled")).__setattr__("text", "nope"))))
        sandbox = Sandbox(self)
        path = sandbox.root / "bad.xml"
        path.write_text("<rss><channel><item/></channel></rss>")
        result = sandbox.run(CLI, "appcast", "check", path)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stderr)
        path.write_bytes(good)
        self.assertEqual(sandbox.run(CLI, "appcast", "check", path).returncode, 0)

    def test_field(self):
        sandbox = Sandbox(self)
        path = sandbox.root / "item.xml"
        path.write_bytes(item_bytes("2026.10.11.1", build_of(11), length=77))
        values = {field: sandbox.run(CLI, "appcast", "field", path, field).stdout.strip()
                  for field in ("version", "short-version", "url", "length", "channel")}
        self.assertEqual(values, {"version": build_of(11), "short-version": "2026.10.11.1",
                                  "url": release.download_url(REPO, "v2026.10.11.1-pre", "Cherry-2026.10.11.1.zip"),
                                  "length": "77", "channel": "prerelease"})


class PromoteTests(unittest.TestCase):
    def test_rewrites_the_urls_drops_the_channel_and_keeps_the_signature(self):
        pre = item("2026.10.11.1", build_of(11), length=1234)
        signature = pre.signature
        promoted = release.Item(release.promote_item(pre, "v2026.10.11.1", REPO))
        page = f"https://github.com/{REPO}/releases/tag/v2026.10.11.1"
        self.assertEqual(promoted.channel, "")
        self.assertEqual(promoted.element.findtext("link"), page)
        self.assertEqual(promoted.element.findtext(release.sparkle("fullReleaseNotesLink")), page)
        self.assertEqual(promoted.url, f"https://github.com/{REPO}/releases/download/v2026.10.11.1/Cherry-2026.10.11.1.zip")
        self.assertEqual((promoted.signature, promoted.length, promoted.build), (signature, "1234", build_of(11)))
        self.assertEqual(promoted.problems(), [])
        self.assertNotEqual(promoted.element.findtext("pubDate"), "Sun, 11 Oct 2026 12:00:00 +0000")

    def test_refuses_a_stable_item_or_another_versions_tag(self):
        with self.assertRaises(release.ReleaseError):
            release.promote_item(item("2026.10.11.1", build_of(11), channel=""), "v2026.10.11.1", REPO)
        for tag in ("v2026.10.11.2", "v2026.10.11.1-pre", "2026.10.11.1"):
            with self.assertRaises(release.ReleaseError, msg=tag):
                release.promote_item(item("2026.10.11.1", build_of(11)), tag, REPO)

    def test_checks_the_zips_length(self):
        sandbox = Sandbox(self)
        path = sandbox.root / "pre.xml"
        path.write_bytes(item_bytes("2026.10.11.1", build_of(11), length=10))
        zip_path = sandbox.root / "Cherry-2026.10.11.1.zip"
        zip_path.write_bytes(b"x" * 11)
        result = sandbox.run(CLI, "appcast", "promote", path, "--tag", "v2026.10.11.1", "--repo", REPO,
                             "--zip", zip_path, "--output", sandbox.root / "out.xml")
        self.assertEqual(result.returncode, 1)
        self.assertIn("11 bytes", result.stderr)
        zip_path.write_bytes(b"x" * 10)
        result = sandbox.run(CLI, "appcast", "promote", path, "--tag", "v2026.10.11.1", "--repo", REPO,
                             "--zip", zip_path, "--output", sandbox.root / "out.xml")
        self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "needs macOS (xcrun swift, CryptoKit)")
class SparkleKeyTests(unittest.TestCase):
    """Scripts/sparkle-key.swift against RFC 8032's Ed25519 test vectors 1 to 3. macOS only."""

    VECTORS = (
        ("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
         "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
         "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46b"
         "d25bf5f0595bbe24655141438e7a100b"),
        ("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb",
         "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
         "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c"
         "387b2eaeb4302aeeb00d291612bb0c00"),
        ("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
         "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
         "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc659"
         "4a7c15e9716ed28dc027beceea1ec40a"),
    )

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="cherry-sparkle-key-"))
        self.addCleanup(shutil.rmtree, self.directory, True)

    def tool(self, *arguments, stdin=""):
        return subprocess.run(["xcrun", "swift", str(SCRIPTS / "sparkle-key.swift"), *map(str, arguments)],
                              input=stdin, capture_output=True, text=True, timeout=300)

    @staticmethod
    def b64(hex_text):
        return base64.b64encode(bytes.fromhex(hex_text)).decode()

    def message(self, index, hex_text):
        path = self.directory / f"message-{index}"
        path.write_bytes(bytes.fromhex(hex_text))
        return path

    def test_derive_gives_each_vectors_public_key_and_verify_accepts_its_signature(self):
        for index, (secret, public, message, signature) in enumerate(self.VECTORS, 1):
            with self.subTest(vector=index):
                derived = self.tool("derive", stdin=self.b64(secret) + "\n")
                self.assertEqual((derived.returncode, derived.stdout.strip()), (0, self.b64(public)), derived.stderr)
                self.assertNotIn(self.b64(secret), derived.stdout + derived.stderr)
                verified = self.tool("verify", self.b64(public), self.message(index, message), self.b64(signature))
                self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_a_legacy_96_byte_key_gives_its_last_32_bytes(self):
        secret, public, _, _ = self.VECTORS[1]
        legacy = bytes(64) + bytes.fromhex(public)
        derived = self.tool("derive", stdin=base64.b64encode(legacy).decode())
        self.assertEqual((derived.returncode, derived.stdout.strip()), (0, self.b64(public)), derived.stderr)

    def test_a_key_of_another_length_is_refused_without_printing_it(self):
        key = base64.b64encode(bytes(range(40))).decode()
        derived = self.tool("derive", stdin=key)
        self.assertEqual(derived.returncode, 2)
        self.assertIn("40 bytes", derived.stderr)
        self.assertNotIn(key, derived.stdout + derived.stderr)
        self.assertEqual(self.tool("derive", stdin="not base64!").returncode, 2)

    def test_a_mismatch_is_refused(self):
        _, public, message, signature = self.VECTORS[2]
        other_public = self.VECTORS[0][1]
        path = self.message(3, message)
        self.assertEqual(self.tool("verify", self.b64(other_public), path, self.b64(signature)).returncode, 1)
        wrong = self.directory / "wrong"
        wrong.write_bytes(b"\xaf\x83")
        self.assertEqual(self.tool("verify", self.b64(public), wrong, self.b64(signature)).returncode, 1)
        self.assertEqual(self.tool("verify", self.b64(public), path, "AAAA").returncode, 2)


class ConfTests(unittest.TestCase):
    PATTERNS = {
        "RELEASE_BUNDLE_ID": r"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$",
        "RELEASE_APP_NAME": r"^[A-Za-z0-9]+$",
        "TEAM_ID": r"^[A-Z0-9]{10}$",
        "GITHUB_REPOSITORY": release.REPO,
        "SPARKLE_FEED_URL": r"^https://[^\s/]+/\S+\.xml$",
        "SPARKLE_KEYCHAIN_ACCOUNT": r"^\S+$",
        "R2_BUCKET": r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$",
        "APPCAST_KEEP_PRERELEASES": r"^[1-9]\d*$",
        "APPCAST_KEEP_STABLE": r"^[1-9]\d*$",
    }

    def test_the_real_release_conf_parses_and_matches_the_formats(self):
        path = REPOSITORY / "Packaging/release.conf"
        conf = release.read_conf(path)
        for key, pattern in self.PATTERNS.items():
            self.assertRegex(conf.get(key, ""), pattern, key)
        self.assertEqual(conf["RELEASE_BUNDLE_ID"], "dev.patrick.cherry")
        public_key = conf.get("SPARKLE_PUBLIC_ED_KEY")
        self.assertIsNotNone(public_key, "SPARKLE_PUBLIC_ED_KEY is missing (it may be empty)")
        if public_key:
            self.assertEqual(len(base64.b64decode(public_key, validate=True)), 32)
        for line in path.read_text().splitlines():
            self.assertTrue(line == "" or line.startswith("#") or re.match(r"^[A-Z0-9_]+=\S*$", line), line)
        # The shell scripts' reader gives the same values.
        for key in self.PATTERNS:
            shell = subprocess.run(["sh", "-c", 'sed -n "s/^$1=//p" "$2" | tail -n 1', "conf", key, str(path)],
                                   capture_output=True, text=True, check=True).stdout.rstrip("\n")
            self.assertEqual(shell, conf[key], key)

    def test_cherry_release_conf_overrides_the_path(self):
        sandbox = Sandbox(self)
        sandbox.conf.write_text(sandbox.conf.read_text().replace("TEAM_ID=Z7Q27G3R62", "TEAM_ID=ABCDEFGHIJ")
                                + "TEAM_ID=LASTWINS00\n")
        result = sandbox.run(CLI, "conf", "TEAM_ID")
        self.assertEqual(result.stdout, "LASTWINS00\n", result.stderr)
        self.assertEqual(sandbox.run(CLI, "conf", "NO_SUCH_KEY").returncode, 1)
        old = os.environ.get("CHERRY_RELEASE_CONF")
        os.environ["CHERRY_RELEASE_CONF"] = str(sandbox.conf)
        try:
            self.assertEqual(release.read_conf()["TEAM_ID"], "LASTWINS00")
        finally:
            if old is None:
                del os.environ["CHERRY_RELEASE_CONF"]
            else:
                os.environ["CHERRY_RELEASE_CONF"] = old


# -- Shell scripts -----------------------------------------------------------------

class ReleasePreflightTests(unittest.TestCase):
    KEY = "the-private-key"
    SECRETS = {"DEVELOPER_ID_P12_BASE64": "cDEy", "DEVELOPER_ID_P12_PASSWORD": "pw", "NOTARY_KEY_P8": "p8",
               "NOTARY_KEY_ID": "ABC123", "NOTARY_ISSUER_ID": "issuer", "SPARKLE_ED_PRIVATE_KEY": KEY}

    def preflight(self, public_key=None, **environment):
        sandbox = Sandbox(self, public_key=fake_public(self.KEY) if public_key is None else public_key)
        result = sandbox.run("release-preflight", **environment)
        return result, sandbox.summary.read_text() if sandbox.summary.exists() else ""

    def test_ready_with_every_secret_and_the_matching_key(self):
        result, _ = self.preflight(APPCAST_SECRETS="all", **self.SECRETS)
        self.assertEqual((result.returncode, result.stdout), (0, "ready=true\n"), result.stderr)
        self.assertNotIn(self.KEY, result.stdout + result.stderr)

    def test_paused_is_not_ready_and_green_unless_a_dry_run(self):
        result, summary = self.preflight(RELEASES_PAUSED="true", APPCAST_SECRETS="partial")
        self.assertEqual((result.returncode, result.stdout), (0, "ready=false\n"), result.stderr)
        self.assertIn("::notice::Releases are paused (RELEASES_PAUSED); a dry run still works", result.stderr)
        self.assertIn("Releases are paused", summary)
        result, _ = self.preflight(RELEASES_PAUSED="true", DRY_RUN="true", APPCAST_SECRETS="all", **self.SECRETS)
        self.assertEqual(result.stdout, "ready=true\n", result.stderr)

    def test_a_dry_run_needs_only_the_signing_secrets(self):
        for appcast in ("none", "partial"):
            result, _ = self.preflight(RELEASES_PAUSED="true", DRY_RUN="true", APPCAST_SECRETS=appcast, **self.SECRETS)
            self.assertEqual((result.returncode, result.stdout), (0, "ready=true\n"), result.stderr)
            self.assertIn("This dry run publishes nothing", result.stderr)
        partial = dict(self.SECRETS)
        del partial["NOTARY_KEY_P8"]
        result, _ = self.preflight(DRY_RUN="true", APPCAST_SECRETS="none", **partial)
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOTARY_KEY_P8", result.stderr)
        self.assertNotIn("appcast environment has", result.stderr)

    def test_no_secrets_at_all_is_not_ready_and_green(self):
        result, summary = self.preflight(APPCAST_SECRETS="none")
        self.assertEqual((result.returncode, result.stdout), (0, "ready=false\n"), result.stderr)
        self.assertIn("nothing was published because the release environments have no secrets", result.stderr)
        self.assertIn("Scripts/release-setup", summary)
        self.assertIn("SPARKLE_ED_PRIVATE_KEY", summary)

    def test_incomplete_secrets_fail(self):
        partial = dict(self.SECRETS)
        del partial["NOTARY_KEY_ID"]
        result, _ = self.preflight(APPCAST_SECRETS="all", **partial)
        self.assertEqual(result.returncode, 1)
        self.assertIn("NOTARY_KEY_ID", result.stderr)
        result, _ = self.preflight(APPCAST_SECRETS="none", **self.SECRETS)
        self.assertEqual(result.returncode, 1)
        self.assertIn("appcast environment", result.stderr)
        result, _ = self.preflight(APPCAST_SECRETS="all")
        self.assertEqual(result.returncode, 1)

    def test_an_empty_public_key_is_not_ready_and_green(self):
        result, _ = self.preflight(public_key="", APPCAST_SECRETS="all", **self.SECRETS)
        self.assertEqual((result.returncode, result.stdout), (0, "ready=false\n"), result.stderr)
        self.assertIn("commit the public key (Scripts/release-setup)", result.stderr)

    def test_a_key_that_is_not_the_committed_ones_fails(self):
        result, _ = self.preflight(public_key=fake_public("another key"), APPCAST_SECRETS="all", **self.SECRETS)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not match SPARKLE_PUBLIC_ED_KEY", result.stderr)
        self.assertNotIn(self.KEY, result.stdout + result.stderr)


class PublishAppcastTests(unittest.TestCase):
    VERSION = "2026.10.11.1"
    BUILD = "20261011120000.abcdef0"
    R2 = {"CLOUDFLARE_ACCOUNT_ID": "account", "AWS_ACCESS_KEY_ID": "key-id", "AWS_SECRET_ACCESS_KEY": "secret"}

    def setUp(self):
        self.sandbox = Sandbox(self)
        self.item = self.sandbox.root / "appcast-item.xml"
        self.item.write_bytes(item_bytes(self.VERSION, self.BUILD, length=4321))
        self.url = release.download_url(REPO, f"v{self.VERSION}-pre", f"Cherry-{self.VERSION}.zip")
        self.sandbox.update(heads={self.url: {"status": 200, "length": 4321}})

    def publish(self, *arguments):
        return self.sandbox.run("publish-appcast", *arguments, **self.R2)

    def feed(self):
        return self.sandbox.state()["objects"]["appcast.xml"]

    def puts(self):
        return [call for call in self.sandbox.calls("aws") if call["operation"] == "put-object"]

    def seed(self, data):
        state = self.sandbox.state()
        state["objects"]["appcast.xml"] = {"body": data.decode(), "etag": '"seed"'}
        self.sandbox.save(state)

    def test_no_feed_yet_creates_it_with_if_none_match(self):
        result = self.publish("add", self.item)
        self.assertEqual(result.returncode, 0, result.stderr)
        puts = self.puts()
        self.assertEqual(len(puts), 1)
        self.assertEqual(puts[0]["options"]["--if-none-match"], "*")
        self.assertEqual(puts[0]["options"]["--content-type"], "application/xml; charset=utf-8")
        self.assertEqual(puts[0]["options"]["--cache-control"], "public, max-age=300")
        self.assertEqual(puts[0]["options"]["--bucket"], "cherry-updates")
        self.assertEqual(puts[0]["options"]["--endpoint-url"], "https://account.r2.cloudflarestorage.com")
        self.assertEqual(puts[0]["environment"], {"AWS_DEFAULT_REGION": "auto", "AWS_PAGER": "",
                                                  "AWS_REQUEST_CHECKSUM_CALCULATION": "when_required",
                                                  "AWS_RESPONSE_CHECKSUM_VALIDATION": "when_required"})
        feed = reload(self.feed()["body"].encode())
        self.assertEqual([i.build for i in feed.items], [self.BUILD])
        self.assertEqual(release.check(feed), [])
        self.assertEqual(outputs(result.stdout), {"etag": self.feed()["etag"]})
        self.assertNotIn("::warning::", result.stderr)

    def test_a_precondition_failure_is_retried(self):
        self.seed(release.Feed.empty(REPO).serialize())
        self.sandbox.update(put_failures=1)
        result = self.publish("add", self.item)
        self.assertEqual(result.returncode, 0, result.stderr)
        puts = self.puts()
        self.assertEqual(len(puts), 2)
        self.assertEqual([p["options"].get("--if-match") for p in puts], ['"seed"', '"seed"'])
        self.assertIn("trying again", result.stderr)
        self.assertEqual([i.build for i in reload(self.feed()["body"].encode()).items], [self.BUILD])

    def test_an_unchanged_feed_is_not_written(self):
        self.seed(merged([release.load_item(str(self.item))]))
        result = self.publish("add", self.item)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("appcast unchanged", result.stderr)
        self.assertEqual(self.puts(), [])

    def test_a_bad_enclosure_is_refused(self):
        for answer, text in (({"status": 200, "length": 4320}, "not 4321"), ({"status": 404, "length": 9}, "")):
            with self.subTest(answer=answer):
                self.sandbox.update(heads={self.url: answer})
                result = self.publish("add", self.item)
                self.assertEqual(result.returncode, 1)
                self.assertIn(text, result.stderr)
                self.assertEqual(self.sandbox.calls("aws"), [])

    def test_remove_and_restore(self):
        other = item("2026.10.11.2", "20261011130000.bcdef01")
        self.seed(merged([release.load_item(str(self.item)), other]))
        result = self.publish("remove", self.VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = reload(self.feed()["body"].encode())
        self.assertEqual([i.version for i in feed.items], ["2026.10.11.2"])
        self.assertTrue(feed.is_pulled(self.BUILD))
        self.assertEqual(self.puts()[-1]["options"]["--if-match"], '"seed"')

        result = self.publish("restore", self.BUILD)
        self.assertEqual(result.returncode, 0, result.stderr)
        feed = reload(self.feed()["body"].encode())
        self.assertFalse(feed.is_pulled(self.BUILD))
        self.assertEqual([i.version for i in feed.items], ["2026.10.11.2"])

        result = self.publish("remove", "2026.10.30.1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(self.puts()), 2)

    def test_add_release_merges_the_releases_item(self):
        self.sandbox.add_release(f"v{self.VERSION}-pre", assets=[
            self.sandbox.asset("appcast-item.xml", self.item.read_bytes())], commit="a" * 40)
        result = self.publish("add-release", f"v{self.VERSION}-pre")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([i.build for i in reload(self.feed()["body"].encode()).items], [self.BUILD])
        self.assertEqual(self.sandbox.run("publish-appcast", "show", **self.R2).stdout, self.feed()["body"])

    def test_add_release_refuses_an_item_of_another_release(self):
        self.sandbox.add_release("v2026.10.11.2-pre", assets=[
            self.sandbox.asset("appcast-item.xml", self.item.read_bytes())], commit="a" * 40)
        result = self.publish("add-release", "v2026.10.11.2-pre")
        self.assertEqual(result.returncode, 1)
        self.assertIn("another release", result.stderr)
        self.assertEqual(self.puts(), [])


class PublishGithubReleaseTests(unittest.TestCase):
    TAG = "v2026.10.11.1-pre"
    TARGET = "1" * 40

    def setUp(self):
        self.sandbox = Sandbox(self)
        self.files = []
        for name, data in (("Cherry-2026.10.11.1.zip", b"zip" * 100), ("Cherry-2026.10.11.1.dmg", b"dmg" * 200),
                           ("SHA256SUMS", b"sums\n"), ("appcast-item.xml", b"<item/>\n")):
            path = self.sandbox.root / "out" / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(data)
            self.files.append(path)
        self.notes = self.sandbox.root / "notes.md"
        self.notes.write_text("- A change\n")
        self.draft_id = self.sandbox.root / "draft-id"

    def publish(self, *kind, tag=TAG):
        return self.sandbox.run("publish-github-release", *kind, "--tag", tag, "--target", self.TARGET,
                                "--title", "Cherry 2026.10.11.1", "--notes", self.notes,
                                "--draft-id-file", self.draft_id, *self.files)

    def test_uploads_go_to_the_drafts_id_as_octet_stream_then_it_is_published(self):
        result = self.publish("--prerelease")
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.sandbox.state()
        [published] = state["releases"]
        identifier = published["id"]
        self.assertEqual(self.draft_id.read_text().strip(), str(identifier))
        uploads = [call for call in self.sandbox.calls("curl") if call["method"] == "POST"]
        self.assertEqual(len(uploads), 4)
        for call, path in zip(uploads, self.files):
            self.assertEqual(call["url"], f"https://uploads.github.com/repos/{REPO}/releases/{identifier}"
                                          f"/assets?name={path.name}")
            self.assertIn("Content-Type: application/octet-stream", call["headers"])
            self.assertTrue(call["authorized"])
        [create] = [c for c in self.sandbox.calls("gh") if c["method"] == "POST"]
        self.assertEqual(create["fields"], {"tag_name": self.TAG, "target_commitish": self.TARGET,
                                            "name": "Cherry 2026.10.11.1", "draft": True, "prerelease": True,
                                            "body": "- A change\n"})
        [patch] = [c for c in self.sandbox.calls("gh") if c["method"] == "PATCH"]
        self.assertEqual(patch["fields"], {"draft": False, "prerelease": True, "make_latest": "false"})
        self.assertEqual((published["draft"], published["prerelease"]), (False, True))
        self.assertEqual(state["tags"][self.TAG], self.TARGET)
        self.assertEqual(outputs(result.stdout), {"tag": self.TAG, "url": published["html_url"]})

    def test_a_digest_mismatch_deletes_the_draft(self):
        self.sandbox.update(corrupt_digest=["Cherry-2026.10.11.1.dmg"])
        result = self.publish("--prerelease")
        self.assertEqual(result.returncode, 1)
        self.assertIn("digest", result.stderr)
        self.assertEqual(self.sandbox.state()["releases"], [])
        deletes = [c for c in self.sandbox.calls("gh") if c["method"] == "DELETE"]
        self.assertEqual([c["path"] for c in deletes], [f"repos/{REPO}/releases/100"])
        self.assertEqual([c for c in self.sandbox.calls("gh") if c["method"] == "PATCH"], [])
        self.assertNotIn(self.TAG, self.sandbox.state()["tags"])

    def test_stable_sends_make_latest_and_needs_the_tag_on_the_target(self):
        tag = "v2026.10.11.1"
        for latest in ("true", "false"):
            with self.subTest(latest=latest):
                self.sandbox.save({"releases": [], "next_id": 100, "tags": {tag: self.TARGET}, "tag_objects": {},
                                   "latest": None, "objects": {}})
                result = self.publish("--stable", "--latest", latest, "--verify-tag", tag=tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                patch = [c for c in self.sandbox.calls("gh") if c["method"] == "PATCH"][-1]
                self.assertEqual(patch["fields"], {"draft": False, "prerelease": False, "make_latest": latest})
        self.sandbox.save({"releases": [], "next_id": 100, "tags": {tag: "2" * 40}, "tag_objects": {},
                           "latest": None, "objects": {}})
        self.sandbox.log_path.write_text("")
        result = self.publish("--stable", "--latest", "true", "--verify-tag", tag=tag)
        self.assertEqual(result.returncode, 1)
        self.assertIn("is on " + "2" * 40, result.stderr)
        self.assertEqual(self.sandbox.writes(), [])

    def test_refuses_an_existing_tag_or_published_release(self):
        self.sandbox.update(tags={self.TAG: self.TARGET})
        result = self.publish("--prerelease")
        self.assertEqual(result.returncode, 1)
        self.assertIn("exists already", result.stderr)
        self.sandbox.add_release(self.TAG, commit=self.TARGET)
        result = self.publish("--prerelease")
        self.assertEqual(result.returncode, 1)
        self.assertIn("published already", result.stderr)
        self.assertEqual(self.sandbox.writes(), [])

    def test_cleanup_deletes_only_a_draft(self):
        draft = self.sandbox.add_release("v2026.10.11.2-pre", draft=True)
        published = self.sandbox.add_release("v2026.10.11.1-pre", commit=self.TARGET)
        for identifier in (published, draft):
            self.draft_id.write_text(f"{identifier}\n")
            result = self.sandbox.run("publish-github-release", "--cleanup", self.draft_id)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([r["id"] for r in self.sandbox.state()["releases"]], [published])
        self.draft_id.unlink()
        self.assertEqual(self.sandbox.run("publish-github-release", "--cleanup", self.draft_id).returncode, 0)
        self.draft_id.write_text("")
        self.assertEqual(self.sandbox.run("publish-github-release", "--cleanup", self.draft_id).returncode, 0)


def git(directory, *arguments):
    environment = {name: value for name, value in os.environ.items() if not name.startswith("GIT_")}
    environment.update({"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Test",
                        "GIT_AUTHOR_EMAIL": "test@example.com", "GIT_COMMITTER_NAME": "Test",
                        "GIT_COMMITTER_EMAIL": "test@example.com", "GIT_AUTHOR_DATE": "2026-10-10T10:00:00Z",
                        "GIT_COMMITTER_DATE": "2026-10-10T10:00:00Z"})
    return subprocess.run(["git", *arguments], cwd=str(directory), capture_output=True, text=True, check=True,
                          env=environment).stdout.strip()


class ReleasePlanTests(unittest.TestCase):
    MORNING = 1791626400  # 2026-10-10 10:00:00 UTC
    PREV_BUILD = "20261010120000.0000000"

    def setUp(self):
        self.sandbox = Sandbox(self)
        self.repository = self.sandbox.root / "repository"
        self.repository.mkdir()
        git(self.repository, "init", "-q", "-b", "main")
        self.commits = []
        for subject in ("First", "Second", "Third <with> & stuff", "Fourth"):
            git(self.repository, "commit", "-q", "--allow-empty", "-m", subject)
            self.commits.append(git(self.repository, "rev-parse", "HEAD"))
        git(self.repository, "checkout", "-q", "-b", "side")
        git(self.repository, "commit", "-q", "--allow-empty", "-m", "Side change")
        git(self.repository, "checkout", "-q", "main")
        git(self.repository, "merge", "-q", "--no-ff", "-m", "Merge something", "side")
        git(self.repository, "tag", "v2026.10.10.1-pre", self.commits[1])
        self.out = self.sandbox.root / "plan"
        item_data = item_bytes("2026.10.10.1", self.PREV_BUILD)
        self.sandbox.add_release("v2026.10.10.1-pre", commit=self.commits[1],
                                 assets=[self.sandbox.asset("appcast-item.xml", item_data)])

    def plan(self, sha, *arguments, now=MORNING):
        result = self.sandbox.run("release-plan", "--out", self.out, "--no-fetch", *arguments, cwd=self.repository,
                                  GITHUB_SHA=sha, CHERRY_RELEASE_NOW=now)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = outputs(result.stdout)
        self.assertEqual(set(values), {"build", "publish", "appcast_tag", "version", "tag", "build_id", "prev_tag",
                                       "reason"})
        return values

    def test_an_older_commit_is_skipped(self):
        values = self.plan(self.commits[0])
        self.assertEqual((values["build"], values["publish"], values["appcast_tag"]), ("false", "false", ""))
        self.assertIn("older than v2026.10.10.1-pre", values["reason"])

    def test_the_released_commit_gives_its_tag_for_the_appcast(self):
        values = self.plan(self.commits[1])
        self.assertEqual((values["build"], values["publish"], values["appcast_tag"]),
                         ("false", "false", "v2026.10.10.1-pre"))
        self.assertEqual(self.sandbox.writes(), [])

    def test_a_newer_commit_gets_the_next_n_and_a_stamp_after_the_previous_build(self):
        git(self.repository, "tag", "v2026.10.10.2-pre", self.commits[0])  # a stray tag: N skips it
        values = self.plan(git(self.repository, "rev-parse", "HEAD"))
        head = git(self.repository, "rev-parse", "HEAD")
        self.assertEqual((values["build"], values["publish"], values["appcast_tag"]), ("true", "true", ""))
        self.assertEqual(values["version"], "2026.10.10.3")
        self.assertEqual(values["tag"], "v2026.10.10.3-pre")
        self.assertEqual(values["build_id"], f"20261010120001.{head[:7]}")
        self.assertEqual(values["prev_tag"], "v2026.10.10.1-pre")
        markdown = (self.out / "notes.md").read_text()
        self.assertIn("Third \\<with> & stuff", markdown)
        self.assertIn("Fourth", markdown)
        self.assertIn("Side change", markdown)
        self.assertNotIn("Second", markdown)
        self.assertNotIn("Merge something", markdown)
        self.assertIn(f"compare/v2026.10.10.1-pre...v2026.10.10.3-pre", markdown)
        self.assertIn(f"Build `20261010120001.{head[:7]}`", markdown)
        self.assertIn("Third &lt;with&gt; &amp; stuff", (self.out / "notes.html").read_text())

    def test_a_dry_run_builds_and_never_deletes_or_publishes(self):
        self.sandbox.add_release("v2026.10.10.5-pre", draft=True)
        values = self.plan(self.commits[1], "--dry-run")
        self.assertEqual((values["build"], values["publish"], values["appcast_tag"]), ("true", "false", ""))
        self.assertEqual(values["version"], "2026.10.10.6")
        self.assertEqual(self.sandbox.writes(), [])

    def test_stale_prerelease_drafts_are_deleted_and_stable_drafts_and_tags_kept(self):
        stale = self.sandbox.add_release("v2026.10.10.5-pre", draft=True)
        stable_draft = self.sandbox.add_release("v2026.10.10.1", draft=True, prerelease=False)
        values = self.plan(self.commits[3], now=self.MORNING + 86400)
        self.assertEqual(values["version"], "2026.10.11.1")
        writes = self.sandbox.writes()
        self.assertEqual([(w["method"], w["path"]) for w in writes], [("DELETE", f"repos/{REPO}/releases/{stale}")])
        self.assertEqual(sorted(r["id"] for r in self.sandbox.state()["releases"]), [100, stable_draft])
        self.assertIn("v2026.10.10.1-pre", git(self.repository, "tag", "-l"))

    def test_a_rewritten_main_releases_its_tip_only(self):
        git(self.repository, "checkout", "-q", "-b", "rewritten", self.commits[0])
        git(self.repository, "commit", "-q", "--allow-empty", "-m", "Rewritten")
        rewritten = git(self.repository, "rev-parse", "HEAD")
        result = self.sandbox.run("release-plan", "--out", self.out, "--no-fetch", cwd=self.repository,
                                  GITHUB_SHA=rewritten, CHERRY_RELEASE_NOW=self.MORNING)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("::warning::main was rewritten", result.stderr)
        values = outputs(result.stdout)
        self.assertEqual((values["build"], values["publish"]), ("true", "true"))
        markdown = (self.out / "notes.md").read_text()
        self.assertIn("Rewritten", markdown)
        self.assertNotIn("First", markdown)
        git(self.repository, "checkout", "-q", "main")
        values = self.plan(rewritten)
        self.assertEqual((values["build"], values["publish"]), ("false", "false"))
        self.assertIn("not main's tip", values["reason"])

    def test_the_first_release(self):
        self.sandbox.save({"releases": [], "next_id": 100, "tags": {}, "tag_objects": {}, "latest": None,
                           "objects": {}})
        values = self.plan(self.commits[2])
        self.assertEqual((values["build"], values["publish"], values["prev_tag"]), ("true", "true", ""))
        self.assertEqual(values["version"], "2026.10.10.2")  # the local tag v2026.10.10.1-pre counts
        self.assertEqual(values["build_id"], f"20261010100000.{self.commits[2][:7]}")
        markdown = (self.out / "notes.md").read_text()
        self.assertIn("First", markdown)
        self.assertNotIn("compare", markdown)


class PromoteReleaseTests(unittest.TestCase):
    VERSION = "2026.10.11.1"
    BUILD = "20261011120000.abcdef0"
    PRE_SHA = "1" * 40

    def setUp(self):
        self.sandbox = Sandbox(self)
        zip_data = b"the notarized zip" * 50
        dmg_data = b"the notarized dmg" * 70
        sums = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in (
            (f"Cherry-{self.VERSION}.zip", zip_data), (f"Cherry-{self.VERSION}.dmg", dmg_data))).encode()
        self.pre_item = item_bytes(self.VERSION, self.BUILD, length=len(zip_data))
        self.zip_data, self.dmg_data = zip_data, dmg_data
        self.sandbox.add_release(f"v{self.VERSION}-pre", commit=self.PRE_SHA, body="- A change\n", assets=[
            self.sandbox.asset(f"Cherry-{self.VERSION}.zip", zip_data),
            self.sandbox.asset(f"Cherry-{self.VERSION}.dmg", dmg_data),
            self.sandbox.asset("SHA256SUMS", sums),
            self.sandbox.asset("appcast-item.xml", self.pre_item)])
        self.sandbox.update(public_feed=merged([release.Item(ET.fromstring(self.pre_item))]).decode())
        self.draft_id = self.sandbox.root / "draft-id"

    def promote(self, requested):
        return self.sandbox.run("promote-release", requested, "--draft-id-file", self.draft_id)

    def stable_release(self):
        return next(r for r in self.sandbox.state()["releases"] if r["tag_name"] == f"v{self.VERSION}")

    def test_a_missing_prerelease(self):
        result = self.promote("v2026.10.12.1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("There is no pre-release `v2026.10.12.1-pre`, so `v2026.10.12.1` promotes nothing. "
                      "Delete the tag (`git push origin :refs/tags/v2026.10.12.1`)", result.stderr)
        self.assertEqual(self.sandbox.writes(), [])

    def test_paused_releases_promote_nothing(self):
        result = self.sandbox.run("promote-release", f"v{self.VERSION}", "--draft-id-file", self.draft_id,
                                  RELEASES_PAUSED="true")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"Releases are paused (RELEASES_PAUSED is true), so v{self.VERSION} is not promoted.",
                      result.stderr)
        self.assertIn("nothing was promoted", self.sandbox.summary.read_text())
        self.assertEqual(self.sandbox.calls(), [])
        result = self.sandbox.run("promote-release", "", "--draft-id-file", self.draft_id, RELEASES_PAUSED="true")
        self.assertEqual(result.returncode, 1)
        self.assertIn("so the newest pre-release is not promoted", result.stderr)
        self.assertEqual(self.sandbox.calls(), [])

    def test_a_malformed_request(self):
        result = self.promote("v2026.10.12")
        self.assertEqual(result.returncode, 1)
        self.assertIn("`v2026.10.12` is not vYYYY.MM.DD.N", result.stderr)

    def test_a_stable_tag_on_another_commit(self):
        self.sandbox.update(tags={f"v{self.VERSION}-pre": self.PRE_SHA, f"v{self.VERSION}": "2" * 40})
        result = self.promote(f"v{self.VERSION}")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"`v{self.VERSION}` is on {'2' * 40} but `v{self.VERSION}-pre` is on {self.PRE_SHA}: "
                      f"delete it and run Scripts/promote {self.VERSION}.", result.stderr)
        self.assertEqual(self.sandbox.writes(), [])

    def test_already_stable_changes_nothing(self):
        self.sandbox.add_release(f"v{self.VERSION}", prerelease=False, commit=self.PRE_SHA)
        result = self.promote(f"v{self.VERSION}")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = outputs(result.stdout)
        self.assertEqual((values["already_stable"], values["tag"]), ("true", f"v{self.VERSION}"))
        self.assertEqual(self.sandbox.writes(), [])

    def test_a_pulled_build_is_refused(self):
        feed = reload(self.sandbox.state()["public_feed"].encode())
        release.remove(feed, self.VERSION)
        self.sandbox.update(public_feed=feed.serialize().decode())
        result = self.promote(self.VERSION)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{self.VERSION} was pulled from the appcast; restore it first (Actions › Appcast › restore).",
                      result.stderr)
        self.assertEqual(self.sandbox.writes(), [])

    def test_publishes_five_assets_including_cherry_dmg_and_tags_a_dispatch(self):
        stale = self.sandbox.add_release(f"v{self.VERSION}", draft=True, prerelease=False)
        result = self.promote("")
        self.assertEqual(result.returncode, 0, result.stderr)
        values = outputs(result.stdout)
        self.assertEqual((values["already_stable"], values["tag"]), ("false", f"v{self.VERSION}"))
        state = self.sandbox.state()
        self.assertNotIn(stale, [r["id"] for r in state["releases"]])
        stable = self.stable_release()
        self.assertEqual(values["url"], stable["html_url"])
        self.assertEqual((stable["draft"], stable["prerelease"], stable["make_latest"]), (False, False, "true"))
        self.assertEqual(state["latest"], f"v{self.VERSION}")
        self.assertEqual(state["tags"][f"v{self.VERSION}"], self.PRE_SHA)
        [tag_object] = state["tag_objects"].values()
        self.assertEqual((tag_object["tag"], tag_object["object"], tag_object["message"]),
                         (f"v{self.VERSION}", self.PRE_SHA, f"Cherry {self.VERSION}"))
        assets = {asset["name"]: Path(asset["path"]).read_bytes() for asset in stable["assets"]}
        self.assertEqual(sorted(assets), sorted([f"Cherry-{self.VERSION}.zip", f"Cherry-{self.VERSION}.dmg",
                                                 "Cherry.dmg", "SHA256SUMS", "appcast-item.xml"]))
        self.assertEqual(assets["Cherry.dmg"], self.dmg_data)
        self.assertEqual(assets[f"Cherry-{self.VERSION}.zip"], self.zip_data)
        sums = assets["SHA256SUMS"].decode().splitlines()
        self.assertEqual(sorted(line.split()[1] for line in sums),
                         sorted([f"Cherry-{self.VERSION}.zip", f"Cherry-{self.VERSION}.dmg", "Cherry.dmg"]))
        promoted = release.Item(ET.fromstring(assets["appcast-item.xml"]))
        self.assertEqual(promoted.channel, "")
        self.assertEqual(promoted.url, release.download_url(REPO, f"v{self.VERSION}", f"Cherry-{self.VERSION}.zip"))
        self.assertEqual(promoted.signature, release.Item(ET.fromstring(self.pre_item)).signature)
        self.assertTrue(stable["body"].startswith(
            f"Promoted from [`v{self.VERSION}-pre`](https://github.com/{REPO}/releases/tag/v{self.VERSION}-pre)."))
        self.assertIn("- A change", stable["body"])

    def test_a_newer_stable_release_stays_latest(self):
        self.sandbox.add_release("v2026.10.12.1", prerelease=False, commit="3" * 40, latest=True)
        result = self.promote(self.VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stable_release()["make_latest"], "false")
        self.assertEqual(self.sandbox.state()["latest"], "v2026.10.12.1")


class ReleaseSetupTests(unittest.TestCase):
    """Scripts/release-setup, run from a copy of the repository whose
    .build/artifacts holds the fake generate_keys."""

    KEY = "the-sparkle-seed"
    ACCOUNT = "dev.patrick.cherry"

    def setUp(self, public_key=None):
        self.sandbox = Sandbox(self, public_key=fake_public(self.KEY) if public_key is None else public_key)
        self.repository = self.sandbox.root / "repository"
        (self.repository / "Scripts").mkdir(parents=True)
        shutil.copy2(SCRIPTS / "release-setup", self.repository / "Scripts/release-setup")
        tool = self.repository / ".build/artifacts/sparkle/Sparkle/bin/generate_keys"
        tool.parent.mkdir(parents=True)
        tool.write_text(WRAPPER.format(python=sys.executable, directory=str(self.sandbox.bin), tool="generate_keys"))
        tool.chmod(0o755)
        self.sandbox.update(keychain={self.ACCOUNT: self.KEY})

    def setup(self, *arguments, stdin=""):
        return self.sandbox.run(self.repository / "Scripts/release-setup", *arguments, stdin=stdin)

    def secrets(self):
        return self.sandbox.state().get("secrets", {})

    def generate_keys_actions(self):
        return [call["action"] for call in self.sandbox.calls("generate_keys")]

    def test_a_full_run_skips_the_parts_it_is_not_given_and_ends_with_what_is_left(self):
        for stdin in ("\n\n\n", ""):
            with self.subTest(stdin=stdin):
                result = self.setup(stdin=stdin)
                self.assertEqual(result.returncode, 0, result.stderr)
                for part in ("developer-id --p12 PATH", "notary --notary-key AuthKey_<KEY ID>.p8", "cloudflare"):
                    self.assertIn(f"skipped for now: run Scripts/release-setup --only {part} once you have it",
                                  result.stdout)
                self.assertIn("Skipped for now: developer-id, notary, cloudflare.", result.stdout)
                self.assertIn("Left to do by hand", result.stdout)
                state = self.sandbox.state()
                self.assertEqual(state["variables"], {"RELEASES_PAUSED": "true"})
                self.assertEqual(state["environments"]["release"]["policies"], [{"name": "main", "type": "branch"}])
                self.assertEqual(state["environments"]["appcast"]["policies"],
                                 [{"name": "main", "type": "branch"}, {"name": "v*", "type": "tag"}])
                self.assertEqual(self.secrets(), {"release": {"SPARKLE_ED_PRIVATE_KEY": self.KEY + "\n"}})
        self.assertNotIn("generate", self.generate_keys_actions())
        self.assertNotIn(self.KEY, self.setup(stdin="").stdout)

    def test_a_part_run_alone_needs_its_file_or_account_id(self):
        for part, message in (("developer-id", "no file"), ("notary", "no file"), ("cloudflare", "no account ID")):
            with self.subTest(part):
                result = self.setup("--only", part, stdin="\n")
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"error: {message}", result.stderr)
                self.assertNotIn("Left to do by hand", result.stdout)
        self.assertEqual(self.secrets(), {})

    def test_a_given_p12_sets_both_secrets(self):
        p12 = self.sandbox.root / "developer-id.p12"
        p12.write_bytes(bytes(range(256)) * 3)
        result = self.setup("--only", "developer-id", "--p12", p12, stdin="the password\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        secrets = self.secrets()["release"]
        self.assertEqual(base64.b64decode(secrets["DEVELOPER_ID_P12_BASE64"]), p12.read_bytes())
        self.assertEqual(secrets["DEVELOPER_ID_P12_PASSWORD"], "the password")
        self.assertNotIn("the password", result.stdout + result.stderr)

    def test_a_committed_key_the_keychain_lacks_is_never_replaced_by_a_new_one(self):
        self.sandbox.update(keychain={})
        conf = self.sandbox.conf.read_text()
        result = self.setup("--only", "sparkle")
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"holds the public key {fake_public(self.KEY)}, but this keychain has no Sparkle key for "
                      f"account {self.ACCOUNT}", result.stderr)
        self.assertIn(f"--account {self.ACCOUNT} -f FILE", result.stderr)
        self.assertEqual(self.generate_keys_actions(), ["print"])
        self.assertEqual(self.sandbox.state()["keychain"], {})
        self.assertEqual(self.sandbox.conf.read_text(), conf)
        self.assertEqual(self.secrets(), {})

    def test_with_no_committed_key_it_generates_one_and_writes_its_public_key(self):
        self.sandbox.conf.write_text(FIXTURE_CONF.format(public_key=""))
        self.sandbox.update(keychain={})
        result = self.setup("--only", "sparkle")
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.sandbox.state()
        [seed] = state["generated"]
        self.assertEqual(self.generate_keys_actions(), ["print", "generate", "print"])
        self.assertIn(f"SPARKLE_PUBLIC_ED_KEY={fake_public(seed)}\n", self.sandbox.conf.read_text())
        self.assertEqual(self.secrets(), {"release": {"SPARKLE_ED_PRIVATE_KEY": seed + "\n"}})
        self.assertNotIn(seed, result.stdout + result.stderr)

    def test_a_keychain_key_that_is_not_the_committed_one_is_refused(self):
        self.sandbox.update(keychain={self.ACCOUNT: "another seed"})
        result = self.setup("--only", "sparkle")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Changing the key is a rotation", result.stderr)
        self.assertEqual(self.generate_keys_actions(), ["print"])
        self.assertEqual(self.secrets(), {})


class SignAppTests(unittest.TestCase):
    """Scripts/sign-app with a fake codesign: which signatures get the hardened
    runtime and the entitlements."""

    def setUp(self):
        self.sandbox = Sandbox(self)
        self.app = self.sandbox.root / "Cherry.app"
        framework = self.app / "Contents/Frameworks/Sparkle.framework/Versions/B"
        (framework / "Updater.app/Contents/MacOS").mkdir(parents=True)
        (framework / "Autoupdate").write_bytes(b"")
        (self.app / "Contents/MacOS").mkdir(parents=True)
        for name in ("CherryApp", "cherry", "cherry-host"):
            (self.app / "Contents/MacOS" / name).write_bytes(b"")
        self.entitlements = self.sandbox.root / "Cherry.entitlements"
        self.entitlements.write_text("<plist version=\"1.0\"><dict/></plist>\n")

    def sign(self, identity, team=None):
        self.sandbox.update(codesign_team=team)
        return self.sandbox.run("sign-app", "--identity", identity, "--entitlements", self.entitlements, self.app)

    def signatures(self):
        """(file name, arguments) of each signature, in order."""
        return [(Path(call["args"][-1]).name, call["args"]) for call in self.sandbox.calls("codesign")
                if "--sign" in call["args"]]

    def assertSigned(self, signatures, runtime, entitlements):
        names = [name for name, _ in signatures]
        self.assertEqual(names, ["Updater.app", "Sparkle.framework", "cherry", "cherry-host", "Cherry.app"])
        for name, arguments in signatures:
            with self.subTest(name):
                self.assertEqual("--options" in arguments and "runtime" in arguments, runtime)
                self.assertEqual("--entitlements" in arguments, entitlements and name == "Cherry.app")

    def test_a_certificate_with_a_team_id_signs_with_the_hardened_runtime_and_entitlements(self):
        result = self.sign("Developer ID Application: Someone (Z7Q27G3R62)", team="Z7Q27G3R62")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        signatures = self.signatures()
        self.assertEqual([name for name, _ in signatures].count("Autoupdate"), 1)
        self.assertIn("runtime", signatures[0][1])
        self.assertIn("--timestamp", signatures[0][1])
        self.assertSigned(signatures[1:], runtime=True, entitlements=True)

    def test_a_certificate_without_a_team_id_signs_as_ad_hoc_does(self):
        result = self.sign("My Local Cert")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("warning: My Local Cert has no Team ID", result.stderr)
        signatures = self.signatures()
        self.assertEqual([name for name, _ in signatures[:2]], ["Autoupdate", "Autoupdate"])
        self.assertIn("runtime", signatures[0][1])
        self.assertNotIn("runtime", signatures[1][1])
        self.assertSigned(signatures[2:], runtime=False, entitlements=False)
        self.assertTrue(all("--timestamp" in arguments for _, arguments in signatures))

    def test_ad_hoc_signs_with_neither_runtime_nor_entitlements_nor_a_timestamp(self):
        result = self.sign("-")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("warning", result.stderr)
        self.assertEqual([call["args"][0] for call in self.sandbox.calls("codesign") if call["args"][0] == "-dv"], [])
        signatures = self.signatures()
        self.assertEqual(signatures[0][0], "Autoupdate")
        self.assertSigned(signatures[1:], runtime=False, entitlements=False)
        self.assertTrue(all("--timestamp=none" in arguments for _, arguments in signatures))


if __name__ == "__main__":
    unittest.main()
