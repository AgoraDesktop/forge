/*
 * AGProjectInfoView.m — the pane's form, its verbs, and the icon.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See the header for why this is a pane.
 *
 * **THE FORM IS THREE IDEAS, NOT FOUR ROWS.** The fields were a flat list with captions beside them, invented row by row,
 * and it read as a debug tool: every caption drew as a boxed field (a non-editable `NSTextField` keeps its BEZEL unless
 * `-setBezeled:NO` is said as well as `-setBordered:NO`), the fields stretched the width of the window whatever they held,
 * and nothing on the pane said what the pane was for. What a person edits here is two things — the identity a bundle
 * carries, and the face it wears — so the pane is a header, two captioned sections, and a footer that holds the verbs and
 * says whether there is anything to apply.
 *
 * The layout is arithmetic in one place, `-fn_layout`: a form of a dozen controls is smaller than the machinery a
 * constraint solver needs, and the pane is resized by the window, which is a `-setFrame:` override rather than a pass.
 */
#import "AGProjectInfoView.h"

#import "AGProject.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBezierPath.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSImageView.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

/* THE COLUMN THE FORM LIVES IN: a field two thirds of a screen wide is no easier to type in than one four hundred points
 * wide, and the eye travels less to check a value that is short. */
static const CGFloat AGFormWidth = 560.0;
static const CGFloat AGSideMargin = 24.0;
static const CGFloat AGLabelWidth = 92.0;
static const CGFloat AGFieldHeight = 24.0;
static const CGFloat AGRowGap = 8.0;
static const CGFloat AGIconSide = 64.0;

/* A GAP THAT SEPARATES SECTIONS RATHER THAN ROWS. */
static const CGFloat AGSectionGap = 22.0;

/* **THE FOOTER IS A BAND, NOT THE LAST ROW.** The verbs belong to the whole form, so they sit under a hairline at the
 * pane's floor with room of their own; a form that ended one row above them read as if Apply belonged to the icon. */
static const CGFloat AGFooterHeight = 54.0;
static const CGFloat AGFooterGap = 22.0;

/* ===================================================================================================
 * THE ICON WELL: a picture, or the shape of the slot one belongs in.
 *
 * A bare "(none)" in a text field was the old answer and it said nothing about what a person would get. The well is the
 * shape of the slot, so "there is no icon" is visible before the words are read.
 * =================================================================================================== */
@interface AGIconWell : NSView
{
	NSImageView *_imageView;	/* RETAINED */
	NSTextField *_placeholder;	/* RETAINED */
}
- (void)setImage:(NSImage *)image;
@end

@implementation AGIconWell

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_imageView = [[NSImageView alloc] initWithFrame:NSInsetRect([self bounds], 6.0, 6.0)];
		[_imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
		[self addSubview:_imageView];

		_placeholder = [[NSTextField alloc] initWithFrame:NSInsetRect([self bounds], 4.0, 4.0)];
		[_placeholder setStringValue:@"None"];
		[_placeholder setEditable:NO];
		[_placeholder setSelectable:NO];
		[_placeholder setBordered:NO];
		[_placeholder setBezeled:NO];
		[_placeholder setDrawsBackground:NO];
		[_placeholder setAlignment:NSCenterTextAlignment];
		[_placeholder setTextColor:[NSColor colorWithCalibratedWhite:0.62 alpha:1.0]];
		[_placeholder setFont:[NSFont systemFontOfSize:10.0]];
		[self addSubview:_placeholder];
	}
	return self;
}

- (void)dealloc
{
	[_imageView release];
	[_placeholder release];
	[super dealloc];
}

- (void)setImage:(NSImage *)image
{
	[_imageView setImage:image];
	[_imageView setHidden:(image == nil)];
	[_placeholder setHidden:(image != nil)];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[_imageView setFrame:NSInsetRect([self bounds], 6.0, 6.0)];
	[_placeholder setFrame:NSInsetRect([self bounds], 4.0, 4.0)];
}

/* THE WELL IS A HAIRLINE ROUNDED SQUARE, which is the only chrome it needs: it is a slot, not a button. */
- (void)drawRect:(NSRect)rect
{
	NSRect well = NSInsetRect([self bounds], 0.5, 0.5);
	NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:well xRadius:4.0 yRadius:4.0];

	(void)rect;
	[[NSColor colorWithCalibratedWhite:0.97 alpha:1.0] setFill];
	[path fill];
	[[NSColor colorWithCalibratedWhite:0.80 alpha:1.0] setStroke];
	[path setLineWidth:1.0];
	[path stroke];
}

