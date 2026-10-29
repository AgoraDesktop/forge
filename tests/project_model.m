/*
 * project_model — the manifest, the categories and the generated build, with no window anywhere.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **THE CLAIM IS A ROUND TRIP AND A REFUSAL.** A project that is created, written and read back must be the same
 * project — name, type, and the files in the order they were added — and the reader must refuse a manifest it does
 * not fully understand rather than opening an empty project that looks fine. The generated CMake is checked by
 * what a person would look for in it: the target's name, the `../` source path, and the SDK's `find_package`.
 */
#import "AGProject.h"

#import <Foundation/Foundation.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int s_failed;

static void check(int ok, const char *what)
{
	printf("  %s   %s\n", ok ? "ok  " : "FAIL", what);
	if (!ok) {
		s_failed++;
	}
}

static NSString *fn_make_temp_project_directory(void)
{
	NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
		[NSString stringWithFormat:@"forge-project-%d", (int)getpid()]];

	[[NSFileManager defaultManager] createDirectoryAtPath:path
				  withIntermediateDirectories:YES
						   attributes:nil
							error:NULL];
	return path;
}

int main(void)
{
	@autoreleasepool {
		NSString *directory = fn_make_temp_project_directory();
		NSURL *URL = [NSURL fileURLWithPath:directory isDirectory:YES];
		NSString *sources = [directory stringByAppendingPathComponent:@"Sources"];
		NSString *headers = [directory stringByAppendingPathComponent:@"Headers"];
		NSString *mainSource = [sources stringByAppendingPathComponent:@"main.m"];
		NSString *header = [headers stringByAppendingPathComponent:@"Widget.h"];
		AGProject *project;
		AGProject *reloaded;
		NSString *cmake;
		NSError *error = nil;

		[[NSFileManager defaultManager] createDirectoryAtPath:sources
					  withIntermediateDirectories:YES
							   attributes:nil
								error:NULL];
		[[NSFileManager defaultManager] createDirectoryAtPath:headers
					  withIntermediateDirectories:YES
							   attributes:nil
								error:NULL];
		[@"int main(void) { return 0; }\n" writeToFile:mainSource atomically:YES
							encoding:NSUTF8StringEncoding error:NULL];
		[@"@interface Widget : NSObject\n@end\n" writeToFile:header atomically:YES
							encoding:NSUTF8StringEncoding error:NULL];

		/* CREATED, FILLED, WRITTEN. */
		project = [AGProject newProjectAtDirectoryURL:URL name:@"Forge Test" type:AGProjectTypeApplication
						       error:&error];
		check(project != nil, "a project is created in an empty directory");
		check([[project name] isEqualToString:@"Forge Test"], "the name is what the caller asked for");
		check([[project typeName] isEqualToString:@"application"], "the type is spelled the way the manifest says");
		check([[[directory stringByAppendingPathComponent:AGProjectManifestName]
			stringByAppendingString:@""] length] > 0, "the manifest path exists");

		check([project addFileAtAbsolutePath:mainSource error:&error], "a source inside the project is accepted");
		check([project addFileAtAbsolutePath:header error:&error], "a header inside the project is accepted");
		check([project addFileAtAbsolutePath:mainSource error:&error], "adding the same file twice is not an error");
		check([[project files] count] == 2, "the duplicate was not stored a second time");

		error = nil;
		check(![project addFileAtAbsolutePath:@"/etc/hostname" error:&error],
		      "a file outside the project directory is refused");
		check(error != nil, "the refusal says why");

		check([[project categories] count] == 2, "two categories have files in them");
		check([[[project categories] objectAtIndex:0] isEqualToString:AGProjectCategorySources],
		      "Sources is listed first");
		check([[[project categories] objectAtIndex:1] isEqualToString:AGProjectCategoryHeaders],
		      "Headers follows it");
		check([[project filesInCategory:AGProjectCategoryOther] count] == 0,
		      "a category with no files is absent rather than empty");

		check([project writeToURL:URL error:&error], "the manifest is written");

		/* READ BACK. */
		reloaded = [AGProject projectWithContentsOfURL:URL error:&error];
		check(reloaded != nil, "the project reads back");
		check([[reloaded name] isEqualToString:@"Forge Test"], "the name survived the round trip");
		check([[reloaded files] count] == 2, "both files survived the round trip");
		check([[[[reloaded files] objectAtIndex:0] relativePath] isEqualToString:@"Sources/main.m"],
		      "the paths are relative to the project and in the order they were added");
		check(![reloaded isDirty], "a project just read is not dirty");

		/* THE GENERATED BUILD. */
		cmake = [reloaded generatedCMakeLists];
		check([cmake rangeOfString:@"add_executable(Forge_Test"].location != NSNotFound,
		      "the target name is the project's name made safe for CMake");
		check([cmake rangeOfString:@"    ../Sources/main.m\n"].location != NSNotFound,
		      "the source is named relative to the build directory");
		check([cmake rangeOfString:@"find_package(AgoraApp CONFIG REQUIRED)"].location != NSNotFound,
		      "the generated build resolves the SDK");
		check([cmake rangeOfString:@"target_link_libraries(Forge_Test PRIVATE AgoraApp::App)"].location != NSNotFound,
		      "the target links the AppKit");

		/* **THE BUNDLE'S METADATA: DEFAULTS, A REFUSAL, A ROUND TRIP, AND THE PLIST IT PRODUCES.** The defaults matter
		 * because a project written before these keys existed must still build; the refusal matters because the
		 * identifier is what a launcher keys on; and the plist is the file the whole feature exists to write. */
		{
			AGProject *fresh = [AGProject projectWithContentsOfURL:URL error:NULL];

			check([[fresh displayName] isEqualToString:@"Forge Test"], "the display name defaults to the project's name");
			check([[fresh bundleIdentifier] isEqualToString:@"io.github.agoradesktop.forge_test"],
			      "the identifier defaults to reverse-DNS from the target name");
			check([[fresh bundleVersion] isEqualToString:@"0.1.0"], "the version defaults to 0.1.0");
			check([fresh iconPath] == nil, "a project with no icon says so rather than inventing one");

			check(![fresh setBundleIdentifier:@"nonsense"], "an identifier without a dot is refused");
			check(![fresh setBundleIdentifier:@".leading"], "an empty leading component is refused");
			check(![fresh setBundleIdentifier:@"has space.io"], "a space is refused");
			check([fresh setBundleIdentifier:@"io.github.agoradesktop.forge-test"],
			      "a reverse-DNS identifier with a hyphen is accepted");

			[fresh setDisplayName:@"Forge Test App"];
			[fresh setBundleVersion:@"2.1.0"];
			[fresh setIconPath:@"Resources/app.png"];
			check([fresh writeToURL:URL error:NULL], "the manifest with metadata is written");

			{
				AGProject *again = [AGProject projectWithContentsOfURL:URL error:NULL];

				check([[again displayName] isEqualToString:@"Forge Test App"], "the display name round trips");
				check([[again bundleIdentifier] isEqualToString:@"io.github.agoradesktop.forge-test"],
				      "the identifier round trips");
				check([[again bundleVersion] isEqualToString:@"2.1.0"], "the version round trips");
				check([[again iconPath] isEqualToString:@"Resources/app.png"], "the icon path round trips");
			}
			{
				NSString *plist = [fresh generatedInfoPlist];

				check([plist rangeOfString:@"<key>CFBundleIdentifier</key>\n\t<string>io.github.agoradesktop.forge-test</string>"].location != NSNotFound,
				      "the plist carries the identifier");
				check([plist rangeOfString:@"<key>CFBundleName</key>\n\t<string>Forge Test App</string>"].location != NSNotFound,
				      "the plist carries the display name");
				check([plist rangeOfString:@"<key>CFBundleExecutable</key>\n\t<string>Forge_Test</string>"].location != NSNotFound,
				      "the plist names the target the build makes");
				check([plist rangeOfString:@"<key>CFBundleIconFile</key>\n\t<string>app.png</string>"].location != NSNotFound,
				      "the plist names the icon's file");
				check([plist rangeOfString:@"<key>CFBundleShortVersionString</key>\n\t<string>2.1.0</string>"].location != NSNotFound,
				      "the plist carries the version");
			}
			/* A NAME WITH XML'S OWN CHARACTERS IN IT MUST NOT BREAK THE FILE. */
			[fresh setDisplayName:@"A & B <tools>"];
			check([[fresh generatedInfoPlist] rangeOfString:@"A &amp; B &lt;tools&gt;"].location != NSNotFound,
			      "a name with an ampersand and angle brackets is escaped");
			[fresh writeToURL:URL error:NULL];
		}

		/* THE REFUSAL. A manifest carrying a key this reader does not know is refused BY NAME. */
		{
			NSMutableDictionary *plist = [NSMutableDictionary dictionary];
			NSData *data;
			NSURL *other = [NSURL fileURLWithPath:
				[fn_make_temp_project_directory() stringByAppendingPathComponent:@"unknown"]];

			[[NSFileManager defaultManager] createDirectoryAtPath:[other path]
						  withIntermediateDirectories:YES
								   attributes:nil
									error:NULL];
			[plist setObject:[NSNumber numberWithInt:1] forKey:@"AGProjectFormatVersion"];
			[plist setObject:@"Typo" forKey:@"AGProjctName"];
			data = [NSPropertyListSerialization dataWithPropertyList:plist
									  format:NSPropertyListXMLFormat_v1_0
									 options:0
									   error:NULL];
			[data writeToFile:[[other path] stringByAppendingPathComponent:AGProjectManifestName]
			   atomically:YES];
			error = nil;
			check([AGProject projectWithContentsOfURL:other error:&error] == nil,
			      "a manifest with an unknown key is refused");
			check(error != nil && [[error localizedDescription] rangeOfString:@"AGProjctName"].location != NSNotFound,
			      "the refusal names the key");
		}

		[[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
	}
	printf("%s\n", s_failed == 0 ? "all checks passed" : "FAILURES");
	return s_failed == 0 ? 0 : 1;
}
