/*
 * AGTabStrip.m — the chips, their words, the close glyph, and the two clicks.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "AGTabStrip.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSStringDrawing.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSValue.h>

/* THE STRIP'S MEASURES, IN POINTS. The chip is the close glyph, the gap after it, the words, and the air at either end;
 * every one of them is named because the two rectangles the strip reports are built from them and a probe clicks them. */
static const CGFloat AGTabThickness = 24.0;
static const CGFloat AGTabPadLeft = 6.0;
static const CGFloat AGTabPadRight = 10.0;
static const CGFloat AGTabCloseSize = 12.0;
static const CGFloat AGTabCloseGap = 4.0;
static const CGFloat AGTabCornerRadius = 4.0;

static NSFont *fn_tab_font(void)
{
	return [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
}

static NSDictionary *fn_tab_attributes(BOOL selected)
{
	return [NSDictionary dictionaryWithObjectsAndKeys:
		fn_tab_font(), NSFontAttributeName,
		(selected ? [NSColor controlTextColor] : [NSColor disabledControlTextColor]), NSForegroundColorAttributeName,
		nil];
}

@implementation AGTabStrip

+ (CGFloat)thickness
{
	return AGTabThickness;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_titles = [[NSMutableArray alloc] init];
		_selected = -1;
	}
	return self;
}

- (void)dealloc
{
	[_titles release];
	[super dealloc];
}

- (void)setTarget:(id)target
{
	_target = target;	/* NOT RETAINED */
}

- (void)setSelectAction:(SEL)action
{
	_selectAction = action;
}

- (void)setCloseAction:(SEL)action
{
	_closeAction = action;
}

- (void)setTitles:(NSArray *)titles selected:(NSInteger)index
{
	NSArray *copy = [titles copy];

	[_titles release];
	_titles = [copy mutableCopy];
	[copy release];
	_selected = index;
	[self setNeedsDisplay:YES];
}

- (NSUInteger)tabCount
{
	return [_titles count];
}

- (NSInteger)selectedIndex
{
	return _selected;
}

/* ---- THE GEOMETRY -------------------------------------------------------------------------------- */

/* **EVERY CHIP IS AS WIDE AS ITS WORDS PLUS THE GLYPH AND THE AIR, LAID END TO END FROM THE LEFT.** A strip that shares
 * the width out equally would squeeze every title to the same clipped length; a strip that sizes each chip to its own
 * title is what makes `main.m` narrow and `AGProjectWindowController.m` wide, which is how a person tells them apart. */
- (CGFloat)fn_widthForTitleAtIndex:(NSUInteger)index
{
	NSString *title = (index < [_titles count]) ? [_titles objectAtIndex:index] : @"";
	NSSize size = [title sizeWithAttributes:fn_tab_attributes(index == (NSUInteger)_selected)];

	return AGTabPadLeft + AGTabCloseSize + AGTabCloseGap + ceil(size.width) + AGTabPadRight;
}

- (NSRect)rectForTabAtIndex:(NSUInteger)index
{
	CGFloat x = 0.0;
	NSUInteger i;

	for (i = 0; i < index && i < [_titles count]; i++) {
		x += [self fn_widthForTitleAtIndex:i];
	}
	return NSMakeRect(x, 0.0, [self fn_widthForTitleAtIndex:index], [self bounds].size.height - 1.0);
}

- (NSRect)closeRectForTabAtIndex:(NSUInteger)index
{
	NSRect chip = [self rectForTabAtIndex:index];

	return NSMakeRect(chip.origin.x + AGTabPadLeft,
			  chip.origin.y + (chip.size.height - AGTabCloseSize) / 2.0,
			  AGTabCloseSize, AGTabCloseSize);
}

/* ---- THE INK ------------------------------------------------------------------------------------- */

/* **THE SELECTED CHIP IS THE PANE'S OWN FACE AND IT SITS ONE POINT LOWER THAN THE OTHERS**, which is what makes it read as
 * one piece with the editor under it — the separator line runs under every other chip and stops under this one. The
 * unselected chips are the strip's own grey with a hairline between them: no second fill colour, so the strip is two
 * greys and a white and the eye reads the selected one immediately. */
