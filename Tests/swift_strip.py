# The one Swift comment stripper for the run-checks.sh blocks (#190).
#
# A block imports it with sys.path.insert(0, "Tests") and calls strip_swift(text, name)
# (comment-free, blank lines dropped, for pins) or strip_swift_lines(text, name) (one entry
# per source line, for checks that report line numbers). The probe below runs on every
# import, so a broken stripper fails the block that relies on it before any pin reads it.
#
# Lexed as a whole text, not per line: // line comments, /* */ block comments (nested, may
# span lines), "..." strings, """...""" multi-line strings and raw strings #"..."# / #"""..."""#
# with any number of #. A comment marker inside any literal is kept as code; an escape is a
# backslash followed by the literal's own # count. Input that ends inside a block comment or
# a literal fails by name instead of silently eating the rest of the file.
import re
import sys

_OPEN = re.compile(r'(#*)("""|")')


def _fail(msg):
    sys.stderr.write("FAIL: %s (#190 swift_strip)\n" % msg)
    sys.exit(1)


def strip_swift_lines(text, name="input"):
    out, i, n, depth, closer, esc, multi = [], 0, len(text), 0, None, "", False
    while i < n:
        c = text[i]
        if depth:
            if text.startswith("/*", i):
                depth, i = depth + 1, i + 2
            elif text.startswith("*/", i):
                depth, i = depth - 1, i + 2
            else:
                if c == "\n":
                    out.append(c)
                i += 1
            continue
        if closer:
            if text.startswith(closer, i):
                out.append(closer)
                i, closer = i + len(closer), None
            elif text.startswith(esc, i):
                out.append(text[i:i + len(esc) + 1])
                i += len(esc) + 1
            elif c == "\n" and not multi:
                _fail("%s: a single-line string literal is still open at line %d"
                      % (name, text.count("\n", 0, i) + 1))
            else:
                out.append(c)
                i += 1
            continue
        m = _OPEN.match(text, i)
        if m:
            closer, esc, multi = m.group(2) + m.group(1), "\\" + m.group(1), m.group(2) == '"""'
            out.append(m.group(0))
            i = m.end()
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            depth, i = 1, i + 2
        else:
            out.append(c)
            i += 1
    if depth:
        _fail("%s: a /* block comment is still open at end of input" % name)
    if closer:
        _fail("%s: a string literal (closer %s) is still open at end of input" % (name, closer))
    return [l.rstrip() for l in "".join(out).split("\n")]


def strip_swift(text, name="input"):
    return "\n".join(l for l in strip_swift_lines(text, name) if l.strip()) + "\n"


# The probe: every shape the lexer has a branch for, and each guarded file's hard cases.
_PROBE = ('/// doc return added\n        let added = SecItemAdd(x) // return errSecSuccess\n'
          '        // stored = SettingsMirrorStore.queuePatch(patch)\n        log.error("a // b \\(added)")\n'
          '        /* let added = SecItemAdd(y)\n           /* nested */ SecItemDelete(base as CFDictionary)\n'
          '        */ let s = "/* kept */" /* gone */\n        /** doc SecItemDelete(z) */\n'
          '        /* a // */ let t = 1\n'
          '        let js = """\n          /* js block\n          // js line\n          x = "a\\"b" + "";\n'
          '          """ // after\n'
          '        let r = #"a"b // c /* d"# /* e */\n'
          '        let q = #"s \\#(n) \\"# // f\n'
          '        let m = #"""\n          """ still "# open /*\n          """# // g\n')
_WANT = ('        let added = SecItemAdd(x)\n        log.error("a // b \\(added)")\n'
         ' let s = "/* kept */"\n         let t = 1\n'
         '        let js = """\n          /* js block\n          // js line\n          x = "a\\"b" + "";\n'
         '          """\n'
         '        let r = #"a"b // c /* d"#\n'
         '        let q = #"s \\#(n) \\"#\n'
         '        let m = #"""\n          """ still "# open /*\n          """#\n')
if strip_swift(_PROBE, "the probe") != _WANT:
    _fail("the comment stripper is broken: %r" % strip_swift(_PROBE, "the probe"))
if strip_swift_lines("a /* x\n y */ b // z\n\nc", "the probe") != ["a", " b", "", "c"]:
    _fail("strip_swift_lines no longer keeps one entry per source line")

if __name__ == "__main__":
    print("PASS: the shared Swift comment stripper handles line, nested block, string, multi-line "
          "and raw-string shapes, and fails by name on an unterminated comment or literal (#190)")
