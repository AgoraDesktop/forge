/*
 * AGTabStrip.h — the row of chips above the editor: a name, a close glyph on its left, and which file is in front.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * **THE STRIP IS FORGE'S, NOT APPKIT'S, AND THE CLOSE GLYPH IS THE REASON.** `NSTabView` draws a chip and selects its
 * item from a click, and it has no idea what closing one would MEAN — a tab view's items can be anything, and this
 * application's tabs are files that may have unsaved text. A button that discards a file's edit on a stray click is a
 * decision an editor has to make where the editor can see the file, so the strip is a view here and the rule lives one
 * class up, in `AGEditorTabs`.
 *
 * WHAT IT IS: a title per tab, which one is selected, and per chip two rectangles — the chip itself and the close glyph
 * on its LEFT, which is where a Mac editor puts it (`Safari`, `Xcode`, `Terminal`). It draws the chips and it reports
 * clicks; it knows nothing about files, editors or dirtiness.
 */
#ifndef AGTABSTRIP_H
#define AGTABSTRIP_H

#import <AppKit/NSView.h>

@interface AGTabStrip : NSView
{
	NSMutableArray *_titles;	/* RETAINED: NSString, one per tab */
	NSInteger _selected;
	NSInteger _hoverClose;		/* the tab whose close glyph the pointer is over, or -1 */
	NSTrackingArea *_hoverArea;	/* RETAINED, or nil before the strip is in a window */
	CGFloat _offset;		/* how far the chips are scrolled to the left, in points */
	id _target;			/* NOT RETAINED */
	SEL _selectAction;		/* sent with an NSNumber index */
	SEL _closeAction;		/* sent with an NSNumber index */
}

/* THE STRIP'S HEIGHT IN POINTS, which is the space it takes from the pane it covers. */
+ (CGFloat)thickness;

- (void)setTitles:(NSArray *)titles selected:(NSInteger)index;
- (NSUInteger)tabCount;
- (NSInteger)selectedIndex;

/* THE TWO RECTANGLES PER CHIP, in this view's coordinates — the chip, and the close glyph's hot spot inside its left
 * end. Both are also what the drawing uses, so a probe clicking the glyph is clicking what a person sees. */
- (NSRect)rectForTabAtIndex:(NSUInteger)index;
- (NSRect)closeRectForTabAtIndex:(NSUInteger)index;

/* **THE TWO CLICKS, AS TARGET/ACTION PAIRS**, each handed an `NSNumber` index: a press on a chip selects its tab, a
 * press on the glyph asks for it to be closed. Asking is not closing — the caller may refuse, and does. */
/* **THE CHIPS SCROLL WHEN THEY DO NOT FIT.** The strip is as wide as the pane; a project with more files open than fit
 * keeps them all, and the wheel (or a trackpad's sideways swipe) walks along them. There is no visible scroller: a tab
 * strip with a scrollbar under it is a table of contents, and the strip's own job is to keep the SELECTED tab in view —
 * which is what `-revealTabAtIndex:` does on every selection, so a tab opened off the right edge is brought into view
 * rather than left to be found. */
- (CGFloat)contentWidth;
- (CGFloat)scrollOffset;
- (void)revealTabAtIndex:(NSUInteger)index;

/* **AND THE HOVER, WHICH IS THE GLYPH'S OWN.** The close glyph is a target the size of a word's first letter, so the one
 * under the pointer says so by wearing a plate behind it — a button nobody can see they are over is a button people miss. */
- (NSInteger)hoveredCloseIndex;

/* **THE POINT THE HOVER CALLBACKS ARE GIVEN, IN THIS VIEW'S COORDINATES** — what the tracking area's `-mouseMoved:` and a
 * probe both hand over. A point outside every glyph clears the hover. */
- (void)hoverAtPoint:(NSPoint)point;

- (void)setTarget:(nullable id)target;
- (void)setSelectAction:(nullable SEL)action;
- (void)setCloseAction:(nullable SEL)action;

@end

#endif /* AGTABSTRIP_H */
