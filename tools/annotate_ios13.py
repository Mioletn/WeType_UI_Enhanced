#!/usr/bin/env python3
"""iOS 12.2 backport: availability annotation pass.

The app's deployment target drops from 15.5 to 12.2, so every use of an
iOS 13+ API must sit inside an @available(iOS 13.0, *) declaration (the
annotation raises the deployment target used to check that declaration's
body). SwiftUI, Combine (ObservableObject/@Published) and Swift
concurrency (@MainActor/Task) are all iOS 13+, and upstream uses them
across ~46 files.

This script inserts `@available(iOS 13.0, *)` before every top-level
declaration whose own body uses one of those APIs, leaving plain model
types (TLApp, TLReport, TranslationLayer, BundleUnpacker, ...) untouched
so the iOS 12 legacy shell can still use them.

Heuristic and mechanical: it needs a compile pass on a Mac to confirm.
Files already edited by hand are skipped.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "app", "Husk")

SKIP_FILES = {
    # Already handled by hand (entry point rewrite, Logger shim, TLScreenView).
    "HuskApp.swift", "HuskLog.swift", "JITBootstrap.swift", "TLScreenView.swift",
}

# Strings that mean "this declaration needs iOS 13+". Deliberately specific:
# a false positive only over-restricts a type the legacy shell does not use,
# while a false negative is a compile error, so the list errs long.
MARKERS = [
    ": View", "View {", ": App", "App {", ": Scene", "Scene {",
    "ObservableObject", "@Published", "@EnvironmentObject",
    "ViewBuilder", "SwiftUI.", "UIHostingController", "UIViewControllerRepresentable",
    "NavigationStack", "NavigationView", "NavigationLink", "navigationDestination",
    "WindowGroup", "TabView", ".tabItem", "List(", "Form(", "Section {", "Section(",
    "ForEach(", "ScrollView", "LazyVStack", "LazyHStack", "HStack", "VStack", "ZStack",
    "GridItem", ".sheet(", "fullScreenCover", "ShareLink", "LabeledContent",
    "presentationDetents", ".snappy", "presentationDragIndicator",
    ".alert(", "Menu {", "ToolbarItem", ".toolbar", ".navigationTitle",
    ".searchable", ".refreshable", ".swipeActions", ".listRowInsets",
    ".onChange(of:", ".onOpenURL", ".onReceive(", ".task(", ".task(id",
    ".environment(", ".ignoresSafeArea", ".preferredColorScheme",
    ".transition(", ".withAnimation", ".animation(", ".animation(_",
    "@GestureState", "@FocusState", "@FetchRequest", "@AppStorage", "@State",
    "@ObservedObject", "@StateObject", "scenePhase", ".fullScreenCover",
    "Color(", ": Color", "Image(systemName", "ProgressView", "Text(",
    "@MainActor", "Task {", "Task<", "Task.detached", "Task(", "await MainActor",
    "MainActor.run", "nonisolated",
    "UTType", "connectedScenes", "ActivityKit", "CAFrameRateRange",
    "os.Logger", "Logger(", "MTKViewDelegate", ".keyboardType", "UIKeyInput",
    "NSItemProvider", ".buttonStyle(", ".foregroundStyle", ".background(",
    ".cornerRadius", ".clipShape", ".padding(", ".frame(", "Spacer(",
    ".monospaced", ".monospacedDigit", "Divider()", ".disabled(", ".opacity(",
    ".hidden()", ".scaleEffect", ".rotationEffect", ".offset(", ".zIndex(",
    ".allowsHitTesting", ".contentShape", ".gesture(", ".simultaneousGesture",
    ".highPriorityGesture", ".onAppear", ".onDisappear", ".onChange",
    ".navigationBarHidden", ".statusBar", ".safeAreaInset", ".interactiveDismissDisabled",
]

DECL_RE = re.compile(
    r"^(?P<attrs>(?:@\w+(?:\([^)]*\))?[ \t]*\n?)*)"
    r"(?P<mods>(?:(?:private|fileprivate|internal|public|open|final|indirect)[ \t]+)*)"
    r"(?P<kind>struct|class|enum|extension|protocol|actor|func)[ \t]+"
    r"(?P<name>\w+)"
)

ATTR_LINE_RE = re.compile(r"^@\w+")


def split_top_level_declarations(lines):
    """Yield (group_start, keyword_index, kind, name) for each top-level declaration.

    group_start is the first line of the declaration's attribute run (the
    keyword line itself when it carries no attributes), so the previous
    declaration's block never swallows this one's @MainActor/@available.
    """
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


def block_text(lines, start, decls, idx):
    end = decls[idx + 1][0] if idx + 1 < len(decls) else len(lines)
    return "\n".join(lines[start:end])


def has_available_attr(lines, group_start):
    """True if an @available attribute sits in this declaration's own attribute run."""
    j = group_start
    while j < len(lines) and ATTR_LINE_RE.match(lines[j]):
        if lines[j].strip().startswith("@available"):
            return True
        j += 1
    return False


def process(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    lines = text.split("\n")
    decls = split_top_level_declarations(lines)
    if not decls:
        return 0
    changed = 0
    # Walk backwards so insertions do not disturb earlier indices.
    for idx in range(len(decls) - 1, -1, -1):
        start, _kw, kind, name = decls[idx]
        if has_available_attr(lines, start):
            continue
        block = block_text(lines, start, decls, idx)
        if not any(mk in block for mk in MARKERS):
            continue
        lines.insert(start, "@available(iOS 13.0, *)")
        changed += 1
        print(f"  {os.path.basename(path)}: +@available(iOS 13.0, *) {kind} {name}")
    if changed:
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
    return changed


def main():
    total = 0
    files = 0
    for name in sorted(os.listdir(ROOT)):
        if not name.endswith(".swift") or name in SKIP_FILES:
            continue
        path = os.path.join(ROOT, name)
        if not os.path.isfile(path):
            continue
        n = process(path)
        if n:
            files += 1
            total += n
    # Play/ subdirectory
    playdir = os.path.join(ROOT, "Play")
    if os.path.isdir(playdir):
        for name in sorted(os.listdir(playdir)):
            if not name.endswith(".swift"):
                continue
            n = process(os.path.join(playdir, name))
            if n:
                files += 1
                total += n
    print(f"\n{total} annotations across {files} files")


if __name__ == "__main__":
    sys.exit(main())
