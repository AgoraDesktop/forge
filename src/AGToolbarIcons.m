/*
 * AGToolbarIcons.m — the band's pictures, drawn.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See the header for why these are drawn rather than shipped. One number decides the whole band's look — the 24-point
 * tile, which is the size `fn_item_rects` lays out for a regular toolbar item, so the artwork is drawn AT that size
 * rather than scaled into it (an 18-point tile drawn into a 24-point rect is blurred by its own enlargement). Every
 * shape sits inside a margin of three points.
 *
 * The ink is `+controlTextColor`, which is what the toolbar draws a label in; a disabled item's picture is dimmed by the
 * toolbar itself (it sets the alpha for the pair), so nothing here needs a second set of greys.
 */
#import "AGToolbarIcons.h"

#import <AppKit/NSBezierPath.h>
#import <AppKit/NSBitmapImageRep.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSGraphicsContext.h>
#import <AppKit/NSImage.h>
#import <AppKit/NSImageRep.h>

#import <Foundation/NSGeometry.h>
#import <Foundation/NSData.h>
#import <Foundation/NSString.h>

#include <string.h>

/* **THE PICTURES ARE TABLER'S, COMPILED IN, AND THE HEADER IS A SOURCE FILE BESIDE THIS ONE.** `assets/tabler-icons`
 * holds the MIT-licensed outlines with their provenance and `tools/embed-glyphs.py` rasterises them into
 * `src/agora-toolbar-glyphs.h`, which is checked in: the art is data in the binary rather than a path to resolve at run
 * time, and — because a quoted include searches the INCLUDING FILE'S directory — every build of this project finds it,
 * including the one Forge performs on its own project with a generated `CMakeLists.txt` that knows no build rules of
 * ours. It used to be generated into the build directory, which made the pictures a property of HOW the project was
 * built: MEASURED, the Forge that Forge built had no header, `__has_include` failed, and its toolbar drew the fallback
 * below while the checkout's build drew Tabler's. Regenerate with
 * `python3 tools/embed-glyphs.py assets/tabler-icons src/agora-toolbar-glyphs.h /usr/bin/rsvg-convert`.
 * AND EVERY GLYPH HAS A FALLBACK, including the two the detail switch wears: one that covered only the verbs would leave
 * `Code | Info` as two words on exactly the machines a fallback exists for. */
#if defined(__has_include)
#  if __has_include("agora-toolbar-glyphs.h")
#    include "agora-toolbar-glyphs.h"
#    define AG_HAVE_TABLER_GLYPHS 1
#  endif
#endif

static const NSInteger AGIconSize = 24;

/* THE PATH HELPERS, so a shape is a sentence rather than a rectangle literal. */
static void fn_fill(CGFloat x, CGFloat y, CGFloat w, CGFloat h)
{
	[[NSBezierPath bezierPathWithRect:NSMakeRect(x, y, w, h)] fill];
}

/* A CLOSED, FILLED POLYGON. The icons are shapes, and a shape made of four points is easier to read — and to change —
 * than a rectangle plus a rotation that nothing else in this file needs. */
static void fn_polygon(const NSPoint *points, NSUInteger count)
{
	NSBezierPath *path = [NSBezierPath bezierPath];

	if (count < 3) {
		return;
	}
	[path moveToPoint:points[0]];
	{
		NSUInteger i;

		for (i = 1; i < count; i++) {
			[path lineToPoint:points[i]];
		}
	}
	[path closePath];
	[path fill];
}

static void fn_bar(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat thickness)
{
	/* AN AXIS-ALIGNED SEGMENT, which is all any of these shapes needs: a run of rectangles draws a hammer, a bin and a
	 * plus without a transform stack, and a transform is one more thing that can be wrong at a fractional scale. */
	if (y1 == y2) {
		fn_fill(x1, y1 - thickness / 2.0, x2 - x1, thickness);
	} else if (x1 == x2) {
		fn_fill(x1 - thickness / 2.0, y1, thickness, y2 - y1);
	}
}

/* **AND A DOT, WHICH IS A SHAPE TWO OF THESE PICTURES ARE MADE OF**: Tabler's `code-dots` is three of them and its
 * `info-circle` has one over the stem. `radius` is the ink's own half-width, so a dot the art drew with a two-unit stroke
 * is radius 1.0 at a 24-unit tile. */
static void fn_dot(CGFloat x, CGFloat y, CGFloat radius)
{
	fn_fill(x - radius, y - radius, radius * 2.0, radius * 2.0);
}

/* **A TEMPLATE, SO THE TOOLBAR INKS IT AND A DISABLED BUTTON'S PICTURE IS THE SAME GREY AS ITS LABEL.** The image carries
 * the SHAPE in its alpha and no colour at all; `NSToolbar` fills it with the control ink, or with the disabled ink when the
 * item cannot be used — which is what makes the pair dim together instead of a black glyph sitting beside a grey word. */
