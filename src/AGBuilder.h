/*
 * AGBuilder.h — the project's build, run outside the process and read back in.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **FORGE DOES NOT BUILD ANYTHING; IT ASKS THE TOOLCHAIN TO.** The manifest generates a `CMakeLists.txt`
 * (`AGProject -generatedCMakeLists`), and this class runs `cmake` twice — configure, then build — with the
 * output on a pipe. That is the division `DEVELOPMENT-TOOLS.md` §5 recommends for the IDE's build half:
 * "drive existing tools … the IDE is a front-end". There is no compiler invocation to maintain here, so a
 * change in clang's flags is CMake's problem and not this file's.
 *
 * **THE OUTPUT IS PARSED AS IT ARRIVES, AND THE PARSE IS THE POINT.** A build log a person cannot click is a
 * build log they read with their eyes only; the Project Center's build panel is a list of diagnostics that
 * jump to a line. `AGDiagnosticsFromBuildOutput` is that parse, written as a function so the headless test
 * can call it on canned compiler output with no task, no pipe and no window.
 */
#ifndef AGBUILDER_H
#define AGBUILDER_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>

@class AGProject;

/* ONE COMPILER MESSAGE. `file` is absolute; `line` is 1-based and `column` is 0 when the compiler did not say. */
@interface AGDiagnostic : NSObject
{
	NSString *_file;
	NSInteger _line;
	NSInteger _column;
	NSString *_message;
	BOOL _isError;
}

+ (instancetype)diagnosticWithFile:(NSString *)file
			      line:(NSInteger)line
			    column:(NSInteger)column
			   message:(NSString *)message
			   isError:(BOOL)isError;

- (NSString *)file;
- (NSInteger)line;
- (NSInteger)column;
- (NSString *)message;
- (BOOL)isError;
- (NSString *)summary;

@end

/* THE PARSE, ALONE. clang's `file:line:column: error: message`, and CMake's `CMake Error at file:line (verb):`,
 * in one pass over a log. A line that matches neither is not a diagnostic and is skipped. */
NSArray *AGDiagnosticsFromBuildOutput(NSString *output);

@protocol AGBuilderDelegate <NSObject>
@optional
/* CALLED AS THE BYTES ARRIVE, on the run loop. A delegate appends; it must not assume the chunk ended a line. */
- (void)builder:(id)builder didAppendOutput:(NSString *)text;
/* ONCE PER STAGE THAT ENDED. `stage` is "configure", "build", "clean" or "run". */
- (void)builder:(id)builder didFinishStage:(NSString *)stage status:(int)status;
@end

@interface AGBuilder : NSObject
{
	AGProject *_project;			/* RETAINED */
	id <AGBuilderDelegate> _delegate;	/* NOT retained, Apple's contract */
	id _task;				/* RETAINED while running; an NSTask */
	id _pipe;				/* RETAINED: the NSPipe's reading end while a stage runs */
	id _outputPipe;				/* RETAINED: the NSPipe itself, so the write end can be closed */
	id _poll;				/* RETAINED: the timer that notices the child's exit on the main thread */
	id _logHandle;				/* RETAINED, or nil: the file `FORGE_LOG_PATH` names */
	NSMutableString *_output;		/* RETAINED */
	NSMutableArray *_diagnostics;		/* RETAINED */
	NSString *_stage;			/* RETAINED */
	BOOL _buildInFlight;			/* YES from `-build` until the last stage of the chain ends */
	BOOL _stageIsBuild;			/* YES while the task that is running is configure or build */
}

- (instancetype)initWithProject:(AGProject *)project;

- (AGProject *)project;
- (void)setDelegate:(id <AGBuilderDelegate>)delegate;
- (id <AGBuilderDelegate>)delegate;

- (BOOL)isBuilding;

/* **A RUN IS NOT A BUILD, AND THE DIFFERENCE IS A DOOR.** The product is a child process of this one, so `_task` is
 * non-nil while it runs — which the old `-isBuilding` read as "a build is running", and every verb was then refused
 * until the product was quit. Building and running are two facts: this answers the second. */
- (BOOL)isRunningProduct;

/* **THE TWO FACTS A TOOLBAR ASKS ABOUT, ANSWERED FROM THE DISK RATHER THAN GUESSED.** A Build is "done" when the product
 * it makes is there, and a project is "clean" when the build directory is not — both are questions about the filesystem,
 * and both are asked on every validation pass, which is why they are cheap file tests and not cached flags. */
- (BOOL)hasProduct;
- (BOOL)isClean;
- (NSString *)output;
- (NSArray *)diagnostics;		/* AGDiagnostic, in the order they were printed */

/* THE THREE VERBS. `-build` generates the build file, configures and then builds — the chain is sequential
 * because the second half reads what the first half wrote. */
- (BOOL)build;
- (BOOL)clean;
- (BOOL)run;

/* **STOP, BECAUSE A RUNNING CHILD IS A STATE THE WINDOW MUST BE ABLE TO LEAVE.** The product outlives the click on
 * purpose — it has its own window — but a product whose window is behind this one, or which ignores its own close
 * button, would otherwise refuse Build, Clean and Run for ever. Stop terminates whatever child is running: the
 * product, or a build that is taking too long. The completion still arrives through the poll, so the stage ends and
 * the log says so. */
- (BOOL)stop;

/* **A LINE FROM THE APPLICATION ITSELF, INTO THE SAME LOG.** The toolchain's output arrives through the delegate;
 * what Forge wants to say about it — where the bundle went, which identifier it carries, why a verb was refused —
 * belongs in the same place, and in the same FILE when `FORGE_LOG_PATH` names one. Writing it to the text view alone
 * is how the pane and the file came to disagree about the same build. */
- (void)note:(NSString *)text;

@end

#endif /* AGBUILDER_H */
