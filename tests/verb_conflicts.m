/*
 * verb_conflicts — a verb pressed while another is running, which is what a person does when a build feels slow.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE REPORT THIS ANSWERS WAS "BUILDING WORKS THE FIRST TIME, THEN FAILS AFTER CLEANING", AND THE FIRST VERSION OF
 * THESE VERBS COULD PRODUCE EXACTLY THAT SHAPE WITHOUT ANYTHING BEING WRONG WITH THE BUILD.** Each verb cleared the
 * log, called the builder and ignored the answer; a Build pressed while a build was still running therefore wiped
 * the log and printed nothing, and a Clean pressed during a build deleted the directory a running `cmake` was
 * writing into. Both are the same defect: an action that cannot run must SAY so rather than pretend.
 *
 * The claims are measured on the log text and on the filesystem, not on internals: the log is what a person reads,
 * and the product on disk is what a build is for.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectWindowController.h"

#import <AppKit/NSApplication.h>
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

/* WAIT FOR A CONDITION THAT IS NOT `-isBuilding`: a running product is not a build, which is the distinction this
 * probe exists to measure. */
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

static NSUInteger count_of(NSString *haystack, NSString *needle)
{
	NSRange range = NSMakeRange(0, [haystack length]);
	NSUInteger count = 0;

	while (range.length > 0) {
		NSRange found = [haystack rangeOfString:needle options:0 range:range];

		if (found.location == NSNotFound) {
			break;
		}
		count++;
		range = NSMakeRange(NSMaxRange(found), [haystack length] - NSMaxRange(found));
	}
	return count;
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-verbs-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *source = [sources stringByAppendingPathComponent:@"main.m"];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		AGBuilder *builder;
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"#include <stdio.h>\nint main(void) { printf(\"verbs ok\\n\"); return 0; }\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Verbs" type:AGProjectTypeTool
						      error:&error];
		check([project addFileAtAbsolutePath:source error:&error], "the source joins the project");
		check([project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:&error],
		      "the manifest is written");

		controller = [[AGProjectWindowController alloc] initWithProject:project];
		builder = [controller builder];

		/* 1. THE ORDINARY BUILD, so everything below is compared against a working one. */
		[controller build:nil];
		pump(builder, 180.0);
		check(![builder isBuilding], "the first build finishes");
		check([manager fileExistsAtPath:[[project productURL] path]], "the first build produces the product");
		{
			NSString *log = [controller buildLogText];

			check(count_of(log, @"% cmake -S") == 1, "one configure ran");
			check(count_of(log, @"# build exited 0") == 1, "the build stage reported its exit");
		}

		/* 2. A SECOND BUILD PRESSED WHILE THE FIRST IS RUNNING IS REFUSED, IN WORDS, AND STARTS NOTHING. */
		[controller build:nil];
		check([builder isBuilding], "the second build starts while the first is still running");
		[controller build:nil];		/* the impatient click */
		{
			NSString *log = [controller buildLogText];

			check(count_of(log, @"# A build is already running") == 1,
			      "the second Build says it was ignored");
			check(count_of(log, @"% cmake -S") == 1,
			      "and it did not clear the log or start a second configure");
		}
		pump(builder, 180.0);
		check(count_of([[controller buildLogText] copy], @"% cmake -S") == 1,
		      "still exactly one configure after the running build finishes");

		/* 3. CLEAN PRESSED DURING A BUILD IS REFUSED, AND THE RUNNING BUILD IS UNAFFECTED. */
		[manager removeItemAtPath:[[project productURL] path] error:NULL];
		[controller build:nil];
		check([builder isBuilding], "a third build starts");
		[controller clean:nil];		/* delete the build directory under a running compiler */
		check(count_of([controller buildLogText], @"# A build is running; Clean was ignored") == 1,
		      "the Clean says it was ignored");
		pump(builder, 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "the build that Clean tried to interrupt still produced its product");
		check([manager fileExistsAtPath:[[project buildDirectoryURL] path]],
		      "the build directory is still there");

		/* 4. AND A CLEAN ONCE THE BUILD HAS FINISHED IS THE CLEAN THAT WORKS. */
		[controller clean:nil];
		check(![manager fileExistsAtPath:[[project buildDirectoryURL] path]],
		      "a Clean with nothing running removes the build directory");
		check(count_of([controller buildLogText], @"# The build directory was removed") == 1,
		      "and says so");

		/* 5. AFTER THAT CLEAN, A BUILD WORKS AGAIN — the sequence the report was about. */
		[controller build:nil];
		pump(builder, 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "a build after a clean produces the product again");

		/* 6. **A RUNNING PRODUCT IS NOT A BUILD.** The product is this builder's child process too, so `-isBuilding`
		 * used to answer YES for as long as the product was open — and every verb was refused with "a build is
		 * running" when nothing was building. The product here sleeps, so the window is real rather than a race. */
		[@"#include <unistd.h>\nint main(void) { sleep(2); return 0; }\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		[controller build:nil];
		pump(builder, 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]], "the sleeping product is built");

		[controller run:nil];
		check([builder isRunningProduct], "the product is running");
		check(![builder isBuilding], "a running product is NOT a build");

		{
			NSUInteger before = count_of([controller buildLogText], @"# The built product is still running");

			[controller build:nil];
			check(count_of([controller buildLogText], @"# The built product is still running") == before + 1,
			      "Build says the PRODUCT is running, rather than pretending a build is");
			[controller clean:nil];
			check(count_of([controller buildLogText], @"# The built product is still running") == before + 2,
			      "Clean says the same");
			[controller run:nil];
			check(count_of([controller buildLogText], @"# The product is already running.") == 1,
			      "and Run says the product is already up");
			/* THE LOG WAS CLEARED BY THE BUILD ABOVE, so the count here is of THIS window's refusals only: none
			 * of them may say "a build is running" while the only live thing is the product. */
			check(count_of([controller buildLogText], @"# A build is already running") == 0,
			      "no verb claimed a build was running when none was");
		}

		/* **AND STOP ENDS IT WITHOUT WAITING FOR THE PRODUCT'S OWN TIMING.** The window must never be trapped by a
		 * program whose window is behind this one: Stop terminates the child, and the verbs work again. */
		[controller stop:nil];
		check(count_of([controller buildLogText], @"# Stopping the product") == 1,
		      "Stop says what it is stopping");
		wait_until(^int { return ![builder isRunningProduct]; }, 30.0);
		check(![builder isRunningProduct], "the product is gone after Stop");
		check(![builder isBuilding], "and nothing is left marked as building");
		check(count_of([controller buildLogText], @"# run exited") >= 1, "the run stage reported its exit");

		/* **AND THE LOG IS ASCII.** Every line this application writes has to be readable in a pane whose drawing of a
		 * non-ASCII character is, at the time of writing, wrong: the storage and the layout are right and the raster is
		 * not (`AGBuilder -stop` records the measurement). A message with an ellipsis or a Command symbol in it therefore
		 * draws as mojibake and a truncated line, which is precisely how this test came to exist. */
		check([[controller buildLogText] canBeConvertedToEncoding:NSASCIIStringEncoding],
		      "every line the application wrote is ASCII");

		/* STOP WITH NOTHING RUNNING IS ANSWERED, NOT IGNORED. */
		[controller stop:nil];
		check(count_of([controller buildLogText], @"# Nothing is running.") == 1,
		      "Stop with nothing running says so");

		/* AND A BUILD STOPPED PART WAY LEAVES THE WINDOW USABLE — the second way into the trap. */
		[controller build:nil];
		[controller stop:nil];
		wait_until(^int { return ![builder isBuilding]; }, 30.0);
		check(![builder isBuilding], "a stopped build leaves nothing marked as building");
		[controller build:nil];
		pump(builder, 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "a build works again after a stopped build");

		/* AND THE VERBS WORK AGAIN, which is the thing a person notices. */
		[controller build:nil];
		pump(builder, 180.0);
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "a build after the product exits works again");

		if (s_failed != 0) {
			printf("---- log ----\n%s\n-------------\n", [[controller buildLogText] UTF8String]);
		}
		[manager removeItemAtPath:directory error:NULL];
		[controller release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
