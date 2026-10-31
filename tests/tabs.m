/*
 * tabs — one tab per open file: what "open" means the second time, what a tab keeps, and what closing one refuses to do.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE EDITOR USED TO BE ONE BUFFER.** Choosing a file in the browser overwrote whatever was in it, so a person reading
 * two files held one of them in their head. A tab is now a file that stays open, with its own editor — text, selection,
 * scroll, undo — and this probe drives the three promises that makes: a second click on an open file SELECTS rather than
 * reloads, the text typed into a tab survives a visit to another one, and a tab with unsaved text does not close.
 */
#import "AGEditorTabs.h"
#import "AGSourceEditor.h"
#import "AGTabStrip.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>

static int s_failed = 0;

/* **PAINT A VIEW INTO A BITMAP AND COUNT ITS INK IN A RECTANGLE.** The bitmap is kept between paints on purpose: a window
 * reuses its buffer, so the question "did the pane's face cover what was there?" is only asked honestly by painting a
 * SECOND time into the same pixels.
 */
static NSBitmapImageRep *painted_rep(NSView *view)
{
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
		pixelsWide:(int)[view bounds].size.width pixelsHigh:(int)[view bounds].size.height
		bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
		colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:(int)[view bounds].size.width * 4 bitsPerPixel:32];

	return rep;
}

static void paint_into(NSBitmapImageRep *rep, NSView *view)
{
	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:context];
	[view displayRect:[view bounds]];
	[NSGraphicsContext restoreGraphicsState];
}

static int ink_in_rep(NSBitmapImageRep *rep, NSRect rect, int viewHeight)
{
	int x, y, ink = 0;

	for (y = (int)NSMinY(rect); y < (int)NSMaxY(rect); y++) {
		for (x = (int)NSMinX(rect); x < (int)NSMaxX(rect); x++) {
			NSColor *c = [rep colorAtX:x y:viewHeight - 1 - y];

			if (c != nil && [c redComponent] < 0.5) {
				ink++;
			}
		}
	}
	return ink;
}

/* A WHEEL EVENT, built the way the seam builds one: `NSEvent`'s own two numbers, in WHEEL LINES. */
static NSEvent *scroll_event(double dx, double dy)
{
	return [NSEvent cg_scrollEventWithDeltaX:(CGFloat)dx
					  deltaY:(CGFloat)dy
					location:NSMakePoint(10.0, 10.0)
				   modifierFlags:0
				       timestamp:1.0
				    windowNumber:0];
}

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

