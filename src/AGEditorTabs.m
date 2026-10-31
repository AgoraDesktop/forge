/*
 * AGEditorTabs.m — the strip, the editors behind it, and the two rules about closing one.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import "AGEditorTabs.h"
#import "AGSourceEditor.h"
#import "AGTabStrip.h"

#import <AppKit/NSGraphics.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSString.h>

/* **THE LABEL: THE FILE'S NAME, WITH A BULLET FOR A FILE THAT HAS UNSAVED TEXT.** A path would make every tab as wide as
 * the project's directory; the name is what a person recognises a file by, and the window's title carries the path. */
static NSString *fn_label_for_editor(AGSourceEditor *editor)
{
	NSString *name = [[editor filePath] lastPathComponent];

	if (name == nil || [name length] == 0) {
		name = @"Untitled";
	}
	return [editor isDirty] ? [name stringByAppendingString:@" •"] : name;
}

@interface AGEditorTabs ()
- (void)fn_refreshStrip;
- (void)fn_showEditorAtIndex:(NSInteger)index;
- (void)fn_announce;
- (NSInteger)fn_indexOfPath:(NSString *)path;
- (BOOL)fn_closeTabAtIndex:(NSInteger)index;
- (void)fn_stripSelected:(NSNumber *)index;
- (void)fn_stripClosed:(NSNumber *)index;
- (void)editorDidChange:(AGSourceEditor *)editor;
@end

@implementation AGEditorTabs

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_editors = [[NSMutableArray alloc] init];
		_content = [[NSView alloc] initWithFrame:[self fn_contentRect]];
		_strip = [[AGTabStrip alloc] initWithFrame:[self fn_stripRect]];
		[_strip setTarget:self];
		[_strip setSelectAction:@selector(fn_stripSelected:)];
		[_strip setCloseAction:@selector(fn_stripClosed:)];
		[self addSubview:_content];
		[self addSubview:_strip];
	}
	return self;
}

- (void)dealloc
{
	[_editors release];
	[_strip release];
	[_content release];
	[super dealloc];
}

- (void)setTarget:(id)target
{
	_target = target;	/* NOT RETAINED */
}

- (void)setAction:(SEL)action
{
	_action = action;
}

/* ---- THE GEOMETRY -------------------------------------------------------------------------------- */

/* **THE STRIP IS THE TOP OF THE PANE AND THE EDITORS GET THE REST.** The pane's own frame is what the split view sets, so
 * these two rectangles are re-derived from it every time it moves rather than kept in a variable that a resize could
 * leave behind. */
- (NSRect)fn_stripRect
{
	NSRect bounds = [self bounds];
	CGFloat thickness = [AGTabStrip thickness];

	if (bounds.size.height < thickness) {
		thickness = bounds.size.height;
	}
	return NSMakeRect(0.0, bounds.size.height - thickness, bounds.size.width, thickness);
}

- (NSRect)fn_contentRect
{
	NSRect bounds = [self bounds];
	CGFloat thickness = [AGTabStrip thickness];

	if (bounds.size.height < thickness) {
		thickness = bounds.size.height;
	}
	return NSMakeRect(0.0, 0.0, bounds.size.width, bounds.size.height - thickness);
}

- (void)fn_placeChildren
{
	NSArray *editors = _editors;
	NSUInteger i;

	[_strip setFrame:[self fn_stripRect]];
	[_content setFrame:[self fn_contentRect]];
	for (i = 0; i < [editors count]; i++) {
		[[editors objectAtIndex:i] setFrame:[_content bounds]];
	}
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[self fn_placeChildren];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_placeChildren];
}

/* ---- THE TABS ------------------------------------------------------------------------------------ */

- (NSInteger)fn_indexOfPath:(NSString *)path
{
	NSUInteger i;

	if (path == nil) {
		return -1;
	}
	for (i = 0; i < [_editors count]; i++) {
		AGSourceEditor *editor = [_editors objectAtIndex:i];

		if ([[editor filePath] isEqualToString:path]) {
			return (NSInteger)i;
		}
	}
	return -1;
}

- (AGSourceEditor *)openPath:(NSString *)path
{
	NSInteger index;
	AGSourceEditor *editor;
	NSString *source;

	if (path == nil) {
		return nil;
	}
	/* **A FILE THAT IS ALREADY OPEN IS SELECTED, NOT RE-READ.** Reading it again would throw away everything typed into
	 * it since — and the click that got here was "show me that file", not "reload it". */
	index = [self fn_indexOfPath:path];
	if (index >= 0) {
		[self fn_showEditorAtIndex:index];
		return [_editors objectAtIndex:(NSUInteger)index];
	}
	source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
	if (source == nil) {
		source = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
	}
	if (source == nil) {
		return nil;
	}
	editor = [[[AGSourceEditor alloc] initWithFrame:[_content bounds]] autorelease];
	[editor setTarget:self];
	[editor setAction:@selector(editorDidChange:)];
	[editor setFilePath:path];
	[editor setSource:source];
	[_editors addObject:editor];
	[self fn_showEditorAtIndex:(NSInteger)[_editors count] - 1];
	return editor;
}

