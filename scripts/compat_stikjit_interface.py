#!/usr/bin/env python3
"""Make StikJIT's vendored .swiftinterface readable by the Swift 6.1 compiler.

Why this is needed
------------------
Frameworks/StikJIT.xcframework is StikJIT 1.9.0 as published, and its
.swiftinterface files were emitted by **Swift 6.4**. Since Swift 6.2 the module
printer writes qualified names as `Module::Type` (`Swift::String`,
`StikJIT::DDIPaths`, and for nested declarations the delightfully redundant
`StikJIT::StikJIT.StikJIT::Configuration`). Swift 6.1 -- the compiler in Xcode
16.4, which this backport must use because Xcode 26 binaries abort at launch on
iOS 12 -- has no such syntax, so importing the framework fails with ~190 parse
errors ("expected '{' in struct", "unexpected ':' in type; did you mean to
write a dictionary type?"), all inside the interface file.

What this does
--------------
Rewrites only the *textual* interface into the older spelling. The binary
`.swiftmodule` is untouched, and Swift name mangling does not encode this
qualification, so the ABI, symbols and behaviour are identical: the compiler
just now parses the same declarations it was always being handed.

The interface is a 98-line file whose imports (Foundation, JavaScriptCore,
Network, _Concurrency) make every qualifier unambiguous, so dropping the module
prefix is safe. Nested members are rewritten first, while the full form is
still recognisable.

Usage:
    python3 scripts/compat_stikjit_interface.py [--check]

--check exits 1 if any file still needs rewriting (used by CI as a preflight).
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XCFRAMEWORK = os.path.join(ROOT, "src", "app", "Frameworks", "StikJIT.xcframework")

# Order matters: the nested form has to go first, while `StikJIT::StikJIT.…::`
# is still intact. Rewriting it later would leave an extra `StikJIT.` segment
# pointing at a member the enum does not have.
RULES = [
    ("StikJIT::StikJIT.StikJIT::", "StikJIT."),
    ("_Concurrency::", ""),
    ("Foundation::", ""),
    ("Swift::", ""),
    ("StikJIT::", ""),
]


def rewrite(text):
    for old, new in RULES:
        text = text.replace(old, new)
    return text


def main():
    check = "--check" in sys.argv[1:]
    files = sorted(glob.glob(os.path.join(XCFRAMEWORK, "**", "*.swiftinterface"), recursive=True))
    if not files:
        raise SystemExit("no .swiftinterface under %s" % XCFRAMEWORK)

    stale = 0
    for path in files:
        with open(path, encoding="utf-8", newline="") as f:
            raw = f.read()
        # Interfaces are plain text; normalise to LF so the export does not
        # depend on whichever machine checked the file out (this clone has
        # core.autocrlf=true, and the committed files came in as CRLF).
        text = raw.replace("\r\n", "\n").replace("\r", "\n")
        new = rewrite(text)
        if "::" in new:
            leftover = [ln for ln in new.splitlines() if "::" in ln]
            raise SystemExit("%s: qualifiers survived the rewrite:\n  %s"
                             % (os.path.basename(path), "\n  ".join(leftover[:5])))
        if new == raw:
            print("  unchanged  %s" % os.path.relpath(path, ROOT))
            continue
        stale += 1
        if check:
            print("  needs fix  %s" % os.path.relpath(path, ROOT))
            continue
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(new)
        print("  rewrote    %s (%d qualified names)" % (os.path.relpath(path, ROOT), raw.count("::")))

    if check and stale:
        raise SystemExit("%d interface file(s) still use Swift 6.2+ syntax; "
                         "run scripts/compat_stikjit_interface.py" % stale)
    print("done: %d file(s), %d changed" % (len(files), stale))


if __name__ == "__main__":
    main()
