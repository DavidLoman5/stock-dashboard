"""The contract between the pipeline and index.html.

Block ids, their window.* globals and the note-field privacy policy all come from
page-contract.json at the repo root - the same file lib/pagedata.ps1 reads. Before that file
existed this module and publish.ps1/build-demo.ps1/screen.ps1/... each carried their own copy
of the marker convention and their own copy of the guest/owner field lists, so renaming a
block or adding an owner-only note field meant finding every copy.

Leaf module: imports nothing from the package.
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTRACT_PATH = os.path.join(ROOT, "page-contract.json")

_cache = {"mtime": None, "value": None}


def contract():
    """Parsed page-contract.json, re-read when the file changes."""
    mtime = os.path.getmtime(CONTRACT_PATH)
    if _cache["mtime"] != mtime:
        with open(CONTRACT_PATH, "r", encoding="utf-8-sig") as fh:
            _cache["value"] = json.load(fh)
        _cache["mtime"] = mtime
    return _cache["value"]


def block_ids():
    """Every <script id> the pipeline splices data into, in declaration order."""
    return tuple(contract()["blocks"].keys())


def block_var(block_id):
    """The window.* global a block assigns, e.g. 'dashdata' -> 'DASH'."""
    return contract()["blocks"][block_id]["global"]


def guest_note_fields():
    """Per-code note fields that may be shown to non-owners or published."""
    return tuple(contract()["noteFields"]["guest"])


def owner_only_fields():
    """Note fields written with the owner's whole portfolio in view. Never leave this machine."""
    return tuple(contract()["noteFields"]["ownerOnly"])


def market_public_fields():
    """`_market` fields that are genuinely market-wide and may be shown to non-owners."""
    return tuple(contract()["noteFields"]["marketPublic"])


def js(value):
    """JSON for embedding inside <script>. Breaking up '</' is what stops a string in the data
    from closing the tag early and turning data into markup."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


def block_text(html, block_id):
    """Raw inner text of a block, or None if the marker is absent."""
    start_tag = '<script id="%s">' % block_id
    i1 = html.find(start_tag)
    if i1 < 0:
        return None
    i2 = html.find("</script>", i1)
    if i2 < 0:
        return None
    return html[i1 + len(start_tag):i2]


def splice(html, block_id, payload):
    """Replace the body of <script id="block_id">…</script>.

    Fails closed, matching lib/pagedata.ps1's Set-PageBlocks: an unknown id and a marker that
    is not in the page are both programming errors. This used to return the html untouched on a
    missing marker, which renders as a silently blank section - the same failure mode that let
    the tokenusage block ship empty to every self-hosted user (commit 6fc268a). A caller that
    genuinely wants "splice if present" should check block_text() first.
    """
    if block_id not in contract()["blocks"]:
        raise KeyError("%r is not a block in page-contract.json" % block_id)
    start_tag = '<script id="%s">' % block_id
    i1 = html.find(start_tag)
    if i1 < 0:
        raise ValueError("index.html has no marker for block %r" % block_id)
    i2 = html.find("</script>", i1)
    if i2 < 0:
        raise ValueError("block %r is never closed in index.html" % block_id)
    return html[: i1 + len(start_tag)] + payload + html[i2:]


def set_block(html, block_id, value):
    """Splice a Python value as `window.NAME=<json>;`. None empties the block."""
    if value is None:
        return splice(html, block_id, "")
    return splice(html, block_id, "window.%s=%s;" % (block_var(block_id), js(value)))
