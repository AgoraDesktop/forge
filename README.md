# Forge

**Agora's project manager and editor** — a project window with a browser down the left, the file on the right, and
the build's own output underneath. It is an *application*: it consumes the AppKit as a built package
(`AgoraApp::App`), owns no library of its own, and installs its bundle.

It is the Project Builder role, and it is deliberately shaped like **GNUstep's ProjectCenter**: the same project
window, the same browser of files grouped by what they are, the same four verbs (Build, Clean, Run, plus adding a
file), the same editor with line numbers beside it, the same build log a person reads against the code that produced
it. The behaviour is what was studied; the code is this tree's (see `PROVENANCE.md`).

**A BUILT APPLICATION IS A BUNDLE A LAUNCHER CAN OPEN, AND ITS METADATA IS A PANE OF THE PROJECT WINDOW.** The
toolbar's **Code | Info** switch (two pictures: `code-dots` and `info-circle`) swaps the middle region between the source
editor and the metadata pane: the name a
person sees, the reverse-DNS identifier a launcher keys on, the version, and the icon (`Choose Icon…` copies a picture
into the project's `Resources/` and names it). Apply writes the manifest, Revert drops what was typed, and switching
back keeps an open file — and a half-typed identifier — exactly as they were, because both panes stay in the window and
only one is shown. `Project Info…` (⌘I) is the same switch by another route. Those are keys in `Project.agproj` — not build settings — and the build writes them where
they belong: `Contents/Info.plist`, the icon into `Contents/Resources`, and the executable into `Contents/MacOS` (what
`NSBundle -executablePath` reads) with a symlink from `Contents/<platform>/<arch>/` (what this tree's installed
bundles use). `Run` then launches the product, and the log says where the bundle is.

**The toolbar's icons are Tabler's** — the MIT-licensed outlines vendored in `assets/tabler-icons` with their licence and
`PROVENANCE.md`, rasterised at 24 and 48 points by `tools/embed-glyphs.py` into `src/agora-toolbar-glyphs.h`, **which is
checked in**, so the pictures are compiled in, nothing resolves a resource path at run time, and no build needs
`rsvg-convert`, ImageMagick or Python to produce the art it links. The header sits beside the file that includes it on
purpose: a quoted include searches the including file's directory first, so **every** build of this project finds it —
including the one Forge performs on its own project, whose generated `CMakeLists.txt` knows no rules of ours. It used to be
generated into the build directory, and that made the pictures a property of *how* the project was built: an exported Forge
built by Forge drew the fallback shapes while the checkout's build drew Tabler's, because the generated build directory had
no header at all. Regenerate with

    python3 tools/embed-glyphs.py assets/tabler-icons src/agora-toolbar-glyphs.h /usr/bin/rsvg-convert

and commit the result (`src/AGToolbarIcons.m` keeps its drawn fallback for a checkout that deletes the header).

They are **template images**, so the toolbar inks them: a disabled item's glyph is drawn in exactly the grey of its label
and an enabled one in the label's own ink, which is why *Stop* looks greyed above and *Build* does not. **The Code | Info
switch wears two of them and NO WORDS** — `code-dots` on the editor's segment and `info-circle` on the metadata pane's,
because a row of captions in a band of pictures reads as a text control and two pictures read as the mode switch it is.
The names are on the toolbar item, which is where a name for the pair belongs, and the control is the width of its own
measurement (`-sizeToFit`) rather than of two label columns.

The order is **Build · Clean | Run · Stop | Add · Remove | Export** … flexible space … **Code | Info**: four groups, each
a pair of verbs and one rule — what acts, and what undoes it. Build and Clean are the BUILD, Run and Stop are the
PRODUCT, Add and Remove are the project's FILE LIST (what the browser beside them shows), and Export stands alone
because it is the only row that acts on the result rather than changing the project. The flexible space pushes the mode
switch to the right edge, where a mode switch belongs. `tests/toolbar_state.m` asserts that sequence, separators
included.

Agora is an installable desktop environment for Linux and the BSDs; see the project README in the parent directory
(`../README.md`).

## The division of labour

| Here | What it does |
|---|---|
| `src/AGProject.m` | the **project**: `Project.agproj` (an XML property list), the files it names, their categories, and the CMake it generates |
| `src/AGBuilder.m` | the **build**: `cmake` configure then `cmake --build`, as a child process whose output is read on the run loop; and the diagnostic parse |
| `src/AGToolbarIcons.m` | the **toolbar's pictures**, drawn rather than shipped |
| `src/AGSourceEditor.m` | the **glass**: a text view, a line-number ruler drawn from the layout manager, and colour as temporary attributes |
| `src/AGProjectWindowController.m` | the **window**: toolbar, browser, editor, log, and the verbs between them |
| `src/main.m` | the **application**: the menu bar, and one project window per project |

**THE PROJECT IS A MANIFEST, NOT A BUILD SYSTEM.** `DEVELOPMENT-TOOLS.md` §4 puts the cheapest project layer at a
description plus a generator, and that is what this is: the manifest names the targets, the sources and the
resources; `-generatedCMakeLists` emits the CMake that this tree already knows how to build, against the installed
SDK in `build-prefix/`. Nothing here parses CMake, and nothing here invokes a compiler — the toolchain does that,
which is the whole reason a build is a child process.

**THE MANIFEST IS TEXT AND THE BUILD IS AN ARTIFACT.** The generated `CMakeLists.txt` lives in the project's
`build/`, is rewritten on every build, and is never committed; the manifest is what merges. That is the
`.xib`/`.nib` split applied to a project instead of an interface.

## A project on disk

```
Hello/
├── Project.agproj          # the manifest: version, name, type, build directory, file paths
├── Sources/main.m
├── Headers/Widget.h
└── build/                  # generated, never committed
    ├── CMakeLists.txt      # generated by the manifest, rewritten each build
    └── Hello               # the product
```

`Project.agproj` is an XML property list with five keys and no others: `AGProjectFormatVersion`, `AGProjectName`,
`AGProjectType` (`application`, `tool`, `library`, `bundle`), `AGProjectBuildDirectory`, and `AGProjectFilePaths`
(paths **relative to the project directory**, in the order they were added).

**A KEY THE READER DOES NOT KNOW IS REFUSED BY NAME**, rather than ignored — a misspelled key would otherwise open
an empty project that looks fine. The same rule `NSNibSource.h` states for the nib compiler ("a compiler that
silently drops a typo is a compiler that silently drops a design").

`AGProjectBuildDirectory` is the one key whose VALUE is checked as well: it must name a directory inside the project, so
`../..` and `/tmp/x` are refused. `Clean` removes whatever that key names, and a project file somebody was sent is not a
place to accept a path that deletes a tree the project does not own.

## Build and run

```sh
cmake -S . -B build -DCMAKE_C_COMPILER=/usr/bin/clang-19 -DCMAKE_OBJC_COMPILER=/usr/bin/clang-19 \
  -DCMAKE_PREFIX_PATH=../build-prefix -DCMAKE_INSTALL_PREFIX=../build-prefix
cmake --build build -j"$(nproc)"
ctest --test-dir build --output-on-failure
./build/Forge.app/Contents/Linux/amd64/Forge --project /path/to/a/project
```

Doors, named as test doors: `--project DIR` opens a project at launch (so a probe needs no file panel), `--build`
presses Build once it is open, `--clean` presses Clean first, `--steps build,clean,build` runs a SEQUENCE of the
verbs — each starting when the previous one stops, which is what a person's next click does by taking a second — and
`--seconds N` bounds the run the way Workspace's and Terminal's do.

**THIS TREE IS ITSELF ONE OF ITS OWN PROJECTS.** `Project.agproj` in the root names the seven files in `src/`, so Forge
builds Forge:

```sh
./build/Forge.app/Contents/Linux/amd64/Forge --project . --build --seconds 60
./forge-build/Forge.app/Contents/Linux/amd64/Forge       # the product
```

The manifest's build directory is `forge-build` rather than `build`, because the generated `CMakeLists.txt` would
otherwise land in the CMake tree above and the two would fight over one `CMakeCache.txt`. That build is the project
layer's, not the release path's: it has no tests, no install rule, and no Tabler glyph step, so a self-built Forge draws
the fallback toolbar icons (`AGToolbarIcons.m`). Use the CMake build above for those.

**`assets/forge-icon.png` IS THE APPLICATION'S OWN PICTURE.** `Info.plist.in` names it with `CFBundleIconFile` and the
build copies it to `Contents/Resources`, which is where `libagora-iconservices` looks — a PNG, read directly — so the
Dock's tile is this artwork and not the drawn placeholder a bundle with no icon gets. `Project.agproj` names the same
file, so a Forge built by Forge carries it too. The artwork is kept at 512 points: the tile wants a picture, and the
1254-point original was six times the bytes for the same pixels.

`FORGE_LOG_PATH` writes the build log to a file as it arrives, line for line with the pane. A build that fails inside
a window is a build whose error text is on a screen; the file is what a person can send and what a probe can read.

`FORGE_SDK_PREFIX` names the SDK the generated build resolves (a directory holding `lib/cmake/AgoraApp`). With it
unset the builder looks at `AGORA_PREFIX`, then at **the prefix the running AppKit was loaded from** — `dladdr` on
`NSApplicationMain`, which is `<prefix>/lib/libagora-app.so` — and finally at each ancestor of its own binary for
`<dir>/lib/cmake/…` or `<dir>/build-prefix/lib/cmake/…`. That middle step is the one an INSTALLED Forge needs: an
application in `~/Applications` has no ancestor holding a prefix, but it is linked to the AppKit and the AppKit lives
in the SDK. It is also the right prefix to build against, because the product then links the same libraries the
application is running with. An install-wide SDK (`/usr`, or any prefix someone staged) therefore needs no
environment at all, which is the shape this is heading for. `FORGE_CC` / `FORGE_OBJC` choose the compilers the **generated** build is
configured with; the defaults are
`/usr/bin/clang-19`, because this tree is clang-only and there is no plain `clang` on every machine's `PATH`.
`FORGE_BUILD_DIAG=1` prints one line per build stage and read to stderr — the diagnostic a build that does not
finish needs.

## Removing a file from the project

**Remove File from Project (⌘⌫)**, and the Remove button beside Add, take the browser's selection out of `Project.agproj`.
That is a **project edit, not a delete**: the file stays on disk, the log says so (`# Removed: Headers/Notes.h (the file is
still on disk)`), and Add Files brings it back. There is no confirmation sheet for the same reason — nothing on disk
changes.

It answers before it acts like the other verbs: a group (or nothing) under the selection is a refusal with the reason in
the log, and so is a file the project does not carry. `-validateToolbarItem:` offers the button only while a **file** row is
selected and no build is in flight, and every selection change re-asks — a button that is live for a group would be a
button that lies.

Two consequences worth stating: an **empty category disappears** with its last file (the browser is built from the
project's categories), and **a file that was open goes with it** — the editor is cleared and the title drops back to
`project — type`, because leaving the text on screen under a title naming it would be a window claiming something the
manifest denies.

`AGProject -removeFile:error:` finds a member **by path**, not by identity, so a caller holding an equivalent
`AGProjectFile` names the same member; a path that is not in the project is a refusal with a reason.
`forge-remove-file` (17 checks) covers the pair that matters — gone from the manifest, still on disk — plus the categories,
the log, both refusals, and the toolbar item's own press: select the row, validate, fire the action.

## Exporting the app

**Export App… (⌘E)**, and the Export button beside Run, copies the built `.app` bundle wherever a save panel is pointed —
the product of a build lives in `build/`, inside the tree `Clean` deletes, which is a fine place to run from and a bad
place to hand to somebody.

**AND THE PANEL OPENS IN `~/Applications`, WHICH IS WHERE A BUILT BUNDLE BELONGS.** It used to open beside the project,
which is where a person's sources are and where an exported `.app` becomes a file the browser lists and the next build
walks past. The account's own application folder is the Mac's answer for a bundle that did not come from a store: the
session creates it at login as part of the home set, and Launch Services scans it. Forge makes it if it is not there
(a Forge started on its own has never had a login) and answers the home itself when it cannot be made — a file of that
name, an unwritable home — because a panel pointed at something that does not exist is worse than one pointed at the
directory that does. The choice is one door, `+fn_exportDirectoryForHome:`, which is what lets `forge-export` hold it
without a panel.

It answers before it acts, like the other verbs: no product is a refusal with the reason in the log, and a build in
flight is a refusal too, because the bundle on disk at that moment is half of one. The button greys itself through
`-validateToolbarItem:` on the same two questions, so a greyed button and a logged refusal cannot disagree. The
destination is **replaced, not merged** — a `.app` whose `Contents` came half from this build and half from an older one
is not the application that was just built, and a stale file inside a bundle is the one thing nobody sees.

The icon is Tabler's `package-export` (a box with an arrow leaving it), vendored with the others; `AGToolbarIcons.m`
draws the same shape when a machine has no `rsvg-convert` and the generated header is absent.

`forge-export` (26 checks) drives `-fn_exportProductToPath:error:` — the same verb without the panel — through both
refusals, a real copy (executable and `Info.plist` inside), an export over an existing bundle (the stale file is gone),
a destination that cannot be written, and the panel's own start: `~/Applications`, made when it is missing, with the
home as the answer when it cannot be.

## Files: adding one, and making one

Two verbs, because they are two different intentions:

- **Add Files… (⌘D)** chooses files that already exist, in the open panel, starting in the project directory.
- **New File… (⌘N)** *creates* one: a save panel names it, the file is written with the skeleton its type asks for — a
  translation unit for `.m`/`.c`, an include guard for `.h`, nothing at all for a type this program does not know — and
  it joins the manifest and opens in the editor.

**Both were broken, for one reason.** `AGProject -writeToURL:` re-points the project's directory URL at what it wrote, and
it released that URL *before* reading the path out of it. The spelling every caller uses —
`[project writeToURL:[project projectDirectoryURL] error:NULL]` — hands the method the project's own URL, so the release
left the argument dangling: the path came back `nil`, the project was left with **no directory**, and every file after
that was refused as "outside the project directory". The first Add of a session worked and every one after it did
nothing. The path is copied before anything is released now, and `forge-new-file` pins it: two creates in a row, each
with the manifest written in between.

The open panel had a defect of its own: it inherited the save panel's `"Untitled"` name, so pressing **Open** with
nothing selected asked for a file that does not exist and returned in silence — a button that does nothing. An open panel
starts with an empty field now, and a press that cannot accept says what it is waiting for instead of doing nothing.

## Typography, and the bug that looked like a raster defect

The window title is `Hello — café.m — application`, with em dashes and whatever the file is called, and the menu rows say
`New File…`. That is worth a section because it looked impossible for a while.

**THE FINDING WAS "THIS TIER'S RASTER DRAWS A NON-ASCII CHARACTER AS THE FIRST BYTE OF ITS UTF-8 SEQUENCE" — AND IT WAS
WRONG.** A title built as `@"%@ — %@"` arrived as `Hello â( main.m`: `â` is 0xE2, the first byte of U+2014, followed by a
box per remaining byte. The conclusion drawn at the time was that the raster could not carry non-ASCII, so Forge's chrome
was reduced to ASCII: a hyphen in the title, `...` in the menus, a hyphen in the info pane's subtitle.

The raster was innocent. `libagora-base`'s **format scanner** walked the format string's bytes and emitted one byte per
literal chunk, so a three-byte character was handed over as three separate chunks — the split happened before any glyph
was looked up. `@"café.m"` as a literal always drew correctly, and so did the same name read from the manifest.

The scanner takes whole UTF-8 sequences now (`libagora-base/NSString.m`, `tests/constant_string_units.m`), and the
typography came back: em dashes in the title, ellipses in the menus, and a test in `forge-new-file` counts the two U+2014
characters in the title rather than asserting it is ASCII.

## The info pane

The toolbar's Code/Info switch swaps the editor for the project's metadata, and that pane is **a form, not a column of
fields**:

- a header (what the pane is, and which project it is about — type and directory),
- **Bundle Identity**: Name, Identifier with the rule written under it, Version,
- **Presentation**: the icon, shown in a well that is the shape of the slot it fills, with the file's name and
  Choose…/Remove beside it,
- a footer **band** under a hairline at the pane's floor — `Up to date` or `Unsaved changes` on the left, Revert and
  Apply on the right, and at least 22 points between the band and the form's last row so Apply never crowds the icon.
  Apply is live only when it would do something, because a button that writes an unchanged manifest teaches nobody
  anything.

The captions used to draw as empty boxes: a non-editable `NSTextField` keeps its **bezel** unless `-setBezeled:NO` is
said as well as `-setBordered:NO`, and only the second was. That single line is most of the difference between a form and
a debug dump, and `forge-project-info` now checks it (`!isBezeled && !isBordered`) along with the state line, the two
verbs and the field width.

**THE PANE THAT COMES UP IS PLACED WHEN IT COMES UP.** Both children of the detail pane are built with a frame taken from
the content size before the window exists, and only the visible one is laid out — so the metadata pane kept its born
571x390 inside an 852x426 pane: 36 points low and 281 points narrow, which is what made the form look pushed down and
cut short. The switch is what makes a pane visible, so the switch places it, and `forge-project-info` checks that the
pane fills its parent afterwards.

The layout is arithmetic in one place with **a cursor for each row's top edge**: the first version accumulated bottoms, so
every gap had to be reasoned about backwards — which is how the identifier's hint ended up drawn across the version
field's border.

## The panes are `NSSplitView`s, and what a drag costs

The three panes are **two nested `NSSplitView`s**: an outer one that stacks the top row above the log, and an inner one
that puts the browser beside the detail pane. Divider positions are autosaved under `AgoraSplitView AGForgePanes` and
`AgoraSplitView AGForgeLog`, so a window reopens the size it was left.

They were hand-placed once, and that was a defect in both directions. The custom view moved its own gutter at 0.00 ms per
motion and then **threw the movement away**, because a view that does not pump its own events never hears the release in a
running application — every drag ended with a press, some motions and no `-mouseUp:`. `NSSplitView` owns the tracking
loop, the preview line, the release and the store, and it re-places the panes **once**, on the release, for a measured
reason:

| Step | Cost |
|---|---|
| `NSTextView -setFrameSize:`, **height-only** | **0.03 ms** |
| `NSTextView -setFrameSize:`, **width change** (a new wrap) | **112 ms** |
| one `-setPosition:ofDividerAtIndex:` — the release, paid once | 119 ms |

**A DIVIDER'S POSITION MEASURES THE PANE BEFORE IT, AND THE TWO SPLITS DO NOT PUT THE SAME PANE THERE.** The top split
leads with the browser, so its floor is the browser's (140 points) and its ceiling is the detail pane's (160). The outer
split leads with the *top row*, so its floor is the editor's and the log's own floor — 70 points — is the ceiling's
business, on the far side of the divider. Returning the log's floor as the outer split's *minimum* left the log stopping
90 points early, which read as a divider that would not close.

The floors are `AG_BROWSER_MIN` 140, `AG_DETAIL_MIN` 160 and `AG_LOG_MIN` 70; `forge-pane-sizes` drags each divider past
its floor and checks where it lands.

The height/width split is the point: `NSTextView` used to invalidate the layout of the whole document on *every* frame-size
change, so a height-only change — which cannot move a line — re-laid the text out anyway at ~104 ms. It now re-wraps only
when the width moves. That is what makes a drag cheap while still letting the panes be re-placed for real when the hand
stops.

## What is proven, and how

| Probe | Claim |
|---|---|
| `tests/project_model.m` (45 checks) | the manifest's round trip (name, type, paths, order), the categories, the refusal of a file outside the project and of an unknown key, and what the generated CMake says |
| `tests/diagnostics.m` (14 checks) | the build log's parse: a column and no column, a warning, a path containing a colon, and CMake's own error form |
| `tests/end_to_end.m` (14 checks) | **the whole chain, measured**: a manifest names a source, the generator writes the CMake, the toolchain builds it, and the product is where `-productURL` said it would be — inside the `.app` — and the bundle carries `Contents/Info.plist` with the manifest's identifier, an executable in `Contents/MacOS` where `NSBundle` looks, and an `NSBundle` that opens it and resolves that executable |
| `tests/build_sequence.m` (7 checks) | **Build, Clean, Build in ONE process** — the verbs a shell runs as three processes are one project window's session, and the state between them is the thing "it works the first time and fails after cleaning" was about |
| `tests/text_layout.m` (10 checks) | **the last row is on the screen**: the editor's document is tall enough for its last line, a short file still fills its pane, and the log's document grows with what a build appended — measured as rectangles, and re-checked with the fix reverted (the editor came up 8 pt short and the log 15.6 pt) |
| `tests/log_alignment.m` (6 checks) | **the log's first character sits at its pane's left edge**: the window is rendered at 1:1 in points, the log pane's edge read from the view, and the ink measured — the text system's own four points are the only inset there is |
| `tests/pane_sizes.m` (16 checks) |
| `tests/new_file.m` (13 checks) |
| `tests/export.m` (26 checks) |
| `tests/remove_file.m` (17 checks) | **the dividers drag and the sizes are remembered**: two synthetic drags on the real window move the browser and the log by the distance dragged, the numbers land in `NSUserDefaults` (a scratch `AGORA_CONFIG_ROOT`), a drag that would swallow the editor is clamped, the separation is an **eight-point gutter with the two resize cursors over it**, five motions inside one frame are applied as **one** move, and a **second window opens already the right size** |
| `tests/toolbar_icons.m` (15 checks) | **the toolbar's pictures**: each kind answers a 24-point image with ink in it, and **no two kinds are the same picture** — a factory that forgot a `break` would be right in size and wrong in meaning |
| `tests/toolbar_state.m` (17 checks) | **a verb's button says whether it can do anything**: on an unbuilt project Run, Clean and Stop are grey and Build is not; after a build Run and Clean are usable; while the product runs Stop is the only verb left (and Clean is off, because it would delete the product under it); after Stop, Run returns and Stop greys; after Clean, Clean and Run are both off |
| `tests/project_info_view.m` (48 checks) | **the metadata pane, driven end to end**: it is a view with no session of any kind, it shows the project's values, Apply writes the manifest (and the plist the build will emit carries the new identifier), a refused identifier writes nothing and says why in the log, Revert drops what was typed, and the toolbar's Code | Info switch shows exactly one of the editor and the pane at a time |
| `tests/line_numbers.m` (7 checks) | **the numbers sit beside the lines they number, at any scroll**: unscrolled the first is 1, ten lines down it is 11, fifty down it is 51, back at the top it is 1 again, and the run is contiguous — read back through the ruler's own walk, so a passing test cannot sit beside a disagreeing screen |
| `tests/verb_conflicts.m` (33 checks) | **a verb pressed while another is running**: a second Build is refused in words and starts nothing; a Clean during a build is refused and that build still produces its product; a Clean with nothing running does work; and **a running PRODUCT is not a build** — Build, Clean and Run say the product is up rather than claiming a build is, and all three work again when it exits — or when **⌘.** stops it; Stop also ends a build and leaves the window usable |

None of them needs a window, an input device or a compositor.

### Five findings this slice paid for, each of which looked like "the build hangs"

1. **`-availableData` on a pipe reads to the end of the file**, and a pipe whose writer is alive has no end — the
   readability handler blocked the run loop on its first call. `terminal` records the same finding from the pty
   side; this is the pipe's (`AGBuilder.m`, `fn_runTool:`).
2. **A pipe with no writer stays readable for ever**, so a handler that returns without unloading spins the run loop
   at full speed — which starved the timer that notices the exit, so the stage never ended.
3. **`NSTask`'s termination handler runs on the reaper's own thread.** It cannot touch the pipe, the delegate or the
   window, and carrying the status across with `-performSelectorOnMainThread:` did not arrive in a program that is
   not `NSApplication`. The completion is therefore noticed by a timer on the run loop, where all three live.
4. **The parent's write end must be closed before draining**, or the drain waits for bytes that will never come:
   `NSPipe` owns both ends, so the pipe reports no EOF until this process lets go of the writer.
5. **`-performSelector:afterDelay:` did not fire** on this tree's run loop while an `NSTimer` on the same loop did —
   measured in `tests/end_to_end.m`, where the configure stage ended and the build stage never began. The chain is
   a one-shot timer because of it.
6. **A generated build cannot find the SDK by itself.** `find_package(AgoraApp CONFIG REQUIRED)` needs a prefix, and
   an application launched from the desktop inherits no developer environment — the first in-session Build failed
   with "Add the installation prefix of AgoraApp to CMAKE_PREFIX_PATH". The builder now finds it: `FORGE_SDK_PREFIX`,
   then `AGORA_PREFIX`, then the prefix the running AppKit was loaded from (`dladdr` on `NSApplicationMain`), then each
   ancestor of its own binary for `<dir>/lib/cmake/…` or `<dir>/build-prefix/lib/cmake/…`, and it says so in the log
   when it finds none. MEASURED the other way round, which is why the middle step exists: an installed Forge (in
   `~/Applications`) reported "The Agora SDK prefix was not found; set FORGE_SDK_PREFIX …", and with a CLEANED build
   directory the configure failed outright — nothing out there was an ancestor of its binary.
7. **A verb that cannot run must say so, because silence looks like failure.** Each of Build, Clean and Run used to
   clear the log, call the builder and ignore the answer: a Build pressed while a build was still running therefore
   wiped the log and printed nothing, and a Clean pressed during a build deleted the directory a running `cmake` was
   writing into — both of which read, from a person's side of the screen, as "the build failed after cleaning".
   `tests/verb_conflicts.m` is the census of that.
8. **A document view that computes its own height is a document view that is one inset too short.** The editor built
   its height from `-usedRectForTextContainer:` alone and dropped the text view's own `-textContainerInset`, so the
   last line of every file sat below the document's bottom edge and could not be scrolled into view. The log had the
   other half of the same defect: it appended by editing the text STORAGE, which is not an edit the view takes, so
   nothing ever asked it to re-height and its document stayed the pane's birth height. Both now ask the text system
   (`-sizeToFit`) and clamp only upward.
9. **A child process is not a build.** The product runs as this builder's child, so `_task != nil` was true for as
   long as the product was open, and `-isBuilding` answered YES — every verb was then refused with "a build is
   running" when nothing was building. The stage a task belongs to now says whether it is a build, and
   `-isRunningProduct` is the other half. A build stage that fails to LAUNCH also used to leave the flight flag set
   for ever; it now ends the chain and says so.
10. **This tier draws a non-ASCII character as the first byte of its UTF-8 encoding.** The log pane showed
   `# Stopping the productâ` and dropped the rest of the line. The MODEL is right and measured: the text storage holds
   `U+2026` (93 characters, 97 bytes), the layout manager produces one glyph per character (5 for `a…b©c`), and the
   character map is correct (`U+2026 -> glyph 76`, `U+00E2 -> glyph 180`). So the defect is in the raster, not in
   Forge — and until it is found, every line this application writes is **plain ASCII** (asserted by
   `tests/verb_conflicts.m`). Names in the UI follow the same rule.
11. **A ruler's coordinate space is the DOCUMENT's, so converting through the client applies the scroll twice.** A
   vertical ruler's bounds origin is kept equal to the clip view's (`NSScrollView -reflectScrolledClipView:` moves it
   and invalidates the marks); the line-number ruler then converted each fragment with `-convertPoint:toView:`, adding
   the scroll a second time — so every number was drawn a scroll-distance away from its line, right at the top of a
   file and progressively wrong after that. The walk is in document coordinates now (container origin + fragment),
   and a label counts only when its own top is inside the ruler's window, which is where it is actually painted.
12. **An unretained pointer released in `-dealloc` is a segfault at Quit.** The log view was borrowed from its scroll
   view and released by the window controller, so the process died inside `NSClipView -dealloc` on the way out.

## What is not here yet

- **A canvas.** The interface format it would edit exists (`libagora-app/NSNib.h`, AGNib v1, with a text source and
  a compiler in `libagora-app/tests/NSNibSource.h`); what is missing is the editor's half — a view hierarchy to
  drag in, an inspector, and an adornment overlay. `DEVELOPMENT-TOOLS.md` §5 sizes that separately.
- **A debugger.** The reference project manager fronts GDB; this tier's answer is `lldb-dap` and a DAP client, and
  neither is wired.
- **`NSDocument`.** Forge owns its buffers directly, which §9 of `DEVELOPMENT-TOOLS.md` names as the cheap way
  round a document model. Save is `⌘S` on the open file and nothing more.
- **File creation from templates** (New Class, New Header, New Window). The reference tool has it; the manifest
  makes it a small next slice rather than a new concept.
- ~~**Draggable dividers.**~~ They drag now (and the drag moves the GUTTER, not the panes — see `README` §"what the
  drag costs"): `AGPanesView` hit-tests a six-point band at each divider, moves a NUMBER
  while the hand moves, and writes it to `NSUserDefaults` when the hand lets go, so the next window opens at the size
  the last one was left at. The panes are still placed by arithmetic rather than by an `NSSplitView`, because a split
  view re-places its subviews on its own schedule and this tier's `-setFrame:` does not call
  `-resizeSubviewsWithOldSize:` — the divider was the thing worth keeping from a split view, and it is the part this
  class now owns.
- **Per-file build settings and a real inspector.** The manifest carries no per-file attributes yet.
- **Syntax definitions as data.** The colour pass knows one language (C/Objective-C) and says so; the reference tool
  reads its colours from definition files.
