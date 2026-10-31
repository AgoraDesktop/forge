/*
 * _open_cost — where the time goes when a file is opened, measured rather than guessed.
 */
#import "AGEditorTabs.h"
#import "AGSourceEditor.h"
#import "AGTabStrip.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <time.h>

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		const char *path = (argc > 1) ? argv[1] : "/home/kyle/Development/Agora/forge/src/AGProjectWindowController.m";
		NSString *file = [NSString stringWithUTF8String:path];
		NSString *source = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
		AGEditorTabs *tabs;
		AGSourceEditor *editor;
		double t0, t1;
		int i;

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		printf("open cost: %s (%lu bytes, %lu lines)\n", path, (unsigned long)[source length],
		       (unsigned long)[[source componentsSeparatedByString:@"\n"] count]);

		tabs = [[AGEditorTabs alloc] initWithFrame:NSMakeRect(0.0, 0.0, 800.0, 600.0)];
		t0 = now();
		editor = [tabs openPath:file];
		t1 = now();
		printf("  first open (strip + editor + layout + colour): %.1f ms\n", (t1 - t0) * 1000.0);

		t0 = now();
		[editor setSource:source];
		t1 = now();
		printf("  setSource alone:      %.1f ms\n", (t1 - t0) * 1000.0);

		t0 = now();
		[editor highlight];
		t1 = now();
		printf("  highlight alone:      %.1f ms\n", (t1 - t0) * 1000.0);

		t0 = now();
		[[editor textView] sizeToFit];
		t1 = now();
		printf("  sizeToFit alone:      %.1f ms\n", (t1 - t0) * 1000.0);

		/* AND THE PIECES INSIDE `-setSource:`, so the cost is attributed rather than guessed at. */
		{
			NSTextView *view = [editor textView];
			NSLayoutManager *layout = [view layoutManager];

			t0 = now();
			[view setString:@""];
			t1 = now();
			printf("  setString(empty):     %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			[view setString:source];
			t1 = now();
			printf("  setString(source):    %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			[layout removeTemporaryAttribute:NSForegroundColorAttributeName
					     forCharacterRange:NSMakeRange(0, [[view string] length])];
			t1 = now();
			printf("  one temp clear:       %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			[layout addTemporaryAttribute:NSForegroundColorAttributeName
					 value:[NSColor redColor]
				     forCharacterRange:NSMakeRange(0, 100)];
			t1 = now();
			printf("  one temp add (100 ch): %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			for (i = 0; i < 200; i++) {
				NSUInteger at = (NSUInteger)i * 3;

				[layout addTemporaryAttribute:NSForegroundColorAttributeName
						 value:[NSColor redColor]
					     forCharacterRange:NSMakeRange(at, 2)];
			}
			t1 = now();
			printf("  200 temp adds:        %.1f ms (%.2f ms each)\n", (t1 - t0) * 1000.0,
			       (t1 - t0) * 5.0);
		}

		/* **A BARE TEXT VIEW, WITH NO DELEGATE AND NOTHING WATCHING IT**, so the view's own work is separated from the
		 * colour pass the editor's delegate runs on every change. */
		{
			NSTextView *bare = [[[NSTextView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 800.0, 600.0)] autorelease];

			[bare setRichText:NO];
			[bare setVerticallyResizable:YES];
			[bare setHorizontallyResizable:NO];
			[[bare textContainer] setWidthTracksTextView:YES];
			t0 = now();
			[bare setString:source];
			t1 = now();
			printf("  bare text view setString: %.1f ms\n", (t1 - t0) * 1000.0);

			/* AND THE SAME STEPS ONE AT A TIME, because something inside that door is 4 seconds. */
			{
				NSTextStorage *store = [bare textStorage];

				t0 = now();
				[store beginEditing];
				[store replaceCharactersInRange:NSMakeRange(0, [store length]) withString:@""];
				[store endEditing];
				t1 = now();
				printf("  bare: store clear     %.1f ms\n", (t1 - t0) * 1000.0);
				t0 = now();
				[store beginEditing];
				[store replaceCharactersInRange:NSMakeRange(0, 0) withString:source];
				[store endEditing];
				t1 = now();
				printf("  bare: store fill      %.1f ms\n", (t1 - t0) * 1000.0);
				t0 = now();
				[bare setSelectedRange:NSMakeRange([source length], 0)];
				t1 = now();
				printf("  bare: setSelectedRange %.1f ms\n", (t1 - t0) * 1000.0);
				t0 = now();
				[bare sizeToFit];
				t1 = now();
				printf("  bare: sizeToFit       %.1f ms\n", (t1 - t0) * 1000.0);
				{
					NSLayoutManager *layout = [bare layoutManager];
					NSRange all = NSMakeRange(0, [store length]);
					NSUInteger glyphs = 0;

					t0 = now();
					[layout ensureLayoutForCharacterRange:all];
					t1 = now();
					printf("  bare: ensureLayout    %.1f ms\n", (t1 - t0) * 1000.0);
					t0 = now();
					[layout invalidateLayoutForCharacterRange:all actualCharacterRange:NULL];
					t1 = now();
					printf("  bare: invalidate      %.1f ms\n", (t1 - t0) * 1000.0);
					t0 = now();
					glyphs = [layout numberOfGlyphs];
					[layout ensureLayoutForCharacterRange:all];
					t1 = now();
					printf("  bare: relayout (%lu glyphs) %.1f ms\n", (unsigned long)glyphs, (t1 - t0) * 1000.0);
				}
			}
		}

		/* **THE STORAGE ALONE, THEN WITH A LAYOUT MANAGER.** `-setString:` is 4.4 s, and the question is whether that
		 * is the store's attribute fixing or the manager's layout. */
		{
			NSTextStorage *store = [[[NSTextStorage alloc] init] autorelease];

			t0 = now();
			[store beginEditing];
			[store replaceCharactersInRange:NSMakeRange(0, [store length]) withString:source];
			[store addAttribute:NSFontAttributeName value:[NSFont userFixedPitchFontOfSize:12.0]
				       range:NSMakeRange(0, [source length])];
			[store endEditing];
			t1 = now();
			printf("  storage alone:        %.1f ms\n", (t1 - t0) * 1000.0);
			{
				NSLayoutManager *layout = [[[NSLayoutManager alloc] init] autorelease];
				NSTextContainer *container = [[[NSTextContainer alloc] initWithContainerSize:NSMakeSize(700.0, 1e7)] autorelease];

				[layout addTextContainer:container];
				[store addLayoutManager:layout];
				t0 = now();
				[store beginEditing];
				[store replaceCharactersInRange:NSMakeRange(0, [store length]) withString:source];
				[store endEditing];
				t1 = now();
				printf("  storage + manager:    %.1f ms\n", (t1 - t0) * 1000.0);
				t0 = now();
				[layout removeTemporaryAttribute:NSForegroundColorAttributeName
					      forCharacterRange:NSMakeRange(0, [store length])];
				t1 = now();
				printf("  clear temp (no marks): %.1f ms\n", (t1 - t0) * 1000.0);
			}
		}

		/* **THE COLOUR PASS'S TWO HALVES: READING THE STRING, AND APPLYING THE RUNS.** */
		{
			NSString *text = [editor source];
			NSUInteger n = [text length];
			unichar *buffer = (unichar *)malloc(n * sizeof(unichar));
			NSUInteger k;
			NSUInteger acc = 0;

			t0 = now();
			[text getCharacters:buffer range:NSMakeRange(0, n)];
			t1 = now();
			printf("  getCharacters (65k):  %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			for (k = 0; k < n; k++) {
				acc += buffer[k];
			}
			t1 = now();
			printf("  C scan of the buffer: %.1f ms\n", (t1 - t0) * 1000.0);
			t0 = now();
			for (k = 0; k < n; k++) {
				acc += [text characterAtIndex:k];
			}
			t1 = now();
			printf("  ObjC characterAtIndex: %.1f ms (%lu)\n", (t1 - t0) * 1000.0, (unsigned long)(acc & 1));
			free(buffer);
		}

		/* **THE LIBRARY'S PER-CALL COST, WITHOUT THE SCANNER**: the same number of temporary attributes a colour pass
		 * applies, over the same document. */
		{
			NSLayoutManager *layout = [[editor textView] layoutManager];
			NSTextStorage *store = [[editor textView] textStorage];
			NSColor *red = [NSColor redColor];
			NSUInteger i;

			for (i = 0; i < 7000; i++) {
				[layout addTemporaryAttribute:NSForegroundColorAttributeName value:red
					     forCharacterRange:NSMakeRange(i * 9, 5)];
			}
			t0 = now();
			for (i = 0; i < 7000; i++) {
				[layout addTemporaryAttribute:NSForegroundColorAttributeName value:red
					     forCharacterRange:NSMakeRange(i * 9, 5)];
			}
			t1 = now();
			printf("  7000 temp adds:       %.1f ms (%.1f us each)\n", (t1 - t0) * 1000.0,
			       (t1 - t0) * 1000000.0 / 7000.0);
			t0 = now();
			[layout removeTemporaryAttribute:NSForegroundColorAttributeName
				      forCharacterRange:NSMakeRange(0, [store length])];
			t1 = now();
			printf("  clear 7000 marks:     %.1f ms\n", (t1 - t0) * 1000.0);
		}

		/* five edits, which is what typing costs per keystroke */
		t0 = now();
		for (i = 0; i < 5; i++) {
			[editor textDidChange:nil];
		}
		t1 = now();
		printf("  five textDidChange:   %.1f ms (%.1f ms each)\n", (t1 - t0) * 1000.0, (t1 - t0) * 200.0);
		[tabs release];
	}
	return 0;
}
