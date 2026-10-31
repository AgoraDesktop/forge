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
#import <AppKit/NSTrackingArea.h>
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
/* **ONE WHEEL LINE'S WORTH OF STRIP, IN POINTS.** `-deltaY` counts lines (a notch is 1.0, a trackpad's fraction of a
 * notch is a fraction), so this is what one line moves the chips: a little less than a short chip, so a swipe walks
 * along the strip instead of jumping a whole file per notch. */
static const CGFloat AGTabScrollLine = 20.0;

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

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_clampOffset];
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
	if (_hoverClose >= (NSInteger)[_titles count]) {
		_hoverClose = -1;
	}
	[self fn_clampOffset];
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
	CGFloat x = -_offset;
	NSUInteger i;

	for (i = 0; i < index && i < [_titles count]; i++) {
		x += [self fn_widthForTitleAtIndex:i];
	}
	return NSMakeRect(x, 0.0, [self fn_widthForTitleAtIndex:index], [self bounds].size.height - 1.0);
}

- (CGFloat)contentWidth
{
	CGFloat width = 0.0;
	NSUInteger i;

	for (i = 0; i < [_titles count]; i++) {
		width += [self fn_widthForTitleAtIndex:i];
	}
	return width;
}

- (CGFloat)scrollOffset
{
	return _offset;
}

/* **THE OFFSET NEVER GOES PAST EITHER END**, which is the one clamp: a strip narrower than its chips cannot scroll, and
 * one scrolled past the last chip would show a blank band with no way back except the wheel. */
- (void)fn_clampOffset
{
	CGFloat excess = [self contentWidth] - [self bounds].size.width;

	if (excess < 0.0) {
		excess = 0.0;
	}
	if (_offset > excess) {
		_offset = excess;
	}
	if (_offset < 0.0) {
		_offset = 0.0;
	}
}

/* **AND THE SELECTED CHIP IS ALWAYS ON SCREEN.** A tab selected by a click is already visible, but one selected by an
 * OPEN (a file chosen in the browser, a build diagnostic jumping to a line) may be off the right edge — and a strip that
 * silently changes which file is in front without showing where it went is worse than one that cannot scroll. */
- (void)revealTabAtIndex:(NSUInteger)index
{
	NSRect chip;
	CGFloat visible = [self bounds].size.width;

	if (index >= [_titles count]) {
		return;
	}
	/* **A STRIP WITH NO WIDTH REVEALS NOTHING, AND MUST NOT SCROLL ITSELF AWAY.** A tab opened before the pane has been
	 * laid out is revealed into a strip zero points wide — and "bring the chip's right edge to the strip's right edge"
	 * then means "scroll the whole strip off to the left", which is a band of nothing where the tabs should be: MEASURED,
	 * the strip came up empty on the first file opened. A zero-width strip leaves the offset at the start and the first
	 * real layout takes it from there. */
	if (visible <= 0.0) {
		_offset = 0.0;
		return;
	}
	[self fn_clampOffset];
	chip = [self rectForTabAtIndex:index];
	if (NSMinX(chip) < 0.0) {
		_offset += NSMinX(chip);
	} else if (NSMaxX(chip) > visible) {
		_offset += NSMaxX(chip) - visible;
	}
	[self fn_clampOffset];
	[self setNeedsDisplay:YES];
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

		/* **THE ONE UNDER THE POINTER WEARS A PLATE**, which is how a twelve-point target says "press me": the same
		 * prelight a push button has, in the same colour, so the two kinds of button on this desktop agree. It is
		 * drawn BEFORE the strokes so the cross stays crisp over it. */
		if (_hoverClose == i) {
			NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(glyph, -2.0, -2.0)
									      xRadius:3.0 yRadius:3.0];

			[[NSColor cg_prelightControlFaceColor] setFill];
			[plate fill];
		}
		/* THE GLYPH IS TWO STROKES, WHICH IS ALL A CLOSE BUTTON IS AT TWELVE POINTS.** A tabler `x` would be a
		 * 24-point tile scaled down to six; two lines at this size are both crisper and the right weight beside
		 * eleven-point words. */
		[cross moveToPoint:NSMakePoint(centre.x - arm, centre.y - arm)];
		[cross lineToPoint:NSMakePoint(centre.x + arm, centre.y + arm)];
		[cross moveToPoint:NSMakePoint(centre.x - arm, centre.y + arm)];
		[cross lineToPoint:NSMakePoint(centre.x + arm, centre.y - arm)];
		[cross setLineWidth:1.5];
		{
			NSColor *ink = (i == _selected || _hoverClose == i) ? [NSColor controlTextColor]
									   : [NSColor disabledControlTextColor];

			[ink setStroke];
		}
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
/* ---- THE POINTER'S TWO REPORTS ------------------------------------------------------------------- */