/* **ONE EDITOR IS IN THE HIERARCHY AT A TIME.** Each tab keeps its own editor alive — text, selection, scroll, undo — and
 * selecting a tab swaps which of them is a subview of the content area. That is the whole of "the tab remembers where I
 * was": there is no per-tab state to copy, because the view itself is the state. */
- (void)fn_showEditorAtIndex:(NSInteger)index
{
	NSInteger i;

	if (index < 0 || (NSUInteger)index >= [_editors count]) {
		return;
	}
	for (i = 0; i < (NSInteger)[_editors count]; i++) {
		AGSourceEditor *editor = [_editors objectAtIndex:(NSUInteger)i];

		if (i == index) {
			if ([editor superview] != _content) {
				[editor setFrame:[_content bounds]];
				[_content addSubview:editor];
			}
		} else if ([editor superview] == _content) {
			[editor removeFromSuperview];
		}
	}
	_current = index;
	[self fn_refreshStrip];
	/* **AND THE SELECTED CHIP IS BROUGHT INTO VIEW.** A file opened from the browser — or jumped to from a build
	 * diagnostic — can be a tab past the strip's right edge, and a strip that changes which file is in front without
	 * showing where it went is worse than one that cannot scroll at all. */
	[_strip revealTabAtIndex:(NSUInteger)index];
	[self fn_announce];
}

- (AGSourceEditor *)currentEditor
{
	if (_current < 0 || (NSUInteger)_current >= [_editors count]) {
		return nil;
	}
	return [_editors objectAtIndex:(NSUInteger)_current];
}

- (NSString *)currentPath
{
	return [[self currentEditor] filePath];
}

- (NSUInteger)tabCount
{
	return [_editors count];
}

- (AGTabStrip *)tabStrip
{
	return _strip;
}

/* **THE STRIP IS TOLD THE WHOLE LIST EVERY TIME, NOT PATCHED.** A tab's label is a file name and a bullet, and both come
 * from the editor's own state; re-deriving the list is what stops a "saved" file from wearing a bullet forever. */
- (void)fn_refreshStrip
{
	NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[_editors count]];
	NSUInteger i;

	for (i = 0; i < [_editors count]; i++) {
		[titles addObject:fn_label_for_editor([_editors objectAtIndex:i])];
	}
	[_strip setTitles:titles selected:_current];
}

- (void)fn_announce
{
	if (_target != nil && _action != NULL && [_target respondsToSelector:_action]) {
		[_target performSelector:_action withObject:self];
	}
}

/* ---- THE STRIP'S TWO CLICKS ---------------------------------------------------------------------- */

- (void)fn_stripSelected:(NSNumber *)index
{
	[self fn_showEditorAtIndex:[index integerValue]];
}

/* **THE CLOSE GLYPH ASKS; THIS CLASS DECIDES.** A tab with unsaved text is refused, which is the one rule here — see
 * `-closeCurrentTab`. */
- (void)fn_stripClosed:(NSNumber *)index
{
	[self fn_closeTabAtIndex:[index integerValue]];
}

- (void)editorDidChange:(AGSourceEditor *)editor
{
	(void)editor;
	[self fn_refreshStrip];
	[self fn_announce];
}

/* ---- CLOSING ------------------------------------------------------------------------------------- */

- (BOOL)closeCurrentTab
{
	return [self fn_closeTabAtIndex:_current];
}

- (BOOL)closeTabAtIndex:(NSUInteger)index
{
	return [self fn_closeTabAtIndex:(NSInteger)index];
}

/* **A TAB WITH UNSAVED TEXT DOES NOT CLOSE, WHICH IS THE ONE RULE THIS CLASS REFUSES ON.** There is no save prompt in this
 * Forge — the window's ⌘S is the save door — so closing anyway would discard an edit with nothing to undo it and no
 * dialog to say so. The bullet in the tab's label is what explains the refusal, and ⌘S clears it. */
- (BOOL)fn_closeTabAtIndex:(NSInteger)index
{
	AGSourceEditor *editor;
	NSInteger next;

	if (index < 0 || (NSUInteger)index >= [_editors count]) {
		return NO;
	}
	editor = [_editors objectAtIndex:(NSUInteger)index];
	if ([editor isDirty]) {
		return NO;
	}
	[editor removeFromSuperview];
	[_editors removeObjectAtIndex:(NSUInteger)index];
	/* **THE NEIGHBOUR BECOMES CURRENT**, which is what a strip of tabs does: the one that moved into this place, or the
	 * last one when the closed tab was on the right. An empty strip selects nothing and the pane shows its own face. */
	next = index;
	if (next >= (NSInteger)[_editors count]) {
		next = (NSInteger)[_editors count] - 1;
	}
	_current = -1;
	if (next >= 0) {
		[self fn_showEditorAtIndex:next];
	} else {
		[self fn_refreshStrip];
		[self fn_announce];
	}
	return YES;
}

- (BOOL)closePath:(NSString *)path
{
	NSInteger index = [self fn_indexOfPath:path];

	if (index < 0) {
		return NO;
	}
	return [self fn_closeTabAtIndex:index];
}

- (void)setLayoutDeferred:(BOOL)deferred
{
	NSUInteger i;

	for (i = 0; i < [_editors count]; i++) {
		[[_editors objectAtIndex:i] setLayoutDeferred:deferred];
	}
}

@end
