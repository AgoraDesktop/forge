/*
 * AGBuilder.m — the three verbs, the pipe, and the diagnostic parse.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See AGBuilder.h. The mechanics worth knowing before reading the code:
 *
 * **EACH STAGE IS A TASK, AND THE CHAIN IS A TERMINATION HANDLER.** `cmake -S … -B …` and `cmake --build …` are
 * two processes; the second starts when the first says it exited 0. That keeps one pipe and one set of
 * readability callbacks rather than two overlapping ones, and it is what makes `isBuilding` one boolean.
 *
 * **THE PIPE IS DRAINED ON THE RUN LOOP.** `NSFileHandle -setReadabilityHandler:` fires whenever the descriptor
 * is readable — the header in `libagora-base/NSFileHandle.h` says so and says what happens when a handler is
 * installed twice — so the handler is installed once per stage and cleared when the stage ends. The task is
 * RETAINED in `_task` for exactly as long as its pipe is live.
 */

/* `dladdr` IS A GNU EXTENSION ON GLIBC (declared in `<dlfcn.h>` only under this macro) and a plain function on the
 * BSDs, where defining it changes nothing. It has to come before ANY header, which is why it is here rather than
 * beside the include. */
#define _GNU_SOURCE 1

#import "AGBuilder.h"
#import "AGProject.h"

#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSFileHandle.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSPipe.h>
#import <Foundation/NSProcessInfo.h>
#import <Foundation/NSTask.h>
#import <Foundation/NSThread.h>
#import <Foundation/NSTimer.h>
#import <Foundation/NSURL.h>

/* **THE APPKIT'S OWN HEADER FOR ONE SYMBOL: `NSApplicationMain` is the address this file asks the dynamic loader
 * about.** A Forge that was INSTALLED has no ancestor holding a prefix — nothing about `~/Applications/Forge.app`
 * says where the AppKit came from — but it is linked to that AppKit, and `dladdr` turns that link back into a path. */
#import <AppKit/NSApplication.h>

#include <dlfcn.h>
#include <stdint.h>

#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>

/* **A DIAGNOSTIC LINE PER STAGE, BEHIND THE ENVIRONMENT VARIABLE THIS TREE ALREADY USES FOR THE SAME REASON**
 * (`APPKIT_MENU_DIAG`, `AWS_INPUT_DIAG`, …). A build that does not finish has to say which child it was waiting on. */
static BOOL AGDebugging(void)
{
	static int decided = -1;

	if (decided < 0) {
		decided = (getenv("FORGE_BUILD_DIAG") != NULL) ? 1 : 0;
	}
	return decided == 1;
}


/* The toolchain, named once. `cmake` comes from PATH through `/usr/bin/env` so a caller's toolchain choice (a
 * release prefix, a CI image's newer CMake) is honoured, which is the same rule every demo script follows. */
static NSString *const AGCmakePath = @"/usr/bin/cmake";

/* THE PROCESS'S OWN BINARY, WHICH IS HOW THE SDK IS FOUND WHEN NOBODY SAID WHERE IT IS. `libagora-base` has no
 * `-executablePath` on `NSProcessInfo`, so the kernel's answer is read directly; `$_` is the fallback a shell
 * leaves behind. Answered as nil when neither is available, which leaves the environment variables as the doors. */
static NSString *AGExecutablePath(void)
{
	char buffer[4096];
	ssize_t length = readlink("/proc/self/exe", buffer, sizeof buffer - 1);

	if (length > 0) {
		buffer[length] = '\0';
		return [NSString stringWithUTF8String:buffer];
	}
	{
		const char *underscore = getenv("_");

		if (underscore != NULL && underscore[0] == '/') {
			return [NSString stringWithUTF8String:underscore];
		}
	}
	return nil;
}

@implementation AGDiagnostic

+ (instancetype)diagnosticWithFile:(NSString *)file
			      line:(NSInteger)line
			    column:(NSInteger)column
			   message:(NSString *)message
			   isError:(BOOL)isError
{
	AGDiagnostic *diagnostic = [[[self alloc] init] autorelease];

	diagnostic->_file = [(file != nil ? file : @"") copy];
	diagnostic->_line = line;
	diagnostic->_column = column;
	diagnostic->_message = [(message != nil ? message : @"") copy];
	diagnostic->_isError = isError;
	return diagnostic;
}

- (void)dealloc
{
	[_file release];
	[_message release];
	[super dealloc];
}

- (NSString *)file
{
	return _file;
}

- (NSInteger)line
{
	return _line;
}

