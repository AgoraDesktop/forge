/*
 * project_info_window — the metadata panel: a WINDOW, and the manifest is what it writes.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE PANEL USED TO BE AN ALERT, AND AN ALERT IS A NESTED LOOP INSIDE WHOEVER OPENED IT.** Forge opened it from a
 * menu pick, so the menu's tracking frame was the panel's parent and the panel's lifetime was that frame's — which is
 * how "the menu stays up over the sheet" and "the sheet will not close" arrive together. A window has none of that: no
 * modal loop, no parent on a stack, and nothing for a test to hang in.
 *
 * So this probe can drive the whole thing: fill the fields, press Apply, and read the manifest back. It also asserts the
 * absence of the old behaviour — no modal window is in flight while the panel is open — because "it is not modal" is a
 * claim, not an implementation detail.
 */
#import "AGProject.h"
#import "AGProjectInfoView.h"
#import "AGProjectWindowController.h"
#import "AGSourceEditor.h"
#import <AppKit/NSSegmentedControl.h>

#import <AppKit/NSApplication.h>
#import <AppKit/NSTextField.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

@interface AGInfoRecorder : NSObject <AGProjectInfoViewDelegate>
{
@public
	int applied;
	int logged;
	NSString *lastLog;
	NSString *lastAddedFile;
}
@end

@implementation AGInfoRecorder

- (void)projectInfoDidApply:(id)sender
{
	(void)sender;
	applied++;
}

- (void)projectInfoDidLog:(NSString *)line
{
	logged++;
	[lastLog release];
	lastLog = [line copy];
}

- (void)projectInfoDidAddFile:(NSString *)relativePath
{
	[lastAddedFile release];
	lastAddedFile = [relativePath copy];
}

- (void)dealloc
{
	[lastLog release];
	[lastAddedFile release];
	[super dealloc];
}

@end

/* **TWO PICTURES ARE THE SAME ONLY IF THEIR BYTES ARE.** The segments' images are made by a factory that answers a fresh
 * image per call, so identity says nothing; the representations are the same size and layout, which is what makes a memcmp
 * the whole answer. */
