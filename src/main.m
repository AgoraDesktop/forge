/*
 * main.m — Forge's own process: the menu bar, the application, and one project window per project.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Forge [--project DIR] [--build] [--clean] [--steps LIST] [--seconds N]
 *
 * **THE APPLICATION IS THE MENU BAR AND NOTHING ELSE** — the project windows are `AGProjectWindowController`s and
 * the application's own object is the one thing that must exist before there is a project. It forwards the verbs a
 * menu row sends to the FRONT project, which is the reference project manager's arrangement too: Build in the menu
 * is the build of the window you are looking at.
 *
 * `--seconds` is the test's door, the same as Workspace's and Terminal's: a bounded pump, so a probe can launch a
 * real application and stop it without a person clicking Quit. `--build` presses Build once the project is open, so
 * the whole build path — generator, toolchain, log, diagnostics — is exercised without a pointer.
 */
#import "AGBuilder.h"
#import <Foundation/NSRunLoop.h>
#import <Foundation/NSTimer.h>
#import "AGProject.h"
#import "AGProjectWindowController.h"

#import <AppKit/NSAlert.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSEvent.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSMenuItem.h>
#import <AppKit/NSOpenPanel.h>
#import <AppKit/NSPanel.h>
#import <AppKit/NSWindow.h>

#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSError.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSRunLoop.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------------------------------
 * The menu bar. A top-level item is a title whose whole content is a submenu; the commands are one level
 * down, which is the lesson `libagora-app/tests/appkit_menu_draw.m` records making the other way.
 * --------------------------------------------------------------------------------------------------- */

static NSMenuItem *AGBarTitle(NSString *title, NSMenu *submenu)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];

	[item setSubmenu:submenu];
	return [item autorelease];
}

static NSMenuItem *AGRow(NSMenu *menu, NSString *title, SEL action, id target, NSString *key, NSUInteger mask)
{
	NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:(key != nil) ? key : @""];

	[item setTarget:target];
	[item setKeyEquivalentModifierMask:((key != nil) && [key length] > 0) ? mask : 0];
	return item;
}

@interface AGAppController : NSObject
{
	NSMutableArray *_windowControllers;	/* RETAINED: AGProjectWindowController */
	NSMutableArray *_steps;			/* RETAINED: the `--steps` queue */
	id _stepTimer;				/* RETAINED while the queue runs */
}
- (void)installMenu;
- (AGProjectWindowController *)frontController;
- (void)openProjectAtURL:(NSURL *)url;
- (void)newProject:(id)sender;
- (void)openProject:(id)sender;
- (void)build:(id)sender;
- (void)clean:(id)sender;
- (void)run:(id)sender;
- (void)addFiles:(id)sender;
- (void)newFile:(id)sender;
- (void)saveDocument:(id)sender;
- (void)toggleBuildLog:(id)sender;
- (void)runSteps:(NSString *)list;
@end

@implementation AGAppController

- (instancetype)init
{
	self = [super init];
	if (self != nil) {
		_windowControllers = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_stepTimer invalidate];
	[_stepTimer release];
	[_steps release];
	[_windowControllers release];
	[super dealloc];
}

- (AGProjectWindowController *)frontController
{
	return [_windowControllers count] > 0 ? [_windowControllers lastObject] : nil;
}

- (void)openProjectAtURL:(NSURL *)url
{
	NSError *error = nil;
	AGProject *project = [AGProject projectWithContentsOfURL:url error:&error];
	AGProjectWindowController *controller;

	if (project == nil) {
		[[NSAlert alertWithError:(error != nil ? error : nil)] runModal];
		return;
	}
	controller = [[AGProjectWindowController alloc] initWithProject:project];
	[_windowControllers addObject:controller];
	[controller showWindow:nil];
	[controller release];
}