@end

/* =================================================================================================== */

@interface AGProjectInfoView () <NSTextFieldDelegate>
- (NSTextField *)fn_label:(NSString *)text size:(CGFloat)size grey:(BOOL)grey;
- (NSTextField *)fn_field:(NSString *)value;
- (NSButton *)fn_button:(NSString *)title action:(SEL)action;
- (NSButton *)fn_chooseButton;
- (NSButton *)fn_revertButton;
- (void)fn_layout;
- (void)fn_placeIcon;
- (void)fn_captureBaseline;
- (void)fn_updateStatus;
- (NSString *)fn_currentState;
@end

@implementation AGProjectInfoView

- (instancetype)initWithFrame:(NSRect)frame project:(AGProject *)project
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_project = [project retain];

		/* THE HEADER: what this pane IS, and which project it is about. */
		_titleLabel = [[self fn_label:@"Project Info" size:15.0 grey:NO] retain];
		[_titleLabel setFont:[NSFont boldSystemFontOfSize:15.0]];
		_subtitleLabel = [[self fn_label:@"" size:11.0 grey:YES] retain];

		/* SECTION 1: THE BUNDLE'S IDENTITY. */
		_identityCaption = [[self fn_label:@"BUNDLE IDENTITY" size:10.0 grey:YES] retain];
		_nameCaption = [[self fn_label:@"Name" size:0.0 grey:YES] retain];
		_nameField = [[self fn_field:[project displayName]] retain];
		_identifierCaption = [[self fn_label:@"Identifier" size:0.0 grey:YES] retain];
		_identifierField = [[self fn_field:[project bundleIdentifier]] retain];
		_identifierHint = [[self fn_label:@"Reverse-DNS, for example io.github.you.app" size:10.0 grey:YES] retain];
		_versionCaption = [[self fn_label:@"Version" size:0.0 grey:YES] retain];
		_versionField = [[self fn_field:[project bundleVersion]] retain];

		/* SECTION 2: THE FACE IT WEARS. */
		_presentationCaption = [[self fn_label:@"PRESENTATION" size:10.0 grey:YES] retain];
		_iconCaption = [[self fn_label:@"Icon" size:0.0 grey:YES] retain];
		_iconWell = [[AGIconWell alloc] initWithFrame:NSMakeRect(0.0, 0.0, AGIconSide, AGIconSide)];
		[self addSubview:_iconWell];
		_iconLabel = [[self fn_label:@"No icon chosen" size:0.0 grey:YES] retain];
		(void)[self fn_button:@"Choose..." action:@selector(chooseIcon:)];
		_removeIconButton = [[self fn_button:@"Remove" action:@selector(removeIcon:)] retain];

		/* THE FOOTER: what the state is, and the two verbs. There is no Cancel — this pane changes nothing until Apply —
		 * so the words are Revert and Apply, and the state line is what tells a person which one they need. */
		_statusLabel = [[self fn_label:@"" size:11.0 grey:YES] retain];
		(void)[self fn_button:@"Revert" action:@selector(revert:)];
		_applyButton = [[self fn_button:@"Apply" action:@selector(apply:)] retain];
		[_applyButton setKeyEquivalent:@"\r"];

		[_nameField setDelegate:self];
		[_identifierField setDelegate:self];
		[_versionField setDelegate:self];

		[self reloadFields];
		[self fn_layout];
	}
	return self;
}

/* **A LABEL IS NOT A FIELD.** A non-editable text field keeps its bezel unless BOTH `-setBordered:NO` and
 * `-setBezeled:NO` are said; with only the first the captions drew as empty boxes — the defect that made this pane look
 * like a debug dump. Size 0 means the control's own default, which is what a value label wants. */
- (NSTextField *)fn_label:(NSString *)text size:(CGFloat)size grey:(BOOL)grey
{
	NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];

	[label setStringValue:text];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setBezeled:NO];
	[label setDrawsBackground:NO];
	if (size > 0.0) {
		[label setFont:(size <= 10.5) ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size]];
	}
	if (grey) {
		[label setTextColor:[NSColor colorWithCalibratedWhite:0.42 alpha:1.0]];
	}
	[self addSubview:label];
	return [label autorelease];
}

