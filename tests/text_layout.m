/*
 * text_layout — the last row of text is ON the screen, in the editor and in the log.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE DEFECT THIS MEASURES WAS A DOCUMENT ONE INCH TOO SHORT, IN TWO PLACES, FOR TWO DIFFERENT REASONS.** The
 * editor computed its document height from `-usedRectForTextContainer:` alone, dropping the view's own
 * `-textContainerInset` — so the last line of every file sat below the document's bottom edge and could not be
 * scrolled into view. The log appended by poking the text storage, which does not ask the view to re-height itself
 * (only the view's OWN edit does that), so its document stayed the height the pane was born with and the last line
 * was cut and unreachable.
 *
 * The claim is a rectangle, not an intention: the last line's fragment, converted through the view's container
 * origin, has to end at or above the document's bottom edge, and — after the log's own `-scrollRangeToVisible:` —
 * inside the clip view that shows it. The first version of that arithmetic is in `AGSourceEditor -fn_placeScrollView`
 * and its comment records why it is the text system's answer rather than this file's.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectWindowController.h"
#import "AGSourceEditor.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSClipView.h>
#import <AppKit/NSLayoutManager.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSTextView.h>
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

/* THE MEASUREMENT, in one place because both panes make the same claim: the document is tall enough for its last
 * line, and the last line's rect ends at or above the document's own bottom edge. */
static BOOL last_line_fits(NSTextView *view, double *outShortfall)
{
	NSLayoutManager *layoutManager = [view layoutManager];
	NSTextContainer *container = [view textContainer];
	NSSize inset = [view textContainerInset];
	NSRect used;
	NSUInteger glyphCount = [layoutManager numberOfGlyphs];
	NSRect last;

	if (layoutManager == nil || container == nil || glyphCount == 0) {
		if (outShortfall != NULL) {
			*outShortfall = 0.0;
		}
		return NO;
	}
	used = [layoutManager usedRectForTextContainer:container];
	last = [layoutManager lineFragmentRectForGlyphAtIndex:glyphCount - 1 effectiveRange:NULL];
	if (outShortfall != NULL) {
		double needed = NSMaxY(last) + inset.height;

		*outShortfall = needed - [view frame].size.height;
	}
	return (NSMaxY(last) + inset.height) <= ([view frame].size.height + 0.5);
}

static BOOL document_is_tall_enough(NSTextView *view, double *outShortfall)
{
	NSLayoutManager *layoutManager = [view layoutManager];
	NSTextContainer *container = [view textContainer];
	NSSize inset = [view textContainerInset];
	NSRect used;

	if (layoutManager == nil || container == nil) {
		return NO;
	}
	used = [layoutManager usedRectForTextContainer:container];
	if (outShortfall != NULL) {
		*outShortfall = (used.size.height + 2.0 * inset.height) - [view frame].size.height;
	}
	return (used.size.height + 2.0 * inset.height) <= ([view frame].size.height + 1.0);
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-text-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *source = [sources stringByAppendingPathComponent:@"main.m"];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		NSError *error = nil;
		double shortfall = 0.0;

		(void)[[NSApplication sharedApplication] finishLaunching];
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:sources withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"#include <stdio.h>\nint main(void) { printf(\"layout ok\\n\"); return 0; }\n"
			writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Layout" type:AGProjectTypeTool
						      error:&error];
		[project addFileAtAbsolutePath:source error:&error];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:&error];

		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];	/* makes the pane's geometry real, without showing it */

		/* 1. THE EDITOR, WITH MORE TEXT THAN THE PANE HOLDS. */
		{
			NSMutableString *text = [NSMutableString string];
			NSInteger i;

			for (i = 0; i < 200; i++) {
				[text appendFormat:@"/* line %ld of a file longer than the pane */\n", (long)i];
			}
			[[controller editor] setSource:text];
			[[controller editor] setFrameSize:[[controller editor] frame].size];	/* the pane's own placement */
			{
				NSTextView *view = [[controller editor] textView];

				if (!document_is_tall_enough(view, &shortfall)) {
					printf("       editor document short by %.1f pt\n", shortfall);
				}
				check(document_is_tall_enough(view, NULL),
				      "the editor's document is tall enough for all of its text");
				if (!last_line_fits(view, &shortfall)) {
					printf("       editor last line %.1f pt below the document's edge\n", shortfall);
				}
				check(last_line_fits(view, NULL), "the editor's last line is inside the document");
			}
		}

		/* 2. THE EDITOR, WITH LESS TEXT THAN THE PANE HOLDS: the document still fills the pane. */
		{
			NSTextView *view = [[controller editor] textView];
			CGFloat pane = [[controller editor] bounds].size.height;

			[[controller editor] setSource:@"one line\n"];
			check([view frame].size.height >= pane - 0.5,
			      "a short file's document still fills the pane");
		}

		/* 3. THE LOG, APPORTIONED BY A REAL BUILD: its document has to grow with what was appended, and its last
		 *    line has to be inside the clip after the scroll the controller asks for. */
		{
			NSString *product = [[project productURL] path];
			NSTextView *log;
			NSClipView *clip;
			NSSize inset;
			NSLayoutManager *layoutManager;
			NSUInteger glyphCount;
			NSRect last;
			double clipped;

			[controller build:nil];
			pump([controller builder], 180.0);
			check([manager fileExistsAtPath:product], "the build produced its product");

			log = [controller buildLogTextView];
			check(log != nil, "the log view is reachable");
			check([[log string] length] > 200, "the log holds the build's own output");

			if (!document_is_tall_enough(log, &shortfall)) {
				printf("       log document short by %.1f pt\n", shortfall);
			}
			check(document_is_tall_enough(log, NULL), "the log's document grew with what was appended");
			if (!last_line_fits(log, &shortfall)) {
				printf("       log last line %.1f pt below the document's edge\n", shortfall);
			}
			check(last_line_fits(log, NULL), "the log's last line is inside the document");

			/* AND IT IS IN THE CLIP, which is the claim a person makes when they say they can read it. */
			clip = (NSClipView *)[[log enclosingScrollView] contentView];
			layoutManager = [log layoutManager];
			inset = [log textContainerInset];
			glyphCount = [layoutManager numberOfGlyphs];
			last = [layoutManager lineFragmentRectForGlyphAtIndex:glyphCount - 1 effectiveRange:NULL];
			clipped = (NSMaxY(last) + inset.height) - ([clip bounds].origin.y + [clip bounds].size.height);
			if (clipped > 0.5) {
				printf("       the log's last line is %.1f pt below the clip\n", clipped);
			}
			check(clipped <= 0.5, "the log's last line is inside the clip view, not cut by it");
		}

		if (s_failed != 0) {
			printf("---- log ----\n%s\n-------------\n", [[controller buildLogText] UTF8String]);
		}
		[manager removeItemAtPath:directory error:NULL];
		[controller release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