- (void)newProject:(id)sender
{
	(void)sender;
	{
		NSOpenPanel *panel = [NSOpenPanel openPanel];

		[panel setCanChooseDirectories:YES];
		[panel setCanChooseFiles:NO];
		[panel setAllowsMultipleSelection:NO];
		if ([panel runModalForDirectory:NSHomeDirectory() file:nil types:nil] == NSOKButton) {
			NSString *path = [[[panel URLs] lastObject] path];
			NSFileManager *manager = [NSFileManager defaultManager];
			NSString *manifest = [path stringByAppendingPathComponent:AGProjectManifestName];
			NSError *error = nil;
			AGProject *project;

			if ([manager fileExistsAtPath:manifest]) {
				/* A directory that already holds a project is an OPEN, not an overwrite: creating one over
				 * another project is the one thing this door must never do silently. */
				[self openProjectAtURL:[NSURL fileURLWithPath:path]];
				return;
			}
			project = [AGProject newProjectAtDirectoryURL:[NSURL fileURLWithPath:path]
								name:[path lastPathComponent]
								type:AGProjectTypeApplication
							       error:&error];
			if (project == nil) {
				[[NSAlert alertWithError:(error != nil ? error : nil)] runModal];
				return;
			}
			[self openProjectAtURL:[NSURL fileURLWithPath:path]];
		}
	}
}

- (void)openProject:(id)sender
{
	(void)sender;
	{
		NSOpenPanel *panel = [NSOpenPanel openPanel];

		[panel setCanChooseDirectories:YES];
		[panel setCanChooseFiles:YES];
		[panel setAllowsMultipleSelection:NO];
		if ([panel runModalForDirectory:NSHomeDirectory() file:nil types:nil] == NSOKButton) {
			[self openProjectAtURL:[[panel URLs] lastObject]];
		}
	}
}

/* THE FOUR VERBS ARE THE FRONT PROJECT'S, AND THEIR TARGET IS ALWAYS THIS OBJECT.** A row whose target were nil
 * would be greyed by `-[NSMenu update]`'s walk in the windows where no project is key, which is the right answer
 * for a command that needs a project; the front controller answers the selector or the walk finds nothing. */
- (void)build:(id)sender
{
	[[self frontController] build:sender];
}

/* THE STEP LIST. A repeating timer asks the front builder whether it is idle; when it is, the next step runs. */
- (void)runSteps:(NSString *)list
{
	NSMutableArray *queue = [NSMutableArray array];

	{
		NSArray *parts = [list componentsSeparatedByString:@","];
		NSUInteger i;

		for (i = 0; i < [parts count]; i++) {
			NSString *step = [parts objectAtIndex:i];

			if ([step length] > 0) {
				[queue addObject:step];
			}
		}
	}
	[_steps release];
	_steps = [queue retain];
	_stepTimer = [[NSTimer scheduledTimerWithTimeInterval:0.2
						      target:self
						    selector:@selector(fn_step)
						    userInfo:nil
						     repeats:YES] retain];
}

- (void)fn_step
{
	AGProjectWindowController *front = [self frontController];
	AGBuilder *builder = [front builder];

	if (front == nil || builder == nil) {
		return;
	}
	if ([builder isBuilding]) {
		return;		/* the previous step is still running; a person's next click would be a second later */
	}
	if ([_steps count] == 0) {
		[_stepTimer invalidate];
		[_stepTimer release];
		_stepTimer = nil;
		fprintf(stderr, "---- forge steps done ----\n%s\n--------------------------\n",
			[[builder output] UTF8String]);
		return;
	}
	{
		NSString *step = [[[_steps objectAtIndex:0] retain] autorelease];

		[_steps removeObjectAtIndex:0];
		if ([step isEqualToString:@"build"]) {
			[front build:nil];
		} else if ([step isEqualToString:@"clean"]) {
			[front clean:nil];
		} else if ([step isEqualToString:@"run"]) {
			[front run:nil];
		} else if ([step isEqualToString:@"stop"]) {
			[front stop:nil];
		}
	}
}

- (void)clean:(id)sender
{
	[[self frontController] clean:sender];
}

- (void)run:(id)sender
{
	[[self frontController] run:sender];
}

- (void)stop:(id)sender
{
	[[self frontController] stop:sender];
}

- (void)addFiles:(id)sender
{
	[[self frontController] addFiles:sender];
}

- (void)newFile:(id)sender
{
	[[self frontController] newFile:sender];
}

- (void)showProjectInfo:(id)sender
{
	[[self frontController] showProjectInfo:sender];
}

- (void)chooseIcon:(id)sender
{
	[[self frontController] chooseIcon:sender];
}

- (void)saveDocument:(id)sender
{
	[[self frontController] saveDocument:sender];
}

