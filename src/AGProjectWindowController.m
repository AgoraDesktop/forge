/*
 * AGProjectWindowController.m — the window, its three panes, and the verbs.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See AGProjectWindowController.h. Two implementation notes that matter:
 *
 * **THE SPLIT VIEWS ARE NESTED, AND THE OUTER ONE IS VERTICAL.** `-setVertical:YES` means the subviews are side by
 * side (Apple's naming is about the DIVIDER), so the outer split is browser | rest and the inner one is editor over
 * log. Both get provisional frames here and the split view's own `-adjustSubviews` does the rest.
 *
 * **THE BROWSER'S GROUPS ARE BUILT FROM THE PROJECT, NOT FROM A DIRECTORY WALK.** `-fn_reloadGroups` asks the
 * project for its categories and its files in each; a file that is on disk and not in the manifest therefore does
 * not appear, which is the rule the manifest exists to state (AGProject.h).
 */
#import "AGProjectWindowController.h"

#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectInfoView.h"
#import "AGToolbarIcons.h"
#import "AGSourceEditor.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSAttributedString.h>
#import <AppKit/NSClipView.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSCursor.h>
#import <AppKit/NSLayoutManager.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSOutlineView.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSSegmentedControl.h>
#import <AppKit/NSSplitView.h>
#import <AppKit/NSTableColumn.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSTextStorage.h>
#import <AppKit/NSToolbar.h>
#import <AppKit/NSToolbarItem.h>
#import <AppKit/NSUserInterfaceValidation.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSAlert.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

#include <stdio.h>
#include <stdlib.h>

static NSString *const AGToolbarIdentifier = @"AGProjectToolbar";
/* THE FIRST GROUP: the two verbs that OPEN a project, which belong to the application rather than to one window. */
static NSString *const AGToolbarNewProject = @"AGToolbarNewProject";
static NSString *const AGToolbarOpenProject = @"AGToolbarOpenProject";
static NSString *const AGToolbarBuild = @"AGToolbarBuild";
static NSString *const AGToolbarClean = @"AGToolbarClean";
static NSString *const AGToolbarRun = @"AGToolbarRun";
static NSString *const AGToolbarStop = @"AGToolbarStop";
static NSString *const AGToolbarDetail = @"AGToolbarDetail";
static NSString *const AGToolbarAddFiles = @"AGToolbarAddFiles";
static NSString *const AGToolbarExport = @"AGToolbarExport";
static NSString *const AGToolbarRemoveFile = @"AGToolbarRemoveFile";

/* **AND THE ONE PREFERENCE THE TOOLBAR HAS, BESIDE THE IDENTIFIERS IT IS BUILT FROM.** One key, one window class: the menu
 * row that flips it and every window that obeys it go through the two class doors below, so there is no second place that
 * could disagree about what a person chose. */
static NSString *const AGToolbarLabelsKey = @"AGShowToolbarLabels";

static NSError *AGForgeError(NSString *reason)
{
	return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError
			       userInfo:[NSDictionary dictionaryWithObject:reason
								   forKey:NSLocalizedDescriptionKey]];
}


/* ===================================================================================================
 * THE DETAIL PANE, WHICH IS TWO PANES IN ONE PLACE.
 *
 * The editor and the metadata pane are the same REGION of the window — the middle on the right — and the toolbar's
 * segmented control says which one is in it. The container is what makes that one region: it holds both, places both to
 * its own bounds, and shows exactly one. Doing it here rather than by adding and removing subviews is what keeps each
 * pane's state (an open file, half-typed metadata) alive across a switch.
 * =================================================================================================== */
@interface AGDetailView : NSView
{
@public
	NSView *_editor;
	NSView *_info;
}
@end

@implementation AGDetailView

- (void)fn_placePanes
{
	/* **A HIDDEN PANE IS NOT LAID OUT.** Resizing both children costs a text layout for the editor even when the metadata
	 * pane is the one on screen, and the editor's layout is the expensive half (see `AGPanesView -fn_endDrag`). */
	if (![_editor isHidden]) {
		[_editor setFrame:[self bounds]];
	}
	if (![_info isHidden]) {
		[_info setFrame:[self bounds]];
	}
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[self fn_placePanes];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_placePanes];
}

/* **AND THE DEFERRAL IS THE CONTAINER'S TO PASS ON**, because the panes view holds the container and the container holds
 * the two things that would each re-lay-out. A pane that does not care answers nothing and is skipped. */
/* **NO DRAG DEFERS THIS ANY MORE** — the split view re-places the panes once, on the release — but the door stays: it is
 * what the detail pane uses to hold the editor's re-fit while the switch swaps editor for metadata. */
- (void)setLayoutDeferred:(BOOL)deferred
{
	if ([_editor respondsToSelector:@selector(setLayoutDeferred:)]) {
		[(id)_editor setLayoutDeferred:deferred];
	}
	if ([_info respondsToSelector:@selector(setLayoutDeferred:)]) {
		[(id)_info setLayoutDeferred:deferred];
	}
}

@end

/* ===================================================================================================
 * THE PANES, PLACED BY HAND.
 *
 * **THE SPLIT VIEWS WERE THE PROBLEM, NOT THE SOLUTION.** With an `NSSplitView` owning the three panes, the first
 * real sessions drew a browser collapsed to a sliver, an editor that kept the size it was born at, and a log under
 * a divider nobody could see — three symptoms of the same thing: a split view re-places its subviews on its own
 * schedule, and this tier's `-setFrame:` does not call `-resizeSubviewsWithOldSize:`, so the panes' own children
 * lagged behind. `Workspace` records the same finding and answers it with constraints. This container answers it
 * with arithmetic in the one place that owns the frame: `-setFrame:` and `-setFrameSize:`. Dragging a divider is
 * the thing given up, and it is named in the README as the next slice rather than pretended away.
 * =================================================================================================== */
#define AG_GUTTER 8.0			/* the band between two panes, and the thing a hand grabs */
#define AG_BROWSER_MIN 140.0
#define AG_LOG_MIN 70.0
#define AG_DETAIL_MIN 160.0


/* **THE PANES ARE PLACED BY HAND AND SIZED BY THE HAND, AND THE GUTTER IS THE PART THAT SAYS SO.** `NSSplitView` is what
 * this class exists to avoid: it re-places its subviews on its own schedule, and this tier's `-setFrame:` does not call
 * `-resizeSubviewsWithOldSize:`, so a pane's children lag behind the pane. What a split view got RIGHT is the gutter — a
 * band wide enough to hit, three hollow rings down it, and a resize cursor over it — and that is the part reproduced here,
 * from the same artwork `NSSplitViewDividerStylePaneSplitter` draws.
 *
 * **WHAT IS REMEMBERED IS THE NUMBER, NOT A PROPORTION.** A person who makes the browser 240 points wide means 240 points,
 * whatever size the window is next time. Both numbers live in `NSUserDefaults` — the same store a window's frame autosave
 * uses — read when the view is made and written when a drag ends.
 *
 * **AND A DRAG IS CHEAP BECAUSE IT MOVES THINGS RATHER THAN REDRAWING THEM.** A drag applies at most one move per
 * sixtieth of a second, and the split view re-places the panes once the hand stops: wrapping a file
 * on every motion event is most of what a lagging drag is made of. */
/* ===================================================================================================
 * THE PANES, AS TWO `NSSplitView`s.
 *
 * **THIS CLASS USED TO OWN A DRAG, AND THAT WAS THE BUG.** It placed three subviews by hand, drew its own gutters, and
 * answered `-mouseDown:` — but a custom view that does not pump its own events never hears the RELEASE in a running
 * application, so the divider moved under the hand (0.00 ms per motion, MEASURED) and then threw the movement away:
 * every drag ended with a press, some motions and no `-mouseUp:` at all.
 *
 * `NSSplitView` is the tier's own answer and it already has the shape a hand expects: a tracking loop that owns the
 * motion AND the release, a floating preview while the divider follows the pointer, one real re-placement when the hand
 * stops, autosaved positions under `AgoraSplitView <name>`, and delegate callbacks for the minimum sizes. Its drag applies
 * on the release for the same reason this class's did — re-placing the panes per motion costs a text re-wrap (104 ms
 * MEASURED on the editor) — so the two designs agree about the hard part, and the split view agrees with the platform
 * about the easy ones.
 *
 * TWO SPLIT VIEWS, NESTED: an outer one that stacks the top row above the log, and an inner one that puts the browser
 * beside the detail pane. The log spans the window because its split view does.
 * =================================================================================================== */
