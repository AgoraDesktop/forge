/*
 * log_alignment — the build log's first character sits at its pane's left edge.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A PANE'S TEXT STARTS WHERE THE PANE DOES, AND THAT IS A PIXEL CLAIM.** The log is a text view inside a scroll view
 * inside a pane, and three separate origins decide where its first glyph lands (the view's frame, the clip's bounds and
 * the container's inset) — so a probe that read any one of them would be reading an intention. This renders the window's
 * content at 1:1 in points, finds the log pane's left edge from the subview it shares with the editor, and measures where
 * the ink actually starts.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectInfoView.h"
#import "AGProjectWindowController.h"
#import "AGSourceEditor.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSClipView.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define SURFACE_W 840
#define SURFACE_H 560

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

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *directory = [NSString stringWithFormat:@"%s/forge-logalign-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		AGProject *project;
		AGProjectWindowController *controller;
		NSView *content;
		NSBitmapImageRep *rep;
		unsigned char *px;
		NSInteger W = SURFACE_W, H = SURFACE_H;
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		unsetenv("CMAKE_PREFIX_PATH");
		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"#include <stdio.h>\nint main(void) { printf(\"hi\\n\"); return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];
		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"LogAlign" type:AGProjectTypeTool error:&error];
		[project addFileAtAbsolutePath:[directory stringByAppendingPathComponent:@"Sources/main.m"] error:NULL];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL];

		controller = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[controller window];
		[controller build:nil];
		pump([controller builder], 180.0);
		check([[controller buildLogText] length] > 0, "the build wrote lines into the log");

		content = [[controller window] contentView];
		[content setFrame:NSMakeRect(0.0, 0.0, W, H)];
		rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:W pixelsHigh:H
			bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
			colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:W * 4 bitsPerPixel:32];
		[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
		[[NSColor whiteColor] setFill];
		NSRectFill(NSMakeRect(0.0, 0.0, W, H));
		[content displayRect:[content bounds]];
		px = [rep bitmapData];

		/* THE PANE'S LEFT EDGE: the detail container shares its x with the log's scroll view. */
		{
			NSArray *frames = [controller paneViewFrames];
			NSRect logFrame = [[frames objectAtIndex:2] rectValue];
			NSRect detailFrame = [[frames objectAtIndex:1] rectValue];
			NSView *logPane = nil;
			NSView *detail = nil;
			CGFloat paneLeft = 0.0;
			/* THE BITMAP'S ROW 0 IS ITS TOP, and the log is the bottom strip of the window. */
			NSInteger bandTop = H - 150, bandBottom = H - 40;
			NSInteger y;

			logPane = (logFrame.size.width > 0.0) ? content : nil;	/* non-nil is all the two checks below need */
			detail = (detailFrame.size.width > 0.0) ? content : nil;
			paneLeft = logFrame.origin.x;
			check(logPane != nil && detail != nil, "the window has the log pane and the detail pane");
			check(fabs((double)NSMinX(logFrame)) < 0.5,
			      "the log pane starts at the window's left edge");
			check(fabs((double)NSWidth(logFrame) - (double)NSWidth([content bounds])) < 0.5,
			      "and spans the window, so it is not a column indented under the editor");

			/* THE FIRST INK IN THE LOG'S BAND, measured from the pane's own edge. */
			{
				NSInteger first = -1, at = 0;

				for (y = bandBottom; y > bandTop; y--) {
					NSInteger x;

					for (x = (NSInteger)paneLeft; x < W; x++) {
						unsigned char *p = px + (y * [rep bytesPerRow]) + x * 4;

						if (p[0] < 120 && p[1] < 120 && p[2] < 120) {
							if (first < 0 || x < first) {
								first = x;
							}
							at = y;
							break;
						}
					}
				}
				check(first >= 0, "the log has ink in its band");
				/* **THE TEXT SYSTEM'S OWN PADDING IS FOUR POINTS** (`-lineFragmentPadding`) plus a glyph's bearing —
				 * and that is the ONLY inset there should be. Anything larger is a document narrower than its clip,
				 * which the clip then centres. */
				if (first >= 0 && fabs((double)(first - (NSInteger)paneLeft)) > 6.0) {
					printf("       first ink at x=%ld, pane starts at %.1f (row %ld)\n",
						(long)first, (double)paneLeft, (long)at);
				}
				check(first >= 0 && fabs((double)(first - (NSInteger)paneLeft)) <= 6.0,
				      "and its first character starts at the pane's left edge, its own four points aside");
			}
		}

		[rep release];
		[manager removeItemAtPath:directory error:NULL];
		[controller release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
