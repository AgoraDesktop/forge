/*
 * AGEditorTabs.h — one tab per open file, and the editor that belongs to each.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A TAB IS A FILE THAT IS STILL OPEN, AND THAT IS THE WHOLE MODEL.** The editor used to be one buffer: choosing a file
 * in the browser overwrote what was in it, so a person reading two files held one of them in their head. Now each file
 * that is opened KEEPS its editor — its text, its selection, its scroll position, its undo stack — and the tab strip is
 * how that set is chosen from. Nothing is remembered "per tab" separately: the tab's view IS the editor, so there is no
 * second copy of the state to keep in step.
 *
 * **THE STRIP IS FORGE'S OWN (`AGTabStrip`), AND THE CLOSE GLYPH IS WHY.** `NSTabView` draws a chip and selects it from a
 * click, but it has no idea what closing one would mean — and here a close is a decision that may be REFUSED, because the
 * file in the tab can have unsaved text. A button that discards an edit on one stray click has to live where the editor is,
 * so the strip is a view in this application and the rule is one class above it.
 *
 * **DIRTY IS THE TAB'S, AND IT IS THE EDITOR THAT KNOWS.** A file whose text has been typed into since it was opened or
 * last saved wears a bullet in its label, and closing such a tab REFUSES rather than discarding the edit: there is no
 * save prompt in this tier's Forge, and a silent discard is the one outcome a person cannot undo. ⌘S clears the bullet.
 */
#ifndef AGEDITORTABS_H
#define AGEDITORTABS_H

#import <AppKit/NSView.h>

@class AGSourceEditor, AGTabStrip;

@interface AGEditorTabs : NSView
{
	NSMutableArray *_editors;	/* RETAINED: AGSourceEditor per open file, in tab order */
	AGTabStrip *_strip;		/* RETAINED: the chips above the editor */
	NSView *_content;		/* RETAINED: the area the current editor fills */
	NSInteger _current;		/* index into `_editors`, or -1 */
	id _target;			/* NOT RETAINED: the object told when the selected file changes */
	SEL _action;
}

- (instancetype)initWithFrame:(NSRect)frame;

/* **OPENS A FILE, OR SELECTS THE TAB THAT ALREADY HAS IT.** Answers the editor now on screen, or nil when the file cannot
 * be read — the caller logs that, because it is the caller who owns the log. A file that is already open is NOT re-read:
 * the tab holds the text a person has been editing, and re-reading would throw it away. */
- (nullable AGSourceEditor *)openPath:(nullable NSString *)path;

/* The editor the strip is showing, or nil when no file is open. */
- (nullable AGSourceEditor *)currentEditor;
- (nullable NSString *)currentPath;
- (NSUInteger)tabCount;

/* **THE STRIP, FOR THE PROBES.** Its chips and its close glyphs are the geometry a test clicks, and the click is the
 * behaviour worth asserting — the refusal lives in this class, not in the button. */
- (nullable AGTabStrip *)tabStrip;

/* **CLOSES THE CURRENT TAB, AND REFUSES WHILE IT HAS UNSAVED TEXT.** Answers YES when the tab went away. */
- (BOOL)closeCurrentTab;

/* And one by index — what the strip's close glyph asks for, and what a probe drives to prove the refusal. */
- (BOOL)closeTabAtIndex:(NSUInteger)index;

/* **AND ONE NAMED FILE'S TAB, FOR A FILE THAT LEFT THE PROJECT.** Also refuses while the text is unsaved. */
- (BOOL)closePath:(nullable NSString *)path;

/* `AGSourceEditor -setLayoutDeferred:`, forwarded to every editor — the panes view defers a re-fit while a divider is
 * being dragged, and a tab strip that answered for only the visible editor would re-wrap the others mid-drag. */
- (void)setLayoutDeferred:(BOOL)deferred;

/* **THE ONE ANNOUNCEMENT: "THE FILE ON SCREEN IS NOW A DIFFERENT ONE".** Sent as a plain target/action pair after a tab
 * is selected, added, removed or closed, so the window's title and the keyboard's owner are updated by the controller
 * rather than guessed at here. */
- (void)setTarget:(nullable id)target;
- (void)setAction:(nullable SEL)action;

@end

#endif /* AGEDITORTABS_H */