@interface AGPanesView : NSView <NSSplitViewDelegate>
{
@public
	NSView *_browser;
	NSView *_editor;
	NSView *_log;
	NSSplitView *_topSplit;		/* RETAINED: browser | detail */
	NSSplitView *_outerSplit;	/* RETAINED: the top row above the log */
}
- (void)setBrowser:(NSView *)browser editor:(NSView *)editor log:(NSView *)log;
- (CGFloat)browserPaneWidth;
- (CGFloat)logPaneHeight;
- (void)fn_placePanes;
@end

@implementation AGPanesView

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_topSplit = [[NSSplitView alloc] initWithFrame:frame];
		[_topSplit setVertical:YES];			/* side by side: the browser's divider is vertical */
		[_topSplit setDividerStyle:NSSplitViewDividerStylePaneSplitter];
		[_topSplit setAutosaveName:@"AGForgePanes"];
		[_topSplit setDelegate:self];

		_outerSplit = [[NSSplitView alloc] initWithFrame:frame];
		[_outerSplit setVertical:NO];			/* stacked: the log's divider is horizontal */
		[_outerSplit setDividerStyle:NSSplitViewDividerStylePaneSplitter];
		[_outerSplit setAutosaveName:@"AGForgeLog"];
		[_outerSplit setDelegate:self];
		[_outerSplit addSubview:_topSplit];

		[self addSubview:_outerSplit];
	}
	return self;
}

- (void)dealloc
{
	[_topSplit release];
	[_outerSplit release];
	[super dealloc];
}

/* **THE THREE PANES ARRIVE AFTER THE SPLIT VIEWS, AND EACH ONE JOINS THE SPLIT THAT OWNS IT.** The order is the split
 * view's own arithmetic — the leading subview is the one whose size a divider drag changes — so the browser leads the top
 * row and the top row leads the outer split. */
- (void)setBrowser:(NSView *)browser editor:(NSView *)editor log:(NSView *)log
{
	_browser = browser;
	_editor = editor;
	_log = log;
	[_topSplit addSubview:browser];
	[_topSplit addSubview:editor];
	[_outerSplit addSubview:log];
	[_topSplit adjustSubviews];
	[_outerSplit adjustSubviews];
}

- (CGFloat)browserPaneWidth
{
	return NSWidth([_browser frame]);
}

- (CGFloat)logPaneHeight
{
	return NSHeight([_log frame]);
}

- (void)fn_placePanes
{
	[_outerSplit setFrame:[self bounds]];
	[_topSplit adjustSubviews];
	[_outerSplit adjustSubviews];
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[_outerSplit setFrame:[self bounds]];
	[_outerSplit adjustSubviews];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[_outerSplit setFrame:[self bounds]];
	[_outerSplit adjustSubviews];
}

/* **THE FLOOR IS NOT A MATTER OF TASTE: a browser narrower than 140 points shows a column of clipped filenames, and a
 * detail pane narrower than 160 shows nothing but the scroll bar.** The ceiling is the other pane's floor, so neither
 * divider can squeeze its neighbour out of existence. */
- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMinCoordinate:(CGFloat)proposedMinimumPosition
       ofSubviewAt:(NSInteger)dividerIndex
{
	(void)dividerIndex;
	/* **A DIVIDER'S POSITION MEASURES THE PANE ABOVE OR BEFORE IT, WHICH IS WHY THE TWO FLOORS ARE NOT THE SAME
	 * NUMBER.** A stacked split reports the height of the TOP row, so its minimum is the editor's floor; the log's own
	 * floor is the maximum's business, on the other side of the divider. Returning the log's floor here made the log
	 * stop at 160 points and look like it could not be closed at all. */
	return (splitView == _topSplit) ? AG_BROWSER_MIN : (AG_DETAIL_MIN + AG_GUTTER);
}

- (CGFloat)splitView:(NSSplitView *)splitView
    constrainMaxCoordinate:(CGFloat)proposedMaximumPosition
       ofSubviewAt:(NSInteger)dividerIndex
{
	(void)dividerIndex;
	/* THE CEILING IS THE OTHER PANE'S FLOOR, so neither divider can squeeze its neighbour out of existence. */
	if (splitView == _topSplit) {
		return NSWidth([splitView bounds]) - AG_DETAIL_MIN - [splitView dividerThickness];
	}
	return NSHeight([splitView bounds]) - AG_LOG_MIN - [splitView dividerThickness];
}

@end



@interface AGProjectWindowController () <NSToolbarDelegate, NSToolbarItemValidation,
					  NSOutlineViewDataSource, NSOutlineViewDelegate, AGBuilderDelegate,
					  AGProjectInfoViewDelegate>
/* THE PRIVATE DOORS, declared together so a method above another one's definition still compiles. */
- (void)fn_buildInterface;
- (void)fn_reloadGroups;
- (void)fn_openFile:(AGProjectFile *)file;
- (void)fn_log:(NSString *)text;
- (void)fn_clearLog;
- (NSString *)fn_windowTitle;
- (NSToolbarItem *)fn_toolbarItem:(NSString *)identifier
			     label:(NSString *)label
			    action:(SEL)action
			 toolTip:(NSString *)toolTip;
@end

/* ===================================================================================================
 * THE LOG PANE, WHICH IS A SCROLL VIEW AND A DOCUMENT THAT TRACKS ITS WIDTH.
 *
 * **THE WIDTH IS THE WRAP'S BUSINESS, NOT THE LAYOUT'S.** The log's text view is kept as wide as its clip view because a
 * wrapping document has to be told how wide the pane is; it starts at the width it is born with, which is the width of the
 * empty frame, and a paragraph laid out to that width would wrap early forever.
 *
 * The HEIGHT is left to the text view, and a log shorter than its pane now sits at the TOP of it — it used to be pushed to
 * the middle by a clip view that centred any document smaller than itself (see `libagora-app/NSClipView.m`
 * `-constrainScrollPoint:`), and this pane worked around that by inventing a document as tall as the clip. That workaround
 * is gone with the rule: a log begins at its first line.
 * =================================================================================================== */
@interface AGLogPane : NSView
{
@public
	NSScrollView *_scrollView;
	NSTextView *_textView;
}
@end

@implementation AGLogPane

- (void)fn_placePanes
{
	NSRect bounds = [self bounds];
	NSSize document = NSMakeSize(bounds.size.width, [_textView frame].size.height);

	[_scrollView setFrame:bounds];
	[_textView setFrameSize:document];
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[self fn_placePanes];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_placePanes];
}

@end

@implementation AGProjectWindowController

- (instancetype)initWithProject:(AGProject *)project
{
	NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40.0, 24.0, 840.0, 560.0)
						       styleMask:(NSTitledWindowMask | NSClosableWindowMask |
								  NSMiniaturizableWindowMask | NSResizableWindowMask)
							 backing:NSBackingStoreBuffered
							   defer:NO];
	self = [super initWithWindow:window];
	[window release];
	if (self != nil) {
		_project = [project retain];
		_groups = [[NSMutableArray alloc] init];
		_builder = [[AGBuilder alloc] initWithProject:project];
		[_builder setDelegate:self];
		[self fn_buildInterface];
		/* **THE CONTENT SIZE IS ASKED FOR, NOT INHERITED FROM THE FRAME.** The window's content view reports a
		 * 0x0 bounds until the window is shown, and the first real session laid every pane out from that — MEASURED
		 * by FORGE_LAYOUT_DIAG: `content 0x0` with a browser, an editor and a log sized from zero. */
		[window setTitle:[self fn_windowTitle]];
		[window setFrameAutosaveName:@"AGProjectWindow"];
		[window center];
	}
	return self;
}

