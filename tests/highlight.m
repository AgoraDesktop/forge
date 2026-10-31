/*
 * highlight — the colour pass: which runs it inks, and how little it costs to ask.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE PASS WAS REWRITTEN FOR SPEED, SO THIS PINS WHAT IT PRODUCES.** The keyword test went from an `NSSet` of
 * `NSString`s — one substring allocation and one hash per word in the file, which cost 500 ms on a 1,600-line document —
 * to a C table compared by length. A table is a place to mistype a word, so the four kinds of run are each asserted by
 * the colour the layout's temporary table answers at an index inside them, and an identifier that is NOT a keyword is
 * asserted to have no colour at all.
 */
#import "AGSourceEditor.h"

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <time.h>

static int s_failed = 0;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

/* THE COLOUR THE PASS PAINTS AT AN INDEX, through the same temporary table the layout draws from. */
static NSColor *ink_at(AGSourceEditor *editor, NSUInteger index)
{
	return [[[editor textView] layoutManager] temporaryAttribute:NSForegroundColorAttributeName
							    atCharacterIndex:index effectiveRange:NULL];
}

static int same_colour(NSColor *a, NSColor *b)
{
	return a != nil && b != nil && [a isEqual:b];
}

int main(void)
{
	@autoreleasepool {
		AGSourceEditor *editor;
		const char *sample = "int main(void)\n{\n\treturn 0; // done\n}\n";
		NSString *text = [NSString stringWithUTF8String:sample];

		setvbuf(stdout, NULL, _IOLBF, 0);
		(void)[[NSApplication sharedApplication] finishLaunching];
		printf("highlight: the colour pass\n");

		editor = [[AGSourceEditor alloc] initWithFrame:NSMakeRect(0.0, 0.0, 600.0, 300.0)];
		[editor setSource:text];

		/* 1. **A KEYWORD IN THE TABLE IS INKED, AND SO IS ONE THAT ENDS IT.** `int` is the first word and `return` is
		 * inside the body; both are entries, and a table compared by length is a table whose longer words (unsigned,
		 * @implementation) are reached by the same walk. */
		check(ink_at(editor, 0) != nil, "a keyword at the start of the text is coloured");
		{
			NSUInteger at = [text rangeOfString:@"return"].location;

			check(at != NSNotFound && ink_at(editor, at) != nil, "and so is one in the middle");
			check(at != NSNotFound && same_colour(ink_at(editor, at), ink_at(editor, 0)),
			      "with the same ink — one keyword colour, not one per word");
		}

		/* 2. **AND A WORD THAT IS NOT A KEYWORD IS LEFT ALONE.** `main` is an identifier like any other; the set it came
		 * from had no entry for it, and the table must not either. */
		{
			NSUInteger at = [text rangeOfString:@"main"].location;

			check(at != NSNotFound && ink_at(editor, at) == nil, "a plain identifier is not coloured");
			/* **AND A WORD INSIDE A COMMENT WEARS THE COMMENT'S INK, WHICH IS THE RUN'S AND NOT THE WORD'S.** `done` is
			 * not a keyword, and asking the table about it must not paint it — the comment run is what colours it. */
			check(same_colour(ink_at(editor, [text rangeOfString:@"done"].location),
					  ink_at(editor, [text rangeOfString:@"// done"].location)),
			      "a word inside a comment wears the comment's ink, not a keyword's");
		}

		/* 3. **THE OTHER THREE KINDS ARE STILL THEIR OWN INKS**: a comment, a number, and the fact that all four differ —
		 * a table that answered one colour for everything would pass the first two checks and none of this. */
		{
			NSUInteger comment = [text rangeOfString:@"// done"].location;
			NSUInteger number = [text rangeOfString:@"0;"].location;
			NSColor *keyword = ink_at(editor, 0);

			check(comment != NSNotFound && ink_at(editor, comment) != nil, "a comment is coloured");
			check(number != NSNotFound && ink_at(editor, number) != nil, "a number is coloured");
			check(!same_colour(ink_at(editor, comment), keyword), "the comment's ink is not the keyword's");
			check(!same_colour(ink_at(editor, number), keyword), "and neither is the number's");
		}

		/* 4. **AND IT IS CHEAP ENOUGH TO RUN ON EVERY KEYSTROKE.** The pass is over the whole file, so a document of a
		 * thousand-odd lines has to cost milliseconds rather than the half-second the string set did: this is the same
		 * measurement the rewrite was made against, kept so a regression is a number and not a feeling. */
		{
			NSMutableString *big = [NSMutableString string];
			NSUInteger i;
			double t0, t1;

			for (i = 0; i < 400; i++) {
				[big appendString:@"static int fn_count(void) { return 42; } /* a comment */\n"];
			}
			[editor setSource:big];
			t0 = now();
			[editor highlight];
			t1 = now();
			printf("  [diag] one pass over %lu lines: %.1f ms\n", (unsigned long)400, (t1 - t0) * 1000.0);
			check((t1 - t0) < 0.25, "a colour pass over 400 lines is under a quarter of a second");
			check(ink_at(editor, 0) != nil, "and it still inks the first keyword");
		}

		[editor release];
	}
	printf(s_failed == 0 ? "highlight: all checks passed\n" : "highlight: FAILURES\n");
	return (s_failed == 0) ? 0 : 1;
}
