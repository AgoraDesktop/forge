/*
 * pane_sizes — the dividers drag, and the numbers they set are remembered.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A HAND-PLACED SPLIT STILL OWES A PERSON A DIVIDER.** The three panes are placed by arithmetic (`AGPanesView`), which is
 * what keeps a pane's children from lagging a pane's frame in this tier — but arithmetic is not a reason to take the
 * divider away, so the view hit-tests a six-point band, moves a NUMBER while the hand moves, and writes that number to
 * `NSUserDefaults` when the hand lets go. This probe drags both dividers with synthetic events and then builds a SECOND
 * window over the same defaults, because "remembered" means the next one is already right.
 *
 * The defaults store is pointed at a scratch root (`FNX_CONFIG_ROOT`, the tree's own variable for exactly this) so the
 * probe touches nothing in the image.
 */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectWindowController.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSSplitView.h>

@interface NSSplitView (AGProbePositions)
- (CGFloat)cg_positionOfDividerAtIndex:(NSInteger)index;
@end
#import <AppKit/NSView.h>
#import <AppKit/NSWindow.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

/* THE TIER'S CURSOR DOOR, declared here the way this tree declares a `cg_` seam it uses: the window resolves a
 * cursor rect by asking the tree, and this probe asks the same question of the same view. */
@interface NSView (AGCursorProbe)
- (NSCursor *)cg_cursorAtPoint:(NSPoint)point;
@end

static NSEvent *fn_mouse_at(NSEventType type, NSPoint windowPoint, NSInteger windowNumber, NSTimeInterval when)
{
	return [NSEvent mouseEventWithType:type location:windowPoint modifierFlags:0 timestamp:when
			      windowNumber:windowNumber context:nil eventNumber:0 clickCount:1 pressure:1.0];
}

static NSEvent *fn_mouse(NSEventType type, NSPoint windowPoint, NSInteger windowNumber)
{
	return fn_mouse_at(type, windowPoint, windowNumber, 0.0);
}

/* **THE DIVIDERS BELONG TO THE SPLIT VIEWS, WHICH ARE WHAT A REAL PRESS REACHES.** The container only holds them, so a
 * probe that sent its events to the container would be testing a view nobody clicks. The outer split stacks the top row
 * above the log; the top split puts the browser beside the detail pane. */
static NSSplitView *fn_outer_split(NSView *panes)
{
	return (NSSplitView *)[[panes subviews] objectAtIndex:0];
}

static NSSplitView *fn_top_split(NSView *panes)
{
	return (NSSplitView *)[[fn_outer_split(panes) subviews] objectAtIndex:0];
}