- (void)dealloc
{
	[_infoView release];
	[_logPane release];
	[_detail release];
	[_detailSwitch release];
	[_builder release];
	[_groups release];
	[_outline release];
	[_editor release];
	[_logView release];
	[_project release];
	[super dealloc];
}

- (AGProject *)project
{
	return _project;
}

- (AGSourceEditor *)editor
{
	return _editor;
}

- (NSView *)panesView
{
	return [[self window] contentView];
}

- (NSArray *)paneViewFrames
{
	AGPanesView *panes = (AGPanesView *)[[self window] contentView];

	/* **IN THE CONTAINER'S SPACE, BECAUSE THE PANES NOW LIVE IN TWO DIFFERENT SPLIT VIEWS.** Their own frames are
	 * relative to their parent, so comparing a detail pane's x with a log pane's y across parents measured a
	 * coincidence of layout order rather than a gutter. */
	return [NSArray arrayWithObjects:
		[NSValue valueWithRect:[panes->_browser convertRect:[panes->_browser bounds] toView:panes]],
		[NSValue valueWithRect:[panes->_editor convertRect:[panes->_editor bounds] toView:panes]],
		[NSValue valueWithRect:[panes->_log convertRect:[panes->_log bounds] toView:panes]], nil];
}

- (CGFloat)browserPaneWidth
{
	return [(AGPanesView *)[[self window] contentView] browserPaneWidth];
}

- (CGFloat)logPaneHeight
{
	return [(AGPanesView *)[[self window] contentView] logPaneHeight];
}

- (NSSegmentedControl *)detailSwitch
{
	return _detailSwitch;
}

- (AGProjectInfoView *)infoView
{
	return _infoView;
}

- (AGBuilder *)builder
{
	return _builder;
}

- (NSString *)fn_windowTitle
{
	/* **THE SEPARATOR IS AN EM DASH, AND IT DRAWS.** It used to be read as a raster defect — a title built as
	 * `@"%@ — %@"` arrived as `Hello â( …` — but the fault was `libagora-base`'s format scanner emitting one byte per
	 * literal chunk, which split the three-byte character before any glyph was looked up. That is fixed
	 * (`tests/constant_string_units.m`), so this is the typography the title should always have had. */
	return [NSString stringWithFormat:@"%@ — %@", [_project name], [_project typeName]];
}

/* ---------------------------------------------------------------------------------------------------
 * The interface.
 * --------------------------------------------------------------------------------------------------- */

- (NSToolbarItem *)fn_toolbarItem:(NSString *)identifier
			     label:(NSString *)label
			    action:(SEL)action
			 toolTip:(NSString *)toolTip
{
	NSToolbarItem *item = [[[NSToolbarItem alloc] initWithItemIdentifier:identifier] autorelease];

	[item setLabel:label];
	[item setPaletteLabel:label];
	[item setToolTip:toolTip];
	[item setTarget:self];
	[item setAction:action];
	return item;
}

- (void)fn_buildInterface
{
	NSWindow *window = [self window];
	/* THE CONTENT RECT, ASKED OF THE WINDOW — `[[window contentView] bounds]` is 0x0 before the window is shown. */
	NSRect content = [window contentRectForFrameRect:[window frame]];
	NSSplitView *outer, *inner;
	NSOutlineView *outline;
	NSTableColumn *column;
	NSScrollView *browserScroll, *editorScroll, *logScroll;
	NSToolbar *toolbar;
	CGFloat halfWidth = content.size.width * 0.32;
	CGFloat logHeight = 170.0;
	CGFloat editorHeight = content.size.height - logHeight - 8.0;

	/* THE BROWSER: the scroll view first, the outline inside its clip's bounds — Workspace's sidebar recipe. */
	browserScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, halfWidth, content.size.height)];
	[browserScroll setHasVerticalScroller:YES];
	[browserScroll setAutohidesScrollers:YES];
	[browserScroll setBorderType:NSNoBorder];
	[browserScroll setDrawsBackground:YES];

	outline = [[NSOutlineView alloc] initWithFrame:[[browserScroll contentView] bounds]];
	column = [[NSTableColumn alloc] initWithIdentifier:@"Files"];
	[column setWidth:halfWidth];
	[outline addTableColumn:column];
	[outline setOutlineTableColumn:column];
	[column release];
	[outline setHeaderView:nil];
	[outline setDataSource:self];
	[outline setDelegate:self];
	[outline setRowHeight:18.0];
	[outline setIndentationPerLevel:12.0];
	[outline setAllowsEmptySelection:YES];
	[outline setAllowsMultipleSelection:NO];
	[browserScroll setDocumentView:outline];
	_outline = [outline retain];
	[outline release];

	/* THE EDITOR, and the log under it. */
	_editor = [[AGSourceEditor alloc] initWithFrame:NSMakeRect(0.0, 0.0, content.size.width - halfWidth,
								   content.size.height - logHeight)];
	/* **AND THE METADATA PANE IN THE SAME REGION.** Both are the size of the detail container; the switch chooses
	 * which is visible, and neither is thrown away when the other is shown. */
	_infoView = [[AGProjectInfoView alloc] initWithFrame:NSMakeRect(0.0, 0.0, content.size.width - halfWidth,
								       content.size.height - logHeight)
						     project:_project];
	[_infoView setDelegate:self];
	[_infoView setHidden:YES];
	_detail = [[AGDetailView alloc] initWithFrame:NSMakeRect(0.0, 0.0, content.size.width - halfWidth,
								content.size.height - logHeight)];
	((AGDetailView *)_detail)->_editor = _editor;
	((AGDetailView *)_detail)->_info = _infoView;
	[_detail addSubview:_editor];
	[_detail addSubview:_infoView];

	/* **THE SWITCH THAT CHOOSES BETWEEN THEM IS A TOOLBAR ITEM WITH A VIEW.** A segmented control is the control a
	 * mode switch is, and a toolbar item that CARRIES a view is how one lives in the band. */
	_detailSwitch = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(0.0, 0.0, 96.0, 24.0)];
	[_detailSwitch setSegmentCount:2];
	/* **TWO PICTURES AND NO WORDS.** Each segment wears the icon of what it shows — Tabler's `code-dots` for the editor
	 * and `info-circle` for the metadata pane — and the band they live in is a row of pictures, so a word beside each
	 * would read as the label of a text control rather than as a mode switch. The names survive where a name belongs:
	 * the toolbar item's own label and tool tip say what the pair is, and the two segments are the two panes of the
	 * window. They are the same 24-point tiles the verbs use, drawn into the segment's sixteen-point box, and the frame
	 * is the control's OWN measurement rather than a guessed width: picture-only segments are what `-sizeToFit` fits. */
	[_detailSwitch setImage:AGToolbarIcon(AGToolbarIconCode) forSegment:0];
	[_detailSwitch setImage:AGToolbarIcon(AGToolbarIconInfo) forSegment:1];
	[_detailSwitch sizeToFit];
	[_detailSwitch setSelectedSegment:0];
	[_detailSwitch setTarget:self];
	[_detailSwitch setAction:@selector(detailSegmentChanged:)];

	logScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0.0, 0.0, content.size.width - halfWidth,
							  logHeight)];
	[logScroll setHasVerticalScroller:YES];
	[logScroll setAutohidesScrollers:YES];
	[logScroll setBorderType:NSNoBorder];
	[logScroll setDrawsBackground:YES];
	{
		NSTextView *log = [[NSTextView alloc] initWithFrame:[[logScroll contentView] bounds] textContainer:nil];
		NSFont *font = [NSFont userFixedPitchFontOfSize:11.0];

		[log setEditable:NO];
		[log setRichText:NO];
		if (font != nil) {
			[log setFont:font];
		}
		[log setVerticallyResizable:YES];
		[log setHorizontallyResizable:NO];
		[[log textContainer] setWidthTracksTextView:YES];
		/* **THE LOG VIEW IS RETAINED HERE, BECAUSE `-dealloc` RELEASES IT.** It was a borrowed pointer to the scroll
		 * view's document view, and the release in `-dealloc` took a reference this class never held — MEASURED as a
		 * segfault in `NSClipView -dealloc` at the end of a bounded run, which is the same teardown a person's Quit
		 * performs. */
		_logView = [log retain];
		[logScroll setDocumentView:log];
		[log release];
	}
	{
		AGLogPane *logPane = [[AGLogPane alloc] initWithFrame:NSMakeRect(0.0, 0.0, content.size.width, logHeight)];

		logPane->_scrollView = logScroll;
		logPane->_textView = _logView;
		[logPane addSubview:logScroll];
		[logScroll release];
		_logPane = logPane;
	}

	/* THE CONTAINER, which is what the window's content view becomes. */
	{
		AGPanesView *panes = [[AGPanesView alloc] initWithFrame:content];

		[panes setBrowser:browserScroll editor:_detail log:_logPane];
		[browserScroll release];
		[panes setFrame:content];
		[window setContentView:panes];
		[panes release];
	}

	toolbar = [[NSToolbar alloc] initWithIdentifier:AGToolbarIdentifier];
	[toolbar setDelegate:self];
	/* **AND THE MODE IS THE PREFERENCE, READ WHEN THE WINDOW IS MADE**, so a second window is right the first time and a
	 * relaunch does not flicker through the wrong one. */
	[toolbar setDisplayMode:[AGProjectWindowController fn_toolbarLabelsVisible]
		? NSToolbarDisplayModeIconAndLabel : NSToolbarDisplayModeIconOnly];
	[toolbar setAllowsUserCustomization:NO];
	[window setToolbar:toolbar];
	[toolbar release];

	[self fn_reloadGroups];
	[self refreshToolbarState];
	/* **AND THE PANE STATE IS ESTABLISHED ONCE THE TREE IS IN THE WINDOW.** `-setHidden:` on a view that has no window
	 * yet does not survive being added to one (MEASURED: the session opened with the metadata pane on top of the
	 * editor), so the switch is asked for its answer after the panes are where they live. */
	[self detailSegmentChanged:_detailSwitch];
}

