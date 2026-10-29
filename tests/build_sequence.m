/*
 * build_sequence — Build, Clean, Build in ONE process, which is the sequence a person performs and a shell does not.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **`tests/end_to_end.m` RUNS EACH VERB IN ITS OWN PROCESS, AND A PROJECT WINDOW DOES NOT.** The first session's
 * failure report — "building works the first time, then fails after cleaning" — is a statement about state that
 * survives between verbs: the builder's `_buildInFlight`, its poll timer, the generated build on disk, and what
 * `-clean:` leaves behind. So this probe drives the WINDOW CONTROLLER, in one process, in that order, and reads the
 * builder's own log when a stage fails.
 *
 * It needs no window server: the window is made and never shown, and the builder is a child process either way.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectWindowController.h"

#import <AppKit/NSApplication.h>
#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

static int s_failed;

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

static void drain_events(void)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.2];

	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
		[pool release];
	}
}

static void report(AGBuilder *builder, const char *stage)
{
	printf("---- %s log ----\n%s\n---------------\n", stage, [[builder output] UTF8String]);
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-seq-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *source = [sources stringByAppendingPathComponent:@"main.m"];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		AGBuilder *builder;
		NSError *error = nil;
		NSApplication *application = [NSApplication sharedApplication];

		(void)[application finishLaunching];
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"#include <stdio.h>\nint main(void) { printf(\"seq ok\\n\"); return 0; }\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];

		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Sequence" type:AGProjectTypeTool
						      error:&error];
		check(project != nil, "the project is created");
		check([project addFileAtAbsolutePath:source error:&error], "the source joins the project");
		check([project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:&error],
		      "the manifest is written");

		controller = [[AGProjectWindowController alloc] initWithProject:project];
		builder = [controller builder];

		/* 1. BUILD. */
		[controller build:nil];
		pump(builder, 180.0);
		drain_events();
		if (![manager fileExistsAtPath:[[project productURL] path]]) {
			report(builder, "first build");
		}
		check([[project productURL] path] != nil && [manager fileExistsAtPath:[[project productURL] path]],
		      "the first build produces the product");

		/* 2. CLEAN. */
		[controller clean:nil];
		drain_events();
		check(![manager fileExistsAtPath:[[project buildDirectoryURL] path]],
		      "the clean removes the build directory");

		/* 3. BUILD AGAIN — THE SEQUENCE THE REPORT IS ABOUT. */
		[controller build:nil];
		pump(builder, 180.0);
		drain_events();
		if (![manager fileExistsAtPath:[[project productURL] path]]) {
			report(builder, "build after clean");
		}
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "a build after a clean produces the product again");
		check(![builder isBuilding], "the builder is idle again after the second build");

		[manager removeItemAtPath:directory error:NULL];
		[controller release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
