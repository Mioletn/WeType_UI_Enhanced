#!/usr/bin/env python3
"""iOS 12.2 backport: cross-reference verification.

After the availability pass, every top-level declaration that references an
iOS 13+ type must itself carry an @available annotation high enough to cover
it (the backport marks the whole SwiftUI layer iOS 15+; the UIKit legacy
shell in LegacyUI/ and the shared model types stay unannotated).

This checker walks every top-level declaration in src/app/Husk (plus Play/)
and src/app/LegacyUI, builds the set of @available-annotated type names, and
reports unannotated declarations whose bodies mention one of them. It also
scans for raw iOS 13+ framework tokens in unannotated code, which the
name-based check cannot see.

Heuristic, like the pass it verifies: comments and string literals are
stripped crudely, and a hit is a lead to check by hand, not a certainty.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "app")

DECL_RE = re.compile(
    r"^(?P<attrs>(?:@\w+(?:\([^)]*\))?[ \t]*\n?)*)"
    r"(?P<mods>(?:(?:private|fileprivate|internal|public|open|final|indirect)[ \t]+)*)"
    r"(?P<kind>struct|class|enum|extension|protocol|actor|func)[ \t]+"
    r"(?P<name>\w+)"
)
ATTR_LINE_RE = re.compile(r"^@\w+")

# Framework symbols that do not exist below iOS 13/14/15. Deliberately
# specific: a false positive costs a glance, a false negative costs a build.
RAW_TOKENS = [
    # iOS 13 UIKit
    "UIColor.systemBackground", "UIColor.secondarySystemBackground", "UIColor.systemFill",
    "UIColor.secondarySystemFill", "UIColor.tertiarySystemFill",
    "UIColor.label", "UIColor.secondaryLabel", "UIColor.tertiaryLabel",
    "UIColor.quaternaryLabel", "UIColor.placeholderText", "UIColor.separator",
    "UIColor.opaqueSeparator", "UIColor.link", "UIColor.systemGray",
    "UIColor.systemGray2", "UIColor.systemGray3", "UIColor.systemGray4",
    "UIColor.systemGray5", "UIColor.systemGray6",
    "UIWindowScene", "connectedScenes", "UISceneSession", "UISceneDelegate",
    "UIActivityItemsConfiguration", "UIContextMenuConfiguration",
    "NSDiffableDataSourceSnapshot", "UICollectionViewCompositionalLayout",
    "UIMenu(", "UIMenuElement", "UIKeyCommand(", "UIScreenshotService",
    "UIWindowSceneDelegate", "UIActivityItemsConfigurationReading",
    "NSPersistentCloudKitContainer", "NSBatchDeleteRequest",
    "MKPointOfInterestCategory", "CLBackgroundActivitySession",
    # iOS 14
    "UITableView.CellRegistration", "UIListContentConfiguration",
    "PHPickerViewController", "PHPickerConfiguration", "UTType",
    "NSAttributedString.Key.backgroundColor",
    # iOS 15 SwiftUI/UIKit
    "foregroundStyle", "AnyShapeStyle", ".refreshable", ".swipeActions",
    ".searchable", "AsyncImage", ".safeAreaInset", ".interactiveDismissDisabled",
    ".listRowInsets", ".scrollIndicators", "CAFrameRateRange", "preferredFrameRateRange",
    ".containerRelativeFrame", "symbolEffect", "ViewThatFits",
    "UIButton.Configuration", "UIBarButtonItem.Style",
    # iOS 15+ Foundation (FormatStyle)
    ".formatted(", "Date.FormatStyle", "ISO8601FormatStyle",
    # iOS 16+ SwiftUI (upstream guards these; an unannotated hit is a real error)
    "Grid {", "GridRow", ".scrollContentDisabled", ".navigationDestination",
    "NavigationSplitView", ".presentationBackground", ".scrollDismissesKeyboard",
    ".toolbarColorScheme", ".navigationSubtitle", "UIHostingConfiguration",
    ".safeAreaBar", ".inspector(", "Chart {", "TimelineView", ".scrollPosition",
    ".onChange(of:zero", "NavigationPath", ".springLoading", ".scrollTargetBehavior",
]


def strip_comments_and_strings(text):
    """Remove // and /* */ comments and string literals, keeping line count."""
    out = []
    i, n = 0, len(text)
    in_line_comment = in_block_comment = False
    in_string = False
    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                out.append("\n")
            else:
                out.append(" ")
            i += 1
        elif in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                out.append("  ")
                i += 2
            else:
                out.append("\n" if ch == "\n" else " ")
                i += 1
        elif in_string:
            if ch == "\\":
                out.append("  ")
                i += 2
                continue
            if ch == '"':
                in_string = False
                out.append('""')
            else:
                out.append("\n" if ch == "\n" else " ")
            i += 1
        else:
            if ch == "/" and nxt == "/":
                in_line_comment = True
                out.append("  ")
                i += 2
            elif ch == "/" and nxt == "*":
                in_block_comment = True
                out.append("  ")
                i += 2
            elif ch == '"':
                in_string = True
                out.append('"')
                i += 1
            else:
                out.append(ch)
                i += 1
    return "".join(out)


