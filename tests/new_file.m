/*
 * new_file — the half of "Add" that CREATES a file.
 *
 * The open panel can only choose what already exists, so a project could never gain a fourth file: pressing Add listed
 * what was there. `-fn_createFileAtPath:error:` is everything after the panel picks a name — the skeleton the type asks
 * for, the manifest entry, the manifest write, the browser reload and the file left open in the editor — and this probe
 * drives it without a window server.
 */
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

static NSString *fn_contents(NSString *path)
{
	NSData *data = [NSData dataWithContentsOfFile:path];

	return (data != nil) ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *scratch = [NSString stringWithFormat:@"%s/forge-newfile-config",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp"];
		NSString *directory = [NSString stringWithFormat:@"%s/forge-newfile-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		NSError *error = nil;
		NSString *source;
		NSString *header;

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		/* THE DEFAULTS STORE'S ROOT: the panes save their divider positions as the window is built. */
		setenv("FNX_CONFIG_ROOT", [scratch UTF8String], 1);
		[manager removeItemAtPath:scratch error:NULL];
		[manager createDirectoryAtPath:[scratch stringByAppendingPathComponent:@"Users"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];

		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"int main(void) { return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];
		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Headers"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];

		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Files" type:AGProjectTypeTool error:&error];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL];
		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];

		/* 1. A NEW SOURCE IS WRITTEN WITH A SKELETON, not as an empty file a compiler rejects. */
		source = [directory stringByAppendingPathComponent:@"Sources/Extra.m"];
		error = nil;
		check([controller fn_createFileAtPath:source error:&error], "a new .m file is created");
		check([manager fileExistsAtPath:source], "and it is on disk");
		check([fn_contents(source) rangeOfString:@"int main(void)"].location != NSNotFound,
		      "with a translation unit in it rather than nothing");
		check(error == nil, "with no error");

		/* 1b. **THE PROJECT STILL KNOWS WHERE IT LIVES.** `-writeToURL:` re-points the directory URL, and the obvious
		 * save — `[project writeToURL:[project projectDirectoryURL] error:NULL]` — used to hand it that URL and then
		 * release it: every add after the first was refused as "outside the project directory". */
		check([project projectDirectoryURL] != nil, "the project still knows its directory after a save");
		check([[[project projectDirectoryURL] path] length] > 0, "and the path it knows is a path");

		/* 1c. **THE TITLE'S SEPARATOR IS ONE CHARACTER, NOT ITSUTF-8 BYTES.** A format string's literal chunk used to reach
		 * the sink a byte at a time, so the em dash between the parts arrived as `â` and two boxes. What this asserts is the
		 * character: the title carries U+2014 twice, once on each side of the file's name. */
		{
			NSString *title = [[controller window] title];
			NSUInteger i, dashes = 0;

			check([title length] > 0, "the window has a title after opening the file");
			check([title rangeOfString:@"Extra.m"].location != NSNotFound,
			      "and the title names the file that is open");
			for (i = 0; i < [title length]; i++) {
				if ([title characterAtIndex:i] == 0x2014) {
					dashes++;
				}
			}
			check(dashes == 2, "and its two separators are em dashes, not the bytes of one");
			check([title canBeConvertedToEncoding:NSASCIIStringEncoding] == NO,
			      "which is why the title is not ASCII any more");
		}

		/* 2. IT IS IN THE MANIFEST, and the manifest on disk says so too. */
		{
			NSUInteger i;
			BOOL found = NO;

			for (i = 0; i < [[project files] count]; i++) {
				if ([[[project files] objectAtIndex:i] relativePath] != nil
				    && [[[[project files] objectAtIndex:i] relativePath] isEqualToString:@"Sources/Extra.m"]) {
					found = YES;
				}
			}
			check(found, "the file joined the project");
			check([fn_contents([directory stringByAppendingPathComponent:@"Project.agproj"])
				rangeOfString:@"Sources/Extra.m"].location != NSNotFound,
			      "and the manifest on disk records it");
		}

		/* 3. A HEADER GETS A GUARD, because a header with no guard is a header that cannot be included twice. */
		header = [directory stringByAppendingPathComponent:@"Headers/Extra.h"];
		check([controller fn_createFileAtPath:header error:&error], "a new .h file is created");
		check([fn_contents(header) rangeOfString:@"#ifndef"].location != NSNotFound,
		      "and it opens with a guard");

		/* 4. AN UNKNOWN TYPE IS CREATED EMPTY, which is the only honest answer for a type this program does not know. */
		{
			NSString *other = [directory stringByAppendingPathComponent:@"notes.txt"];

			check([controller fn_createFileAtPath:other error:&error], "a file of an unknown type is created");
			check([fn_contents(other) length] == 0, "and it is empty");
		}

		/* 5. **A PATH OUTSIDE THE PROJECT IS REFUSED**, so the manifest never names what it cannot carry. */
		{
			NSString *outside = [NSString stringWithFormat:@"%s/forge-newfile-outside-%d.m",
				(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];

			error = nil;
			check(![controller fn_createFileAtPath:outside error:&error],
			      "a file outside the project is refused");
			check(error != nil, "and the refusal says why");
			check(![manager fileExistsAtPath:outside],
			      "and nothing was written there before the refusal");
			[manager removeItemAtPath:outside error:NULL];
		}

		[controller release];
		[manager removeItemAtPath:directory error:NULL];
		[manager removeItemAtPath:scratch error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