static int fn_same_picture(NSImage *a, NSImage *b)
{
	NSBitmapImageRep *ra = (NSBitmapImageRep *)[[a representations] lastObject];
	NSBitmapImageRep *rb = (NSBitmapImageRep *)[[b representations] lastObject];

	if (ra == nil || rb == nil || [ra pixelsWide] != [rb pixelsWide] || [ra pixelsHigh] != [rb pixelsHigh]) {
		return 0;
	}
	return memcmp([ra bitmapData], [rb bitmapData],
		      (size_t)([ra bytesPerRow] * [ra pixelsHigh])) == 0;
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-info-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSURL *URL = [NSURL fileURLWithPath:directory isDirectory:YES];
		AGProject *project;
		AGProjectInfoView *info;
		AGInfoRecorder *recorder = [[AGInfoRecorder alloc] init];
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"int main(void) { return 0; }\n" writeToFile:[sources stringByAppendingPathComponent:@"main.m"]
						     atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		project = [AGProject newProjectAtDirectoryURL:URL name:@"Info Test" type:AGProjectTypeApplication
						       error:&error];
		check(project != nil, "the project is created");
		[project addFileAtAbsolutePath:[sources stringByAppendingPathComponent:@"main.m"] error:NULL];
		[project writeToURL:URL error:NULL];

		info = [[AGProjectInfoView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 380.0) project:project];
		[info setDelegate:recorder];

		/* 1. THE PANE SHOWS THE PROJECT, and being a view there is no session of any kind to enter. */
		check([info superview] == nil, "the pane is a view, not a window");
		check([[NSApplication sharedApplication] modalWindow] == nil, "and no modal session is in flight");
		check([[[info nameField] stringValue] isEqualToString:@"Info Test"], "the name field shows the project's name");
		check([[[info identifierField] stringValue] isEqualToString:[project bundleIdentifier]],
		      "the identifier field shows the project's identifier");
		check([[[info versionField] stringValue] isEqualToString:@"0.1.0"],
		      "the version field shows the project's default version");
		check([[[info iconLabel] stringValue] length] > 0, "and the icon row says there is none");

		/* 2. APPLY WRITES THE MANIFEST, and the write is what the next build reads. */
		[[info nameField] setStringValue:@"Info Test App"];
		[[info identifierField] setStringValue:@"io.github.agoradesktop.info-test"];
		[[info versionField] setStringValue:@"3.0.0"];
		[info apply:nil];
		check(recorder->applied == 1, "Apply told the delegate the manifest was written");
		{
			AGProject *reloaded = [AGProject projectWithContentsOfURL:URL error:NULL];

			check(reloaded != nil, "the manifest still reads");
			check([[reloaded displayName] isEqualToString:@"Info Test App"], "the name was written");
			check([[reloaded bundleIdentifier] isEqualToString:@"io.github.agoradesktop.info-test"],
			      "the identifier was written");
			check([[reloaded bundleVersion] isEqualToString:@"3.0.0"], "the version was written");
			check([[reloaded generatedInfoPlist] rangeOfString:@"io.github.agoradesktop.info-test"].location != NSNotFound,
			      "and the plist the build will write carries it");
		}

		/* 3. A REFUSED IDENTIFIER CHANGES NOTHING AND SAYS WHY — the field reverts to what the project will use. */
		[[info nameField] setStringValue:@"Should Not Land"];
		[[info identifierField] setStringValue:@"not an identifier"];
		recorder->applied = 0;
		recorder->logged = 0;
		[info apply:nil];
		check(recorder->applied == 0, "a refused identifier does not write the manifest");
		check(recorder->logged > 0, "and the refusal is reported");
		check([[recorder->lastLog lowercaseString] rangeOfString:@"identifier"].location != NSNotFound,
		      "with a line about the identifier");
		check([[info identifierField].stringValue isEqualToString:@"io.github.agoradesktop.info-test"],
		      "and the field shows the identifier the project actually has");
		{
			AGProject *reloaded = [AGProject projectWithContentsOfURL:URL error:NULL];

			check([[reloaded displayName] isEqualToString:@"Info Test App"],
			      "while the name the panel was holding was not written either");
		}
		/* **AND NOT IN THE OBJECT EITHER.** The manifest is not the only copy a refused Apply can damage: the name and
		 * the version used to be set BEFORE the identifier was asked, so the project object kept them and the next save
		 * (any Add or Remove) wrote them after all, while the log said the apply had been refused. */
		check([[project displayName] isEqualToString:@"Info Test App"],
		      "and the project the window holds still names itself");
		check([[project bundleVersion] isEqualToString:@"3.0.0"],
		      "and still carries the version it had");

		/* 4. REVERT DROPS WHAT WAS TYPED AND SHOWS THE PROJECT AGAIN. */
		[[info versionField] setStringValue:@"9.9.9"];
		[info revert:nil];
		check([[info versionField].stringValue isEqualToString:@"3.0.0"], "Revert put the project's version back");

		/* 4b. **THE FORM SAYS WHAT IT IS AND WHETHER THERE IS ANYTHING TO APPLY.** The pane used to be four unlabelled
		 * rows with a caption that drew as a box; the header, the state line and the two verbs are what make it a form
		 * rather than a debug dump, and each of them is driven by something. */
		{
			[info reloadFields];
			check(![info isDirty], "a freshly loaded form has nothing to apply");
			check([[info applyButton] isEnabled] == NO,
			      "so Apply is not offered: a button that writes an unchanged manifest teaches nothing");
			check([[[info statusLabel] stringValue] rangeOfString:@"Up to date"].location != NSNotFound,
			      "and the footer says so in words");

			[[info nameField] setStringValue:@"A Different Name"];
			[info controlTextDidChange:nil];
			check([info isDirty], "typing into a field makes the form dirty");
			check([[info applyButton] isEnabled], "which is what enables Apply");
			check([[[info statusLabel] stringValue] rangeOfString:@"Unsaved"].location != NSNotFound,
			      "and the footer says that instead");

			[info revert:nil];
			check(![info isDirty], "and Revert puts the form back to the project's own values");
		}

		/* 4c. **THE PANE IS A FORM, NOT A COLUMN OF BOXED CAPTIONS**: the captions are labels with no bezel, and the
		 * fields are shorter than the column so the form has a reading width rather than the window's. */
		{
			NSTextField *caption = nil;
			NSArray *subviews = [info subviews];
			NSUInteger i;

			for (i = 0; i < [subviews count]; i++) {
				id view = [subviews objectAtIndex:i];

				if ([view isKindOfClass:[NSTextField class]] && [view isEditable] == NO
				    && [[view stringValue] isEqualToString:@"Name"]) {
					caption = view;
				}
			}
			check(caption != nil, "the Name caption exists");
			check(caption != nil && ![caption isBezeled], "and it draws as a label, not as an empty field");
			check(caption != nil && ![caption isBordered], "with no border either");
			check(NSWidth([[info nameField] frame]) < NSWidth([info bounds]) - 80.0,
			      "and the fields are a reading width, not the whole pane");
		}

		/* 5. **AND IT IS A PANE OF THE PROJECT WINDOW, SWAPPED WITH THE EDITOR BY A SEGMENTED CONTROL.** The claim is
		 * the visibility pair: one of the two is on at a time, and neither is thrown away — which is what keeps an open
		 * file and a half-typed identifier alive across a look at the other. */
		{
			AGProjectWindowController *projectWindow = [[AGProjectWindowController alloc] initWithProject:project];
			NSSegmentedControl *detailSwitch = [projectWindow detailSwitch];

			check(detailSwitch != nil, "the window has the detail switch");
			check([detailSwitch segmentCount] == 2, "with two segments");
			/* **TWO PICTURES AND NO WORDS.** Tabler's `code-dots` and `info-circle` are what the segments say; a word
			 * beside each would read as the label of a text control in a band of pictures. The two claims below are
			 * therefore the whole of the switch's meaning: each has a picture, and the two pictures differ — a factory
			 * that answered one shape twice would make a switch that says nothing. */
			check([detailSwitch imageForSegment:0] != nil && [detailSwitch imageForSegment:1] != nil,
			      "each segment wears a picture");
			check(!fn_same_picture([detailSwitch imageForSegment:0], [detailSwitch imageForSegment:1]),
			      "and the two are different pictures");
			check([[detailSwitch labelForSegment:0] length] == 0 &&
			      [[detailSwitch labelForSegment:1] length] == 0,
			      "with no words beside them");
			check([detailSwitch frame].size.width < 120.0,
			      "and the control is the width of its pictures, not of two empty label columns");
			check([detailSwitch selectedSegment] == 0, "with the editor showing to begin with");
			check(![[projectWindow editor] isHidden], "the editor is visible");
			check([[projectWindow infoView] isHidden], "and the metadata pane is not");

			[projectWindow showProjectInfo:nil];
			check([detailSwitch selectedSegment] == 1, "Project Info… moves the switch to Info");
			check([[projectWindow editor] isHidden], "the editor stands aside");
			check(![[projectWindow infoView] isHidden], "and the metadata pane is up");

			/* **AND IT FILLS THE PANE IT CAME UP IN.** Both children are built with a frame taken from the content size
			 * before the window exists, and only the visible one is placed — so the metadata pane kept its born 571x390
			 * inside an 852x426 pane, 36 points low and 281 points narrow (MEASURED with `FORGE_LAYOUT_DIAG`). The swap is
			 * what makes a pane visible, so the swap is what places it. */
			{
				NSView *pane = [projectWindow infoView];
				NSRect frame = [pane frame];
				NSRect bounds = [[pane superview] bounds];

				check(fabs((double)(frame.size.width - bounds.size.width)) < 0.5
				      && fabs((double)(frame.size.height - bounds.size.height)) < 0.5,
				      "and it fills the detail pane rather than keeping the frame it was born with");
				check(fabs((double)frame.origin.x) < 0.5 && fabs((double)frame.origin.y) < 0.5,
				      "so the form starts at the top of its pane instead of sitting low in it");
			}

			[detailSwitch setSelectedSegment:0];
			[(id)projectWindow performSelector:@selector(detailSegmentChanged:) withObject:detailSwitch];
			check(![[projectWindow editor] isHidden], "and switching back shows the editor again");
			check([[projectWindow infoView] isHidden], "with the metadata pane put away");
			[projectWindow release];
		}

		[info release];
		[recorder release];
		[manager removeItemAtPath:directory error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
