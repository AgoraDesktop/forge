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
		check([[[info iconLabel] stringValue] isEqualToString:@"(none)"], "and the icon says there is none");

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

		/* 4. REVERT DROPS WHAT WAS TYPED AND SHOWS THE PROJECT AGAIN. */
		[[info versionField] setStringValue:@"9.9.9"];
		[info revert:nil];
		check([[info versionField].stringValue isEqualToString:@"3.0.0"], "Revert put the project's version back");

		/* 5. **AND IT IS A PANE OF THE PROJECT WINDOW, SWAPPED WITH THE EDITOR BY A SEGMENTED CONTROL.** The claim is
		 * the visibility pair: one of the two is on at a time, and neither is thrown away — which is what keeps an open
		 * file and a half-typed identifier alive across a look at the other. */
		{
			AGProjectWindowController *projectWindow = [[AGProjectWindowController alloc] initWithProject:project];
			NSSegmentedControl *detailSwitch = [projectWindow detailSwitch];

			check(detailSwitch != nil, "the window has the detail switch");
			check([detailSwitch segmentCount] == 2, "with two segments");
			check([[detailSwitch labelForSegment:0] isEqualToString:@"Code"], "Code first");
			check([[detailSwitch labelForSegment:1] isEqualToString:@"Info"], "and Info second");
			check([detailSwitch selectedSegment] == 0, "with the editor showing to begin with");
			check(![[projectWindow editor] isHidden], "the editor is visible");
			check([[projectWindow infoView] isHidden], "and the metadata pane is not");

			[projectWindow showProjectInfo:nil];
			check([detailSwitch selectedSegment] == 1, "Project Info… moves the switch to Info");
			check([[projectWindow editor] isHidden], "the editor stands aside");
			check(![[projectWindow infoView] isHidden], "and the metadata pane is up");

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
