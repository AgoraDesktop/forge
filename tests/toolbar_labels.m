/*
 * toolbar_labels.m — the View menu's "Show Toolbar Labels" and the tick that agrees with it.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE WORDS UNDER A VERB ARE A PREFERENCE, AND THE ROW THAT FLIPS IT HAS TO SAY WHICH WAY IT IS.** `NSToolbar` already
 * speaks for this — `NSToolbarDisplayModeIconAndLabel` is a verb with its word, `NSToolbarDisplayModeIconOnly` is the word
 * gone — so the work is three things this file pins:
 *
 *   1. a window whose person has never chosen DRAWS THE LABELS (the default, because that is what the band has always
 *      done, and a preference nobody has touched must not silently change the look of the application);
 *   2. turning them off changes the toolbar's display mode, and a SECOND window built afterwards starts the way the first
 *      one ended, which is what makes it a remembered choice rather than a per-window one;
 *   3. the menu row's state is ON exactly while the labels are showing, so the tick is a fact about the preference and not
 *      about the last time the row was pressed.
 *
 * Offscreen: a scratch defaults root, so the probe neither reads a person's choice nor writes its own into it.
 */
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#import "AGProject.h"
#import "AGProjectWindowController.h"

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

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *scratch = [NSString stringWithFormat:@"%s/forge-labels-config", (tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp"];
		NSString *directory = [NSString stringWithFormat:@"%s/forge-labels-%d", (tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *first;
		AGProjectWindowController *second;
		NSMenuItem *row;
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		setenv("AGORA_CONFIG_ROOT", [scratch UTF8String], 1);
		[manager removeItemAtPath:scratch error:NULL];
		[manager createDirectoryAtPath:[scratch stringByAppendingPathComponent:@"home"] withIntermediateDirectories:YES
				    attributes:nil error:NULL];

		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"int main(void) { return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];
		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Labels" type:AGProjectTypeTool error:&error];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL];

		/* 1. **A WINDOW NOBODY HAS TOLD ANYTHING DRAWS THE LABELS.** */
		check([AGProjectWindowController fn_toolbarLabelsVisible],
		      "the toolbars' labels are ON for a person who has never chosen");
		first = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[first window];
		check([[[first window] toolbar] displayMode] == NSToolbarDisplayModeIconAndLabel,
		      "and a window made now draws icon AND label");

		/* AND THE ROW SAYS SO. A row with no state is the case a person reads as "off". */
		row = [[NSMenuItem alloc] initWithTitle:@"Show Toolbar Labels" action:@selector(toggleToolbarLabels:)
					  keyEquivalent:@""];
		[row setTarget:first];
		[AGProjectWindowController fn_showToolbarLabelsStateOn:row];
		check([row state] == NSOnState, "the menu row is TICKED while the labels are showing");

		/* 2. **TURNED OFF, IT IS THE TOOLBAR'S OWN DISPLAY MODE.** */
		[AGProjectWindowController fn_setToolbarLabelsVisible:NO];
		[first fn_applyToolbarLabels];
		check([[[first window] toolbar] displayMode] == NSToolbarDisplayModeIconOnly,
		      "turning them off makes the toolbar draw the icon ALONE");
		[AGProjectWindowController fn_showToolbarLabelsStateOn:row];
		check([row state] == NSOffState, "and the menu row loses its tick");

		/* **AND A WINDOW MADE AFTERWARDS STARTS THE WAY THE LAST PRESS LEFT IT** — the preference, not a per-window flag. */
		second = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[second window];
		check([[[second window] toolbar] displayMode] == NSToolbarDisplayModeIconOnly,
		      "a SECOND window is made without labels, which is what remembering the choice means");

		/* 3. **AND BACK ON IS THE SAME DOOR THE OTHER WAY.** */
		[AGProjectWindowController fn_setToolbarLabelsVisible:YES];
		[second fn_applyToolbarLabels];
		[first fn_applyToolbarLabels];
		check([[[second window] toolbar] displayMode] == NSToolbarDisplayModeIconAndLabel &&
		      [[[first window] toolbar] displayMode] == NSToolbarDisplayModeIconAndLabel,
		      "turning them back on restores both windows, because the door applies the stored answer");
		[AGProjectWindowController fn_showToolbarLabelsStateOn:row];
		check([row state] == NSOnState, "and the tick comes back with them");

		[row release];
		[second release];
		[first release];
		[manager removeItemAtPath:directory error:NULL];
		[manager removeItemAtPath:scratch error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
