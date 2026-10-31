/*
 * toolbar_state — a verb's button says whether it can do anything.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A BUTTON THAT WOULD BE REFUSED IN THE LOG SHOULD BE GREY INSTEAD.** Run on an unbuilt project, Clean on a clean one and
 * Stop on nothing are all states the verbs already refuse in words; the toolbar answering the same question beforehand is
 * what stops a person learning it by clicking. The rules are the controller's `-validateToolbarItem:` — this probe drives
 * the real window through build → run → stop → clean and reads each item's `-isEnabled` after the validation pass the
 * controller asks for.
 *
 * It is one process and one project, because the states are SEQUENCES: a product has to exist before Run is usable, and
 * has to be running before Stop is.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectInfoView.h"
#import "AGProjectWindowController.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSToolbar.h>
#import <AppKit/NSToolbarItem.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int s_failed;

/* **THE APPLICATION'S TWO NEW VERBS, STOOD IN FOR BY THIS PROBE.** `-itemForItemIdentifier:` targets the application's
 * DELEGATE for New and Open — as every row Forge builds names its target — so a probe that builds a window with no
 * delegate would be asking about a button with no verb behind it. The selectors are the contract being measured; nothing
 * here runs them. */
@interface AGToolbarStandIn : NSObject
- (void)newProject:(id)sender;
- (void)openProject:(id)sender;
@end

@implementation AGToolbarStandIn
- (void)newProject:(id)sender { (void)sender; }
- (void)openProject:(id)sender { (void)sender; }
@end

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