int main(void)
{
	@autoreleasepool {
		const char *tmp = getenv("TMPDIR");
		NSString *dir = [NSString stringWithFormat:@"%s/forge-tabs-%d",
			(tmp != NULL && tmp[0] != '\0') ? tmp : "/tmp", (int)getpid()];
		NSFileManager *manager = [NSFileManager defaultManager];
		NSString *alpha = [dir stringByAppendingPathComponent:@"alpha.m"];
		NSString *beta = [dir stringByAppendingPathComponent:@"beta.h"];
		AGEditorTabs *tabs;
		AGSourceEditor *editor;
		NSTextView *textView;

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		[manager removeItemAtPath:dir error:NULL];
		[manager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
		[@"// alpha\n" writeToFile:alpha atomically:YES encoding:NSUTF8StringEncoding error:NULL];
		[@"// beta\n" writeToFile:beta atomically:YES encoding:NSUTF8StringEncoding error:NULL];

		printf("tabs: one tab per open file\n");
		tabs = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 400.0)];
		check([tabs tabCount] == 0, "a new strip is empty");
		check([tabs currentEditor] == nil && [tabs currentPath] == nil, "and has nothing on screen");

		/* 1. **OPENING A FILE GIVES IT A TAB AND PUTS IT ON SCREEN.** */
		editor = [tabs openPath:alpha];
		check(editor != nil, "a file opens");
		check([tabs tabCount] == 1, "and it gets a tab");
		check([tabs currentEditor] == editor, "which is the editor on screen");
		check([[tabs currentPath] isEqualToString:alpha], "and the strip names the file it shows");
		check([[editor source] isEqualToString:@"// alpha\n"] && ![editor isDirty],
		      "the text is the file's, and a file's own text is not an edit");

		/* 2. **A SECOND FILE GETS ITS OWN EDITOR.** The first one is not reused and its content is not thrown away,
		 * which is the whole point: one buffer per window was the behaviour being fixed. */
		textView = [editor textView];
		[textView setString:@"// alpha, edited\n"];
		[editor textDidChange:nil];		/* what the text view's own report does */
		check([editor isDirty], "typing into a tab makes it unsaved");
		{
			AGSourceEditor *second = [tabs openPath:beta];

			check(second != nil && second != editor, "the second file gets an editor of its own");
			check([tabs tabCount] == 2, "and the strip has two tabs");
			check([tabs currentEditor] == second, "with the new one on screen");
			check([[second source] isEqualToString:@"// beta\n"], "showing the second file's text");
			check([[editor source] isEqualToString:@"// alpha, edited\n"], "the first file's edit is still there");
		}

		/* 3. **CLICKING AN OPEN FILE SELECTS ITS TAB INSTEAD OF RE-READING THE FILE.** Re-reading is what would throw the
		 * edit away, so the text proves which door ran. */
		{
			AGSourceEditor *again = [tabs openPath:alpha];

			check(again == editor, "opening an already-open file answers the editor it already had");
			check([tabs tabCount] == 2, "without adding a tab");
			check([tabs currentEditor] == editor, "and the strip moves to it");
			check([[editor source] isEqualToString:@"// alpha, edited\n"],
			      "with the edit intact — the file on disk was NOT re-read");
		}

		/* 4. **AND A TAB WITH UNSAVED TEXT DOES NOT CLOSE.** There is no save prompt in this Forge, and a silent discard
		 * is the one outcome a person cannot undo — so the strip refuses and the caller says why. */
		check(![tabs closeCurrentTab], "a tab with unsaved changes refuses to close");
		check([tabs tabCount] == 2, "so the strip still has both tabs");
		check([tabs currentEditor] == editor, "and the same file is on screen");

		/* 5. **SAVING CLEARS THE BULLET, AND THEN THE TAB CLOSES.** `-setDirty:NO` is what the window's ⌘S does after it
		 * has written the file. */
		[editor setDirty:NO];
		check(![editor isDirty], "a saved file is not unsaved");
		check([tabs closeCurrentTab], "and its tab closes");
		check([tabs tabCount] == 1, "leaving the other one");
		check([[tabs currentPath] isEqualToString:beta], "which becomes the file on screen");

		/* 6. **CLOSING A NAMED FILE'S TAB IS THE PROJECT'S DOOR** — a file that leaves the project must stop being shown,
		 * and only if it has nothing unsaved. */
		check([tabs closePath:alpha] == NO, "a tab that is already gone answers NO");
		check([tabs closePath:@"/nowhere/at/all.m"] == NO, "and so does a path that was never open");
		{
			AGSourceEditor *betaEditor = [tabs currentEditor];

			[betaEditor setDirty:YES];
			check(![tabs closePath:beta], "a named tab with unsaved text refuses too");
			[betaEditor setDirty:NO];
			check([tabs closePath:beta], "and closes once it is saved");
			check([tabs tabCount] == 0, "leaving an empty strip");
			check([tabs currentEditor] == nil, "with nothing on screen");
		}

		/* 6b. **EVERY TAB HAS A CLOSE GLYPH, AND IT IS ON THE CHIP'S LEFT.** A Mac editor puts the ✕ before the name —
		 * Safari, Xcode, Terminal — and the glyph is a rectangle the strip reports, so a probe clicks what a person
		 * sees. The two rectangles must not overlap in a way that makes the glyph unclickable: the strip tests the
		 * glyph FIRST, which is the rule that keeps a press on it from selecting the tab instead. */
		{
			AGTabStrip *strip = [tabs tabStrip];
			AGSourceEditor *first;
			AGSourceEditor *second;

			first = [tabs openPath:alpha];
			second = [tabs openPath:beta];
			check(strip != nil && [strip tabCount] == 2, "the strip knows there are two tabs");
			if (strip != nil) {
				NSRect chip = [strip rectForTabAtIndex:1];
				NSRect glyph = [strip closeRectForTabAtIndex:1];
				NSRect chipZero = [strip rectForTabAtIndex:0];

				check(NSPointInRect(NSMakePoint(NSMinX(glyph), NSMidY(glyph)), chip),
				      "the close glyph is INSIDE its chip");
				check(NSMinX(glyph) < NSMidX(chip), "and on the chip's LEFT half, where a Mac puts it");
				check(NSMinX(chip) >= NSMaxX(chipZero) - 0.5, "the chips run left to right without overlapping");
				check([strip selectedIndex] == 1, "the newest tab is the selected one");
			}
			(void)first;
			(void)second;

			/* **AND A CLICK ON THE GLYPH ASKS TO CLOSE** — it does not select, and a tab with unsaved text is refused
			 * by the class above, which is why the glyph is a request rather than a close. */
			check([tabs closeTabAtIndex:1], "a saved tab closes by its glyph's request");
			check([tabs tabCount] == 1, "leaving the other one");
			[first setDirty:YES];
			check(![tabs closeTabAtIndex:0], "and an unsaved one refuses");
			check([tabs tabCount] == 1, "so it is still there");
			[first setDirty:NO];
			check([tabs closeTabAtIndex:0], "and closes once it is saved");
			check([tabs tabCount] == 0, "leaving an empty strip");
			(void)second;
		}

		/* 6c. **THE LABEL IS CENTRED IN ITS CHIP.** The tab strip draws its own words, and `-drawAtPoint:` takes a
		 * BASELINE: the box to centre is ascender-to-descender. Measured as ink, the two margins are compared with each
		 * other, because the question is whether the words are centred and not what a padding constant happens to be. */
		{
			AGEditorTabs *probe = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 300.0)];
			AGSourceEditor *probeEditor = [probe openPath:alpha];
			AGTabStrip *strip = [probe tabStrip];
			NSRect chip;
			NSBitmapImageRep *rep;
			NSGraphicsContext *context;
			int x, y, top = -1, bottom = -1;

			(void)probeEditor;
			chip = [strip rectForTabAtIndex:0];
			rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(int)[strip bounds].size.width
				pixelsHigh:(int)[strip bounds].size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
				isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
				bytesPerRow:(int)[strip bounds].size.width * 4 bitsPerPixel:32];
			context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
			[NSGraphicsContext saveGraphicsState];
			[NSGraphicsContext setCurrentContext:context];
			[[NSColor whiteColor] setFill];
			[[NSBezierPath bezierPathWithRect:[strip bounds]] fill];
			[strip displayRect:[strip bounds]];
			[NSGraphicsContext restoreGraphicsState];
			/* the label's own columns only: past the glyph, inside the chip */
			for (y = (int)NSMinY(chip) + 2; y < (int)NSMaxY(chip) - 2; y++) {
				for (x = (int)NSMaxX([strip closeRectForTabAtIndex:0]) + 4; x < (int)NSMaxX(chip) - 2; x++) {
					NSColor *c = [rep colorAtX:x y:(int)[rep pixelsHigh] - 1 - y];

					if (c != nil && [c redComponent] < 0.5) {
						if (top < 0) {
							top = y;
						}
						bottom = y;
					}
				}
			}
			check(top >= 0 && bottom >= top, "the chip inks its label");
			if (top >= 0 && bottom >= top) {
				int fromFloor = top - (int)NSMinY(chip);
				int fromCeiling = (int)NSMaxY(chip) - 1 - bottom;

				printf("  [diag] tab label %d from the chip's floor, %d from its ceiling\n", fromFloor,
				       fromCeiling);
				check(abs(fromFloor - fromCeiling) <= 3, "and the words are CENTRED in the chip");
			}
			[rep release];
			[probe release];
		}

		/* 6d. **THE CLOSE GLYPH UNDER THE POINTER WEARS A PLATE.** It is a twelve-point target, so the one a press would
		 * hit says so before the press: the hover is asked per motion and costs a redraw only when the ANSWER changes. */
		{
			AGEditorTabs *probe = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 300.0)];
			AGTabStrip *strip;

			(void)[probe openPath:alpha];
			(void)[probe openPath:beta];
			strip = [probe tabStrip];
			check([strip hoveredCloseIndex] == -1, "nothing is hovered to begin with");
			[strip hoverAtPoint:NSMakePoint(NSMidX([strip closeRectForTabAtIndex:1]),
							NSMidY([strip closeRectForTabAtIndex:1]))];
			check([strip hoveredCloseIndex] == 1, "the pointer over a glyph hovers THAT tab's");
			[strip hoverAtPoint:NSMakePoint(NSMidX([strip rectForTabAtIndex:1]),
							NSMidY([strip rectForTabAtIndex:1]))];
			check([strip hoveredCloseIndex] == -1,
			      "and the middle of the chip — the name — hovers no glyph");
			[strip hoverAtPoint:NSMakePoint(NSMidX([strip closeRectForTabAtIndex:1]),
							NSMidY([strip closeRectForTabAtIndex:1]))];
			[strip mouseExited:nil];
			check([strip hoveredCloseIndex] == -1, "a pointer that leaves the strip drops the hover");
			[probe release];
		}

		/* 6e. **AND THE CHIPS SCROLL WHEN THEY DO NOT FIT.** The strip is as wide as the pane and a project can have more
		 * files open than that holds: the wheel walks along them, the offset never passes either end, and selecting a tab
		 * brings it into view — which is the promise that makes a tab you cannot see still reachable. */
		{
			AGEditorTabs *probe = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 100.0, 300.0)];
			AGTabStrip *strip;
			NSEvent *wheel;
			CGFloat width;

			(void)[probe openPath:alpha];
			(void)[probe openPath:beta];
			(void)[probe openPath:alpha];	/* the strip keeps two: the second open of alpha SELECTS */
			strip = [probe tabStrip];
			width = [strip bounds].size.width;
			check([strip contentWidth] > width, "two chips are wider than a 100-point strip");
			check([strip scrollOffset] == 0.0, "which starts unscrolled");
			check(NSMaxX([strip rectForTabAtIndex:1]) > width,
			      "so the second chip ends past the strip's right edge");

			/* THE WHEEL, AND ITS TWO ENDS. */
			wheel = scroll_event(0.0, -3.0);
			[strip scrollWheel:wheel];
			check([strip scrollOffset] > 0.0, "a wheel walks the chips along");
			{
				CGFloat scrolled = [strip scrollOffset];

				check(NSMaxX([strip rectForTabAtIndex:1]) <= width + 0.5,
				      "and the last chip comes fully into view");

				/* past the end the offset STOPS, and the event goes on to the view behind the strip. */
				[strip scrollWheel:scroll_event(0.0, -40.0)];
				check([strip scrollOffset] >= scrolled, "a second wheel past the end does not run away");
				check(NSMaxX([strip rectForTabAtIndex:1]) <= width + 0.5, "and the chips stay where they are");
				[strip scrollWheel:scroll_event(0.0, 40.0)];
				check([strip scrollOffset] == 0.0, "wheeling back returns them to the first chip");
			}

			/* **AND A SELECTION BRINGS ITS CHIP INTO VIEW**, which is the promise that makes a tab scrolled off the left
			 * edge reachable by clicking its name in the browser. */
			[strip scrollWheel:scroll_event(0.0, -40.0)];
			check([strip scrollOffset] > 0.0, "the chips are scrolled past the first one");
			(void)[probe openPath:alpha];	/* already open: this SELECTS it */
			check(NSMinX([strip rectForTabAtIndex:0]) >= -0.5,
			      "selecting the first tab scrolls it back into view");
			[probe release];
		}

		/* 6f. **A TAB OPENED BEFORE THE PANE IS LAID OUT IS STILL VISIBLE.** The strip is built at zero size and the first
		 * file is opened before any layout, so "reveal the selected chip" has to know that a strip with no width reveals
		 * nothing: MEASURED, the first open scrolled the whole strip off to the left (offset = the chip's right edge)
		 * and the pane came up with a band of nothing where its tabs should be. */
		{
			AGEditorTabs *probe = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 0.0, 0.0)];
			AGTabStrip *strip;

			(void)[probe openPath:alpha];
			strip = [probe tabStrip];
			check([strip bounds].size.width == 0.0, "the strip has no width yet");
			check([strip tabCount] == 1, "a file opened into it regardless");
			check([strip scrollOffset] == 0.0,
			      "and the strip did NOT scroll itself away revealing a chip into no room");
			/* and once the pane is laid out, the chip is where it should be */
			[probe setFrame:NSMakeRect(0.0, 0.0, 600.0, 300.0)];
			check(NSMinX([strip rectForTabAtIndex:0]) >= 0.0 &&
			      NSMaxX([strip rectForTabAtIndex:0]) <= 600.0,
			      "so the first chip is on the strip after a real layout");
			[probe release];
		}

		/* 6g. **AN EMPTY PANE PAINTS ITS FACE, NOT THE LAST FILE'S TEXT.** Closing the last tab leaves a view with no
		 * editor in it, and a pane that draws NOTHING keeps whatever the buffer held — MEASURED as the last file's text
		 * staying on the glass, smeared by the next partial repaint. The pane fills itself with the window's background,
		 * so the ink the editor left behind is gone the moment its tab is. */
		{
			AGEditorTabs *probe = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 300.0, 200.0)];
			NSRect content = NSMakeRect(0.0, 0.0, 300.0, 200.0 - [AGTabStrip thickness]);
			NSBitmapImageRep *rep = painted_rep(probe);
			int before, after;

			(void)[probe openPath:alpha];
			paint_into(rep, probe);
			before = ink_in_rep(rep, content, 200);
			check(before > 0, "an open file inks the pane");
			check([probe closeTabAtIndex:0], "and its tab closes");
			check([probe tabCount] == 0, "leaving no tabs at all");
			/* THE SAME PIXELS, PAINTED AGAIN — a window reuses its buffer, so this is the state a person sees. */
			paint_into(rep, probe);
			after = ink_in_rep(rep, content, 200);
			printf("  [diag] pane ink before %d, after the last tab closed %d\n", before, after);
			check(after == 0, "and the pane is its own face again, not the text that was there");
			[rep release];
			[probe release];
		}

		/* 7. **AND A FILE THAT CANNOT BE READ OPENS NOTHING.** The caller logs it; the strip answers nil so it can. */
		check([tabs openPath:[dir stringByAppendingPathComponent:@"missing.m"]] == nil,
		      "a file that is not there opens nothing");
		check([tabs tabCount] == 0, "and adds no tab");

		[tabs release];
		[manager removeItemAtPath:dir error:NULL];
	}
	printf(s_failed == 0 ? "tabs: all checks passed\n" : "tabs: FAILURES\n");
	return (s_failed == 0) ? 0 : 1;
}