/* **WHAT THE TOOLBAR SAYS IS POSSIBLE, IN ONE PLACE.** A button that cannot do anything is greyed rather than clicked and
 * refused in the log: Run needs a product and nothing else running, Clean needs something to clean, Stop needs something
 * to stop, and Build needs the window not to be busy with either. The item's target is this controller, so the toolbar's
 * own validation pass asks here — `NSToolbarItemValidation`, which `-validateVisibleItems` reaches through `-validate`. */
- (BOOL)validateToolbarItem:(NSToolbarItem *)item
{
	NSString *identifier = [item itemIdentifier];
	BOOL building = [_builder isBuilding];
	BOOL running = [_builder isRunningProduct];

	if ([identifier isEqualToString:AGToolbarBuild]) {
		return !building && !running;
	}
	if ([identifier isEqualToString:AGToolbarClean]) {
		return !building && !running && ![_builder isClean];
	}
	if ([identifier isEqualToString:AGToolbarRun]) {
		return !building && !running && [_builder hasProduct];
	}
	if ([identifier isEqualToString:AGToolbarStop]) {
		return running;
	}
	if ([identifier isEqualToString:AGToolbarExport]) {
		/* **A PRODUCT THAT EXISTS AND NO BUILD IN FLIGHT**, which are the two questions `-exportApp:` asks: a greyed
		 * button and a logged refusal can never disagree about whether there is something to export. */
		return !building && [_builder hasProduct];
	}
	if ([identifier isEqualToString:AGToolbarRemoveFile]) {
		/* **A FILE, NOT A GROUP, AND NO BUILD IN FLIGHT.** Removing a file while a build walks the manifest would be two
		 * edits to one list; the button greys until the build ends, exactly as the others do. */
		return !building && ([self fn_selectedFile] != nil);
	}
	return YES;		/* the detail switch and Add a file are always usable */
}

/* AND EVERYTHING THAT CHANGES AN ANSWER ASKS FOR THE PASS AGAIN: the verbs, and each stage the builder finishes — which
 * is where a build becomes runnable and where a product stops running. */
- (void)refreshToolbarState
{
	[[[self window] toolbar] validateVisibleItems];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	/* **THE PROJECT ITSELF COMES FIRST, THEN FOUR GROUPS OF VERBS — each a pair, and one rule.** New and Open are what
	 * a person reaches for before any of the others can mean anything: they make a project or bring one in, and they are
	 * the APPLICATION'S verbs, not this window's. After them: Build and Clean are the BUILD — one makes it, one takes it
	 * away; Run and Stop are the PRODUCT; Add and Remove are the PROJECT'S FILE LIST, which is what the browser beside
	 * them shows; and Export stands alone because it is the only row that acts on the result rather than changing the
	 * project. The separators are the toolbar's own standard identifiers, and the flexible space pushes the Code/Info
	 * switch to the right edge, where a mode switch belongs. */
	return [NSArray arrayWithObjects:
		AGToolbarNewProject, AGToolbarOpenProject,
		NSToolbarSeparatorItemIdentifier,
		AGToolbarBuild, AGToolbarClean,
		NSToolbarSeparatorItemIdentifier,
		AGToolbarRun, AGToolbarStop,
		NSToolbarSeparatorItemIdentifier,
		AGToolbarAddFiles, AGToolbarRemoveFile,
		NSToolbarSeparatorItemIdentifier,
		AGToolbarExport,
		NSToolbarFlexibleSpaceItemIdentifier,
		AGToolbarDetail, nil];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar
{
	(void)toolbar;
	return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSString *)identifier
 willBeInsertedIntoToolbar:(BOOL)flag
{
	(void)toolbar;
	(void)flag;
	if ([identifier isEqualToString:AGToolbarNewProject] || [identifier isEqualToString:AGToolbarOpenProject]) {
		BOOL making = [identifier isEqualToString:AGToolbarNewProject];
		NSToolbarItem *item = [self fn_toolbarItem:identifier
						     label:(making ? @"New Project" : @"Open Project")
						    action:(making ? @selector(newProject:) : @selector(openProject:))
						   toolTip:(making ? @"Start a new project" : @"Open a project")];

		/* **THE TARGET IS THE APPLICATION, BECAUSE THE VERB IS ITS.** A project window edits the project it was given;
		 * making one or opening one is the application's, which is where the File menu's rows point too, so the band and
		 * the menu cannot drift apart and neither gets a second copy of the verb. Naming it is this application's own
		 * choice — every row Forge builds names its target — and not a workaround: AppKit's responder walk ends at the
		 * APPLICATION DELEGATE, so a nil-target item would find the same object. */
		[item setTarget:[[NSApplication sharedApplication] delegate]];
		/* **AND THE PICTURES ARE THE SYSTEM'S SYMBOLS**, asked for by name: a page with a plus, and an open folder. A
		 * machine whose prefix carries no icon theme gets these two rows as LABELS, which is what the band does with any
		 * item that has no picture — usable, rather than a blank cell. */
		[item setImage:[NSImage imageNamed:(making ? @"file-plus" : @"folder-open")]];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarBuild]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Build" action:@selector(build:)
						   toolTip:@"Configure and build the project"];

		[item setImage:AGToolbarIcon(AGToolbarIconBuild)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarClean]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Clean" action:@selector(clean:)
						   toolTip:@"Remove the build directory"];

		[item setImage:AGToolbarIcon(AGToolbarIconClean)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarRun]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Run" action:@selector(run:)
						   toolTip:@"Run the built product"];

		[item setImage:AGToolbarIcon(AGToolbarIconRun)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarStop]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Stop" action:@selector(stop:)
						   toolTip:@"Stop the running product (or a build)"];

		[item setImage:AGToolbarIcon(AGToolbarIconStop)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarExport]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Export" action:@selector(exportApp:)
						   toolTip:@"Copy the built application to a place you choose"];

		[item setImage:AGToolbarIcon(AGToolbarIconExport)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarRemoveFile]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Remove" action:@selector(removeSelectedFile:)
						   toolTip:@"Remove the selected file from the project (it stays on disk)"];

		[item setImage:AGToolbarIcon(AGToolbarIconRemoveFile)];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarDetail]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"View" action:NULL toolTip:@"Code or Info"];

		[item setView:_detailSwitch];
		return item;
	}
	if ([identifier isEqualToString:AGToolbarAddFiles]) {
		NSToolbarItem *item = [self fn_toolbarItem:identifier label:@"Add" action:@selector(addFiles:)
						   toolTip:@"Add a file to the project"];

		[item setImage:AGToolbarIcon(AGToolbarIconAdd)];
		return item;
	}
	return nil;
}

