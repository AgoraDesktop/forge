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
