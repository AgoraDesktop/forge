/*
 * AGToolbarIcons.h — the toolbar's pictures, drawn rather than shipped.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **DRAWN IN CODE, BECAUSE A TOOLBAR ICON IS A FEW SHAPES AND A BUNDLE IS A FILE THAT HAS TO RESOLVE.** The tree's own
 * controls demonstration draws its toolbar's tiles the same way, and for the same reason: a bundle resource is a path that
 * has to be found at run time, and this application has no resource directory to get wrong. Each icon is 18 by 18 points,
 * which is the size the band lays out, and it is drawn in the label's ink so the pair reads as one item.
 *
 * The shapes are the ones a person already knows from every build tool — a hammer, a bin, a play triangle, a stop square,
 * a plus, a page with a minus, a box with an arrow leaving it — and the two the Code | Info switch wears: Tabler's
 * `code-dots` and `info-circle`.
 */
#ifndef AGTOOLBARICONS_H
#define AGTOOLBARICONS_H

#import <AppKit/NSImage.h>

typedef enum {
	AGToolbarIconBuild = 0,
	AGToolbarIconClean,
	AGToolbarIconRun,
	AGToolbarIconStop,
	AGToolbarIconAdd,
	AGToolbarIconExport,
	AGToolbarIconRemoveFile,
	/* **AND THE TWO THE DETAIL SWITCH WEARS**, which is a pair of pictures in the same band rather than toolbar
	 * verbs: `code-dots` is the editor and `info-circle` the metadata pane. They are the same 24-point tiles, so the
	 * switch and the buttons beside it cannot disagree about how big a picture is. */
	AGToolbarIconCode,
	AGToolbarIconInfo,
	AGToolbarIconCount
} AGToolbarIconKind;

/* ANSWERED FRESH EACH CALL rather than cached: five 24-point tiles are cheaper to draw than a cache is to keep honest
 * about the current ink, and a toolbar asks for them once. */
NSImage *AGToolbarIcon(AGToolbarIconKind kind);

#endif /* AGTOOLBARICONS_H */
