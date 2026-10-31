/*
 * AGSourceEditor.h — one file's text, its line numbers and its colour.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE COLOUR IS TEMPORARY ATTRIBUTES, WHICH IS WHAT THEY ARE FOR.** `NSLayoutManager`'s temporary table exists so
 * a caller can paint a run without touching the storage — the text the file holds and the text a person saves stay
 * the same bytes, and the colour is a view of that text rather than a part of it. `libagora-app/NSLayoutManager.h`
 * names the pair (`-addTemporaryAttribute:value:forCharacterRange:` and its remove) and they are here, so
 * highlighting is a pass over the string after every edit rather than a document format.
 *
 * **THE EDITOR IS A CONTAINER RATHER THAN AN `NSTextView` SUBCLASS**, because the line numbers are a ruler in the
 * SCROLL VIEW and not a thing the text view can own: the ruler is the scroll view's (`-setVerticalRulerView:`),
 * the numbers are drawn in it, and the scroll view keeps the two in step when either moves. A subclass would have
 * to reach up to the ancestor to find the ruler; this class is that ancestor.
 */
#ifndef AGSOURCEEDITOR_H
#define AGSOURCEEDITOR_H

#import <AppKit/NSRulerView.h>
#import <AppKit/NSView.h>

@class NSScrollView, NSTextView;

@interface AGSourceEditor : NSView
{
	NSScrollView *_scrollView;	/* RETAINED */
	NSTextView *_textView;		/* RETAINED (also the scroll view's document view) */
	NSRulerView *_ruler;		/* RETAINED */
	NSString *_filePath;		/* RETAINED, or nil for a buffer with no file */
	BOOL _layoutDeferred;		/* YES while a drag is moving this view's frame */
	BOOL _dirty;			/* the text has been typed into since it was opened or saved */
	id _target;			/* NOT RETAINED: told when the text changes, so a tab can re-label itself */
	SEL _action;
}

- (instancetype)initWithFrame:(NSRect)frame;

- (NSTextView *)textView;
- (void)setSource:(NSString *)source;
- (NSString *)source;

/* RE-COLOUR WITHOUT TOUCHING THE TEXT. Called after `-setSource:` and by the text view's delegate when an edit
 * ends; it is safe to call at any time. */
- (void)highlight;

/* **WHETHER THIS BUFFER HAS TEXT THAT IS NOT ON DISK, AND THE DOOR A SAVE CLEARS.** The editor knows because it is its
 * text view's delegate: `-textDidChange:` is the one report every edit makes, and `-setSource:` is the one door that
 * puts a file's own text in. Nothing here decides what an unsaved file MEANS — a tab refuses to close on it, and the
 * window's ⌘S clears it — which is why this is a flag and not a document model. */
- (BOOL)isDirty;
- (void)setDirty:(BOOL)flag;

/* **AND THE ANNOUNCEMENT: "THIS BUFFER CHANGED".** Sent after every edit and after `-setSource:`, so the strip that
 * holds this editor can re-derive its tab's label (the bullet) and pass the news on to the window. */
- (void)setTarget:(nullable id)target;
- (void)setAction:(nullable SEL)action;

/* Put the insertion point on `line` (1-based) and scroll it into view — the door a build diagnostic uses. */
- (void)goToLine:(NSInteger)line;

/* The file this editor shows, for a window title and for "save". Not an `NSDocument`: this tier's Forge owns its
 * buffers directly, which `DEVELOPMENT-TOOLS.md` §9 names as the cheap way round a missing document model. */
- (NSString *)filePath;
- (void)setFilePath:(NSString *)path;

/* THE RULER AND ITS SCROLL VIEW, FOR THE PROBE THAT SCROLLS AND READS THE NUMBERS BACK. Test doors, named as such. */
/* **A RESIZE MAY PUT OFF ITS RE-LAYOUT.** A text view re-wraps when its width changes, and a drag delivers motion faster
 * than a file can be wrapped; the panes view defers for the length of the drag and releases it once, on the way out. While
 * deferred the scroll view still takes the new frame — only the document's re-fit waits. */
- (void)setLayoutDeferred:(BOOL)deferred;

- (NSRulerView *)lineNumberRuler;
- (NSScrollView *)scrollView;

@end

/* THE RULER, WHICH IS A VIEW OF THE LAYOUT AND NOT A SECOND COPY OF THE TEXT.** `-lineFragmentRectForGlyphAtIndex:`
 * is the layout manager's own answer for where a fragment sits, so a wrapped line's number appears once — at the
 * fragment's first row — and the count cannot drift from what is drawn. */
@interface AGLineNumberRuler : NSRulerView

/* THE NUMBERS THE RULER WOULD PAINT NOW. A test door, because the claim "the numbers line up after a scroll" is a
 * claim about where they land, and a screenshot is not an assertion. */
- (NSArray *)cg_visibleLineNumbers;

@end

#endif /* AGSOURCEEDITOR_H */
