/*
 * toolbar_icons — every picture, each with ink in it, and no two the same.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A TOOLBAR ICON DRAWN IN CODE CAN BE AN EMPTY TILE AND NOTHING WOULD SAY SO.** The band would lay out an 18-point
 * rectangle, draw an image whose every pixel is transparent, and the item would look like a label with a gap in front of
 * it. So the claims are: each kind answers an image, at the size the band lays out, with ink in it; and the five are
 * DIFFERENT pictures, because a factory that forgot a `break` would return one shape five times and every icon would be
 * right in size and wrong in meaning. The loop is over `AGToolbarIconCount`, so a kind added to the band is a kind this
 * case asks about without being told.
 */
#import "AGToolbarIcons.h"

#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSImage.h>
#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

/* THE INK A PICTURE PUTS DOWN, counted as pixels with any alpha — the tile is transparent everywhere a shape is not. */
static long fn_ink(NSImage *image)
{
	NSBitmapImageRep *rep = (NSBitmapImageRep *)[[image representations] lastObject];
	unsigned char *bytes;
	NSInteger x, y, ink = 0;

	if (rep == nil) {
		return 0;
	}
	bytes = [rep bitmapData];
	for (y = 0; y < [rep pixelsHigh]; y++) {
		for (x = 0; x < [rep pixelsWide]; x++) {
			if (bytes[(y * [rep bytesPerRow]) + x * 4 + 3] > 0) {
				ink++;
			}
		}
	}
	return ink;
}

/* AND WHETHER TWO ARE THE SAME PICTURE, by their bytes: the representations are the same size and layout, so a memcmp
 * is the whole answer. */
static int fn_same(NSImage *a, NSImage *b)
{
	NSBitmapImageRep *ra = (NSBitmapImageRep *)[[a representations] lastObject];
	NSBitmapImageRep *rb = (NSBitmapImageRep *)[[b representations] lastObject];

	if (ra == nil || rb == nil || [ra pixelsWide] != [rb pixelsWide] || [ra pixelsHigh] != [rb pixelsHigh]) {
		return 0;
	}
	return memcmp([ra bitmapData], [rb bitmapData],
		      (size_t)([ra bytesPerRow] * [ra pixelsHigh])) == 0;
}

int main(void)
{
	@autoreleasepool {
		NSImage *images[AGToolbarIconCount];
		NSUInteger kind, other;

		for (kind = 0; kind < (NSUInteger)AGToolbarIconCount; kind++) {
			images[kind] = AGToolbarIcon((AGToolbarIconKind)kind);
			if (images[kind] == nil) {
				printf("       icon %lu is nil\n", (unsigned long)kind);
			}
			check(images[kind] != nil, "every kind answers an image");
			check([images[kind] size].width == 24.0 && [images[kind] size].height == 24.0,
			      "at the 24-point size the band lays out for a regular item");
			if (fn_ink(images[kind]) < 20) {
				printf("       icon %lu has only %ld pixel(s) of ink\n", (unsigned long)kind,
					fn_ink(images[kind]));
			}
			check(fn_ink(images[kind]) >= 20, "with a shape drawn in it");
		}

		for (kind = 0; kind < (NSUInteger)AGToolbarIconCount; kind++) {
			for (other = kind + 1; other < (NSUInteger)AGToolbarIconCount; other++) {
				if (fn_same(images[kind], images[other])) {
					printf("       icons %lu and %lu are the same picture\n",
						(unsigned long)kind, (unsigned long)other);
				}
				check(!fn_same(images[kind], images[other]), "and no two kinds are the same picture");
			}
		}
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