- (void)toggleBuildLog:(id)sender
{
	[[self frontController] toggleBuildLog:sender];
}

/* THE FILE'S TWO ROWS ARE THIS OBJECT'S, because a project is opened by the application and not by a window. */
- (void)installMenu
{
	NSApplication *application = [NSApplication sharedApplication];
	NSMenu *bar = [[NSMenu alloc] initWithTitle:@"MainMenu"];
	NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
	NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
	NSMenu *project = [[NSMenu alloc] initWithTitle:@"Project"];
	NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
	NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
	NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
	NSMenu *appMenu;
	NSString *name = [[NSProcessInfo processInfo] processName];

	AGRow(file, @"New Project…", @selector(newProject:), self, @"n", NSCommandKeyMask);
	AGRow(file, @"Open Project…", @selector(openProject:), self, @"o", NSCommandKeyMask);
	[file addItem:[NSMenuItem separatorItem]];
	AGRow(file, @"Save", @selector(saveDocument:), self, @"s", NSCommandKeyMask);
	AGRow(file, @"Close Window", @selector(performClose:), nil, @"w", NSCommandKeyMask);

	AGRow(edit, @"Undo", @selector(undo:), nil, @"z", NSCommandKeyMask);
	AGRow(edit, @"Redo", @selector(redo:), nil, @"z", NSCommandKeyMask | NSShiftKeyMask);
	[edit addItem:[NSMenuItem separatorItem]];
	AGRow(edit, @"Cut", @selector(cut:), nil, @"x", NSCommandKeyMask);
	AGRow(edit, @"Copy", @selector(copy:), nil, @"c", NSCommandKeyMask);
	AGRow(edit, @"Paste", @selector(paste:), nil, @"v", NSCommandKeyMask);
	AGRow(edit, @"Select All", @selector(selectAll:), nil, @"a", NSCommandKeyMask);
	[edit addItem:[NSMenuItem separatorItem]];
	/* FINDING IS THE TEXT SYSTEM'S, so the row sends the action a text view answers and the tag says which of
	 * the ten panel actions it means (`NSTextView.h` documents the tag table). */
	{
		NSMenuItem *find = AGRow(edit, @"Find…", @selector(performFindPanelAction:), nil, @"f",
					 NSCommandKeyMask);

		[find setTag:1];	/* NSFindPanelActionShowFindPanel */
	}

	AGRow(project, @"Build", @selector(build:), self, @"b", NSCommandKeyMask);
	AGRow(project, @"Clean", @selector(clean:), self, @"k", NSCommandKeyMask | NSShiftKeyMask);
	AGRow(project, @"Run", @selector(run:), self, @"r", NSCommandKeyMask);
	AGRow(project, @"Stop", @selector(stop:), self, @".", NSCommandKeyMask);
	[project addItem:[NSMenuItem separatorItem]];
	AGRow(project, @"New File…", @selector(newFile:), self, @"n", NSCommandKeyMask);
	AGRow(project, @"Add Files…", @selector(addFiles:), self, @"d", NSCommandKeyMask);
	[project addItem:[NSMenuItem separatorItem]];
	AGRow(project, @"Project Info…", @selector(showProjectInfo:), self, @"i", NSCommandKeyMask);
	AGRow(project, @"Choose Icon…", @selector(chooseIcon:), self, nil, 0);

	AGRow(view, @"Show Build Log", @selector(toggleBuildLog:), self, nil, 0);

	AGRow(window, @"Minimize", @selector(performMiniaturize:), nil, @"m", NSCommandKeyMask);
	AGRow(window, @"Bring All to Front", @selector(arrangeInFront:), application, nil, 0);

	AGRow(help, @"Forge Help", @selector(showHelp:), nil, nil, 0);

	[bar addItem:AGBarTitle(@"File", file)];
	[bar addItem:AGBarTitle(@"Edit", edit)];
	[bar addItem:AGBarTitle(@"Project", project)];
	[bar addItem:AGBarTitle(@"View", view)];
	[bar addItem:AGBarTitle(@"Window", window)];
	[bar addItem:AGBarTitle(@"Help", help)];

	/* THE INSTALL MAKES THE APPLICATION MENU, SO IT IS FILLED AFTERWARDS — the same order `WSMainMenu` records. */
	[application setMainMenu:bar];
	appMenu = [[bar itemAtIndex:0] submenu];
	AGRow(appMenu, [NSString stringWithFormat:@"About %@", name], @selector(orderFrontAboutPanel:), self, nil, 0);
	[appMenu addItem:[NSMenuItem separatorItem]];
	AGRow(appMenu, [NSString stringWithFormat:@"Hide %@", name], @selector(hide:), application, @"h", NSCommandKeyMask);
	[appMenu addItem:[NSMenuItem separatorItem]];
	AGRow(appMenu, [NSString stringWithFormat:@"Quit %@", name], @selector(terminate:), application, @"q",
	      NSCommandKeyMask);

	[file release];
	[edit release];
	[project release];
	[view release];
	[window release];
	[help release];
	[bar release];
}

