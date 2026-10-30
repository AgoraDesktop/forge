# Provenance

**Copyright © 2026 Kyle J. Cardoza.**
**SPDX-FileCopyrightText: 2026 Kyle J. Cardoza**
**SPDX-License-Identifier: GPL-3.0-or-later**

## What this component is

Agora's project manager and editor. It is an application: it links the AppKit as a built package and installs a
bundle, the way `workspace` and `terminal` do.

## Where its behaviour comes from, and where its code does not

The shape of the application — a project window, a browser of files grouped by what they are, a source editor with
line numbers, a build panel that parses compiler output, and the Build/Clean/Run verbs — follows **GNUstep's
ProjectCenter**, which is the reference implementation of the Project Builder role on a free Cocoa.

**No ProjectCenter code is here, and none may be.** ProjectCenter is GPL-2.0-or-later as a *whole program*, and this
tree's rule is that a GPL program is not a dependency (README, "Permissive licences first"); more than that, copying
it would make this component a derived work of a program with a different licence boundary. What was read is its
**documentation and its file inventory** — `Documentation/SCHEME` (the class map), `Documentation/TODO` (the feature
list), the template names in `Framework/Resources/` — which describe what the program does, not how it does it.

Every line in `src/` was written against this tree's own headers:

- the windows, view hierarchy and menu bar: `libagora-app/NSWindow.h`, `NSView.h`, `NSSplitView.h`,
  `NSOutlineView.h`, `NSToolbar.h`, `NSToolbarItem.h`, `NSMenu.h`;
- the editor and its colour: `libagora-app/NSTextView.h`, `NSLayoutManager.h` (the temporary-attribute pair),
  `NSRulerView.h`, `NSScrollView.h`;
- the project file: `libagora-base/NSPropertyListSerialization.h`, `NSData.h`, `NSFileManager.h`;
- the child process and its pipe: `libagora-base/NSTask.h`, `NSPipe.h`, `NSFileHandle.h`, `NSTimer.h`.

Three of those headers' notes wrote this component's design decisions for it, and the places are named in the code:
`NSFileHandle.h` on `-availableData` (findings 1 and 2 in the README), `NSTask.h` on where the termination handler
runs (finding 3), and `NSRunLoop.h` on the delayed-perform family (finding 5).

## The project format

`Project.agproj` is this component's own: an XML property list with five keys (`AGProjectFormatVersion`,
`AGProjectName`, `AGProjectType`, `AGProjectBuildDirectory`, `AGProjectFilePaths`). It is not a translation of
ProjectCenter's `PC.project` bundle, whose layout is keyed to GNUstep-make targets this tree does not build. The
build it generates is CMake, because that is what this tree builds with — the manifest is a description of a
target, not a second build language.

## Third-party art

`assets/tabler-icons/` holds nine icons from **Tabler** (<https://github.com/tabler/tabler-icons>, MIT — the licence is
beside them) with `PROVENANCE.md` recording what was taken and when. They are rasterised at build time by
`tools/embed-glyphs.py` into a generated header, so no bitmap is committed and no resource is loaded at run time; the
component's own drawn fallback is in `src/AGToolbarIcons.m` for a machine without `rsvg-convert`.

## The build model

`DEVELOPMENT-TOOLS.md` §4 ("The project/build layer") and §5 ("The IDE") are the design record this component
follows: a manifest that generates the CMake the tree already knows how to build, and a build half that drives
existing tools rather than reimplementing them. Where this component diverges, the divergence is written in the
README (§"What is not here yet").
