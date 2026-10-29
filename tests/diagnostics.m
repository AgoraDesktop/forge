/*
 * diagnostics — the build log's parse, on canned compiler output, with no compiler, task or window.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE PARSE IS THE PART A PERSON DEPENDS ON, AND IT IS THE PART THAT CAN BE TESTED WITHOUT A BUILD.** A build
 * panel that loses a diagnostic is a build panel that makes a person read the whole log; the cases below are the
 * ones a real clang and a real CMake actually print — a column, no column, a warning, a path containing a colon,
 * and the CMake error form that has no column at all.
 */
#import "AGBuilder.h"

#import <Foundation/Foundation.h>

#include <stdio.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

int main(void)
{
	@autoreleasepool {
		NSString *output =
			@"/tmp/p/Sources/main.m:12:5: error: use of undeclared identifier 'x'\n"
			@"/tmp/p/Sources/main.m:14: warning: unused variable 'y' [-Wunused-variable]\n"
			@"/tmp/a:b/Sources/odd.m:3:1: error: a path may hold a colon\n"
			@"    printf(\"not a diagnostic\\n\");\n"
			@"CMake Error at CMakeLists.txt:7 (add_executable):\n"
			@"  Cannot find source file:\n";
		NSArray *diagnostics = AGDiagnosticsFromBuildOutput(output);
		AGDiagnostic *first;
		AGDiagnostic *second;
		AGDiagnostic *third;
		AGDiagnostic *fourth;

		check([diagnostics count] == 4, "four diagnostics out of six lines");
		first = [diagnostics objectAtIndex:0];
		check([[first file] isEqualToString:@"/tmp/p/Sources/main.m"], "the file is the path before the marker");
		check([first line] == 12, "the line is the first number");
		check([first column] == 5, "the column is the second number");
		check([first isError], "error is an error");
		check([[first message] isEqualToString:@"use of undeclared identifier 'x'"],
		      "the message is what follows the marker");

		second = [diagnostics objectAtIndex:1];
		check([second line] == 14 && [second column] == 0, "a warning with no column answers column 0");
		check(![second isError], "warning is not an error");

		third = [diagnostics objectAtIndex:2];
		check([[third file] isEqualToString:@"/tmp/a:b/Sources/odd.m"],
		      "a colon in the path does not split the file name");

		fourth = [diagnostics objectAtIndex:3];
		check([[fourth file] isEqualToString:@"CMakeLists.txt"], "the CMake form carries its file");
		check([fourth line] == 7, "the CMake form carries its line");
		check([[fourth message] rangeOfString:@"add_executable"].location != NSNotFound,
		      "the CMake form keeps its own sentence");

		check([AGDiagnosticsFromBuildOutput(@"") count] == 0, "an empty log has no diagnostics");
		check([AGDiagnosticsFromBuildOutput(@"Building C object foo.c.o\n") count] == 0,
		      "an ordinary build line is not a diagnostic");
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