/* `applicationShouldTerminateAfterLastWindowClosed:` is asked by `-[NSApplication run]`, so closing the last project
 * quits Forge — which is what an application whose only window is a project's should do. */
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	(void)sender;
	return [_windowControllers count] <= 1;
}

@end

static void AGRunFor(NSApplication *application, double seconds)
{
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];

	while ([deadline timeIntervalSinceNow] > 0.0) {
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		NSEvent *event;

		[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
					 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
		while ((event = [application nextEventMatchingMask:NSAnyEventMask
							     untilDate:[NSDate dateWithTimeIntervalSinceNow:0.0]
								inMode:NSDefaultRunLoopMode
							       dequeue:YES]) != nil) {
			[application sendEvent:event];
		}
		[pool release];
	}
}

int main(int argc, char **argv)
{
	const char *projectPath = NULL;
	double seconds = 0.0;
	int bounded = 0;
	int buildOnLaunch = 0;
	int cleanOnLaunch = 0;
	const char *steps = NULL;
	int i;

	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--project") == 0 && i + 1 < argc) {
			projectPath = argv[++i];
		} else if (strcmp(argv[i], "--build") == 0) {
			buildOnLaunch = 1;
		} else if (strcmp(argv[i], "--clean") == 0) {
			cleanOnLaunch = 1;
		} else if (strcmp(argv[i], "--steps") == 0 && i + 1 < argc) {
			steps = argv[++i];
		} else if (strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
			seconds = atof(argv[++i]);
			bounded = 1;
		} else {
			fprintf(stderr, "usage: %s [--project DIR] [--build] [--clean] [--steps LIST] [--seconds N]\n",
				argv[0]);
			return 2;
		}
	}

	@autoreleasepool {
		NSApplication *application = [NSApplication sharedApplication];
		AGAppController *controller = [[AGAppController alloc] init];

		/* THE DELEGATE IS SET BEFORE `-finishLaunching`, because that call is what announces
		 * `applicationDidFinishLaunching:` to it. */
		[application setDelegate:controller];
		[application finishLaunching];
		[controller installMenu];

		if (projectPath != NULL) {
			[controller openProjectAtURL:[NSURL fileURLWithPath:
				[NSString stringWithUTF8String:projectPath]]];
		}
		if (cleanOnLaunch) {
			[controller clean:nil];
		}
		if (buildOnLaunch) {
			[controller build:nil];
		}
		/* **`--steps build,clean,build` IS THE SEQUENCE A PERSON PERFORMS, IN ONE PROCESS.** Each step waits for the
		 * previous one to stop running, which is what a person's next click does by taking a second; a shell cannot
		 * run them at all, because each of its invocations is a new process with no builder state in it. */
		if (steps != NULL) {
			[controller runSteps:[NSString stringWithUTF8String:steps]];
		}
		[application activateIgnoringOtherApps:YES];

		if (bounded) {
			AGRunFor(application, seconds);
			/* **A BOUNDED RUN IS A PROBE, AND A PROBE NEEDS THE LOG.** With `--seconds` the builder's own output goes
			 * to stderr on the way out, so a headless build's failure is readable without a window. */
			{
				AGBuilder *builder = [[controller frontController] builder];

				if (builder != nil) {
					fprintf(stderr, "---- forge build log ----\n%s\n-------------------------\n",
						[[builder output] UTF8String]);
				}
			}
		} else {
			[application run];
		}
		[controller release];
	}
	return 0;
}