- (void)drawRect:(NSRect)dirtyRect
{
	NSRect bounds = [self bounds];
	NSInteger i, count = (NSInteger)[_titles count];

	(void)dirtyRect;
	[[NSColor cg_chromeFaceColor] setFill];
	NSRectFill(bounds);

	for (i = 0; i < count; i++) {
		NSRect chip = [self rectForTabAtIndex:(NSUInteger)i];

		if (i == _selected) {
			NSRect face = NSMakeRect(chip.origin.x, bounds.origin.y, chip.size.width, bounds.size.height);
			NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:face
									      xRadius:AGTabCornerRadius
									       yRadius:AGTabCornerRadius];

			[[NSColor whiteColor] setFill];
			[shape fill];
			/* AND THE CORNERS UNDER IT ARE THE PANE'S, so the fill does not wear a rounded bottom edge over the
			 * content. */
			[[NSColor whiteColor] setFill];
			NSRectFill(NSMakeRect(face.origin.x, face.origin.y, face.size.width, AGTabCornerRadius));
			NSRectFill(NSMakeRect(face.origin.x, face.origin.y, AGTabCornerRadius, face.size.height));
		} else if (i > 0) {
			/* **A HAIRLINE BETWEEN TWO CHIPS, AND NOT AT THE STRIP'S LEFT EDGE.** Two chairs pushed together have one
			 * line between them; the first one's left edge is the window's. */
			[[NSColor controlShadowColor] setFill];
			NSRectFill(NSMakeRect(chip.origin.x, bounds.origin.y + 4.0, 1.0, bounds.size.height - 8.0));
		}
	}
	/* THE STRIP'S FLOOR, WHICH THE SELECTED CHIP CUTS THROUGH. */
	[[NSColor controlDarkShadowColor] setFill];
	if (_selected >= 0 && _selected < count) {
		NSRect open = [self rectForTabAtIndex:(NSUInteger)_selected];

		NSRectFill(NSMakeRect(bounds.origin.x, bounds.origin.y, open.origin.x, 1.0));
		NSRectFill(NSMakeRect(NSMaxX(open), bounds.origin.y, NSMaxX(bounds) - NSMaxX(open), 1.0));
	} else {
		NSRectFill(NSMakeRect(bounds.origin.x, bounds.origin.y, bounds.size.width, 1.0));
	}

	for (i = 0; i < count; i++) {
		NSRect chip = [self rectForTabAtIndex:(NSUInteger)i];
		NSRect glyph = [self closeRectForTabAtIndex:(NSUInteger)i];
		NSDictionary *attributes = fn_tab_attributes(i == _selected);
		NSFont *font = fn_tab_font();
		NSString *title = [_titles objectAtIndex:(NSUInteger)i];
		NSPoint centre = NSMakePoint(NSMidX(glyph), NSMidY(glyph));
		CGFloat arm = 3.0;
		NSBezierPath *cross = [NSBezierPath bezierPath];

		/* THE GLYPH IS TWO STROKES, WHICH IS ALL A CLOSE BUTTON IS AT TWELVE POINTS.** A tabler `x` would be a
		 * 24-point tile scaled down to six; two lines at this size are both crisper and the right weight beside
		 * eleven-point words. */
		[cross moveToPoint:NSMakePoint(centre.x - arm, centre.y - arm)];
		[cross lineToPoint:NSMakePoint(centre.x + arm, centre.y + arm)];
		[cross moveToPoint:NSMakePoint(centre.x - arm, centre.y + arm)];
		[cross lineToPoint:NSMakePoint(centre.x + arm, centre.y - arm)];
		[cross setLineWidth:1.5];
		[(i == _selected ? [NSColor controlTextColor] : [NSColor disabledControlTextColor]) setStroke];
		[cross stroke];

		/* **AND THE WORDS, CENTRED IN WHAT IS LEFT OF THE CHIP.** `-drawAtPoint:` takes a BASELINE, so the box to centre
		 * is ascender-to-descender and the baseline is that box's bottom — the rule every label on this desktop follows,
		 * and the one whose absence a person reads as "the text is too low". */
		[title drawAtPoint:NSMakePoint(NSMaxX(glyph) + AGTabCloseGap,
					       NSMidY(chip) - ([font ascender] + [font descender]) / 2.0)
		    withAttributes:attributes];
	}
}

/* ---- THE CLICKS ---------------------------------------------------------------------------------- */

/* **THE GLYPH IS TESTED FIRST, BECAUSE IT SITS INSIDE THE CHIP.** A chip that answered "select" for a press on its own
 * close button would make the button useless, and ordering the two tests is the whole of that rule. */
- (void)mouseDown:(NSEvent *)event
{
	NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
	NSUInteger i, count = [_titles count];

	for (i = 0; i < count; i++) {
		if (NSPointInRect(point, [self closeRectForTabAtIndex:i])) {
			if (_target != nil && _closeAction != NULL && [_target respondsToSelector:_closeAction]) {
				[_target performSelector:_closeAction withObject:[NSNumber numberWithInteger:(NSInteger)i]];
			}
			return;
		}
	}
	for (i = 0; i < count; i++) {
		if (NSPointInRect(point, [self rectForTabAtIndex:i])) {
			if (i != (NSUInteger)_selected) {
				_selected = (NSInteger)i;
				[self setNeedsDisplay:YES];
			}
			if (_target != nil && _selectAction != NULL && [_target respondsToSelector:_selectAction]) {
				[_target performSelector:_selectAction withObject:[NSNumber numberWithInteger:(NSInteger)i]];
			}
			return;
		}
	}
}

@end
