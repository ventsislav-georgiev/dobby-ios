# The one JS comment stripper for the run-checks.sh blocks (#194), moved here out of
# BRIDGENAMESPY so PIGATEPY can strip the window.Dobby literal with the same rule.
#
# A block imports it with sys.path.insert(0, "Tests") and calls strip_js(js). Naive by design,
# exactly as the #158 original: /* */ blocks (non-nested, may span lines) go first, then // to
# end of line, with no string awareness, so a // inside a JS string ('dobby-offline:///...')
# loses the rest of its line. Line structure is kept: a stripped block leaves its newlines out,
# so callers that report line numbers must only count lines before the first block comment.
# The probe below runs on every import.
import re
import sys


def strip_js(js):
    js = re.sub(r"/\*.*?\*/", "", js, flags=re.S)
    return "\n".join(re.sub(r"//.*", "", l) for l in js.splitlines())


_PROBE = "a: 1,\n/*\nb: 2,\n*/\nc: 3, // d: 4\n/* e */ f: 5,\n"
_WANT = "a: 1,\n\nc: 3, \n f: 5,"
if strip_js(_PROBE) != _WANT:
    sys.stderr.write("FAIL: the JS comment stripper is broken: %r (#194 js_strip)\n" % strip_js(_PROBE))
    sys.exit(1)

if __name__ == "__main__":
    print("PASS: the shared JS comment stripper drops /* */ blocks across lines and // tails (#194)")