- (NSTextField *)fn_field:(NSString *)value
{
	NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];

	[field setBezeled:YES];
	[field setEditable:YES];
	[field setStringValue:(value != nil ? value : @"")];
	[self addSubview:field];
	return [field autorelease];
}

- (NSButton *)fn_button:(NSString *)title action:(SEL)action
{
	NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];

	[button setTitle:title];
	[button setButtonType:NSMomentaryPushInButton];
	[button setBezelStyle:NSRoundedBezelStyle];
	[button setTarget:self];
	[button setAction:action];
	[self addSubview:button];
	return [button autorelease];
}

/* ===================================================================================================
 * THE LAYOUT: a title, a subtitle, a captioned section of three rows with one hint, a captioned section with the icon
 * well and its two buttons, and a footer. Every y is derived from the top and every x from the column's left edge, so a
 * narrower pane moves nothing but the field widths.
 * =================================================================================================== */
- (void)fn_layout
{
	NSRect bounds = [self bounds];
	CGFloat columnLeft = AGSideMargin;
	CGFloat columnWidth = bounds.size.width - AGSideMargin * 2.0;
	CGFloat fieldLeft;
	CGFloat fieldWidth;
	/* **THE CURSOR IS EACH ROW'S TOP EDGE, NOT ITS BOTTOM.** The first version accumulated bottoms, so every gap had to be
	 * reasoned about backwards — which is how the identifier's hint ended up drawn across the version field's border. A
	 * cursor makes a gap a subtraction and a row's height its own. */
	CGFloat cursor;

	if (columnWidth > AGFormWidth) {
		columnWidth = AGFormWidth;
	}
	if (columnWidth < 200.0) {
		columnWidth = 200.0;
	}
	fieldLeft = columnLeft + AGLabelWidth + 10.0;
	fieldWidth = columnWidth - AGLabelWidth - 10.0;

	cursor = bounds.size.height - AGSideMargin;
	cursor -= 20.0;
	[_titleLabel setFrame:NSMakeRect(columnLeft, cursor, columnWidth, 20.0)];
	cursor -= (20.0 + 2.0);

	[_subtitleLabel setFrame:NSMakeRect(columnLeft, cursor, columnWidth, 16.0)];
	cursor -= (16.0 + 16.0);

	[_identityCaption setFrame:NSMakeRect(columnLeft, cursor, columnWidth, 14.0)];
	cursor -= (14.0 + AGRowGap);

	[_nameCaption setAlignment:NSRightTextAlignment];
	[_nameCaption setFrame:NSMakeRect(columnLeft, cursor - AGFieldHeight + 3.0, AGLabelWidth, 18.0)];
	[_nameField setFrame:NSMakeRect(fieldLeft, cursor - AGFieldHeight, fieldWidth, AGFieldHeight)];
	cursor -= (AGFieldHeight + AGRowGap);

	[_identifierCaption setAlignment:NSRightTextAlignment];
	[_identifierCaption setFrame:NSMakeRect(columnLeft, cursor - AGFieldHeight + 3.0, AGLabelWidth, 18.0)];
	[_identifierField setFrame:NSMakeRect(fieldLeft, cursor - AGFieldHeight, fieldWidth, AGFieldHeight)];
	cursor -= AGFieldHeight;

	/* THE HINT SITS UNDER THE FIELD IT EXPLAINS, with air on both sides: it is a note, not a row. */
	cursor -= 5.0;
	[_identifierHint setFrame:NSMakeRect(fieldLeft + 2.0, cursor - 13.0, fieldWidth, 13.0)];
	cursor -= (13.0 + AGRowGap + 5.0);

	[_versionCaption setAlignment:NSRightTextAlignment];
	[_versionCaption setFrame:NSMakeRect(columnLeft, cursor - AGFieldHeight + 3.0, AGLabelWidth, 18.0)];
	[_versionField setFrame:NSMakeRect(fieldLeft, cursor - AGFieldHeight, fieldWidth, AGFieldHeight)];
	cursor -= (AGFieldHeight + 30.0);

	[_presentationCaption setFrame:NSMakeRect(columnLeft, cursor, columnWidth, 14.0)];
	cursor -= (14.0 + 6.0);

	/* THE ICON: the well at the left of the field column, and the picture's NAME above its two verbs to the right of it
	 * — so the well, the name and the buttons read as one row about one picture. */
	{
		NSRect well = NSMakeRect(fieldLeft, cursor - AGIconSide, AGIconSide, AGIconSide);
		CGFloat textLeft = NSMaxX(well) + 14.0;
		CGFloat textWidth = fieldWidth - AGIconSide - 14.0;
		CGFloat buttonsY = NSMinY(well) + 4.0;

		[_iconCaption setAlignment:NSRightTextAlignment];
		[_iconCaption setFrame:NSMakeRect(columnLeft, NSMidY(well) - 8.0, AGLabelWidth, 18.0)];
		[_iconWell setFrame:well];

		[_iconLabel setFrame:NSMakeRect(textLeft, NSMaxY(well) - 22.0, textWidth, 18.0)];
		[_removeIconButton setFrame:NSMakeRect(textLeft, buttonsY, 84.0, 24.0)];
		[[self fn_chooseButton] setFrame:NSMakeRect(textLeft + 92.0, buttonsY, 100.0, 24.0)];
	}

	/* THE FOOTER BAND: a hairline at `AGFooterHeight`, the two verbs centred in the band's lower half, and the state line
	 * beside them. The form's last row is left at least `AGFooterGap` above the hairline so Apply never crowds the icon. */
	{
		CGFloat footerY = (AGFooterHeight - 26.0) / 2.0;
		CGFloat applyWidth = 84.0;
		CGFloat revertWidth = 84.0;
		CGFloat applyX = columnLeft + columnWidth - applyWidth;
		CGFloat revertX = applyX - revertWidth - 8.0;

		[_applyButton setFrame:NSMakeRect(applyX, footerY, applyWidth, 26.0)];
		[[self fn_revertButton] setFrame:NSMakeRect(revertX, footerY, revertWidth, 26.0)];
		[_statusLabel setFrame:NSMakeRect(columnLeft, footerY + 5.0, revertX - columnLeft - 12.0, 16.0)];
	}

	/* AND THE FORM CANNOT REACH THE BAND: with a pane too short for its content the gap is what gives way first, so a
	 * window dragged small loses air rather than overlapping the verbs. */
	(void)cursor;
}

