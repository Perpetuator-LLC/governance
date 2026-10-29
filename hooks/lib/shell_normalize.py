"""hooks/lib/shell_normalize.py — resolve shell quoting and backslash escapes well enough to defeat
the common secret-read evasions, for MATCHING only; the result is never executed.

Handles: adjacent quoted/unquoted word fragments concatenating ('.e'nv -> .env), an unquoted
backslash before an ordinary character being dropped (a shell removes it: .\\env -> .env), a
double-quoted span's escapes limited to \\$ \\` \\" \\\\ and a line continuation (every other
backslash inside "..." stays literal, as a real shell leaves it), and a $'...' ANSI-C string's
common escapes (\\n \\t \\xHH and the rest).

NOT a full shell grammar: $(...), backticks and arithmetic are left as literal text — the caller's
own nesting check already refuses those outright before this ever runs, which is the safer
direction for a detector whose only failure mode that matters is a MISSED read.
"""
import re

_ANSIC = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
          "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?"}


def _ansic_unescape(body):
    out, i, n = [], 0, len(body)
    while i < n:
        c = body[i]
        if c == "\\" and i + 1 < n:
            nxt = body[i + 1]
            if nxt in _ANSIC:
                out.append(_ANSIC[nxt]); i += 2; continue
            if nxt == "x":
                m = re.match(r"[0-9A-Fa-f]{1,2}", body[i + 2:i + 4])
                if m:
                    out.append(chr(int(m.group(0), 16))); i += 2 + len(m.group(0)); continue
            if nxt in "01234567":
                m = re.match(r"[0-7]{1,3}", body[i + 1:i + 4])
                if m:
                    out.append(chr(int(m.group(0), 8) & 0xFF)); i += 1 + len(m.group(0)); continue
            out.append(nxt); i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def normalize(text):
    """<shell text> -> <text a detector should match against>, quoting and escapes resolved."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":
            j = text.find("'", i + 1)
            if j == -1:
                out.append(text[i:]); break
            out.append(text[i + 1:j]); i = j + 1; continue
        if c == "$" and text[i + 1:i + 2] == "'":
            j = text.find("'", i + 2)
            if j == -1:
                out.append(text[i:]); break
            out.append(_ansic_unescape(text[i + 2:j])); i = j + 1; continue
        if c == '"':
            j, buf = i + 1, []
            while j < n and text[j] != '"':
                if text[j] == "\\" and j + 1 < n and text[j + 1] in '$`"\\\n':
                    buf.append(text[j + 1]); j += 2
                else:
                    buf.append(text[j]); j += 1
            out.append("".join(buf)); i = j + 1; continue
        if c == "\\" and i + 1 < n:
            nxt = text[i + 1]
            i += 2
            if nxt != "\n":
                out.append(nxt)
            continue
        out.append(c); i += 1
    return "".join(out)
