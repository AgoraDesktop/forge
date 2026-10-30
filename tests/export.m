/*
 * export — the built bundle leaves the project, and the verb refuses when there is nothing to send.
 *
 * A build writes `build/<Name>.app`, which is inside a tree that `Clean` deletes; Export copies it where a person says. The
 * panel's only job is to produce a path, so everything after that is `-fn_exportProductToPath:error:` and this probe drives
 * it without a window server — including the two refusals, because "answers before it acts" is the rule every Forge verb
 * follows and a refusal with no reason is the failure the rule exists to prevent.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectWindowController.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>

static int s_failed = 0;
static int s_passed = 0;

static void check(int ok, const char *what)
{
	if (ok) {
		s_passed++;
		printf("  ok     %s\n", what);
	} else {
		s_failed++;
		printf("  FAIL   %s\n", what);
	}
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *scratch = [NSString stringWithFormat:@"%s/forge-export-config",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp"];
		NSString *root = [NSString stringWithFormat:@"%s/forge-export-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSString *projectDirectory = [root stringByAppendingPathComponent:@"Project"];
		AGProject *project;
		AGProjectWindowController *controller;
		NSError *error = nil;

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		setenv("FNX_CONFIG_ROOT", [scratch UTF8String], 1);
		[manager removeItemAtPath:scratch error:NULL];
		[manager createDirectoryAtPath:[scratch stringByAppendingPathComponent:@"Users"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];

		[manager createDirectoryAtPath:[projectDirectory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"int main(void) { return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[projectDirectory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];

		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:projectDirectory isDirectory:YES]
						       name:@"Exported" type:AGProjectTypeApplication error:&error];
		[project addFileAtAbsolutePath:[projectDirectory stringByAppendingPathComponent:@"Sources/main.m"]
					 error:NULL];
		[project writeToURL:[NSURL fileURLWithPath:projectDirectory isDirectory:YES] error:NULL];
		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];

		/* 1. **NO PRODUCT IS A REFUSAL WITH A REASON**, before anything is copied or even asked for a destination. */
		{
			NSString *destination = [root stringByAppendingPathComponent:@"Nowhere.app"];

			error = nil;
			check(![controller fn_productIsExportable],
			      "with nothing built, the verb is not available");
			check(![controller fn_exportProductToPath:destination error:&error],
			      "and the export door refuses");
			check(error != nil, "with a reason on the error");
			check(![manager fileExistsAtPath:destination], "and nothing was written");
		}

		/* 2. A PRODUCT IS EXPORTED WITH EVERYTHING A BUNDLE NEEDS. The bundle is built by hand here rather than by
		 * invoking cmake: what this probe is about is the copy, and `forge-end-to-end` already proves the build. */
		{
			NSString *bundle = [[project bundleURL] path];
			NSString *product = [[project productURL] path];
			NSString *plistPath;
			NSString *destination = [root stringByAppendingPathComponent:@"Exported.app"];
			NSString *copiedProduct;
			NSString *copiedPlist;

			check(bundle != nil && product != nil, "the project names its bundle and its product");
			/* **THE PRODUCT LIVES WHERE `-productURL` SAYS**, which is `Contents/<platform>/<arch>/`, the layout
			 * libagora-core's resolver reads — not `Contents/MacOS`, which is where a probe that guessed would put it. */
			check([manager createDirectoryAtPath:[product stringByDeletingLastPathComponent]
			    withIntermediateDirectories:YES attributes:nil error:NULL],
			      "the product's directory was made");
			check([[@"#!/bin/sh\nexit 0\n" dataUsingEncoding:NSUTF8StringEncoding]
				writeToFile:product atomically:YES], "and the product was written");
			[manager createDirectoryAtPath:[bundle stringByAppendingPathComponent:@"Contents/Resources"]
			    withIntermediateDirectories:YES attributes:nil error:NULL];
			plistPath = [bundle stringByAppendingPathComponent:@"Contents/Info.plist"];
			[[project generatedInfoPlist] writeToFile:plistPath atomically:YES
						    encoding:NSUTF8StringEncoding error:NULL];

			check([controller fn_productIsExportable], "a built product makes the verb available");
			error = nil;
			check([controller fn_exportProductToPath:destination error:&error],
			      "the bundle is exported to the chosen place");
			check(error == nil, "with no error");
			copiedProduct = [destination stringByAppendingPathComponent:
				[product substringFromIndex:[bundle length] + 1]];
			copiedPlist = [destination stringByAppendingPathComponent:@"Contents/Info.plist"];
			check([manager fileExistsAtPath:destination], "a bundle exists where the person asked");
			check([manager fileExistsAtPath:copiedProduct], "with the executable inside it");
			check([manager fileExistsAtPath:copiedPlist], "and the Info.plist the generator wrote");
			check([[controller buildLogText] rangeOfString:@"# Export:"].location != NSNotFound,
			      "and the log says where it went");
			check([[controller buildLogText] rangeOfString:destination].location != NSNotFound,
			      "naming the path that was written");
		}

		/* 3. **AN EXPORT REPLACES WHAT IS THERE RATHER THAN MERGING WITH IT.** A bundle that keeps a file from an older
		 * build is not the application that was just built, and the stale file is the one thing nobody can see. */
		{
			NSString *destination = [root stringByAppendingPathComponent:@"Exported.app"];
			NSString *stale = [destination stringByAppendingPathComponent:@"Contents/Resources/stale.txt"];

			[[@"stale\n" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:stale atomically:YES];
			check([manager fileExistsAtPath:stale], "a stale file was put in the exported bundle");
			check([controller fn_exportProductToPath:destination error:&error], "the bundle is exported again");
			check(![manager fileExistsAtPath:stale], "and the stale file is gone rather than carried over");
			check([manager fileExistsAtPath:[destination stringByAppendingPathComponent:@"Contents/Info.plist"]],
			      "while the bundle itself is there");
		}

		/* 4. A DESTINATION THAT CANNOT BE MADE IS AN ERROR, not a silent success. */
		{
			error = nil;
			check(![controller fn_exportProductToPath:@"/proc/forge-cannot-write.app" error:&error],
			      "a destination that cannot be written is refused");
			check(error != nil, "with the filesystem's own reason");
		}

		/* 5. **AND THE PANEL OPENS IN THE ACCOUNT'S APPLICATION FOLDER.** The choice is one door because that is the
		 * part a probe can hold: `~/Applications` — made when it is not there, because a Forge started without a session
		 * has never had one — and the home itself when it cannot be made. */
		{
			NSString *scratchHome = [root stringByAppendingPathComponent:@"Home"];
			NSString *applications = [scratchHome stringByAppendingPathComponent:@"Applications"];
			NSString *blockedHome = [root stringByAppendingPathComponent:@"Blocked"];

			[manager createDirectoryAtPath:scratchHome withIntermediateDirectories:YES attributes:nil error:NULL];
			check(![manager fileExistsAtPath:applications], "the scratch home has no Applications folder to begin with");
			check([[AGProjectWindowController fn_exportDirectoryForHome:scratchHome] isEqualToString:applications],
			      "an export defaults to ~/Applications");
			check([manager fileExistsAtPath:applications], "and the folder is made when the account has never had one");

			[manager createDirectoryAtPath:blockedHome withIntermediateDirectories:YES attributes:nil error:NULL];
			[[@"not a directory\n" dataUsingEncoding:NSUTF8StringEncoding]
				writeToFile:[blockedHome stringByAppendingPathComponent:@"Applications"] atomically:YES];
			check([[AGProjectWindowController fn_exportDirectoryForHome:blockedHome] isEqualToString:blockedHome],
			      "a home whose Applications is a FILE answers the home rather than a path that is not a folder");
			check([AGProjectWindowController fn_exportDirectoryForHome:nil] == nil,
			      "and no home at all answers nil rather than inventing one");

			[manager removeItemAtPath:blockedHome error:NULL];
			[manager removeItemAtPath:scratchHome error:NULL];
		}

		[controller release];
		[manager removeItemAtPath:root error:NULL];
		[manager removeItemAtPath:scratch error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