static void pump(AGBuilder *builder, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([builder isBuilding] && [deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		[pool release];
	}
}

static void wait_until(int (^done)(void), double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while (!done() && [deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		[pool release];
	}
}

/* **THE ITEM'S OWN ANSWER, WITH NOBODY ASKING FOR A PASS FIRST.** That is the claim: the toolbar reflects the state by
 * itself — every verb and every finished stage asks for the validation, so a probe that called `-refreshToolbarState`
 * here would be measuring its own call rather than the application's. MEASURED: it hid a completed build that never told
 * the toolbar anything, and the band stayed grey over a project that had just built. */
static BOOL item_enabled(AGProjectWindowController *controller, NSString *identifier)
{
	NSToolbar *toolbar = [[controller window] toolbar];
	NSArray *items = [toolbar items];
	NSUInteger i;

	for (i = 0; i < [items count]; i++) {
		NSToolbarItem *item = [items objectAtIndex:i];

		if ([[item itemIdentifier] isEqualToString:identifier]) {
			return [item isEnabled];
		}
	}
	return NO;
}

int main(void)
{
	@autoreleasepool {
		AGToolbarStandIn *standIn = [[AGToolbarStandIn alloc] init];
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-toolbar-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *source = [sources stringByAppendingPathComponent:@"main.m"];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSURL *URL = [NSURL fileURLWithPath:directory isDirectory:YES];
		AGProject *project;
		AGProjectWindowController *controller;
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		/* A PRODUCT THAT STAYS UP LONG ENOUGH TO BE RUNNING: the point of the run/stop pair. */
		[@"#include <unistd.h>\nint main(void) { sleep(3); return 0; }\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		project = [AGProject newProjectAtDirectoryURL:URL name:@"Toolbar" type:AGProjectTypeTool
						       error:&error];
		[project addFileAtAbsolutePath:source error:NULL];
		[project writeToURL:URL error:NULL];
		[[NSApplication sharedApplication] setDelegate:standIn];
		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];

		/* 0. **THE ORDER IS PART OF THE DESIGN**: the two verbs that make or open a project come first — nothing else can
		 * mean anything until one exists — then the four groups, then the flexible space that pushes the mode switch to
		 * the right edge. */
		{
			NSArray *items = [[[controller window] toolbar] items];
			/* **THE PROJECT FIRST, THEN THE RESULT.** New and Open make a project or bring one in; Add and Remove act on
			 * the project's file list; then the pairs that act on the BUILD and the PRODUCT — what acts, and what undoes
			 * it — and Export last, because it is the only row that takes the result out rather than changing it. The fill
			 * space puts the mode switch at the right edge. */
			NSArray *wanted = [NSArray arrayWithObjects:
				@"AGToolbarNewProject", @"AGToolbarOpenProject", NSToolbarSeparatorItemIdentifier,
				@"AGToolbarAddFiles", @"AGToolbarRemoveFile", NSToolbarSeparatorItemIdentifier,
				@"AGToolbarBuild", @"AGToolbarClean", NSToolbarSeparatorItemIdentifier,
				@"AGToolbarRun", @"AGToolbarStop", NSToolbarSeparatorItemIdentifier,
				@"AGToolbarExport", NSToolbarFlexibleSpaceItemIdentifier,
				@"AGToolbarDetail", nil];
			NSUInteger i;
			BOOL matches = ([items count] == [wanted count]);

			for (i = 0; matches && i < [items count]; i++) {
				matches = [[[items objectAtIndex:i] itemIdentifier] isEqualToString:[wanted objectAtIndex:i]];
			}
			if (!matches) {
				NSMutableArray *got = [NSMutableArray array];

				for (i = 0; i < [items count]; i++) {
					[got addObject:[[items objectAtIndex:i] itemIdentifier]];
				}
				printf("       toolbar order: %s\n", [[got componentsJoinedByString:@", "] UTF8String]);
			}
			check(matches, "the toolbar is New, Open | Add, Remove | Build, Clean | Run, Stop | Export, space, the mode switch");
		}

		/* 0b. **AND THE TWO NEW ROWS ARE THE APPLICATION'S VERBS, NAMED AND ROUTED LIKE THE FILE MENU'S.** A project
		 * window edits the project it was given; making one or opening one belongs to the application, so the item's
		 * action is the delegate's and its label is what the band shows. The PICTURE is the system's symbol (`file-plus`,
		 * `folder-open` from the Tabler theme) and a machine without that theme gets the row as a label, which is what
		 * the band does with any item that has none — so what is asserted here is the verb and the word, not the ink. */
		{
			NSArray *items = [[[controller window] toolbar] items];
			NSUInteger i;
			BOOL newOK = NO, openOK = NO;

			for (i = 0; i < [items count]; i++) {
				NSToolbarItem *item = [items objectAtIndex:i];

				if ([[item itemIdentifier] isEqualToString:@"AGToolbarNewProject"]) {
					newOK = [[item label] isEqualToString:@"New"] &&
						sel_isEqual([item action], @selector(newProject:));
				}
				if ([[item itemIdentifier] isEqualToString:@"AGToolbarOpenProject"]) {
					openOK = [[item label] isEqualToString:@"Open"] &&
						sel_isEqual([item action], @selector(openProject:));
				}
			}
			check(newOK, "the first row says New and names the application's -newProject:");
			{
				BOOL targeted = YES;
				for (i = 0; i < [items count]; i++) {
					NSToolbarItem *item = [items objectAtIndex:i];

					if ([[item itemIdentifier] isEqualToString:@"AGToolbarNewProject"] ||
					    [[item itemIdentifier] isEqualToString:@"AGToolbarOpenProject"]) {
						targeted = targeted && [item target] == standIn;
					}
				}
				check(targeted, "and both are TARGETED at the application's delegate, which is where the verb lives");
			}
			check(openOK, "and the second is Open Project, naming -openProject:");
			check(item_enabled(controller, @"AGToolbarNewProject") &&
			      item_enabled(controller, @"AGToolbarOpenProject"),
			      "both are enabled: they never depend on what this window has built");
		}

		/* 1. NOTHING BUILT: Build is the only verb that can do anything. */
		check(item_enabled(controller, @"AGToolbarBuild"), "on an unbuilt project, Build is enabled");
		check(!item_enabled(controller, @"AGToolbarRun"), "Run is disabled: there is no product");
		check(!item_enabled(controller, @"AGToolbarClean"), "Clean is disabled: there is nothing to clean");
		check(!item_enabled(controller, @"AGToolbarStop"), "Stop is disabled: nothing is running");

		/* 2. BUILT: Run and Clean both have something to act on. */
		[controller build:nil];
		pump([controller builder], 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]], "the build produced its product");
		check(item_enabled(controller, @"AGToolbarRun"), "after a build, Run is enabled");
		check(item_enabled(controller, @"AGToolbarClean"), "and Clean has a build directory to remove");
		check(!item_enabled(controller, @"AGToolbarStop"), "while Stop still has nothing to stop");

		/* 3. RUNNING: Run and Clean stand aside, Stop is the verb that applies. */
		[controller run:nil];
		check([[controller builder] isRunningProduct], "the product is running");
		check(!item_enabled(controller, @"AGToolbarRun"), "while it runs, Run is disabled");
		check(!item_enabled(controller, @"AGToolbarClean"),
		      "and Clean would delete the product under it, so it is disabled too");
		/* **BUILD STANDS ASIDE TOO, BECAUSE THE BUILDER HAS ONE CHILD SLOT.** A build while a product runs would have to
		 * read two pipes at once, which this class cannot; the verb refuses it in the log, so the button says so first. */
		check(!item_enabled(controller, @"AGToolbarBuild"), "and Build stands aside while the product holds the builder");
		check(item_enabled(controller, @"AGToolbarStop"), "and Stop is enabled, because something is running");

		/* 4. STOPPED: back to the built state, with Stop greyed again. */
		[controller stop:nil];
		wait_until(^int { return ![[controller builder] isRunningProduct]; }, 30.0);
		check(item_enabled(controller, @"AGToolbarRun"), "after Stop, Run is enabled again");
		check(!item_enabled(controller, @"AGToolbarStop"), "and Stop is greyed");

		/* 5. CLEANED: both Run and Clean have nothing to act on. */
		[controller clean:nil];
		check(!item_enabled(controller, @"AGToolbarClean"), "after Clean, Clean is disabled");
		check(!item_enabled(controller, @"AGToolbarRun"), "and Run is disabled, because the product is gone");
		check(item_enabled(controller, @"AGToolbarBuild"), "while Build is enabled to make it again");

		[manager removeItemAtPath:directory error:NULL];
		[controller release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
