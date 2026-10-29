/* a measurement, not a test: what one drag step costs. */
#import "AGBuilder.h"
#import "AGProject.h"
#import "AGProjectInfoView.h"
#import "AGProjectWindowController.h"
#import <AppKit/AppKit.h>

/* THE TIER'S DIVIDER-POSITION DOOR, declared the way this tree declares a `cg_` seam its probes use. */
@interface NSSplitView (AGProbePositions)
- (CGFloat)cg_positionOfDividerAtIndex:(NSInteger)index;
@end
#include <stdio.h>

int main(void)
{
	@autoreleasepool {
		NSString *directory = @"/tmp/forge-play/Hello";
		AGProjectWindowController *controller;
		AGSourceEditor *editor;
		NSTimeInterval t0;
		NSRect frame;
		NSInteger i;
		CGFloat heightOnly, widthChange, replace;

		(void)[[NSApplication sharedApplication] finishLaunching];
		controller = [[AGProjectWindowController alloc] initWithProject:
			[AGProject projectWithContentsOfURL:[NSURL fileURLWithPath:directory isDirectory:YES] error:NULL]];
		(void)[controller window];
		editor = [controller editor];
		frame = [editor frame];
		if (frame.size.width < 10.0) {
			printf("no editor frame; is the project at %s?\n", [directory UTF8String]);
			return 1;
		}

		/* 1. A HEIGHT-ONLY CHANGE IS NOT A WRAP, and it used to re-lay out the whole document anyway (104 ms). */
		t0 = [NSDate timeIntervalSinceReferenceDate];
		for (i = 0; i < 20; i++) {
			[editor setFrame:NSMakeRect(frame.origin.x, frame.origin.y,
						    frame.size.width, frame.size.height + (CGFloat)i)];
			[editor setFrame:frame];
		}
		heightOnly = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0 / 40.0;

		/* 2. A WIDTH CHANGE IS a wrap, and the text has to be laid out again. */
		t0 = [NSDate timeIntervalSinceReferenceDate];
		for (i = 0; i < 20; i++) {
			[editor setFrame:NSMakeRect(frame.origin.x, frame.origin.y,
						    frame.size.width + (CGFloat)i, frame.size.height)];
			[editor setFrame:frame];
		}
		widthChange = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0 / 40.0;

		/* 3. **A DIVIDER DRAG, AS `NSSplitView` PERFORMS IT**: no pane is re-placed until the release, so the motions
		 * themselves cost a preview line and nothing else. */
		{
			NSSplitView *outer = (NSSplitView *)[[[controller panesView] subviews] objectAtIndex:0];
			NSSplitView *split = (NSSplitView *)[[outer subviews] objectAtIndex:0];
			CGFloat start = [split cg_positionOfDividerAtIndex:0];

			t0 = [NSDate timeIntervalSinceReferenceDate];
			for (i = 0; i < 60; i++) {
				[split setPosition:start + (CGFloat)(i % 20) ofDividerAtIndex:0];
			}
			replace = ([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0 / 60.0;
			[split setPosition:start ofDividerAtIndex:0];
		}

		printf("editor -setFrame: height-only %.2f ms, width change %.2f ms\n", heightOnly, widthChange);
		printf("split divider re-place: %.2f ms each\n", replace);
		[controller release];
	}
	return 0;
}
