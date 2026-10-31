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
- (void)setTarget:(nullable id)target;
- (void)setSelectAction:(nullable SEL)action;
- (void)setCloseAction:(nullable SEL)action;

@end

#endif /* AGTABSTRIP_H */
