#!/usr/bin/env python3
"""frontmatter_paths.py — the ONE definition of "a path value in vault frontmatter".

Shared by every tool that detects or repairs frontmatter paths, so they cannot disagree about what
counts as a path — a second definition would let a fixer repair values the check never looks at, or
worse, the reverse.

WHY DETECTION IS BY SHAPE, NOT BY A KEY ROSTER
----------------------------------------------
The obvious design is a list of path-bearing keys (`attachments[].path`, `related_state_doc`, …). A
real vault easily carries dozens of such keys, and a roster has exactly the failure mode this check
exists to prevent: **a key added next month is not in the roster, so its dead paths are silently
outside the denominator.** A check that cannot see a whole category reports green about it forever.

So detection is by VALUE SHAPE — a string containing "/" that ends in a known file extension — which
picks up new keys for free. The cost is false positives (prose living in a path field, e.g.
`State/{A,B,C}.md`), and those are handled by an explicit BASELINE rather than by narrowing the
detector.
"""
import os
import re

# Extensions a vault actually references. Deliberately explicit: a bare
# "contains a slash" test matches half the prose in a journal.
EXTS = (".md", ".markdown", ".txt", ".csv", ".json", ".yaml", ".yml", ".pdf",
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".svg",
        ".mp4", ".mov", ".m4a", ".mp3", ".wav", ".vtt", ".zip",
        ".docx", ".xlsx", ".pptx")

FM_RE = re.compile(r"\A---\n(.*?)\n---\n", re.S)
SKIP_DIRS = {".git", ".trash", ".obsidian", "node_modules", "__pycache__", ".workspace"}


def looks_like_path(value):
    """A string that claims to point at a file in (or beside) the vault."""
    if not isinstance(value, str) or len(value) > 512:
        return False
    v = value.strip()
    if not v or "://" in v or v.startswith(("http", "mailto:", "#")):
        return False
    if "/" not in v:
        return False
    return v.lower().endswith(EXTS)


def walk_values(node, trail=()):
    """Yield (dotted-key-path, string value) for every scalar in the frontmatter."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk_values(v, trail + (str(k),))
    elif isinstance(node, list):
        for v in node:
            yield from walk_values(v, trail + ("[]",))
    elif isinstance(node, str):
        yield ".".join(trail), node


def resolve(root, value, aliases=None):
    """Does this value point at a real, non-empty file?

    Absolute paths (e.g. a large-file store outside the vault) are tested as-is; everything else is
    vault-relative.

    `aliases` maps a path PREFIX to ANOTHER vault root, for CROSS-VAULT references.
    ⚠️ Without it, a multi-vault setup reports correct references as dead: a value like
    `Other/State/Doc.md` that is right as written, inside a sibling vault, only looks broken to a
    single-root scan.

    That false-positive class is dangerous beyond noise. A basename-unique "relocation" of such a
    value can rewrite it to point at the very file it sits in — a self-reference that also breaks a
    custody boundary — and the dead-path COUNT IMPROVES. A repair measured by "less of the bad thing"
    can always improve its own metric by manufacturing the good thing falsely.
    """
    # A ~-prefixed value is HOME-relative, i.e. absolute — not vault-relative. Joining it to a vault
    # root produces a confident false positive: the instrument answers about a path that was never
    # the one being referenced.
    if value.startswith("~"):
        candidates = [os.path.expanduser(value)]
    elif os.path.isabs(value):
        candidates = [value]
    else:
        candidates = [os.path.join(root, value)]
        for prefix, alt_root in (aliases or {}).items():
            if value.startswith(prefix):
                candidates.append(os.path.join(alt_root, value[len(prefix):]))
    for i, p in enumerate(candidates):
        try:
            if os.path.isfile(p) and os.path.getsize(p) > 0:
                # i > 0 means it resolved via an ALIAS, i.e. the reference crosses a vault/custody
                # boundary. Reported as its own category rather than folded into "resolved": an
                # alias that silently passes every cross-vault reference converts a possible
                # CUSTODY-BOUNDARY question into an invisible one. Whether such a link is legitimate
                # or a boundary leak is a governance judgement the checker cannot make — so it must
                # not make it silently in either direction.
                return "cross-vault" if i else True
        except OSError:
            continue
    return False


class UnreadableError(Exception):
    """A part of the vault could not be read. NEVER silently skipped."""


def iter_markdown(root, unreadable=None):
    """Yield (abs_path, frontmatter_text, body) for every .md carrying frontmatter.

    Raises on a missing root rather than yielding nothing — a routine that reads a dead path and
    continues on defaults emits a confident report about a vault it never opened.

    ⚠️ A PRESENT-BUT-UNREADABLE root, subtree, or file is NOT the same as a missing one, and it is
    the more dangerous case: `os.walk` swallows permission errors by default and an unreadable
    subtree simply produces fewer results — a smaller, confident, entirely clean-looking report.
    That is precisely the disease this module exists to find, so:
      * an unreadable ROOT raises;
      * an unreadable SUBTREE or FILE is appended to `unreadable` (caller-supplied list) and MUST be
        surfaced as a failure by the caller — never dropped.
    """
    if not os.path.isdir(root):
        raise SystemExit("VAULT ROOT MISSING: %s\n"
                         "Refusing to report on a vault that was never opened." % root)
    if not os.access(root, os.R_OK | os.X_OK):
        raise SystemExit("VAULT ROOT PRESENT BUT UNREADABLE: %s\n"
                         "A permissions failure that yields fewer files reads as a "
                         "clean vault. Refusing." % root)
    sink = unreadable if unreadable is not None else []

    def on_walk_error(exc):
        sink.append({"path": getattr(exc, "filename", "?"),
                     "error": type(exc).__name__, "kind": "directory"})

    seen_any = False
    for dirpath, dirnames, filenames in os.walk(root, onerror=on_walk_error):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = open(p, encoding="utf-8").read()
            except (OSError, UnicodeDecodeError) as exc:
                sink.append({"path": p, "error": type(exc).__name__, "kind": "file"})
                continue
            seen_any = True
            m = FM_RE.match(text)
            if m:
                yield p, m.group(1), text[m.end():]
    if not seen_any:
        raise SystemExit("VAULT ROOT %s contains no readable .md files — that is a "
                         "broken selector, not an empty vault." % root)