- (NSInteger)column
{
	return _column;
}

- (NSString *)message
{
	return _message;
}

- (BOOL)isError
{
	return _isError;
}

- (NSString *)summary
{
	return [NSString stringWithFormat:@"%@:%ld: %@: %@", [_file lastPathComponent],
		(long)_line, (_isError ? @"error" : @"warning"), _message];
}

@end

/* IS THE WHOLE STRING A LINE NUMBER? A column is optional, so the test is used for both positions and the
 * caller decides whether a missing one means 0 or "this token is the file". */
static BOOL AGAllDigits(NSString *text)
{
	NSUInteger i, length = [text length];

	if (length == 0) {
		return NO;
	}
	for (i = 0; i < length; i++) {
		unichar c = [text characterAtIndex:i];

		if (c < '0' || c > '9') {
			return NO;
		}
	}
	return YES;
}

/* `file:line:column:` OR `file:line:` before a marker, split from the right so a path with a colon in it survives
 * (the leftmost split would make `/tmp/a:b.m` into a file called `/tmp/a`). Answered as three out-parameters so
 * the caller does not build a dictionary per line of a build log. */
static BOOL AGParseLocation(NSString *head, NSString **outFile, NSInteger *outLine, NSInteger *outColumn)
{
	NSArray *parts = [head componentsSeparatedByString:@":"];
	NSUInteger count = [parts count];
	NSInteger line = 0, column = 0;
	NSUInteger fileParts;

	if (count < 2) {
		return NO;
	}
	if (AGAllDigits([parts objectAtIndex:count - 1])) {
		line = [[parts objectAtIndex:count - 1] integerValue];
		fileParts = count - 1;
		if (count >= 3 && AGAllDigits([parts objectAtIndex:count - 2])) {
			column = line;
			line = [[parts objectAtIndex:count - 2] integerValue];
			fileParts = count - 2;
		}
	} else {
		return NO;
	}
	if (fileParts == 0) {
		return NO;
	}
	{
		NSMutableArray *fileComponents = [NSMutableArray array];
		NSUInteger i;

		for (i = 0; i < fileParts; i++) {
			[fileComponents addObject:[parts objectAtIndex:i]];
		}
		*outFile = [fileComponents componentsJoinedByString:@":"];
	}
	*outLine = line;
	*outColumn = column;
	return YES;
}

NSArray *AGDiagnosticsFromBuildOutput(NSString *output)
{
	NSMutableArray *diagnostics = [NSMutableArray array];
	NSArray *lines = [output componentsSeparatedByString:@"\n"];
	NSUInteger i;

	for (i = 0; i < [lines count]; i++) {
		NSString *line = [lines objectAtIndex:i];
		NSString *head = nil;
		NSString *message = nil;
		BOOL isError = NO;
		NSRange marker;

		/* clang's own two markers first: they are the ones that carry a file and a line. */
		marker = [line rangeOfString:@": error: "];
		if (marker.location == NSNotFound) {
			marker = [line rangeOfString:@": warning: "];
		}
		if (marker.location != NSNotFound) {
			head = [line substringToIndex:marker.location];
			message = [line substringFromIndex:marker.location + marker.length];
			isError = ([line rangeOfString:@": error: "].location != NSNotFound);
		} else if ([line rangeOfString:@"CMake Error at "].location == 0) {
			/* `CMake Error at CMakeLists.txt:12 (add_executable):` — a location with no column. */
			NSUInteger start = [@"CMake Error at " length];
			NSRange paren = [line rangeOfString:@" (" options:0
						      range:NSMakeRange(start, [line length] - start)];

			isError = YES;
			head = (paren.location != NSNotFound)
				? [line substringWithRange:NSMakeRange(start, paren.location - start)]
				: [line substringFromIndex:start];
			message = line;
		} else {
			continue;
		}
		{
			NSString *file = nil;
			NSInteger lineNumber = 0, column = 0;

			if (!AGParseLocation(head, &file, &lineNumber, &column)) {
				continue;
			}
			[diagnostics addObject:[AGDiagnostic diagnosticWithFile:file
								   line:lineNumber
								 column:column
								message:message
								isError:isError]];
		}
	}
	return diagnostics;
}

@implementation AGBuilder