#ifdef AG_HAVE_TABLER_GLYPHS
static NSImage *fn_glyph_image(const unsigned char *small, const unsigned char *large)
{
	NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(24.0, 24.0)] autorelease];
	NSInteger sizes[2] = {24, 48};
	NSInteger i;

	for (i = 0; i < 2; i++) {
		NSInteger size = sizes[i];
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
									 pixelsWide:size pixelsHigh:size
									 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
									   isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
									 bytesPerRow:size * 4 bitsPerPixel:32];

		memcpy([rep bitmapData], (i == 0) ? small : large, (size_t)(size * size * 4));
		[rep setSize:NSMakeSize(size, size)];
		[image addRepresentation:rep];
		[rep release];
	}
	[image setTemplate:YES];
	return image;
}
#endif

NSImage *AGToolbarIcon(AGToolbarIconKind kind)
{
#ifdef AG_HAVE_TABLER_GLYPHS
	switch (kind) {
	case AGToolbarIconBuild:	return fn_glyph_image(AGGlyph_hammer[0], AGGlyph_hammer[1]);
	case AGToolbarIconRun:		return fn_glyph_image(AGGlyph_player_play[0], AGGlyph_player_play[1]);
	case AGToolbarIconClean:	return fn_glyph_image(AGGlyph_trash[0], AGGlyph_trash[1]);
	case AGToolbarIconStop:		return fn_glyph_image(AGGlyph_square[0], AGGlyph_square[1]);
	case AGToolbarIconAdd:		return fn_glyph_image(AGGlyph_plus[0], AGGlyph_plus[1]);
	case AGToolbarIconExport:	return fn_glyph_image(AGGlyph_package_export[0], AGGlyph_package_export[1]);
	case AGToolbarIconRemoveFile:	return fn_glyph_image(AGGlyph_file_minus[0], AGGlyph_file_minus[1]);
	case AGToolbarIconCode:		return fn_glyph_image(AGGlyph_code_dots[0], AGGlyph_code_dots[1]);
	case AGToolbarIconInfo:		return fn_glyph_image(AGGlyph_info_circle[0], AGGlyph_info_circle[1]);
	case AGToolbarIconCount:	break;
	}
#endif
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
									 pixelsWide:AGIconSize pixelsHigh:AGIconSize
									 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
									   isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
									 bytesPerRow:AGIconSize * 4 bitsPerPixel:32];
	NSImage *image = [[[NSImage alloc] initWithSize:NSMakeSize(AGIconSize, AGIconSize)] autorelease];
	NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

	[NSGraphicsContext saveGraphicsState];
	[NSGraphicsContext setCurrentContext:context];
	[[NSColor controlTextColor] setFill];

	switch (kind) {
	case AGToolbarIconBuild:
		/* **A HAMMER, DRAWN AS TWO POLYGONS.** The handle runs up-right at forty-five degrees and the head lies across
		 * its top end — the shape every icon set draws, and the reason a T with a vertical handle never read as a tool.
		 * Four points per piece, because a quad is all a hammer needs: no path arithmetic, no transform stack, and the
		 * same drawing works at any scale the band asks for. */
		fn_polygon((NSPoint[]){ {3.0, 3.0}, {5.5, 3.0}, {13.5, 13.5}, {11.0, 13.5} }, 4);	/* handle */
		fn_polygon((NSPoint[]){ {10.0, 13.5}, {22.0, 13.5}, {22.0, 20.0}, {10.0, 20.0} }, 4);	/* head */
		fn_polygon((NSPoint[]){ {17.0, 20.0}, {22.0, 20.0}, {22.0, 22.5} }, 3);			/* claw */
		break;
	case AGToolbarIconClean:
		/* A BIN: a lid wider than the body, and three rules down the body so it reads as a container rather than a box. */
		fn_fill(3.0, 17.0, 18.0, 3.0);
		fn_fill(6.0, 5.0, 12.0, 11.0);
		[[NSColor whiteColor] setFill];
		fn_fill(8.5, 7.0, 1.5, 7.0);
		fn_fill(11.25, 7.0, 1.5, 7.0);
		fn_fill(14.0, 7.0, 1.5, 7.0);
		[[NSColor controlTextColor] setFill];
		break;
	case AGToolbarIconRun:
		/* A PLAY TRIANGLE, pointing right, built as a narrow run of bars so it needs no path arithmetic. */
		{
			CGFloat y;

			for (y = 4.0; y < 20.0; y += 1.0) {
				CGFloat half = 16.0 - fabs(y - 12.0);
				CGFloat width = (half > 0.0) ? half * 0.6 : 0.0;

				if (width > 0.0) {
					fn_fill(6.0, y, width, 1.0);
				}
			}
		}
		break;
	case AGToolbarIconStop:
		/* A SQUARE, which is what stop is everywhere. */
		fn_fill(5.0, 5.0, 14.0, 14.0);
		break;
	case AGToolbarIconExport:
		/* **A BOX WITH ITS TOP LID OPEN AND AN ARROW LEAVING IT.** Drawn when the generated header is absent: the body is
		 * a box, the lid is the two lines that meet above it, and the arrow is a shaft with a head — the shape Tabler's
		 * `package-export` uses, so the fallback and the vendored art agree. */
		{
			NSBezierPath *box = [NSBezierPath bezierPath];
			NSBezierPath *arrow = [NSBezierPath bezierPath];

			[[NSColor controlTextColor] setStroke];
			[box setLineWidth:1.6];
			[box moveToPoint:NSMakePoint(3.5, 8.0)];
			[box lineToPoint:NSMakePoint(11.0, 4.0)];
			[box lineToPoint:NSMakePoint(18.5, 8.0)];
			[box moveToPoint:NSMakePoint(3.5, 8.0)];
			[box lineToPoint:NSMakePoint(3.5, 17.0)];
			[box lineToPoint:NSMakePoint(11.0, 21.0)];
			[box lineToPoint:NSMakePoint(11.0, 12.5)];
			[box moveToPoint:NSMakePoint(11.0, 12.5)];
			[box lineToPoint:NSMakePoint(18.5, 8.0)];
			[box stroke];

			[arrow setLineWidth:1.6];
			[arrow moveToPoint:NSMakePoint(13.5, 17.0)];
			[arrow lineToPoint:NSMakePoint(21.0, 17.0)];
			[arrow moveToPoint:NSMakePoint(18.0, 14.0)];
			[arrow lineToPoint:NSMakePoint(21.0, 17.0)];
			[arrow moveToPoint:NSMakePoint(18.0, 20.0)];
			[arrow lineToPoint:NSMakePoint(21.0, 17.0)];
			[arrow stroke];
		}
		break;
	case AGToolbarIconRemoveFile:
		/* **A PAGE WITH A MINUS IN IT**, drawn when the generated header is absent: the page is a rectangle with a folded
		 * corner, and the minus is one bar — the shape Tabler's `file-minus` uses, so the fallback and the art agree. */
		{
			NSBezierPath *page = [NSBezierPath bezierPath];

			[[NSColor controlTextColor] setStroke];
			[page setLineWidth:1.6];
			[page moveToPoint:NSMakePoint(6.0, 3.0)];
			[page lineToPoint:NSMakePoint(14.0, 3.0)];
			[page lineToPoint:NSMakePoint(19.0, 8.0)];
			[page lineToPoint:NSMakePoint(19.0, 21.0)];
			[page lineToPoint:NSMakePoint(6.0, 21.0)];
			[page closePath];
			[page moveToPoint:NSMakePoint(14.0, 3.0)];
			[page lineToPoint:NSMakePoint(14.0, 8.0)];
			[page lineToPoint:NSMakePoint(19.0, 8.0)];
			[page stroke];
			fn_bar(9.0, 14.5, 16.0, 14.5, 1.8);
		}
		break;
	case AGToolbarIconAdd:
		/* A PLUS: two bars crossing at the tile's middle. */
		fn_bar(5.0, 12.0, 19.0, 12.0, 3.0);
		fn_bar(12.0, 5.0, 12.0, 19.0, 3.0);
		break;
	case AGToolbarIconCode:
		/* **THREE DOTS IN A ROW, WHICH IS WHAT TABLER'S `CODE-DOTS` IS** — an ellipsis, not a pair of angle brackets —
		 * so the fallback draws the same shape the vendored art does, and a machine without `rsvg-convert` gets a
		 * picture whose meaning is the same one. */
		fn_dot(9.0, 12.0, 1.4);
		fn_dot(12.0, 12.0, 1.4);
		fn_dot(15.0, 12.0, 1.4);
		break;
	case AGToolbarIconInfo:
		/* A CIRCLE WITH AN `i`: the ring, the dot above, the stem below — `info-circle`'s three paths. */
		{
			NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(4.0, 4.0, 16.0, 16.0)];

			[[NSColor controlTextColor] setStroke];
			[ring setLineWidth:1.6];
			[ring stroke];
			fn_dot(12.0, 9.5, 1.0);
			fn_bar(12.0, 12.0, 12.0, 16.0, 1.6);
		}
		break;
	case AGToolbarIconCount:
		break;
	}
	[NSGraphicsContext restoreGraphicsState];
	[image addRepresentation:rep];
	[rep release];
	/* THE DRAWN FALLBACK IS A TEMPLATE TOO, for the same reason: the ink is the toolbar's, so a disabled item's picture
	 * greys with its label exactly as the vendored ones do. */
	[image setTemplate:YES];
	return image;
}