/* **THE AREA IS THE VIEW'S OWN VISIBLE RECTANGLE**, the same shape the toolbar's prelight uses: a strip that is resized by
 * a split view needs no pass to keep its region in step, and motion leaving the strip altogether arrives as an exit. */
- (void)viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	if ([self window] == nil) {
		return;
	}
	if (_hoverArea == nil) {
		_hoverArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
							  options:(NSTrackingMouseEnteredAndExited |
								   NSTrackingMouseMoved |
								   NSTrackingActiveInActiveApp |
								   NSTrackingInVisibleRect)
							    owner:self userInfo:nil];
	}
	if ([self trackingAreas] == nil || ![[self trackingAreas] containsObject:_hoverArea]) {
		[self addTrackingArea:_hoverArea];
	}
}

- (NSInteger)hoveredCloseIndex
{
	return _hoverClose;
}

/* **ONE QUESTION PER MOTION: WHICH GLYPH IS UNDER THE POINTER?** The plate costs a redraw, so it is only asked for when the
 * ANSWER changes — a motion inside one glyph is not a reason to repaint the strip. */
- (void)hoverAtPoint:(NSPoint)point
{
	NSInteger i, count = (NSInteger)[_titles count];
	NSInteger hover = -1;

	for (i = 0; i < count; i++) {
		if (NSPointInRect(point, [self closeRectForTabAtIndex:(NSUInteger)i])) {
			hover = i;
			break;
		}
	}
	if (hover != _hoverClose) {
		_hoverClose = hover;
		[self setNeedsDisplay:YES];
	}
}

- (void)mouseMoved:(NSEvent *)event
{
	[self hoverAtPoint:[self convertPoint:[event locationInWindow] fromView:nil]];
}

- (void)mouseEntered:(NSEvent *)event
{
	[self mouseMoved:event];
}

- (void)mouseExited:(NSEvent *)event
{
	(void)event;
	if (_hoverClose != -1) {
		_hoverClose = -1;
		[self setNeedsDisplay:YES];
	}
	[super mouseExited:event];
}

/* **THE WHEEL WALKS ALONG THE STRIP.** A tab strip is a HORIZONTAL list, so a trackpad's sideways swipe is the natural
 * gesture — but a mouse has one wheel, and every Mac application with a horizontal strip (Chrome, Xcode's tab bar) moves
 * it with the vertical wheel rather than doing nothing. The horizontal delta wins when there is one, so a trackpad does
 * not have its two axes fight; a wheel past either end is passed up the chain, which is what lets a strip that cannot
 * scroll leave the scroll to the view behind it. */
- (void)scrollWheel:(NSEvent *)event
{
	CGFloat delta = [event deltaX];
	CGFloat before = _offset;

	if (delta == 0.0) {
		delta = [event deltaY];
	}
	_offset -= delta * AGTabScrollLine;
	[self fn_clampOffset];
	if (_offset == before) {
		[super scrollWheel:event];
		return;
	}
	[self setNeedsDisplay:YES];
}

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