- (instancetype)initWithProject:(AGProject *)project
{
	self = [super init];
	if (self != nil) {
		_project = [project retain];
		_output = [[NSMutableString alloc] init];
		_diagnostics = [[NSMutableArray alloc] init];
		/* **THE LOG GOES TO A FILE TOO WHEN `FORGE_LOG_PATH` NAMES ONE.** A build that fails inside a window is a
		 * build whose error text is on a screen; a file is what a person can send and what a test can read. The file
		 * is created (truncated) here and every emitted line is written to it, so the window and the file cannot
		 * disagree. */
		{
			const char *logPath = getenv("FORGE_LOG_PATH");

			if (logPath != NULL && logPath[0] != '\0') {
				NSString *path = [NSString stringWithUTF8String:logPath];

				[[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
				_logHandle = [[NSFileHandle fileHandleForWritingAtPath:path] retain];
			}
		}
	}
	return self;
}

- (void)dealloc
{
	[_logHandle closeFile];
	[_logHandle release];
	[_poll invalidate];
	[_poll release];
	[_outputPipe release];
	[_pipe release];
	[_task release];
	[_output release];
	[_diagnostics release];
	[_stage release];
	[_project release];
	[super dealloc];
}

- (AGProject *)project
{
	return _project;
}

- (void)setDelegate:(id <AGBuilderDelegate>)delegate
{
	_delegate = delegate;
}

- (id <AGBuilderDelegate>)delegate
{
	return _delegate;
}

- (BOOL)isBuilding
{
	/* **THE CHAIN IS ONE BUILD, NOT ONE CHILD PROCESS.** Configure and build are two tasks with a gap between them,
	 * and that gap is a timer — so `-isBuilding` has to answer for the whole chain or a caller sees the build end
	 * after its first half. AND A RUNNING PRODUCT IS NOT A BUILD: it is a child process too, which is why this asked
	 * `_task != nil` and refused every verb for as long as the product was open. */
	return _buildInFlight || (_task != nil && _stageIsBuild);
}

- (BOOL)isRunningProduct
{
	return _task != nil && !_stageIsBuild;
}

- (BOOL)hasProduct
{
	NSString *path = [[_project productURL] path];

	return (path != nil) && [[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (BOOL)isClean
{
	NSString *path = [[_project buildDirectoryURL] path];

	return (path != nil) && ![[NSFileManager defaultManager] fileExistsAtPath:path];
}

- (NSString *)output
{
	return _output;
}

- (NSArray *)diagnostics
{
	return _diagnostics;
}

/* ---------------------------------------------------------------------------------------------------
 * The pipe and the chain.
 * --------------------------------------------------------------------------------------------------- */

- (void)fn_appendData:(NSData *)data
{
	NSString *text;

	if (data == nil || [data length] == 0) {
		return;
	}
	text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
	if (text == nil) {
		/* A compiler that wrote a byte that is not UTF-8 should not cost the rest of the log; the lossy read is
		 * the honest fallback and keeps the readable bytes. */
		text = [[[NSString alloc] initWithBytes:[data bytes] length:[data length]
					       encoding:NSISOLatin1StringEncoding] autorelease];
	}
	if (text == nil) {
		return;
	}
	if (AGDebugging()) {
		fprintf(stderr, "forge: read %d bytes\n", (int)[text length]);
	}
	[self fn_emit:text];
}

/* **ONE PLACE APPENDS THE LOG, SO THE WINDOW, THE FILE AND THE STORED TEXT CANNOT DRIFT.** Before this door the
 * text was appended at eleven call sites and the delegate was told at two of them — which is how a line printed by
 * one path went missing from the other. Everything that writes to the log now writes it through here. */
- (void)fn_emit:(NSString *)text
{
	if ([text length] == 0) {
		return;
	}
	[_output appendString:text];
	if (_logHandle != nil) {
		[_logHandle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
		[_logHandle seekToEndOfFile];
	}
	if ([_delegate respondsToSelector:@selector(builder:didAppendOutput:)]) {
		[_delegate builder:self didAppendOutput:text];
	}
}

/* AND ONE PLACE CLEARS IT, for the same reason. */
- (void)fn_resetLog
{
	[_output setString:@""];
	if (_logHandle != nil) {
		[_logHandle truncateFileAtOffset:0];
		[_logHandle seekToEndOfFile];
	}
}

- (void)fn_finishStage:(NSString *)stage status:(int)status
{
	if ([_delegate respondsToSelector:@selector(builder:didFinishStage:status:)]) {
		[_delegate builder:self didFinishStage:stage status:status];
	}
}

/* READ WHAT THE SOURCE JUST PROMISED, NOT `-availableData`.** In this tree `-availableData` reads TO THE END OF THE
 * FILE (`libagora-base/NSFileHandle.h`), and a pipe whose writer is alive has no end — the first call would block
 * the run loop for ever, and the tool would then block on a full pipe. `terminal` records the same finding from the
 * pty side; this is the pipe side of it. */
- (void)fn_drainPipe
{
	NSFileHandle *reading = _pipe;
	NSData *chunk;

	if (reading == nil) {
		return;
	}
	[reading setReadabilityHandler:nil];
	/* **THE PARENT'S WRITE END IS CLOSED FIRST, OR THE DRAIN BLOCKS FOR EVER.** `NSPipe` owns both ends, so while
	 * this process still holds the write handle the pipe never reports EOF and `-readDataOfLength:` waits for bytes
	 * that will never come — MEASURED as a build that reported its stage finished and then hung. Closing the write
	 * end makes the read see EOF, which is what "the child has gone" means at this layer. */
	if (_outputPipe != nil) {
		[[_outputPipe fileHandleForWriting] closeFile];
		[_outputPipe release];
		_outputPipe = nil;
	}
	while ((chunk = [reading readDataOfLength:4096]) != nil && [chunk length] > 0) {
		[self fn_appendData:chunk];
	}
	[reading release];
	_pipe = nil;
}

/* START ONE STAGE. The child's output is a readability source on the run loop; its completion arrives on the
 * reaper's THREAD, which is why the handler does nothing but carry the status here. */
- (BOOL)fn_runTool:(NSString *)tool
	 arguments:(NSArray *)arguments
       inDirectory:(NSString *)directory
	     stage:(NSString *)stage
{
	NSString *line;
	NSPipe *pipe = [NSPipe pipe];
	NSTask *task = [[NSTask alloc] init];
	id <AGBuilderDelegate> delegate = _delegate;

	line = [NSString stringWithFormat:@"%% %@ %@\n", [tool lastPathComponent],
		[arguments componentsJoinedByString:@" "]];
	[self fn_emit:line];
	if (AGDebugging()) {
		fprintf(stderr, "forge: stage %s: %s\n", [stage UTF8String], [line UTF8String]);
	}

	[task setLaunchPath:tool];
	[task setArguments:arguments];
	[task setCurrentDirectoryPath:directory];
	[task setStandardOutput:pipe];
	[task setStandardError:pipe];	/* ONE pipe, so the interleaving is the tool's own, which is what a person reads */

	[_pipe release];
	_pipe = [[pipe fileHandleForReading] retain];
	[_outputPipe release];
	_outputPipe = [pipe retain];
	[_pipe setReadabilityHandler:^(NSFileHandle *handle) {
		NSData *chunk = [handle readDataOfLength:4096];

		if (AGDebugging() && (chunk == nil || [chunk length] == 0)) {
			fprintf(stderr, "forge: empty read, uninstalling\n");
		}
		if (chunk == nil || [chunk length] == 0) {
			/* **AN EMPTY READ MEANS GONE, AND THE HANDLER UNINSTALLS ITSELF.** A pipe with no writer stays
			 * readable for ever, so a handler that returns without unloading is a run loop spinning at full
			 * speed — which is what starved the timer that notices the exit. `terminal` records the same finding
			 * from the pty side; this is the pipe's. */
			[handle setReadabilityHandler:nil];
			return;
		}
		[self fn_appendData:chunk];
	}];

	/* **THE COMPLETION IS NOTICED ON THE MAIN THREAD, BY WATCHING THE TASK, AND THAT IS A DELIBERATE CHOICE.**
	 * `NSTask`'s termination handler runs on the REAPER'S OWN THREAD (`fn_task_reaper` in
	 * libagora-base/NSTask.m), where the pipe, the delegate and the window are all somebody else's — and carrying
	 * the status over with `-performSelectorOnMainThread:` was MEASURED not to arrive in a program that is not
	 * `NSApplication` (the probe below pumped the same loop the application does). Polling `-isRunning` from a
	 * timer on the run loop keeps every one of those touches on the main thread, which is where they belong, and
	 * it costs one comparison twenty times a second while a build runs. */
	[_poll invalidate];
	[_poll release];
	_poll = [[NSTimer scheduledTimerWithTimeInterval:0.05
						  target:self
						selector:@selector(fn_pollTask:)
						userInfo:nil
						 repeats:YES] retain];

	/* **WHAT KIND OF STAGE THIS IS, SAID ONCE.** "configure" and "build" are a build; "run" is the product's own
	 * process, which must not make the window say a build is in progress. */
	_stageIsBuild = [stage isEqualToString:@"configure"] || [stage isEqualToString:@"build"];
	[stage retain];
	[_stage release];
	_stage = stage;
	[_task release];
	_task = [task retain];
	if (![task launchAndReturnError:NULL]) {
		if (AGDebugging()) {
			fprintf(stderr, "forge: %s did not launch\n", [tool UTF8String]);
		}
		[_task release];
		_task = nil;
		[self fn_drainPipe];
		[task release];
		return NO;
	}
	[task release];
	return YES;
}

/* THE POLL. A running task is nothing to do; a finished one ends the stage. */
- (void)fn_pollTask:(NSTimer *)timer
{
	(void)timer;
	if (_task == nil) {
		[_poll invalidate];
		[_poll release];
		_poll = nil;
		return;
	}
	if ([_task isRunning]) {
		return;
	}
	[_poll invalidate];
	[_poll release];
	_poll = nil;
	[self fn_stageDidFinish:[NSNumber numberWithInt:[_task terminationStatus]]];
}

/* THE COMPLETION, ON THE MAIN THREAD. It drains what is left, reports the stage, and starts whatever comes next
 * for the stage that just ended. */
- (void)fn_stageDidFinish:(NSNumber *)statusNumber
{
	int status = [statusNumber intValue];
	NSString *stage = [[_stage retain] autorelease];
	NSTask *finished = _task;

	_task = nil;
	[self fn_drainPipe];
	[finished autorelease];
	if (AGDebugging()) {
		fprintf(stderr, "forge: stage %s exited %d\n", [stage UTF8String], status);
	}
	[self fn_finishStage:stage status:status];

	if ([stage isEqualToString:@"configure"]) {
		if (status == 0) {
			/* **THE SECOND STAGE IS SCHEDULED, NOT STARTED FROM INSIDE THE COMPLETION.** Launching a child from
			 * within the message that reports the previous child's exit is a re-entrant launch; a zero-delay
			 * perform puts it on the next pass of the run loop instead. */
			/* **A ONE-SHOT TIMER, NOT `-performSelector:afterDelay:`.** The delayed perform did not fire in this
			 * tree's loop while an `NSTimer` on the same loop did — MEASURED in this repository's own end-to-end
			 * test, where the configure stage ended and the build stage never began. */
			[_poll invalidate];
			[_poll release];
			_poll = [[NSTimer scheduledTimerWithTimeInterval:0.01
								  target:self
								selector:@selector(fn_startBuildStage)
								userInfo:nil
								 repeats:NO] retain];
			return;
		}
		[_diagnostics setArray:AGDiagnosticsFromBuildOutput(_output)];
		_buildInFlight = NO;
		[self fn_finishStage:@"diagnostics" status:status];
		return;
	}
	if ([stage isEqualToString:@"build"]) {
		[_diagnostics setArray:AGDiagnosticsFromBuildOutput(_output)];
		_buildInFlight = NO;
		[self fn_finishStage:@"diagnostics" status:status];
	}
}

/* THE SECOND HALF OF `-build`. */
- (void)fn_startBuildStage
{
	NSString *buildPath = [self fn_buildPath];

	if (AGDebugging()) {
		fprintf(stderr, "forge: starting the build stage\n");
	}
	[_poll invalidate];
	[_poll release];
	_poll = nil;

	if (_task != nil) {
		return;
	}
	/* **A STAGE THAT DOES NOT LAUNCH IS AN ENDED STAGE, NOT A BUILD THAT RUNS FOR EVER.** The return value used to be
	 * dropped here, so a `cmake --build` that could not start left `_buildInFlight` YES and every verb refusing for
	 * the life of the window. */
	if (![self fn_runTool:AGCmakePath
		      arguments:[NSArray arrayWithObjects:@"--build", buildPath, nil]
		    inDirectory:[self fn_projectPath]
			  stage:@"build"]) {
		_buildInFlight = NO;
		[self fn_emit:@"error: the build stage could not be started\n"];
		[_diagnostics setArray:AGDiagnosticsFromBuildOutput(_output)];
		[self fn_finishStage:@"diagnostics" status:1];
	}
}

/* **THE PREFIX THE RUNNING APPKIT WAS LOADED FROM, WHICH IS THE ONE ANCHOR AN INSTALLED FORGE HAS.** The search below
 * reads environment variables a person launching a BUNDLE does not have, and then walks this process's own ancestors —
 * which for an application in `~/Applications` is a walk to `/` that finds nothing. But the application is LINKED to the
 * AppKit, and the AppKit sits in `<prefix>/lib/libagora-app.so`, so the prefix is derivable from the link itself.
 * MEASURED: an installed Forge's Build said "The Agora SDK prefix was not found; set FORGE_SDK_PREFIX …" — and with a
 * CLEANED build directory the configure failed outright, because there was no cached `CMAKE_PREFIX_PATH` to fall back
 * on. It is also the RIGHT prefix to build against rather than a copy carried in the bundle: the product links the same
 * libraries this application is running with, which is what makes the product run afterwards. */
static NSString *fn_prefixOfLoadedAppKit(void)
{
	Dl_info info;
	void *symbol = (void *)(uintptr_t)&NSApplicationMain;
	NSString *library;

	if (dladdr(symbol, &info) == 0 || info.dli_fname == NULL) {
		return nil;
	}
	library = [NSString stringWithUTF8String:info.dli_fname];
	if ([library length] == 0) {
		return nil;
	}
	/* `<prefix>/lib/libagora-app.so` -> `<prefix>` */
	return [[library stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

/* **THE SDK PREFIX, BECAUSE A GENERATED BUILD CANNOT GUESS WHERE THE APPKIT WAS INSTALLED.** The generated
 * `CMakeLists.txt` says `find_package(AgoraApp CONFIG REQUIRED)`, and CMake needs a prefix to look in — the first
 * real session's Build failed with exactly "Add the installation prefix of AgoraApp to CMAKE_PREFIX_PATH", because
 * this application was launched without the developer's environment. The search is, in order: `FORGE_SDK_PREFIX`,
 * the tree's own `AGORA_PREFIX`, THE PREFIX THE RUNNING APPKIT CAME FROM (an installed Forge), then each ancestor of
 * this process's binary looking for `<ancestor>/lib/cmake/…` (a Forge installed NEXT TO a prefix) or
 * `<ancestor>/build-prefix/lib/cmake/…` (a Forge built in a checkout, whose binary sits in `<tree>/forge/build/`). */
- (NSString *)fn_sdkPrefix
{
	static NSString *found = nil;
	static BOOL searched = NO;
	NSDictionary *environment = [[NSProcessInfo processInfo] environment];
	NSFileManager *manager = [NSFileManager defaultManager];
	NSArray *keys = [NSArray arrayWithObjects:@"FORGE_SDK_PREFIX", @"AGORA_PREFIX", nil];
	NSUInteger i;

	if (searched) {
		return found;
	}
	searched = YES;
	for (i = 0; i < [keys count]; i++) {
		NSString *candidate = [environment objectForKey:[keys objectAtIndex:i]];

		if ([candidate length] == 0) {
			continue;
		}
		if ([manager fileExistsAtPath:[candidate stringByAppendingPathComponent:
			@"lib/cmake/AgoraApp/AgoraAppConfig.cmake"]]) {
			found = [candidate copy];
			return found;
		}
	}
	{
		/* **AND WHERE THE RUNNING APPKIT LIVES, BEFORE ANY WALK OF THIS BINARY'S OWN ANCESTORS.** An installed application's
		 * ancestors hold no prefix at all, and this is the prefix that matches the libraries it is actually using. A
		 * build-tree AppKit (`libagora-app/build/libagora-app.so`) makes this candidate `<...>/libagora-app`, which fails
		 * the manifest test below and falls through to the checkout walk — so a developer's session keeps working either
		 * way. */
		NSString *loaded = fn_prefixOfLoadedAppKit();

		if ([loaded length] > 0 && [manager fileExistsAtPath:[loaded stringByAppendingPathComponent:
			@"lib/cmake/AgoraApp/AgoraAppConfig.cmake"]]) {
			found = [loaded copy];
			return found;
		}
	}
	{
		NSString *directory = [AGExecutablePath() stringByDeletingLastPathComponent];
		int depth;

		for (depth = 0; depth < 8 && [directory length] > 1; depth++) {
			NSString *direct = [directory stringByAppendingPathComponent:
				@"lib/cmake/AgoraApp/AgoraAppConfig.cmake"];
			NSString *sibling = [directory stringByAppendingPathComponent:
				@"build-prefix/lib/cmake/AgoraApp/AgoraAppConfig.cmake"];

			if ([manager fileExistsAtPath:direct]) {
				found = [directory copy];
				return found;
			}
			if ([manager fileExistsAtPath:sibling]) {
				found = [[directory stringByAppendingPathComponent:@"build-prefix"] copy];
				return found;
			}
			directory = [directory stringByDeletingLastPathComponent];
		}
	}
	return nil;
}

- (NSString *)fn_projectPath
{
	return [[_project projectDirectoryURL] path];
}

- (NSString *)fn_buildPath
{
	return [[_project buildDirectoryURL] path];
}

/* **THE BUNDLE'S METADATA IS WRITTEN BEFORE THE BUILD, NOT BY IT.** `Info.plist` and the icon are the manifest's,
 * generated from the same keys the interface edits (`AGProject -generatedInfoPlist`); the toolchain only puts the
 * executable beside them. That keeps one answer to "what is this application called" — the project file — instead of
 * a plist template that a build would silently overwrite. */
- (BOOL)fn_writeBundleMetadata:(NSError **)error
{
	NSURL *bundle = [_project bundleURL];
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *contents;
	NSString *plist;

	if (bundle == nil || [_project type] == AGProjectTypeLibrary || [_project type] == AGProjectTypeTool) {
		return YES;		/* only a bundle has an Info.plist */
	}
	contents = [[bundle path] stringByAppendingPathComponent:@"Contents"];
	if (![manager createDirectoryAtPath:contents withIntermediateDirectories:YES attributes:nil
					error:error]) {
		return NO;
	}
	plist = [contents stringByAppendingPathComponent:@"Info.plist"];
	if (![[_project generatedInfoPlist] writeToFile:plist atomically:YES
					       encoding:NSUTF8StringEncoding
						  error:error]) {
		return NO;
	}
	{
		NSString *icon = [_project iconPath];

		if (icon != nil && [icon length] > 0) {
			NSString *source = [[[_project projectDirectoryURL] path] stringByAppendingPathComponent:icon];
			NSString *resources = [contents stringByAppendingPathComponent:@"Resources"];
			NSString *destination = [resources stringByAppendingPathComponent:[icon lastPathComponent]];

			if (![manager createDirectoryAtPath:resources withIntermediateDirectories:YES
						 attributes:nil error:error]) {
				return NO;
			}
			[manager removeItemAtPath:destination error:NULL];	/* a replaced icon must not be appended to */
			if (![manager copyItemAtPath:source toPath:destination error:error]) {
				return NO;
			}
		}
	}
	return YES;
}

/* THE GENERATOR, RUN AS A STEP. It is the one thing this class does itself, because it *is* the project layer. */
- (BOOL)fn_writeGeneratedBuild:(NSError **)error
{
	NSString *buildPath = [self fn_buildPath];
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *cmake = [_project generatedCMakeLists];
	NSString *path = [buildPath stringByAppendingPathComponent:@"CMakeLists.txt"];

	if (![manager fileExistsAtPath:buildPath]) {
		if (![manager createDirectoryAtPath:buildPath
			withIntermediateDirectories:YES
					 attributes:nil
					      error:error]) {
			return NO;
		}
	}
	if (![cmake writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:error]) {
		return NO;
	}
	return YES;
}

- (BOOL)build
{
	if ([self isBuilding] || [self isRunningProduct]) {
		return NO;
	}
	_buildInFlight = YES;
	[self fn_resetLog];
	[_diagnostics removeAllObjects];
	if (![self fn_writeBundleMetadata:NULL]) {
		[self fn_emit:@"error: the bundle's Info.plist could not be written\n"];
		_buildInFlight = NO;
		[self fn_finishStage:@"diagnostics" status:1];
		return NO;
	}
	if (![self fn_writeGeneratedBuild:NULL]) {
		[self fn_emit:@"error: the generated build could not be written\n"];
		_buildInFlight = NO;
		[self fn_finishStage:@"diagnostics" status:1];
		return NO;
	}
	/* **`-S` IS THE BUILD DIRECTORY, NOT THE PROJECT'S.** The generated `CMakeLists.txt` lives in `build/` (it is a
	 * build artifact, per the tree's convention), and CMake's source directory is where that file is. The project
	 * directory is the child's WORKING directory, which is what keeps `../Sources/…` resolving.
	 *
	 * **AND THE TOOLCHAIN IS NAMED, because this tree is clang-only and there is no plain `clang` on some machines'
	 * PATH.** `FORGE_CC`/`FORGE_OBJC` override it; the defaults are the compilers the skill and `components.conf`
	 * build with. */
	{
		NSString *projectPath = [self fn_projectPath];
		NSString *buildPath = [self fn_buildPath];
		NSString *cc = [[NSProcessInfo processInfo] environment][@"FORGE_CC"];
		NSString *objc = [[NSProcessInfo processInfo] environment][@"FORGE_OBJC"];
		NSString *sdkPrefix;
		NSMutableArray *arguments;

		/* THE DEFAULTS FIRST, THEN THE ARGUMENTS: the array was built before the defaults were applied and the
		 * first run under ctest asked CMake for a compiler called "(null)". */
		if (cc == nil) {
			cc = @"/usr/bin/clang-19";
		}
		if (objc == nil) {
			objc = cc;
		}
		sdkPrefix = [self fn_sdkPrefix];
		arguments = [NSMutableArray arrayWithObjects:
			@"-S", buildPath, @"-B", buildPath,
			[NSString stringWithFormat:@"-DCMAKE_C_COMPILER=%@", cc],
			[NSString stringWithFormat:@"-DCMAKE_OBJC_COMPILER=%@", objc], nil];

		if (sdkPrefix != nil) {
			[arguments addObject:[NSString stringWithFormat:@"-DCMAKE_PREFIX_PATH=%@", sdkPrefix]];
		} else {
			[self fn_emit:@"# The Agora SDK prefix was not found; set FORGE_SDK_PREFIX to the "
				"directory holding lib/cmake/AgoraApp.\n"];
		}

		if (![self fn_runTool:AGCmakePath
			      arguments:arguments
			    inDirectory:projectPath
				  stage:@"configure"]) {
			_buildInFlight = NO;
			[_diagnostics setArray:AGDiagnosticsFromBuildOutput(_output)];
			[self fn_finishStage:@"diagnostics" status:1];
			return NO;
		}
		return YES;
	}
}

- (BOOL)clean
{
	NSString *buildPath = [self fn_buildPath];
	NSError *error = nil;

	if ([self isBuilding] || [self isRunningProduct]) {
		return NO;
	}

	[self fn_resetLog];
	[_diagnostics removeAllObjects];
	if (![[NSFileManager defaultManager] fileExistsAtPath:buildPath]) {
		[self fn_emit:@"# There is nothing to clean; the build directory does not exist.\n"];
		[self fn_finishStage:@"clean" status:0];
		return YES;
	}
	if (![[NSFileManager defaultManager] removeItemAtPath:buildPath error:&error]) {
		[self fn_emit:[NSString stringWithFormat:@"error: %@\n", [error localizedDescription]]];
		[self fn_finishStage:@"clean" status:1];
		return NO;
	}
	[self fn_emit:@"# The build directory was removed.\n"];
	[self fn_finishStage:@"clean" status:0];
	return YES;
}

- (void)note:(NSString *)text
{
	[self fn_emit:(text != nil ? text : @"")];
}

- (BOOL)stop
{
	BOOL wasBuild;

	if (_task == nil) {
		[self fn_emit:@"# Nothing is running.\n"];
		return NO;
	}
	wasBuild = _stageIsBuild;
	/* **THE LOG IS ASCII, AND THAT IS A RULE RATHER THAN A STYLE.** This tier's text drawing passes a non-ASCII
	 * character through to the rasteriser as the first byte of its UTF-8 encoding — MEASURED: the storage, the layout
	 * and the character map all agree (5 characters, 5 glyphs, U+2026 != U+00E2), and the pane still drew `â`. Until
	 * that is found, a log nobody can read is worse than a log without an ellipsis, so every line this tool writes is
	 * plain ASCII — see `tests/verb_conflicts.m`, which asserts it. */
	[self fn_emit:[NSString stringWithFormat:@"# Stopping %@...\n",
		wasBuild ? @"the build" : @"the product"]];
	/* **THE FLIGHT FLAG IS CLEARED HERE AS WELL AS BY THE STAGE'S COMPLETION.** A child that takes its time to die
	 * (or ignores SIGTERM) would otherwise keep every verb answering "a build is running" — the very state Stop
	 * exists to end. The completion still arrives through the poll and reports the exit. */
	if (wasBuild) {
		_buildInFlight = NO;
	}
	[_task terminate];
	return YES;
}

- (BOOL)run
{
	NSString *productPath = [[_project productURL] path];

	if ([self isBuilding] || [self isRunningProduct]) {
		return NO;
	}
	if (![[NSFileManager defaultManager] fileExistsAtPath:productPath]) {
		[self fn_emit:@"error: there is no product to run; build the project first\n"];
		[self fn_finishStage:@"run" status:1];
		return NO;
	}
	/* A RUN IS THE PRODUCT'S OWN PROCESS, not this one's: the product has its own window and must outlive the
	 * click. `cmake` is not involved, so the stage's pipe is the product's own output. */
	return [self fn_runTool:productPath
		      arguments:[NSArray array]
		    inDirectory:[self fn_projectPath]
			  stage:@"run"];
}

@end