- (void)fn_applyPaneLayout
{
	/* The container owns the arithmetic now; asking it again after the window has appeared is what makes the first
	 * layout the right one. */
	[(AGPanesView *)[[self window] contentView] fn_placePanes];
	[_outline reloadData];
}

- (void)showWindow:(id)sender
{
	[super showWindow:sender];
	[self fn_applyPaneLayout];
}

/* ---------------------------------------------------------------------------------------------------
 * The browser.
 * --------------------------------------------------------------------------------------------------- */

- (void)fn_reloadGroups
{
	NSArray *categories = [_project categories];
	NSUInteger i;

	[_groups removeAllObjects];
	for (i = 0; i < [categories count]; i++) {
		NSString *category = [categories objectAtIndex:i];
		NSMutableDictionary *group = [NSMutableDictionary dictionary];

		[group setObject:category forKey:@"title"];
		[group setObject:[_project filesInCategory:category] forKey:@"files"];
		[_groups addObject:group];
	}
	[_outline reloadData];

	for (i = 0; i < [_groups count]; i++) {
		[_outline expandItem:[_groups objectAtIndex:i]];
	}
	/* **THE FIRST FILE IS OPENED ONCE, SO THE WINDOW ARRIVES WITH SOMETHING IN IT.** A project window whose editor
	 * is a white rectangle is a window a person has to guess at. It happens once, so a later selection is never
	 * overridden. */
	if (!_openedFirstFile) {
		NSArray *sources = [_project filesInCategory:AGProjectCategorySources];
		NSArray *any = ([sources count] > 0) ? sources : [_project files];

		_openedFirstFile = YES;
		if ([any count] > 0) {
			[self fn_openFile:[any objectAtIndex:0]];
		}
	}
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item
{
	(void)outlineView;
	if (item == nil) {
		return (NSInteger)[_groups count];
	}
	if ([item isKindOfClass:[NSDictionary class]]) {
		return (NSInteger)[[item objectForKey:@"files"] count];
	}
	return 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item
{
	(void)outlineView;
	if (item == nil) {
		return [_groups objectAtIndex:(NSUInteger)index];
	}
	return [[item objectForKey:@"files"] objectAtIndex:(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item
{
	(void)outlineView;
	return [item isKindOfClass:[NSDictionary class]];
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item
{
	(void)outlineView;
	(void)tableColumn;
	if ([item isKindOfClass:[NSDictionary class]]) {
		return [item objectForKey:@"title"];
	}
	if ([item isKindOfClass:[AGProjectFile class]]) {
		return [item displayName];
	}
	return nil;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification
{
	NSOutlineView *outline = [notification object];
	id item = [outline itemAtRow:[outline selectedRow]];

	/* THE SELECTION DECIDES WHETHER REMOVE IS OFFERED, so every change re-asks. */
	[self refreshToolbarState];
	if (![item isKindOfClass:[AGProjectFile class]]) {
		return;
	}
	[self fn_openFile:item];
}

- (void)fn_openFile:(AGProjectFile *)file
{
	NSString *path = [_project absolutePathForFile:file];
	NSString *source = [NSString stringWithContentsOfFile:path
						     encoding:NSUTF8StringEncoding
							error:NULL];

	if (source == nil) {
		source = [NSString stringWithContentsOfFile:path
					           encoding:NSISOLatin1StringEncoding
						      error:NULL];
	}
	if (source == nil) {
		[self fn_log:[NSString stringWithFormat:@"error: %@ could not be read\n", path]];
		return;
	}
	if (getenv("FORGE_LAYOUT_DIAG") != NULL) {
		fprintf(stderr, "forge: opened %s (%lu bytes)\n", [path UTF8String], (unsigned long)[source length]);
	}
	[_editor setSource:source];
	[_editor setFilePath:path];
	/* **THE TYPOGRAPHIC SEPARATOR IS BACK, BECAUSE THE BUG WAS NEVER THE RASTER'S.** A format string's literal chunk used
	 * to be handed to the sink ONE BYTE at a time, so `—` (E2 80 94) arrived as three units and drew as `â` and two
	 * boxes. `libagora-base/NSString.m`'s format scanner emits whole UTF-8 sequences now, and this title is the case that
	 * found it: `Hello — main.m — application`. */
	[[self window] setTitle:[NSString stringWithFormat:@"%@ — %@ — %@",
		[_project name], [file displayName], [_project typeName]]];
	[[self window] makeFirstResponder:[_editor textView]];
}

/* ---------------------------------------------------------------------------------------------------
 * The log and the builder's delegate.
 * --------------------------------------------------------------------------------------------------- */

- (void)fn_log:(NSString *)text
{
	NSTextView *log = _logView;
	NSTextStorage *storage;

	if (log == nil || text == nil) {
		return;
	}
	storage = [log textStorage];
	[storage replaceCharactersInRange:NSMakeRange([[log string] length], 0) withString:text];
	/* **A CALLER THAT POKES THE STORAGE HAS TO ASK FOR THE HEIGHT.** The view re-heights itself when IT takes an
	 * edit (`-didChangeText` calls the fit); a `-replaceCharactersInRange:withString:` on its storage is the caller's
	 * edit, so nothing has asked yet — and without this line the log's document stayed the height it was born with,
	 * which cut off the last row and left it unreachable by scrolling. */
	[log sizeToFit];
	[log scrollRangeToVisible:NSMakeRange([[log string] length], 0)];
}

/* **THE FILE LOG IS THE RECORD A PERSON READS AFTERWARDS**, and the builder writes there through its own door. A verb
 * that leaves a trace — an export, a save — mirrors its line into the same file, so the log is one story rather than two
 * (the view shows everything; the file shows what a build and its verbs did). */
- (void)fn_mirrorToLogFile:(NSString *)text
{
	const char *path = getenv("FORGE_LOG_PATH");
	FILE *file;

	if (path == NULL || path[0] == '\0' || text == nil) {
		return;
	}
	file = fopen(path, "a");
	if (file == NULL) {
		return;
	}
	fputs([text UTF8String], file);
	fclose(file);
}

- (void)fn_clearLog
{
	[_logView setString:@""];
}

- (void)builder:(id)builder didAppendOutput:(NSString *)text
{
	(void)builder;
	[self fn_log:text];
}

- (void)builder:(id)builder didFinishStage:(NSString *)stage status:(int)status
{
	(void)builder;
	/* **EVERY FINISHED STAGE ASKS FOR THE PASS, WHICHEVER BRANCH IT TAKES.** The diagnostics branch returns early (it is
	 * the last stage of a build and the one that reports the bundle), and the refresh used to sit after that return — so
	 * a COMPLETED build never told the toolbar anything, and the band kept the during-build picture: every verb grey in a
	 * project that had just built. MEASURED in the running window, and it is why this is the first line of the method. */
	[self refreshToolbarState];
	if ([stage isEqualToString:@"diagnostics"]) {
		NSArray *diagnostics = [_builder diagnostics];
		NSUInteger errors = 0, warnings = 0, i;

		for (i = 0; i < [diagnostics count]; i++) {
			AGDiagnostic *diagnostic = [diagnostics objectAtIndex:i];

			if ([diagnostic isError]) {
				errors++;
			} else {
				warnings++;
			}
		}
		[_builder note:[NSString stringWithFormat:@"# %ld error(s), %ld warning(s)\n",
			(long)errors, (long)warnings]];
		/* **WHERE THE THING IT MADE IS, SAID OUT LOUD, BUT ONLY IF THIS BUILD MADE ONE.** A bundle is the product of an
		 * application project, and a build that does not tell a person where it put one leaves them to guess at
		 * `build/<name>.app`. THE BUILD'S OWN STATUS IS THE TEST, not the directory and not `-hasProduct`: the bundle's
		 * `Info.plist` is written from the manifest BEFORE the toolchain runs (so a failed configure leaves
		 * `<name>.app/Contents` with no executable in it), and `-hasProduct` answers YES for a binary the PREVIOUS build
		 * left behind — MEASURED: a configure error over a stale product still logged `# Bundle:`. */
		if (status == 0 && ([_project type] == AGProjectTypeApplication ||
				    [_project type] == AGProjectTypeBundle)) {
			[_builder note:[NSString stringWithFormat:@"# Bundle: %@\n", [[_project bundleURL] path]]];
		}
		return;
	}
	[_builder note:[NSString stringWithFormat:@"# %@ exited %d\n", stage, status]];
}

/* ---------------------------------------------------------------------------------------------------
 * The verbs.
 * --------------------------------------------------------------------------------------------------- */

- (NSString *)buildLogText
{
	return ([_logView string] != nil) ? [_logView string] : @"";
}

/* THE VIEW ITSELF, FOR THE PROBE THAT MEASURES WHERE THE LAST ROW LANDS. A test door, named as one: the text is
 * enough to read a message, and not enough to check that the message is on the screen. */
- (NSTextView *)buildLogTextView
{
	return _logView;
}

/* **A VERB THAT CANNOT RUN SAYS SO, IN THE LOG, INSTEAD OF CLEARING IT AND DOING NOTHING.** The first version of
 * these three cleared the log, called the builder, and ignored the answer — so a Build pressed while a build was
 * still running wiped the log and produced no output at all, which reads exactly like "the build failed". That is
 * the shape of the report this fix came from, and the reason each verb now answers before it acts. */
- (void)build:(id)sender
{
	[self refreshToolbarState];
	(void)sender;
	if ([_builder isBuilding]) {
		[_builder note:@"# A build is already running; this Build was ignored.\n"];
		return;
	}
	if ([_builder isRunningProduct]) {
		[_builder note:@"# The built product is still running; Build was ignored. (Use Project > Stop.)\n"];
		return;
	}
	[self fn_clearLog];
	[self fn_log:[NSString stringWithFormat:@"# Building %@\n", [_project name]]];
	if (![_builder build]) {
		[_builder note:@"error: the build could not be started\n"];
	}
	[self refreshToolbarState];
}

- (void)clean:(id)sender
{
	[self refreshToolbarState];
	(void)sender;
	if ([_builder isBuilding]) {
		/* **DELETING THE BUILD DIRECTORY UNDER A RUNNING COMPILER IS HOW A BUILD FAILS FOR A REASON NOBODY ASKED
		 * FOR.** Clean is the one verb whose effect is on the other verb's inputs, so it waits its turn. */
		[_builder note:@"# A build is running; Clean was ignored.\n"];
		return;
	}
	if ([_builder isRunningProduct]) {
		[_builder note:@"# The built product is still running; Clean was ignored. (Use Project > Stop.)\n"];
		return;
	}
	[self fn_clearLog];
	if (![_builder clean]) {
		[_builder note:@"error: the build directory could not be removed\n"];
	}
	[self refreshToolbarState];
}

- (void)run:(id)sender
{
	[self refreshToolbarState];
	(void)sender;
	if ([_builder isBuilding]) {
		[_builder note:@"# A build is running; Run was ignored.\n"];
		return;
	}
	if ([_builder isRunningProduct]) {
		[_builder note:@"# The product is already running. (Use Project > Stop.)\n"];
		return;
	}
	[_builder run];
	[self refreshToolbarState];
}

/* **THE DOOR OUT OF A RUNNING PRODUCT.** Run starts a program that has its own window and outlives the click; if
 * that window is behind this one, or the program ignores its own close button, Stop is the only way back to a
 * window whose Build and Clean still work. It stops a build too, for the same reason. */
- (void)stop:(id)sender
{
	[self refreshToolbarState];
	(void)sender;
	if (![_builder isBuilding] && ![_builder isRunningProduct]) {
		[_builder note:@"# Nothing is running.\n"];
		return;
	}
	[_builder stop];
	[self refreshToolbarState];
}

- (void)saveDocument:(id)sender
{
	(void)sender;
	{
		NSString *path = [_editor filePath];

		if (path == nil) {
			[self fn_log:@"# There is no file open to save.\n"];
			return;
		}
		if (![[_editor source] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
			[self fn_log:[NSString stringWithFormat:@"error: %@ could not be written\n", path]];
		}
	}
}

- (void)toggleBuildLog:(id)sender
{
	(void)sender;
	[_logView setHidden:![_logView isHidden]];
}

/* **THE LABELS, REMEMBERED AND APPLIED, IN ONE PLACE.** `NSToolbar`'s display mode is the tier's own vocabulary for this:
 * `NSToolbarDisplayModeIconAndLabel` is a verb with its word under it, and `NSToolbarDisplayModeIconOnly` is the word
 * gone. The default is ON — a window whose person has never chosen keeps what this application has always drawn — and it
 * is written the moment it is changed, so a relaunch shows what the last press asked for. */
+ (BOOL)fn_toolbarLabelsVisible
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

	if ([defaults objectForKey:AGToolbarLabelsKey] == nil) {
		return YES;
	}
	return [defaults boolForKey:AGToolbarLabelsKey];
}

+ (void)fn_setToolbarLabelsVisible:(BOOL)visible
{
	[[NSUserDefaults standardUserDefaults] setBool:visible forKey:AGToolbarLabelsKey];
}

- (void)fn_applyToolbarLabels
{
	[[[self window] toolbar] setDisplayMode:[AGProjectWindowController fn_toolbarLabelsVisible]
		? NSToolbarDisplayModeIconAndLabel : NSToolbarDisplayModeIconOnly];
}

+ (void)fn_showToolbarLabelsStateOn:(NSMenuItem *)item
{
	if (item != nil) {
		[item setState:[self fn_toolbarLabelsVisible] ? NSOnState : NSOffState];
	}
}


/* **THE METADATA HAS A WINDOW OF ITS OWN NOW.** It was an alert — a modal loop inside a menu pick, whose lifetime was
 * the caller's stack frame and whose dismissal was the toolkit's problem. `AGProjectInfoWindowController` is a panel
 * that opens, stays, and writes the manifest when the person says Apply; this controller owns it (one per project
 * window) and is its delegate, which is where the browser and the title are refreshed from. */
/* **THE METADATA IS A PANE OF THIS WINDOW, AND THIS IS WHAT SHOWS IT.** One region holds the editor and the info pane;
 * the switch says which, and the menu row is the same switch by another route. */
- (void)showProjectInfo:(id)sender
{
	(void)sender;
	if (_detailSwitch == nil) {
		return;
	}
	[_detailSwitch setSelectedSegment:1];
	[self detailSegmentChanged:_detailSwitch];
}

/* THE SWITCH. The chosen pane is shown and the other is hidden — never removed — so an open file and a half-typed
 * identifier both survive a look at the other one. */
- (void)detailSegmentChanged:(id)sender
{
	NSInteger segment = (sender != nil) ? [(NSSegmentedControl *)sender selectedSegment] : 0;

	(void)sender;
	[_editor setHidden:(segment != 0)];
	[_infoView setHidden:(segment == 0)];
	/* **THE PANE THAT JUST CAME UP HAS NEVER BEEN LAID OUT.** Both children are created with a frame computed from the
	 * content size at build time, and `AGDetailView -fn_placePanes` only places the visible one — so the metadata pane kept
	 * its born 571x390 inside a 852x426 pane, sitting 36 points low and 281 points narrow (MEASURED with
	 * `FORGE_LAYOUT_DIAG`). The swap is what makes a pane visible, so the swap is what places it. */
	[(AGDetailView *)_detail fn_placePanes];
	if (segment == 0) {
		[[self window] makeFirstResponder:[_editor textView]];
	} else {
		[_infoView reloadFields];
	}
	[_detail setNeedsDisplay:YES];
}

/* The menu row still exists for the icon alone, because choosing a picture is the one thing a person may want without
 * the rest of the panel — and it is the SAME panel's work, so it goes through it rather than through a second copy. */
- (void)chooseIcon:(id)sender
{
	[self showProjectInfo:sender];
	[_infoView chooseIcon:sender];
}

- (void)projectInfoDidApply:(id)sender
{
	(void)sender;
	[self fn_reloadGroups];
	[[self window] setTitle:[self fn_windowTitle]];
}

- (void)projectInfoDidLog:(NSString *)line
{
	[_builder note:line];
}

- (void)projectInfoDidAddFile:(NSString *)relativePath
{
	(void)relativePath;
	[self fn_reloadGroups];
}

/* ===================================================================================================
 * NEW FILE, WHICH IS THE HALF THE ADD PANEL COULD NOT DO.
 *
 * The open panel chooses a file that already exists, so a project with three files could gain no fourth: "Add" opened a
 * list of what was there and nothing else. This writes the file first — an empty body, or the two-line skeleton a C
 * source or header starts from — puts it in the manifest, and opens it, which is the whole of what a person means by
 * "add a file" when the file does not exist yet.
 *
 * THE NAME IS THE SAVE PANEL'S, because a save panel IS a name and a place: it validates the name, appends the type the
 * project asks for, and refuses to step outside the project's directory.
 * =================================================================================================== */
- (void)newFile:(id)sender
{
	NSSavePanel *panel = [NSSavePanel savePanel];
	NSError *error = nil;

	(void)sender;
	/* **THE PANEL STARTS IN THE PROJECT, BECAUSE THE PROJECT IS ALL IT MAY WRITE IN.** It used to start one directory
	 * up — the export panel's rule, copied — and `-fn_createFileAtPath:` then refused the name the panel offered, so
	 * the default press of New File did nothing but log a refusal. */
	[panel setDirectory:[[_project projectDirectoryURL] path]];
	[panel setNameFieldStringValue:@"Untitled.m"];
	[panel setMessage:@"Name the file to create in this project."];
	if ([panel runModal] != NSOKButton) {
		return;
	}
	if (![self fn_createFileAtPath:[[panel URL] path] error:&error]) {
		[self fn_log:[NSString stringWithFormat:@"error: %@\n",
			(error != nil) ? [error localizedDescription] : @"the file could not be created"]];
	}
}

/* THE DOOR WITHOUT THE PANEL, so a probe can create a file without a window server: the panel's only job is to produce a
 * path, and everything after that is this. */
- (BOOL)fn_createFileAtPath:(NSString *)path error:(NSError **)error
{
	NSString *name = [path lastPathComponent];
	NSString *contents = [self fn_templateForFileName:name];
	NSString *base = [[[_project projectDirectoryURL] path] stringByStandardizingPath];
	NSString *standard = [path stringByStandardizingPath];
	NSString *prefix = [base stringByAppendingString:@"/"];

	/* **THE CONTAINMENT IS ASKED BEFORE ANYTHING IS WRITTEN.** Adding to the manifest refuses a path outside the project,
	 * but that happened AFTER the file had been created: a refused name left a stray file behind. A project directory is
	 * the only place this program writes, so the refusal comes first and nothing is touched. */
	if (![standard hasPrefix:prefix]) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:
				[NSDictionary dictionaryWithObject:
					[NSString stringWithFormat:@"%@ is outside the project directory.", path]
				forKey:NSLocalizedDescriptionKey]];
		}
		return NO;
	}
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		if (![contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
			return NO;
		}
	}
	if (![_project addFileAtAbsolutePath:path error:error]) {
		return NO;
	}
	if (![_project writeToURL:[_project projectDirectoryURL] error:NULL]) {
		[self fn_log:@"error: the manifest could not be written\n"];
	}
	[self fn_reloadGroups];
	/* THE MANIFEST STORES PATHS RELATIVE TO THE PROJECT, so the editor is opened with the same spelling. */
	[self fn_openFile:[AGProjectFile fileWithRelativePath:[standard substringFromIndex:[prefix length]]]];
	return YES;
}

/* **THE SKELETON IS THE FILE'S OWN BUSINESS, AND AN UNKNOWN TYPE GETS NOTHING.** A new .m that is empty is a file a
 * compiler rejects the moment it is built; the two lines here are the smallest thing that is a translation unit. A .h
 * gets a guard. Anything else is created empty, because inventing content for a type this program does not know is how a
 * generator becomes a nuisance. */
- (NSString *)fn_templateForFileName:(NSString *)name
{
	NSString *extension = [[name pathExtension] lowercaseString];

	if ([extension isEqualToString:@"m"] || [extension isEqualToString:@"c"]) {
		return @"#include <stdio.h>\n\nint main(void)\n{\n\treturn 0;\n}\n";
	}
	if ([extension isEqualToString:@"h"]) {
		NSString *guard = [[name lastPathComponent] stringByReplacingOccurrencesOfString:@"."
										    withString:@"_"];

		return [NSString stringWithFormat:@"#ifndef %@\n#define %@\n\n#endif\n", guard, guard];
	}
	return @"";
}

/* ===================================================================================================
 * EXPORT APP: THE PRODUCT LEAVES THE PROJECT.
 *
 * A build writes `build/<Name>.app`, which is a fine place to run from and a bad place to hand to somebody — it is inside
 * a directory tree that `Clean` deletes. Export copies the bundle where a person says, with a save panel doing what a save
 * panel does: naming the thing, offering a place, and refusing to leave an extension off.
 *
 * **THE COPY IS THE VERB, SO REFUSING IS CHEAPER THAN COPYING BADLY.** Export answers before it acts, like the other
 * verbs: no product is a refusal with the reason in the log, and a build in flight is a refusal too, because the bundle on
 * disk at that moment is half of one.
 *
 * The destination is replaced rather than merged. A `.app` whose Contents came half from this build and half from an
 * older one is not the application that was just built, and a copy that leaves a stale file behind is the one outcome
 * nobody can see.
 * =================================================================================================== */
- (void)exportApp:(id)sender
{
	NSSavePanel *panel = [NSSavePanel savePanel];
	NSString *product = [[_project bundleURL] path];
	NSError *error = nil;

	(void)sender;
	if (![self fn_productIsExportable]) {
		return;		/* the refusal is already in the log */
	}
	[panel setTitle:@"Export App"];
	[panel setMessage:@"Choose where to save the application bundle."];
	/* **THE ACCOUNT'S APPLICATION FOLDER, WHICH IS WHERE A BUILT BUNDLE BELONGS AND IS ALSO NOT THE PROJECT.** It used to
	 * open beside the project, which is where a person's sources are and where an exported `.app` becomes a file the
	 * browser lists and the next build walks past. `~/Applications` is the Mac's answer for a bundle that did not come
	 * from a store: the session makes it at login and Launch Services scans it. */
	[panel setDirectory:[AGProjectWindowController fn_exportDirectoryForHome:NSHomeDirectory()]];
	[panel setNameFieldStringValue:[product lastPathComponent]];
	[panel setRequiredFileType:@"app"];
	if ([panel runModal] != NSOKButton) {
		return;
	}
	if (![self fn_exportProductToPath:[[panel URL] path] error:&error]) {
		[self fn_log:[NSString stringWithFormat:@"error: %@\n",
			(error != nil) ? [error localizedDescription] : @"the application could not be exported"]];
	}
}

/* **WHERE THE PANEL OPENS, AND IT IS THE ONLY THING THE PANEL'S PLACE DEPENDS ON.** `~/Applications` for the reason the
 * header gives; made here rather than assumed, because a Forge started without a session has never had one; and the home
 * itself when it cannot be made — a file called `Applications`, a home that is not writable — since a panel pointed at
 * something that does not exist is worse than one pointed at the directory that does. */
+ (NSString *)fn_exportDirectoryForHome:(NSString *)home
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *applications;
	BOOL isDirectory = NO;

	if ([home length] == 0) {
		return nil;
	}
	applications = [home stringByAppendingPathComponent:@"Applications"];
	/* **A FILE OF THAT NAME IS NOT THE FOLDER**, which is a second question and not the same one: `-fileExistsAtPath:`
	 * answers YES for both, so the test is `isDirectory:` — a home whose `Applications` is a plain file gets the home
	 * back rather than a panel pointed at something that cannot hold a bundle. */
	if (![manager fileExistsAtPath:applications isDirectory:&isDirectory]) {
		[manager createDirectoryAtPath:applications withIntermediateDirectories:NO attributes:nil error:NULL];
	}
	if ([manager fileExistsAtPath:applications isDirectory:&isDirectory] && isDirectory) {
		return applications;
	}
	return home;
}

/* THE TWO QUESTIONS EVERY EXPORT ASKS, IN ONE PLACE so the toolbar's validation and the verb cannot disagree. */
- (BOOL)fn_productIsExportable
{
	if ([_builder isBuilding]) {
		[self fn_log:@"error: this project is building; export when it has finished\n"];
		return NO;
	}
	if (![_builder hasProduct]) {
		[self fn_log:@"error: there is no built application to export; build it first\n"];
		return NO;
	}
	return YES;
}

/* THE DOOR WITHOUT THE PANEL, so a probe can export without a window server: the panel's only job is to produce a path. */
- (BOOL)fn_exportProductToPath:(NSString *)path error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *product = [[_project bundleURL] path];

	if (product == nil || ![_builder hasProduct]) {
		if (error != NULL) {
			*error = AGForgeError(@"There is no built application to export.");
		}
		return NO;
	}
	if ([path length] == 0) {
		if (error != NULL) {
			*error = AGForgeError(@"Nowhere was named to export to.");
		}
		return NO;
	}
	if ([manager fileExistsAtPath:path]) {
		if (![manager removeItemAtPath:path error:error]) {
			return NO;
		}
	}
	if (![manager copyItemAtPath:product toPath:path error:error]) {
		return NO;
	}
	[self fn_log:[NSString stringWithFormat:@"# Export: %@\n", path]];
	[self fn_mirrorToLogFile:[NSString stringWithFormat:@"# Export: %@\n", path]];
	return YES;
}

/* ===================================================================================================
 * REMOVING A FILE FROM THE PROJECT, WHICH IS NOT DELETING IT.
 *
 * The manifest is a list of what the project carries; taking a name off that list leaves the file where it is, and saying so
 * in the log is the difference between a person's edit and a person's accident. There is no confirmation sheet for that
 * reason: nothing on disk changes, and the file can be added again with Add Files.
 *
 * The verb answers before it acts, like the others: no selection is a refusal with the reason in the log, and so is a
 * selection that is a GROUP rather than a file — the browser holds both.
 * =================================================================================================== */
- (void)removeSelectedFile:(id)sender
{
	AGProjectFile *file = [self fn_selectedFile];
	NSError *error = nil;

	(void)sender;
	if (file == nil) {
		[self fn_log:@"error: select a file in the browser to remove it from the project\n"];
		return;
	}
	if (![self fn_removeFile:file error:&error]) {
		[self fn_log:[NSString stringWithFormat:@"error: %@\n",
			(error != nil) ? [error localizedDescription] : @"the file could not be removed"]];
	}
}

/* THE FILE UNDER THE SELECTION, or nil when the browser has a group (or nothing) selected. */
- (NSOutlineView *)browserOutline
{
	return _outline;
}

- (AGProjectFile *)fn_selectedFile
{
	NSInteger row = [_outline selectedRow];
	id item;

	if (row < 0) {
		return nil;
	}
	item = [_outline itemAtRow:row];
	return [item isKindOfClass:[AGProjectFile class]] ? item : nil;
}

/* THE DOOR WITHOUT THE BROWSER, so a probe can remove a named file: the browser's only job is to say which one. */
- (BOOL)fn_removeFile:(AGProjectFile *)file error:(NSError **)error
{
	NSString *relative;

	if (file == nil) {
		if (error != NULL) {
			*error = AGForgeError(@"No file was named to remove.");
		}
		return NO;
	}
	relative = [[file relativePath] retain];
	{
		/* **THE PATH IS ASKED BEFORE THE FILE LEAVES THE MANIFEST**, because it is the manifest that knows the project's
		 * directory — and it is compared with the editor's own path to see whether the open file is the one going. */
		NSString *absolute = [[_project absolutePathForFile:file] retain];

		if (![_project removeFile:file error:error]) {
			[absolute release];
			[relative release];
			return NO;
		}
		if (![_project writeToURL:[_project projectDirectoryURL] error:error]) {
			[absolute release];
			[relative release];
			return NO;
		}
		/* **AND A FILE THAT WAS OPEN GOES WITH IT.** The editor was showing a file the project no longer carries; leaving
		 * its text on screen under a title naming it would be a window claiming something the manifest denies. */
		if ([[_editor filePath] isEqualToString:absolute]) {
			[_editor setSource:@""];
			[_editor setFilePath:nil];
			[[self window] setTitle:[self fn_windowTitle]];
		}
		[absolute release];
	}
	/* **AN EMPTY GROUP DISAPPEARS WITH ITS LAST FILE**, which is `-fn_reloadGroups`' existing rule: the groups are built
	 * from the project's categories, so one that holds nothing is not in the browser at all. */
	[self fn_reloadGroups];
	[self fn_log:[NSString stringWithFormat:@"# Removed: %@ (the file is still on disk)\n", relative]];
	[self fn_mirrorToLogFile:[NSString stringWithFormat:@"# Removed: %@\n", relative]];
	[relative release];
	[self refreshToolbarState];
	return YES;
}

- (void)addFiles:(id)sender
{
	(void)sender;
	{
		NSOpenPanel *panel = [NSOpenPanel openPanel];
		NSInteger result;

		[panel setAllowsMultipleSelection:YES];
		[panel setCanChooseDirectories:NO];
		[panel setCanChooseFiles:YES];
		result = [panel runModalForDirectory:[[_project projectDirectoryURL] path] file:nil types:nil];
		if (result == NSOKButton) {
			NSArray *URLs = [panel URLs];
			NSUInteger i;

			for (i = 0; i < [URLs count]; i++) {
				NSString *path = [[URLs objectAtIndex:i] path];
				NSError *error = nil;

				if (![_project addFileAtAbsolutePath:path error:&error]) {
					[self fn_log:[NSString stringWithFormat:@"error: %@\n",
						[error localizedDescription]]];
				}
			}
			if (![_project writeToURL:[_project projectDirectoryURL] error:NULL]) {
				[self fn_log:@"error: the manifest could not be written\n"];
			}
			[self fn_reloadGroups];
		}
	}
}

@end
