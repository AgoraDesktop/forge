/*
 * end_to_end — a project that generates a build, builds it, and has a product at the end. No window, no clicks.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THIS IS THE CLAIM THE WHOLE PROJECT LAYER EXISTS TO MAKE.** A manifest names a source; the generator writes the
 * CMake for it; the builder runs the toolchain; the product is where `-productURL` said it would be. If any of the
 * four is wrong the test fails at the door that is wrong, and the README's "an app project is a consumer of the
 * release" stops being an assertion and starts being a measurement.
 *
 * It needs `CMAKE_PREFIX_PATH` to name the installed SDK — ctest passes it — because the generated build resolves
 * `AgoraApp` with `find_package()`, the same way every component in this tree does.
 */
#import "AGBuilder.h"
#import "AGProject.h"

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

/* THE BUILD IS ASYNCHRONOUS — it is a child process read by the run loop — so the test pumps the run loop rather
 * than waiting on a thread. This is the same pump the application runs; nothing here is a test-only path. */
static void fs_pump_until_idle(AGBuilder *builder, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([builder isBuilding] && [deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		[pool release];
	}
}

int main(void)
{
	@autoreleasepool {
		/* **NOT `NSTemporaryDirectory()`, WHICH IS `/System/Temporary Files/` ON THIS MACHINE.** The workspace AGENTS.md
		 * records that directory as world-writable here and absent on a GitHub runner, so a fixture written there
		 * passes locally and fails in CI. `$TMPDIR` when the environment names one, `/tmp` otherwise. */
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-e2e-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *source = [sources stringByAppendingPathComponent:@"main.m"];
		NSURL *URL = [NSURL fileURLWithPath:directory isDirectory:YES];
		AGProject *project;
		AGBuilder *builder;
		NSError *error = nil;
		NSFileManager *manager = [NSFileManager defaultManager];

		/* THE PREFIX IS THE BUILDER'S TO FIND, not this probe's to hand over: `unsetenv` makes the run the same
		 * shape as an application launched from the desktop. */
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"#include <stdio.h>\n\nint main(void)\n{\n\tprintf(\"forge ok\\n\");\n\treturn 0;\n}\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];

		/* AN APPLICATION, SO THE CHAIN IS THE WHOLE CHAIN: the generated build has to lay out the bundle too, or
		 * `-productURL` — which answers a path INSIDE `…app/Contents/<platform>/<arch>/` — has nothing at the end
		 * of it. That is the difference between a tool and an application here, and it is worth measuring. */
		project = [AGProject newProjectAtDirectoryURL:URL name:@"End To End" type:AGProjectTypeApplication
						       error:&error];
		check(project != nil, "the project is created");
		check([project addFileAtAbsolutePath:source error:&error], "the source joins the project");
		check([project writeToURL:URL error:&error], "the manifest is written");

		builder = [[[AGBuilder alloc] initWithProject:project] autorelease];
		check([builder build], "the build starts");
		fs_pump_until_idle(builder, 60.0);
		check(![builder isBuilding], "the build finished");

		check([[[project productURL] path] length] > 0, "the product's location is known");
		check([manager fileExistsAtPath:[[project productURL] path]],
		      "the product exists where -productURL said it would be (inside the .app)");
		check([[[project productURL] path] rangeOfString:@"End_To_End.app/Contents/"].location != NSNotFound,
		      "the product is the bundle's executable, not the bare build output");
		check([[builder diagnostics] count] == 0, "a clean build has no diagnostics");

		/* **AND THE PRODUCT IS A BUNDLE A LAUNCHER CAN OPEN, NOT JUST A FILE.** The manifest's metadata has to reach
		 * `Contents/Info.plist`, the executable has to be where `NSBundle -executablePath` looks, and the bundle has
		 * to be openable by the class that reads it — which is the whole of "a ready-to-run .app". */
		{
			NSString *bundlePath = [[project bundleURL] path];
			NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"];
			NSString *plist = [NSString stringWithContentsOfFile:plistPath encoding:NSUTF8StringEncoding
								      error:NULL];
			NSBundle *bundle;

			check([manager fileExistsAtPath:plistPath], "the bundle carries Contents/Info.plist");
			check(plist != nil && [plist rangeOfString:@"<key>CFBundleIdentifier</key>"].location != NSNotFound,
			      "the plist is the one the manifest generated");
			check([manager fileExistsAtPath:[bundlePath stringByAppendingPathComponent:
				@"Contents/MacOS/End_To_End"]],
			      "the executable is in Contents/MacOS, where NSBundle looks for it");

			bundle = [NSBundle bundleWithPath:bundlePath];
			check(bundle != nil, "NSBundle opens the bundle");
			check([[bundle bundleIdentifier] isEqualToString:[project bundleIdentifier]],
			      "and reads the identifier the manifest carries");
			check([[bundle executablePath] isEqualToString:
				[bundlePath stringByAppendingPathComponent:@"Contents/MacOS/End_To_End"]],
			      "and resolves the executable inside it");
		}

		if (s_failed != 0) {
			printf("---- build output ----\n%s\n----------------------\n", [[builder output] UTF8String]);
		}
		[manager removeItemAtPath:directory error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
