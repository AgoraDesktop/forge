/*
 * line_numbers — the ruler's numbers sit beside the text they number, at any scroll position.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE DEFECT THIS MEASURES WAS A SCROLL APPLIED TWICE.** A vertical ruler's bounds origin is kept in step with the
 * clip view's (`NSScrollView -reflectScrolledClipView:`), which makes the ruler's own space the DOCUMENT's; the first
 * version of the ruler then converted each fragment through the client view as well, so every number was drawn a
 * whole scroll-distance away from its line — right at the top of a file and progressively wrong after that, which is
 * how it was reported ("line numbers aren't rendering correctly after scrolling").
 *
 * The claim is measured through the ruler's own walk, the same one the drawing uses, so a passing test cannot sit
 * beside a disagreeing screen: scroll by N lines and the first number the ruler would paint is N+1.
 */
#import "AGSourceEditor.h"

#import <AppKit/NSApplication.h>
#import <AppKit/NSClipView.h>
#import <AppKit/NSLayoutManager.h>
#import <AppKit/NSRulerView.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <stdlib.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

/* THE LINE HEIGHT, asked of the layout rather than assumed: the test scrolls by exactly N of them. */
static CGFloat line_height(NSTextView *view)
{
	NSLayoutManager *layoutManager = [view layoutManager];
	NSRect fragment = [layoutManager lineFragmentRectForGlyphAtIndex:0 effectiveRange:NULL];

	return fragment.size.height;
}

static void scroll_by(AGSourceEditor *editor, CGFloat offset)
{
	NSScrollView *scrollView = [editor scrollView];
	NSClipView *clip = [scrollView contentView];

	[clip scrollToPoint:NSMakePoint(0.0, offset)];
	[scrollView reflectScrolledClipView:clip];
}

static NSUInteger first_number(AGSourceEditor *editor)
{
	NSArray *numbers = [(AGLineNumberRuler *)[editor lineNumberRuler] cg_visibleLineNumbers];

	if ([numbers count] == 0) {
		return 0;
	}
	return [[numbers objectAtIndex:0] unsignedIntegerValue];
}

int main(void)
{
	@autoreleasepool {
		AGSourceEditor *editor;
		NSMutableString *text = [NSMutableString string];
		NSInteger i;

		(void)[[NSApplication sharedApplication] finishLaunching];
		editor = [[AGSourceEditor alloc] initWithFrame:NSMakeRect(0.0, 0.0, 420.0, 240.0)];
		for (i = 1; i <= 200; i++) {
			[text appendFormat:@"line %ld\n", (long)i];
		}
		[editor setSource:text];

		/* 1. AT THE TOP, THE FIRST NUMBER IS ONE. */
		check(first_number(editor) == 1, "unscrolled, the first number the ruler paints is 1");

		/* 2. AND IT FOLLOWS THE SCROLL, ONE NUMBER PER LINE, WHICH IS THE WHOLE CLAIM. */
		{
			CGFloat height = line_height([editor textView]);

			check(height > 0.0, "the layout has a line height to scroll by");
			scroll_by(editor, 10.0 * height);
			{
				NSUInteger first = first_number(editor);

				if (first != 11) {
					printf("       scrolled 10 lines, the ruler starts at %lu\n",
						(unsigned long)first);
				}
				check(first == 11, "after scrolling ten lines the ruler starts at 11");
			}

			scroll_by(editor, 50.0 * height);
			check(first_number(editor) == 51, "after scrolling fifty lines it starts at 51");

			/* AND BACK, because a ruler that is only right while moving forwards is right by accident. */
			scroll_by(editor, 0.0);
			check(first_number(editor) == 1, "scrolling back to the top starts at 1 again");
		}

		/* 3. THE NUMBERS ARE CONTIGUOUS AND GROW DOWNWARD, which is what a person reads them as. */
		{
			CGFloat height = line_height([editor textView]);
			NSArray *numbers;

			scroll_by(editor, 20.0 * height);
			numbers = [(AGLineNumberRuler *)[editor lineNumberRuler] cg_visibleLineNumbers];
			check([numbers count] > 5, "the pane shows more than five numbers");
			{
				NSUInteger k;
				int contiguous = 1;

				for (k = 1; k < [numbers count]; k++) {
					NSUInteger previous = [[numbers objectAtIndex:k - 1] unsignedIntegerValue];
					NSUInteger current = [[numbers objectAtIndex:k] unsignedIntegerValue];

					if (current != previous + 1) {
						contiguous = 0;
						break;
					}
				}
				check(contiguous, "the numbers are contiguous");
			}
		}

		[editor release];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