- (void)fn_placeIcon
{
	NSImage *image = nil;

	if ([_project iconPath] != nil) {
		NSString *path = [[[_project projectDirectoryURL] path]
			stringByAppendingPathComponent:[_project iconPath]];

		image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
	}
	[_iconWell setImage:image];
}

/* THE HAIRLINE ABOVE THE FOOTER, from the column's left edge to its right. */
- (void)drawRect:(NSRect)rect
{
	NSRect bounds = [self bounds];
	CGFloat columnWidth = bounds.size.width - AGSideMargin * 2.0;

	(void)rect;
	if (columnWidth > AGFormWidth) {
		columnWidth = AGFormWidth;
	}
	[[NSColor colorWithCalibratedWhite:0.87 alpha:1.0] setFill];
	NSRectFill(NSMakeRect(AGSideMargin, AGFooterHeight, columnWidth, 1.0));
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[self fn_layout];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_layout];
}

- (void)dealloc
{
	[_nameField release];
	[_identifierField release];
	[_versionField release];
	[_iconLabel release];
	[_titleLabel release];
	[_subtitleLabel release];
	[_identityCaption release];
	[_presentationCaption release];
	[_nameCaption release];
	[_identifierCaption release];
	[_versionCaption release];
	[_iconCaption release];
	[_identifierHint release];
	[_statusLabel release];
	[_applyButton release];
	[_removeIconButton release];
	[_iconWell release];
	[_baseline release];
	[_project release];
	[super dealloc];
}

/* THE TWO BUTTONS THAT ARE FOUND BY THEIR JOB, because they have no other: keeping an ivar for every push button would be
 * bookkeeping for its own sake. */
- (NSButton *)fn_chooseButton
{
	NSArray *subviews = [self subviews];
	NSUInteger i;

	for (i = 0; i < [subviews count]; i++) {
		id view = [subviews objectAtIndex:i];

		if ([view isKindOfClass:[NSButton class]] && [view action] == @selector(chooseIcon:)) {
			return view;
		}
	}
	return nil;
}

- (NSButton *)fn_revertButton
{
	NSArray *subviews = [self subviews];
	NSUInteger i;

	for (i = 0; i < [subviews count]; i++) {
		id view = [subviews objectAtIndex:i];

		if ([view isKindOfClass:[NSButton class]] && [view action] == @selector(revert:)) {
			return view;
		}
	}
	return nil;
}

