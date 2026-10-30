/*
 * remove_file — taking a name off the manifest, which is not deleting the file.
 *
 * The browser's selection is the subject of the verb; `-fn_removeFile:error:` is the same work for a named file, so this
 * probe needs no browser for most of its claims. What is asserted is the pair that matters: the file leaves the project and
 * stays on disk, and the window stops claiming it was open.
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

/* THE MANIFEST ON DISK, as text: what "the project no longer carries it" means after a relaunch. */
static NSString *fn_manifest(NSString *directory)
{
	NSData *data = [NSData dataWithContentsOfFile:
		[directory stringByAppendingPathComponent:@"Project.agproj"]];

	return (data != nil) ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *scratch = [NSString stringWithFormat:@"%s/forge-remove-config",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp"];
		NSString *directory = [NSString stringWithFormat:@"%s/forge-remove-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		AGProjectFile *kept = nil;
		AGProjectFile *doomed = nil;
		NSError *error = nil;
		NSUInteger i;

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		setenv("AGORA_CONFIG_ROOT", [scratch UTF8String], 1);
		[manager removeItemAtPath:scratch error:NULL];
		[manager createDirectoryAtPath:[scratch stringByAppendingPathComponent:@"Users"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];

		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Notes"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"int main(void) { return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];
		[[@"// a note\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Notes/Note.h"] atomically:YES];

		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Remove" type:AGProjectTypeTool error:&error];
		[project addFileAtAbsolutePath:[directory stringByAppendingPathComponent:@"Sources/main.m"] error:NULL];
		[project addFileAtAbsolutePath:[directory stringByAppendingPathComponent:@"Notes/Note.h"] error:NULL];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL];
		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];

		for (i = 0; i < [[project files] count]; i++) {
			AGProjectFile *file = [[project files] objectAtIndex:i];

			if ([[file relativePath] isEqualToString:@"Notes/Note.h"]) {
				doomed = [file retain];
			} else {
				kept = [file retain];
			}
		}
		check(doomed != nil && kept != nil, "the project carries two files to tell apart");

		/* 1. NOTHING NAMED IS A REFUSAL WITH A REASON, before anything is written. */
		{
			error = nil;
			check(![controller fn_removeFile:nil error:&error], "removing nothing is refused");
			check(error != nil, "with a reason on the error");
		}

		/* 2. **THE FILE LEAVES THE PROJECT AND STAYS ON DISK.** That pair is what makes this a project edit rather than a
		 * delete, and the log says so in words. */
		{
			NSString *path = [directory stringByAppendingPathComponent:@"Notes/Note.h"];

			error = nil;
			check([controller fn_removeFile:doomed error:&error], "the selected file is removed from the project");
			check(error == nil, "with no error");
			check([[project files] count] == 1, "the manifest holds one file now");
			check([[[[project files] objectAtIndex:0] relativePath] isEqualToString:@"Sources/main.m"],
			      "and the file that stayed is the one that stayed");
			check([manager fileExistsAtPath:path], "the file itself is still on disk");
			check([fn_manifest(directory) rangeOfString:@"Notes/Note.h"].location == NSNotFound,
			      "the manifest on disk no longer names it");
			check([fn_manifest(directory) rangeOfString:@"Sources/main.m"].location != NSNotFound,
			      "while the file that stayed is still named");
			check([[controller buildLogText] rangeOfString:@"# Removed: Notes/Note.h"].location != NSNotFound,
			      "and the log says what was removed");
			check([[controller buildLogText] rangeOfString:@"still on disk"].location != NSNotFound,
			      "including that the file was not deleted");
		}

		/* 3. **AN EMPTY CATEGORY GOES WITH ITS LAST FILE**, because the browser is built from the project's categories. */
		{
			NSArray *categories = [project categories];

			check([categories containsObject:@"Notes"] == NO,
			      "the category the removed file was alone in is gone");
			check([categories containsObject:@"Sources"], "while the one that still has a file is there");
		}

		/* 4. A FILE THAT IS NOT A MEMBER IS REFUSED RATHER THAN SILENTLY IGNORED. */
		{
			AGProjectFile *stranger = [AGProjectFile fileWithRelativePath:@"Nowhere/Gone.h"];

			error = nil;
			check(![controller fn_removeFile:stranger error:&error],
			      "a file the project does not carry cannot be removed from it");
			check(error != nil, "and the refusal says why");
		}

		/* 5. **THE TOOLBAR HAS THE ITEM, AND ITS ANSWER COMES FROM THE SELECTION.** The item is found the way the toolbar
		 * finds it, and validation is asked of the controller, which is what the button's own pass does. */
		{
			NSArray *items = [[[controller window] toolbar] items];
			NSToolbarItem *remove = nil;
			NSUInteger k;

			for (k = 0; k < [items count]; k++) {
				if ([[[items objectAtIndex:k] itemIdentifier] isEqualToString:@"AGToolbarRemoveFile"]) {
					remove = [items objectAtIndex:k];
				}
			}
			check(remove != nil, "the toolbar carries a Remove File item");
			check(remove != nil && [[remove label] isEqualToString:@"Remove"], "labelled Remove");
			check(remove != nil && [controller validateToolbarItem:remove] == NO,
			      "and it is not offered while the browser has nothing selected");

			/* **AND THE ITEM'S PRESS IS THE VERB.** Selecting the row a person would select is what enables it, and firing
			 * the item's own action is what a click does — the one link a screenshot cannot prove. */
			if (remove != nil) {
				NSOutlineView *browser = [controller browserOutline];
				NSInteger row, target = -1;

				for (row = 0; row < [browser numberOfRows]; row++) {
					id item = [browser itemAtRow:row];

					if ([item isKindOfClass:[AGProjectFile class]]
					    && [[item relativePath] isEqualToString:@"Sources/main.m"]) {
						target = row;
					}
				}
				check(target >= 0, "the file that is left is a row in the browser");
				if (target >= 0) {
					[browser selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)target]
					     byExtendingSelection:NO];
					check([controller validateToolbarItem:remove],
					      "selecting a file offers Remove");
					[[remove target] performSelector:[remove action] withObject:remove];
					check([[project files] count] == 0,
					      "and pressing it removes that file from the project");
					check([manager fileExistsAtPath:
						[directory stringByAppendingPathComponent:@"Sources/main.m"]],
					      "while the file itself is still on disk");
				}
			}
		}

		[doomed release];
		[kept release];
		[controller release];
		[manager removeItemAtPath:directory error:NULL];
		[manager removeItemAtPath:scratch error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
