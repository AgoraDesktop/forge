/*
 * AGProjectInfoView.m — the pane's fields, its two verbs, and the icon.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See the header for why this is a pane. The layout is arithmetic in ONE place — a form of six controls is smaller than
 * the machinery a constraint solver needs, and the pane has to re-place them whenever the window resizes, which is a
 * `-setFrame:` override rather than a layout pass.
 */
#import "AGProjectInfoView.h"

#import "AGProject.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSButton.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

static const CGFloat AGRowHeight = 30.0;
static const CGFloat AGLabelWidth = 110.0;
static const CGFloat AGTopMargin = 46.0;
static const CGFloat AGSideMargin = 20.0;

@interface AGProjectInfoView ()
- (NSTextField *)fn_label:(NSString *)text;
- (NSTextField *)fn_field:(NSString *)value;
- (NSButton *)fn_button:(NSString *)title action:(SEL)action;
- (void)fn_layout;
@end

@implementation AGProjectInfoView

- (instancetype)initWithFrame:(NSRect)frame project:(AGProject *)project
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		_project = [project retain];

		/* THE THREE ROWS AND THE ICON, built once; `-fn_layout` places them, because a pane is resized by the window. */
		(void)[self fn_label:@"Name"];
		_nameField = [[self fn_field:[project displayName]] retain];
		(void)[self fn_label:@"Identifier"];
		_identifierField = [[self fn_field:[project bundleIdentifier]] retain];
		(void)[self fn_label:@"Version"];
		_versionField = [[self fn_field:[project bundleVersion]] retain];
		(void)[self fn_label:@"Icon"];
		_iconLabel = [[self fn_label:@"(none)"] retain];
		(void)[self fn_button:@"Choose Icon…" action:@selector(chooseIcon:)];

		/* THE TWO VERBS, bottom right. There is no Cancel: this pane changes nothing until Apply, and the segment
		 * switch is how a person leaves it. */
		(void)[self fn_button:@"Apply" action:@selector(apply:)];
		(void)[self fn_button:@"Revert" action:@selector(revert:)];

		[self reloadFields];
		[self fn_layout];
	}
	return self;
}

/* **A PANE IS RESIZED BY THE WINDOW, SO THE FRAMES ARE RECOMPUTED FROM ITS OWN BOUNDS.** The captions and fields are
 * kept in creation order — three label/field pairs, the icon's caption and its button, then Apply and Revert — which is
 * the one place their order matters. */
- (void)fn_layout
{
	NSRect bounds = [self bounds];
	NSArray *subviews = [self subviews];
	CGFloat fieldWidth = bounds.size.width - AGLabelWidth - AGSideMargin * 2.0;
	CGFloat top = bounds.size.height - AGTopMargin;
	NSUInteger i;
	NSInteger row = 0;
	NSInteger button = 0;

	for (i = 0; i < [subviews count]; i++) {
		NSView *view = [subviews objectAtIndex:i];
		CGFloat y = top - (CGFloat)row * AGRowHeight;

		if (view == (NSView *)_nameField || view == (NSView *)_identifierField ||
		    view == (NSView *)_versionField || view == (NSView *)_iconLabel) {
			[view setFrame:NSMakeRect(AGSideMargin + AGLabelWidth, y + 2.0, fieldWidth, 24.0)];
			row++;
			continue;
		}
		if ([view isKindOfClass:[NSTextField class]]) {
			continue;		/* a caption: placed by its field, below */
		}
		/* THE ICON'S BUTTON SITS BESIDE THE ICON'S CAPTION, on the row that caption ends. */
		if (row == 4 && button == 0) {
			[view setFrame:NSMakeRect(NSMaxX(bounds) - AGSideMargin - 150.0, top - 3.0 * AGRowHeight + 2.0,
						  150.0, 26.0)];
			button++;
			continue;
		}
		/* AND THE TWO VERBS AT THE BOTTOM, right to left. */
		{
			CGFloat x = NSMaxX(bounds) - AGSideMargin - 100.0 - (CGFloat)button * 110.0;

			[view setFrame:NSMakeRect(x, AGSideMargin - 4.0, 100.0, 28.0)];
			button++;
		}
	}
	/* THE CAPTIONS KEEP THEIR OWN ORDER BESIDE THE FIELDS THEY NAME. */
	row = 0;
	for (i = 0; i < [subviews count]; i++) {
		NSView *view = [subviews objectAtIndex:i];

		if (![view isKindOfClass:[NSTextField class]] || view == (NSView *)_nameField ||
		    view == (NSView *)_identifierField || view == (NSView *)_versionField ||
		    view == (NSView *)_iconLabel) {
			continue;
		}
		[view setFrame:NSMakeRect(AGSideMargin, top - (CGFloat)row * AGRowHeight + 4.0, AGLabelWidth, 20.0)];
		row++;
	}
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
	[_project release];
	[super dealloc];
}

- (void)setDelegate:(id <AGProjectInfoViewDelegate>)delegate
{
	_delegate = delegate;
}

- (id <AGProjectInfoViewDelegate>)delegate
{
	return _delegate;
}

/* ---------------------------------------------------------------------------------------------------
 * The three pieces of a form.
 * --------------------------------------------------------------------------------------------------- */

- (NSTextField *)fn_label:(NSString *)text
{
	NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];

	[label setStringValue:text];
	[label setEditable:NO];
	[label setSelectable:NO];
	[label setBordered:NO];
	[label setDrawsBackground:NO];
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

/* ---------------------------------------------------------------------------------------------------
 * Reading and writing the project.
 * --------------------------------------------------------------------------------------------------- */

- (void)reloadFields
{
	[_nameField setStringValue:[_project displayName]];
	[_identifierField setStringValue:[_project bundleIdentifier]];
	[_versionField setStringValue:[_project bundleVersion]];
	[_iconLabel setStringValue:([_project iconPath] != nil ? [[_project iconPath] lastPathComponent] : @"(none)")];
}

- (void)apply:(id)sender
{
	NSError *error = nil;

	(void)sender;
	[_project setDisplayName:[_nameField stringValue]];
	[_project setBundleVersion:[_versionField stringValue]];
	if (![_project setBundleIdentifier:[_identifierField stringValue]]) {
		/* **A REFUSED IDENTIFIER LEAVES EVERYTHING ALONE, THE FIELD INCLUDED** — the manifest keeps the identifier it
		 * had, the field shows what the project will actually use, and the reason goes to the project's log. */
		if ([_delegate respondsToSelector:@selector(projectInfoDidLog:)]) {
			[_delegate projectInfoDidLog:
				@"error: the identifier must be reverse-DNS (letters, digits, hyphens and dots, at least one dot)\n"];
		}
		[_identifierField setStringValue:[_project bundleIdentifier]];
		return;
	}
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
	/* THE PROJECT IS THE TRUTH; `-reloadFields` alone would not drop an edit the project has not taken yet, so the
	 * manifest is re-read first and everything the window shows comes from it. */
	{
		AGProject *fresh = [AGProject projectWithContentsOfURL:[_project projectDirectoryURL] error:NULL];

		if (fresh != nil) {
			[_project release];
			_project = [fresh retain];
		}
	}
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

@end