- (void)setDelegate:(id <AGProjectInfoViewDelegate>)delegate
{
	_delegate = delegate;
}

- (id <AGProjectInfoViewDelegate>)delegate
{
	return _delegate;
}

/* ===================================================================================================
 * STATE: what is typed, what is stored, and whether they are the same thing.
 * =================================================================================================== */

- (NSString *)fn_currentState
{
	return [NSString stringWithFormat:@"%@\n%@\n%@\n%@", [_nameField stringValue],
		[_identifierField stringValue], [_versionField stringValue],
		([_project iconPath] != nil ? [_project iconPath] : @"")];
}

- (void)fn_captureBaseline
{
	[_baseline release];
	_baseline = [[self fn_currentState] copy];
}

/* **THE FOOTER SAYS WHICH VERB A PERSON NEEDS**, and Apply is only live when it would do something: a button that writes
 * an unchanged manifest is a button that teaches nobody anything. */
- (void)fn_updateStatus
{
	BOOL changed = (_baseline != nil) && ![[self fn_currentState] isEqualToString:_baseline];

	[_statusLabel setStringValue:(changed ? @"Unsaved changes" : @"Up to date")];
	[_applyButton setEnabled:changed];
	[[self fn_revertButton] setEnabled:changed];
}

- (void)controlTextDidChange:(NSNotification *)notification
{
	(void)notification;
	[self fn_updateStatus];
}

- (void)reloadFields
{
	/* **ASCII ONLY.** This tier's raster draws a non-ASCII character as the first byte of its UTF-8 sequence — a middle
	 * dot came out as "A-" followed by a box — so the separator is a plain hyphen until the raster can carry more. */
	NSString *subtitle = [NSString stringWithFormat:@"%@  -  %@", [_project typeName],
		[[_project projectDirectoryURL] path]];

	[_subtitleLabel setStringValue:subtitle];
	[_nameField setStringValue:[_project displayName]];
	[_identifierField setStringValue:[_project bundleIdentifier]];
	[_versionField setStringValue:[_project bundleVersion]];
	[_iconLabel setStringValue:([_project iconPath] != nil ? [[_project iconPath] lastPathComponent]
							       : @"No icon chosen")];
	[_removeIconButton setEnabled:([_project iconPath] != nil)];
	[self fn_placeIcon];
	[self fn_captureBaseline];
	[self fn_updateStatus];
}

/* ===================================================================================================
 * THE VERBS.
 * =================================================================================================== */

- (void)apply:(id)sender
{
	NSError *error = nil;

	(void)sender;
	/* **THE IDENTIFIER IS ASKED FIRST, BECAUSE A REFUSAL MUST LEAVE EVERYTHING ALONE.** Setting the name and the
	 * version before the identifier was validated left the project object holding a name the manifest never received —
	 * so the next save (any Add, Remove or Apply) wrote it after all, while the log said the apply had been refused. */
	if (![_project setBundleIdentifier:[_identifierField stringValue]]) {
		/* A REFUSED IDENTIFIER LEAVES EVERYTHING ALONE, THE FIELD INCLUDED — the manifest keeps the identifier it
		 * had, the field shows what the project will actually use, and the reason goes to the project's log. */
		if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
			[_delegate projectInfoDidLog:
				@"error: the identifier must be reverse-DNS (letters, digits, hyphens and dots, at least one dot)\n"];
		}
		[_identifierField setStringValue:[_project bundleIdentifier]];
		[self fn_updateStatus];
		return;
	}
	[_project setDisplayName:[_nameField stringValue]];
	[_project setBundleVersion:[_versionField stringValue]];
	if (![_project writeToURL:[_project projectDirectoryURL] error:&error]) {
		if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
			[_delegate projectInfoDidLog:[NSString stringWithFormat:@"error: %@\n",
				(error != nil) ? [error localizedDescription] : @"the manifest could not be written"]];
		}
		return;
	}
	if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
		[_delegate projectInfoDidLog:[NSString stringWithFormat:@"# Info: %@ %@ (%@)\n", [_project displayName],
			[_project bundleVersion], [_project bundleIdentifier]]];
	}
	if ([_delegate respondsToSelector:@selector(projectInfoDidApply:)]) {
		[_delegate projectInfoDidApply:self];
	}
	[self reloadFields];
}