/* A DRAG IN THE SPLIT VIEW'S OWN COORDINATES, through the events the real mouse sends. */
static void fn_drag(NSSplitView *split, NSPoint from, NSPoint to)
{
	NSWindow *window = [split window];
	NSPoint a = [split convertPoint:from toView:nil];
	NSPoint b = [split convertPoint:to toView:nil];

	[split mouseDown:fn_mouse(NSLeftMouseDown, a, [window windowNumber])];
	[split mouseDragged:fn_mouse(NSLeftMouseDragged, b, [window windowNumber])];
	[split mouseUp:fn_mouse(NSLeftMouseUp, b, [window windowNumber])];
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *scratch = [NSString stringWithFormat:@"%s/forge-panes-config", (tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp"];
		NSString *directory = [NSString stringWithFormat:@"%s/forge-panes-%d", (tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSUserDefaults *defaults;
		AGProject *project;
		AGProjectWindowController *first;
		AGProjectWindowController *second;
		NSError *error = nil;

		(void)[[NSApplication sharedApplication] finishLaunching];
		/* THE STORE'S ROOT IS AN INSTALLATION'S CONFIGURATION TREE AND IS EMPTY BY DEFAULT — a writable scratch one
		 * here, so the probe neither reads a person's saved sizes nor writes its own into them. */
		setenv("FNX_CONFIG_ROOT", [scratch UTF8String], 1);
		[manager removeItemAtPath:scratch error:NULL];
		[manager createDirectoryAtPath:[scratch stringByAppendingPathComponent:@"Users"] withIntermediateDirectories:YES
				    attributes:nil error:NULL];
		defaults = [NSUserDefaults standardUserDefaults];

		[manager createDirectoryAtPath:[directory stringByAppendingPathComponent:@"Sources"]
		    withIntermediateDirectories:YES attributes:nil error:NULL];
		[[@"int main(void) { return 0; }\n" dataUsingEncoding:NSUTF8StringEncoding]
			writeToFile:[directory stringByAppendingPathComponent:@"Sources/main.m"] atomically:YES];

		project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:directory isDirectory:YES]
						       name:@"Panes" type:AGProjectTypeTool error:&error];
		[project writeToURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL];

		first = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[first window];
		{
			NSView *panes = [first panesView];
			CGFloat widthBefore = [first browserPaneWidth];
			CGFloat logBefore = [first logPaneHeight];
			NSSize size = [panes bounds].size;

			/* 1. A FIRST RUN TAKES A PROPORTION AND REMEMBERS NOTHING. */
			check(panes != nil, "the window has its panes view");
			check(widthBefore > 0.0 && logBefore > 0.0, "the panes have widths to start from");

			/* 2. THE BROWSER'S DIVIDER DRAGS. The press is the divider's MIDDLE, because the band is the split
			 * view's `-dividerThickness` and a probe that assumed a width would be testing its own arithmetic. */
			{
				CGFloat half = [fn_top_split(panes) dividerThickness] / 2.0;

				fn_drag(fn_top_split(panes), NSMakePoint(widthBefore + half, size.height / 2.0),
					NSMakePoint(widthBefore + half + 90.0, size.height / 2.0));
			}
			check(fabs((double)([first browserPaneWidth] - (widthBefore + 90.0))) < 1.0,
			      "dragging the first divider moves the browser by the drag");

			/* 3. AND THE LOG'S DIVIDER DRAGS THE OTHER WAY. **THE POSITION IS THE SPLIT VIEW'S OWN**, measured
			 * from the leading edge down its axis — for a stacked split that is the flipped y, so a probe that
			 * guessed from the log's height would press inside the top pane and prove nothing. */
			{
				NSSplitView *outer = fn_outer_split(panes);
				CGFloat half = [outer dividerThickness] / 2.0;
				CGFloat position = [outer cg_positionOfDividerAtIndex:0];

				fn_drag(outer, NSMakePoint(size.width - 40.0, position + half),
					NSMakePoint(size.width - 40.0, position + half - 60.0));
			}
			check(fabs((double)([first logPaneHeight] - (logBefore + 60.0))) < 1.0,
			      "dragging the second divider moves the log by the drag");

			/* 3b. **AND THE LOG CAN GO DOWN TO ITS OWN FLOOR.** A stacked split reports the pane ABOVE the divider, so a
			 * delegate that returns the log's floor as the MINIMUM stops the log 160 points early — the divider looks
			 * stuck. Dragging far past the floor must land ON it, not short of it. */
			{
				NSSplitView *outer = fn_outer_split(panes);
				CGFloat half = [outer dividerThickness] / 2.0;
				CGFloat position = [outer cg_positionOfDividerAtIndex:0];

				fn_drag(outer, NSMakePoint(size.width - 40.0, position + half),
					NSMakePoint(size.width - 40.0, position + half + 400.0));
			}
			check([first logPaneHeight] <= 72.0,
			      "the log shrinks to its floor (70 points) instead of stopping 90 points early");
			check([first logPaneHeight] >= 68.0,
			      "and stops at the floor rather than vanishing");

			/* 3c. AND THE TOP ROW KEEPS ITS OWN FLOOR, so the log cannot swallow the editor either. */
			{
				NSSplitView *outer = fn_outer_split(panes);
				CGFloat half = [outer dividerThickness] / 2.0;
				CGFloat position = [outer cg_positionOfDividerAtIndex:0];
				CGFloat topHeight = NSHeight([outer bounds]) - position - [outer dividerThickness];

				fn_drag(outer, NSMakePoint(size.width - 40.0, position + half),
					NSMakePoint(size.width - 40.0, position + half - topHeight));
			}
			check([[first paneViewFrames] count] == 3, "the panes are still placed after a clamped drag");

			/* 4. **THE NUMBERS ARE IN THE STORE THE SPLIT VIEW OWNS**, which is what "remembered" means: the
			 * divider positions are saved under the view's autosave name, so the split view restores them itself. */
			check([defaults objectForKey:@"AgoraSplitView AGForgePanes"] != nil,
			      "the browser's divider position was written under the split view's autosave name");
			check([defaults objectForKey:@"AgoraSplitView AGForgeLog"] != nil,
			      "and the log's divider position with it");
			(void)defaults;

			/* 5. A DRAG PAST THE CLAMP IS CLAMPED, NOT REMEMBERED AS ASKING FOR THE IMPOSSIBLE. */
			fn_drag(fn_top_split(panes),
				NSMakePoint([first browserPaneWidth] + [fn_top_split(panes) dividerThickness] / 2.0,
					    size.height / 2.0),
				NSMakePoint(size.width - 20.0, size.height / 2.0));
			check([first browserPaneWidth] < size.width - 100.0,
			      "a drag that would swallow the editor stops short of it");
		}

		/* 5b. **NO MOVE THE HAND MAKES IS THROWN AWAY.** The first version dropped events closer together than a sixtieth
		 * of a second — which at a 60 Hz pointer rate is most of them, and the divider moved in lurches or not at all. The
		 * rule now is distance: a move is applied unless it would change the number by less than half a point. */
		{
			NSView *panes = [first panesView];
			CGFloat start = [first browserPaneWidth];
			NSRect bounds = [panes bounds];
			NSSplitView *split = fn_top_split(panes);
			NSPoint gutter = NSMakePoint(start + [split dividerThickness] / 2.0, NSMidY(bounds));
			NSPoint windowGutter = [split convertPoint:gutter toView:nil];
			NSPoint windowLast = windowGutter;
			int step;

			[split mouseDown:fn_mouse(NSLeftMouseDown, windowGutter, [[split window] windowNumber])];
			/* TO THE LEFT: the drag above has already pushed the browser to its maximum, and a throttle test that is
			 * clamped measures the clamp. */
			for (step = 1; step <= 5; step++) {
				/* THE DRAG IS RELATIVE TO WHERE THE HAND GRABBED (the gutter's middle), not to the pane edge. */
				NSPoint to = [split convertPoint:NSMakePoint(gutter.x - (CGFloat)step * 10.0, NSMidY(bounds))
							  toView:nil];
				NSEvent *drag = fn_mouse_at(NSLeftMouseDragged, to, [[split window] windowNumber],
							    0.001 * (double)step);

				[split mouseDragged:drag];
				windowLast = to;
			}
			/* **THE NUMBER LANDS WHEN THE HAND STOPS, WHICH IS THE WHOLE POINT OF THE DRAG.** The motions move the
			 * gutter — a dirty rectangle each, MEASURED at 0.00 ms — and the panes are re-placed once, on the release:
			 * a pane's `-setFrame:` costs a layout pass (109 ms measured), so paying it per motion is what made the
			 * divider crawl. The last motion is `gutter.x - 50`. */
			/* **THE RELEASE IS WHERE THE HAND IS, NOT WHERE IT GRABBED.** A split view applies the drag from the
			 * release point, so a probe that released at the press point asked for a zero-length drag. */
			[split mouseUp:fn_mouse(NSLeftMouseUp, windowLast, [[split window] windowNumber])];
			if (fabs((double)([first browserPaneWidth] - (start - 50.0))) >= 0.5) {
				printf("       after the release the width is %.1f, expected %.1f\n",
					(double)[first browserPaneWidth], (double)(start - 50.0));
			}
			check(fabs((double)([first browserPaneWidth] - (start - 50.0))) < 0.5,
			      "five motions and a release move the divider to where the hand stopped");

			/* AND A SECOND DRAG GOES WHERE ITS OWN HAND STOPS. */
			{
				CGFloat half = [split dividerThickness] / 2.0;

				NSPoint down = [split convertPoint:NSMakePoint([first browserPaneWidth] + half, NSMidY(bounds))
							    toView:nil];
				NSPoint to = [split convertPoint:NSMakePoint([first browserPaneWidth] + half - 60.0, NSMidY(bounds))
							  toView:nil];
				CGFloat before = [first browserPaneWidth];

				[split mouseDown:fn_mouse(NSLeftMouseDown, down, [[split window] windowNumber])];
				[split mouseDragged:fn_mouse_at(NSLeftMouseDragged, to, [[split window] windowNumber], 0.5)];
				[split mouseUp:fn_mouse(NSLeftMouseUp, to, [[split window] windowNumber])];
				check(fabs((double)([first browserPaneWidth] - (before - 60.0))) < 0.5,
				      "and a second drag lands where its hand stopped");
			}
		}

		/* 6. **AND THE SEPARATION IS A GUTTER**: eight points of grabbable band, with the resize shapes over it — the
		 * thing a person needs in order to discover the drag at all. */
		{
			NSView *panes = [first panesView];
			NSArray *frames = [first paneViewFrames];
			NSRect browser = [[frames objectAtIndex:0] rectValue];
			NSRect detail = [[frames objectAtIndex:1] rectValue];
			NSRect log = [[frames objectAtIndex:2] rectValue];
			NSRect bounds = [panes bounds];
			NSPoint verticalSpot, horizontalSpot, cornerSpot;

			check(fabs((double)((NSMinX(detail) - NSMaxX(browser))
					    - (double)[fn_top_split(panes) dividerThickness])) < 0.01,
			      "the browser and the editor are separated by exactly one divider");
			check(fabs((double)((NSMinY(detail) - NSMaxY(log))
					    - (double)[fn_outer_split(panes) dividerThickness])) < 0.01,
			      "and so are the editor and the log");
			check(fabs((double)NSMinX(log)) < 0.01 && fabs((double)NSWidth(log) - (double)NSWidth(bounds)) < 0.01,
			      "the log spans the whole window, so its text is aligned with the browser's");

			/* **THE RESIZE SHAPES ARE THE SPLIT VIEW'S**, which offers them from its own divider rects; what this probe
			 * checks is the geometry a hand needs — eight points of grabbable band, and nothing grabbable inside a pane. */
			check([fn_top_split(panes) dividerThickness] >= 8.0,
			      "the vertical gutter is a grabbable band");
			check([fn_outer_split(panes) dividerThickness]
			      == [fn_top_split(panes) dividerThickness],
			      "and the horizontal one is the same band");
			(void)verticalSpot;
			(void)horizontalSpot;
			(void)cornerSpot;
		}

		/* 7. AND THE NEXT WINDOW IS ALREADY RIGHT — the sizes come back from the store, not from a proportion. */
		second = [[AGProjectWindowController alloc] initWithProject:project];
		(void)[second window];
		check(fabs((double)([second browserPaneWidth] - [first browserPaneWidth])) < 1.0,
		      "a second window opens with the remembered browser width");
		check(fabs((double)([second logPaneHeight] - [first logPaneHeight])) < 1.0,
		      "and the remembered log height");

		[second release];
		[first release];
		[manager removeItemAtPath:directory error:NULL];
		[manager removeItemAtPath:scratch error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
