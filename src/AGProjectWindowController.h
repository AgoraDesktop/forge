/*
 * AGProjectWindowController.h — the project window: browser, editor, log, and the verbs between them.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THIS IS THE PROJECT CENTER'S CENTRAL WINDOW, IN THE ORDER IT PUTS THINGS.** A browser down the left, grouped by
 * what the files are; the file on the right in a source editor with line numbers; the build's own output below it,
 * where a person can read it against the code that produced it. The toolbar carries the four verbs the reference
 * project manager's does — Build, Clean, Run — plus the one this tier needs (add a file), and the menu carries the
 * same verbs so a key equivalent works when the toolbar is hidden.
 *
 * **THE BUILDER IS A DELEGATE RATHER THAN A THREAD.** `AGBuilder` runs the toolchain as a child process and reads
 * its pipe on the run loop; this controller is told as bytes arrive and appends them to the log. There is no
 * dispatch queue anywhere in the middle, which is what keeps the window responding while a build runs: the
 * subprocess is the concurrency.
 */
#ifndef AGPROJECTWINDOWCONTROLLER_H
#define AGPROJECTWINDOWCONTROLLER_H

#import <AppKit/NSView.h>
#import <AppKit/NSWindowController.h>

@class AGProject, AGProjectFile, AGSourceEditor, AGBuilder, AGProjectInfoView, NSOutlineView, NSTextView,
       NSSegmentedControl, NSMenuItem;

@interface AGProjectWindowController : NSWindowController
{
	AGProject *_project;		/* RETAINED */
	AGSourceEditor *_editor;	/* RETAINED */
	NSTextView *_logView;		/* RETAINED */
	NSOutlineView *_outline;	/* RETAINED */
	AGBuilder *_builder;		/* RETAINED */
	NSMutableArray *_groups;	/* RETAINED: { title = NSString, files = NSArray } in browser order */
	BOOL _openedFirstFile;		/* the launch-time convenience, done once */
	AGProjectInfoView *_infoView;		/* RETAINED: the metadata pane, swapped with the editor */
	NSView *_logPane;			/* RETAINED: the log's container, which sizes its document */
	NSView *_detail;			/* RETAINED by the panes view; holds the editor and the info pane */
	NSSegmentedControl *_detailSwitch;	/* RETAINED by the toolbar item's view */
}

- (instancetype)initWithProject:(AGProject *)project;

- (AGProject *)project;

/* THE LOG, AS TEXT. The pane is a view; the text is what a test can read, and what a person copies when they report
 * that a verb did something they did not ask for. */
- (NSString *)buildLogText;
- (NSTextView *)buildLogTextView;
- (AGSourceEditor *)editor;

/* TEST DOORS for the detail pane: the switch that chooses between Code and Info, and the metadata pane itself. */
- (NSSegmentedControl *)detailSwitch;

/* THE TOOLBAR'S STATE, ASKED AGAIN. A test door and the door the controller itself uses after every verb and every
 * finished stage; the answer lives in `-validateToolbarItem:`. */
- (void)refreshToolbarState;

/* TEST DOORS for the panes: the view that places them, and the two numbers its dividers move. */
- (NSView *)panesView;
- (CGFloat)browserPaneWidth;

/* THE THREE PANES' FRAMES, in browser/detail/log order. A test that indexed `-subviews` was reading the drag overlay as
 * the browser the moment that overlay existed — this is the order a caller means. */
- (NSArray *)paneViewFrames;
- (CGFloat)logPaneHeight;
- (AGProjectInfoView *)infoView;
- (AGBuilder *)builder;

/* THE VERBS. Each is an action so a menu row and a toolbar item can share it, and each is `-validate…`-free:
 * one that cannot run says so in the log rather than going grey without a reason. */
- (void)build:(id)sender;
- (void)clean:(id)sender;
- (void)run:(id)sender;
- (void)stop:(id)sender;