- (void)revert:(id)sender
{
	(void)sender;
	/* **THE PROJECT IS THE TRUTH, AND IT IS THE ONE EVERYBODY ELSE HOLDS.** This used to re-read the manifest into a
	 * NEW `AGProject` and keep that instead — but the window controller and the builder still pointed at the old one,
	 * so a later New File wrote the manifest from the stale model and dropped what Apply had just saved. Nothing
	 * needs re-reading: an unapplied edit lives in these FIELDS, and `-reloadFields` overwrites them from the project. */
	[self reloadFields];
}

/* **THE ICON IS A FILE, SO IT IS CHOSEN WITH A FILE PANEL.** It is copied into the project's `Resources/` — a manifest
 * that named a picture outside the project would be a manifest that only works on the machine that wrote it, which is
 * the rule the file list already follows. */
- (void)chooseIcon:(id)sender
{
	NSOpenPanel *panel = [NSOpenPanel openPanel];

	(void)sender;
	[panel setCanChooseFiles:YES];
	[panel setCanChooseDirectories:NO];
	[panel setAllowsMultipleSelection:NO];
	if ([panel runModalForDirectory:[[_project projectDirectoryURL] path] file:nil
				  types:[NSArray arrayWithObjects:@"png", @"tiff", @"jpg", @"jpeg", @"icns", nil]] != NSOKButton) {
		return;
	}
	{
		NSString *source = [[[panel URLs] lastObject] path];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSString *resources = [[[_project projectDirectoryURL] path] stringByAppendingPathComponent:@"Resources"];
		NSString *destination = [resources stringByAppendingPathComponent:[source lastPathComponent]];
		NSString *relative = [@"Resources" stringByAppendingPathComponent:[source lastPathComponent]];

		if (![manager createDirectoryAtPath:resources withIntermediateDirectories:YES attributes:nil error:NULL]) {
			if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
				[_delegate projectInfoDidLog:@"error: the Resources directory could not be made\n"];
			}
			return;
		}
		[manager removeItemAtPath:destination error:NULL];
		if (![manager copyItemAtPath:source toPath:destination error:NULL]) {
			if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
				[_delegate projectInfoDidLog:@"error: the icon could not be copied into the project\n"];
			}
			return;
		}
		/* THE PROJECT OWNS IT NOW, so its own file list claims it: a picture in Resources that the manifest did not
		 * name would be a file the browser does not show and the next build does not carry. */
		[_project addFileAtAbsolutePath:destination error:NULL];
		[_project setIconPath:relative];
		if (![_project writeToURL:[_project projectDirectoryURL] error:NULL]) {
			if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
				[_delegate projectInfoDidLog:@"error: the manifest could not be written\n"];
			}
			return;
		}
		if ([_delegate respondsToSelector:@selector(projectInfoDidAddFile:)]) {
			[_delegate projectInfoDidAddFile:relative];
		}
		if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
			[_delegate projectInfoDidLog:[NSString stringWithFormat:@"# Icon: %@\n", relative]];
		}
		[self reloadFields];
	}
}

/* **REMOVING THE ICON IS REMOVING THE NAME, NOT DELETING THE PICTURE.** The file stays in the project's Resources and in
 * its file list, because a person who stops using a picture has not asked for it to be destroyed. */
- (void)removeIcon:(id)sender
{
	(void)sender;
	if ([_project iconPath] == nil) {
		return;
	}
	[_project setIconPath:nil];
	if (![_project writeToURL:[_project projectDirectoryURL] error:NULL]) {
		if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
			[_delegate projectInfoDidLog:@"error: the manifest could not be written\n"];
		}
		return;
	}
	if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
		[_delegate projectInfoDidLog:@"# Icon: none\n"];
	}
	[self reloadFields];
}

/* ---- THE TEST DOORS, named as such. ------------------------------------------------------------- */

- (NSTextField *)nameField
{
	return _nameField;
}

- (NSTextField *)identifierField
{
	return _identifierField;
}

- (NSTextField *)versionField
{
	return _versionField;
}

- (NSTextField *)iconLabel
{
	return _iconLabel;
}

- (NSTextField *)statusLabel
{
	return _statusLabel;
}

- (NSButton *)applyButton
{
	return _applyButton;
}

- (NSButton *)removeIconButton
{
	return _removeIconButton;
}

- (BOOL)isDirty
{
	return (_baseline != nil) && ![[self fn_currentState] isEqualToString:_baseline];
}

@end