def split_declarations(lines):
    decls = []
    for i, line in enumerate(lines):
        if line.startswith((" ", "\t", "}", ")", "//", "/*", "*", "#")):
            continue
        m = DECL_RE.match(line)
        if m:
            start = i
            while start > 0 and ATTR_LINE_RE.match(lines[start - 1]):
                start -= 1
            decls.append((start, i, m.group("kind"), m.group("name")))
    return decls


def attr_run(lines, group_start):
    j = group_start
    out = []
    while j < len(lines) and ATTR_LINE_RE.match(lines[j]):
        out.append(lines[j])
        j += 1
    return out


def main():
    annotated = {}   # type name -> version string
    decl_list = []   # (path, lines, start, kw, kind, name, version or None)
    for sub in ("Husk", os.path.join("Husk", "Play"), "LegacyUI"):
        d = os.path.join(ROOT, sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(d, name)
            with open(path, encoding="utf-8") as f:
                lines = f.read().split("\n")
            for start, kw, kind, dname in split_declarations(lines):
                version = None
                for a in attr_run(lines, start):
                    m = re.search(r"@available\(iOS ([0-9.]+)", a)
                    if m:
                        version = m.group(1)
                decl_list.append((path, lines, start, kw, kind, dname, version))
                if version:
                    annotated[dname] = version

    problems = 0
    # Pass 1: unannotated declarations referencing annotated types.
    for path, lines, start, kw, kind, dname, version in decl_list:
        if version:
            continue
        end = start + 1
        # block runs to the next declaration's group start or EOF
        nxt = None
        for p2, l2, s2, k2, ki2, n2, v2 in decl_list:
            if p2 == path and s2 > start and (nxt is None or s2 < nxt):
                nxt = s2
        if nxt is None:
            nxt = len(lines)
        block = strip_comments_and_strings("\n".join(lines[start:nxt]))
        for tname, tver in sorted(annotated.items()):
            if tname == dname:
                continue  # the declaration's own name on its keyword line
            if re.search(rf"\b{re.escape(tname)}\b", block):
                print(f"MISSING-ANNOTATION {os.path.relpath(path, ROOT)}:{start+1}: "
                      f"{kind} {dname} references {tname} (@available iOS {tver})")
                problems += 1

    # Pass 2: raw framework tokens inside unannotated declarations.
    for path, lines, start, kw, kind, dname, version in decl_list:
        if version:
            continue
        nxt = None
        for p2, l2, s2, k2, ki2, n2, v2 in decl_list:
            if p2 == path and s2 > start and (nxt is None or s2 < nxt):
                nxt = s2
        if nxt is None:
            nxt = len(lines)
        block = strip_comments_and_strings("\n".join(lines[start:nxt]))
        for tok in RAW_TOKENS:
            if tok in block:
                print(f"RAW-API {os.path.relpath(path, ROOT)}:{start+1}: "
                      f"{kind} {dname} uses {tok} with no @available")
                problems += 1

    print(f"\n{problems} problem(s) across {len(decl_list)} top-level declarations")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