/* **THE APPLICATION'S OWN METADATA, EDITED WHERE IT LIVES.** A bundle's identifier, name, version and icon are keys in
 * the project file — not build settings and not a plist a person edits by hand — so the interface that changes them
 * changes the project, and the next build's `Info.plist` says what the interface said. */
- (void)showProjectInfo:(id)sender;
- (void)chooseIcon:(id)sender;
- (void)addFiles:(id)sender;

/* Creates a file, adds it to the manifest and opens it: the half `-addFiles:` cannot do, because an open panel can only
 * choose something that already exists. */
- (void)newFile:(id)sender;

/* COPIES THE BUILT BUNDLE WHERE A PERSON SAYS. A save panel does the naming and the placing; `-fn_exportProductToPath:error:`
 * is the same verb without the panel, so a probe can drive it. It refuses when there is no product, and while a build is
 * in flight, because the bundle on disk then is half of one. */
- (void)exportApp:(id)sender;
- (BOOL)fn_exportProductToPath:(NSString *)path error:(NSError **)error;

/* **WHERE THE EXPORT PANEL OPENS: THE ACCOUNT'S OWN APPLICATION FOLDER.** `~/Applications` is where a bundle a person
 * built belongs — the session creates it at login as part of the Mac's home set, and Launch Services scans it, so what
 * leaves the project is an application rather than a folder beside somebody's source. It is made if it is not there
 * yet (a Forge started on its own has never had a login), and an account whose home cannot hold it gets the home
 * itself rather than a panel pointed at a directory that does not exist. THE HOME IS AN ARGUMENT because
 * `NSHomeDirectory()` is the real account's: a probe asks about a scratch one. */
+ (NSString *)fn_exportDirectoryForHome:(NSString *)home;

/* TAKES THE BROWSER'S SELECTION OUT OF THE MANIFEST, not off the disk. No selection is a refusal with the reason in the log;
 * `-fn_removeFile:error:` is the same verb for a named file, so a probe needs no browser. */
- (void)removeSelectedFile:(id)sender;
- (BOOL)fn_removeFile:(AGProjectFile *)file error:(NSError **)error;

/* THE BROWSER ITSELF, so a probe can put the selection a person would put and then ask the toolbar item to fire. */
- (NSOutlineView *)browserOutline;
- (BOOL)fn_productIsExportable;

/* THE HALF WITHOUT THE PANEL: writes the file (with the skeleton its type asks for), puts it in the manifest, writes the
 * manifest and opens the file. The panel's only job is to produce a path, so a probe can exercise everything else. */
- (BOOL)fn_createFileAtPath:(NSString *)path error:(NSError **)error;
- (void)saveDocument:(id)sender;
- (void)toggleBuildLog:(id)sender;

/* **THE TOOLBAR'S LABELS, WHICH ARE A PREFERENCE AND NOT A PER-WINDOW CHOICE.** `NSToolbar`'s display mode is the tier's
 * own answer — icon-and-label, or icon alone — and turning the words off is how a person makes room for more verbs. The
 * choice is remembered under `AGShowToolbarLabels` and DEFAULTS TO ON, because a window that has never been told
 * otherwise draws the labels it has always drawn. `-fn_applyToolbarLabels` is the door that puts the stored answer on THIS
 * window's toolbar, which is what a second window and a menu toggle both need. */
+ (BOOL)fn_toolbarLabelsVisible;
+ (void)fn_setToolbarLabelsVisible:(BOOL)visible;
- (void)fn_applyToolbarLabels;

/* **AND THE CHECKMARK, PUT ON A ROW FROM THE PREFERENCE** — one place, so the menu's update walk and the press that just
 * happened cannot disagree about which state to draw. `NSOnState` (a tick) means the labels are showing. */
+ (void)fn_showToolbarLabelsStateOn:(NSMenuItem *)item;

@end

#endif /* AGPROJECTWINDOWCONTROLLER_H */
