/*
 * AGProject.h — a project on disk: its manifest, the files it names, and the build it generates.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A PROJECT IS A DIRECTORY WITH A TEXT FILE IN IT, AND THAT FILE IS THE PROJECT.** The directory is the
 * project (the way `Foo.pcproj` is a directory and not a document in the reference project manager); inside it
 * is `Project.agproj`, an XML property list, which is the only file this class reads or writes. Everything else
 * in the directory — the sources, the resources, the generated build — is named BY that file rather than
 * inferred from a scan, so a file that is in the directory and not in the manifest is a file the project does
 * not claim. That is the same rule the tree states for components ("a manifest that says what to build").
 *
 * **THE MANIFEST IS A MANIFEST FOR A GENERATED BUILD, NOT A BUILD SYSTEM.** See `DEVELOPMENT-TOOLS.md` §4: the
 * cheapest project layer is a description plus a generator, and `-generatedCMakeLists` is the generator. It
 * emits the CMake this tree already knows how to build, against the installed SDK in `build-prefix/`. Nothing
 * here parses or interprets CMake; the toolchain does.
 *
 * **CATEGORIES ARE THE BROWSER'S, AND THEY ARE DERIVED RATHER THAN STORED.** The Project Center browser groups a
 * project's files (Sources, Headers, Resources, Other); a stored group would be a second copy of a fact the path
 * already carries, and a group whose entries disagreed with the file list would be a bug with no owner. So the
 * category is computed from the extension at the point of display, in one place.
 */
#ifndef AGPROJECT_H
#define AGPROJECT_H

#import <Foundation/NSArray.h>
#import <Foundation/NSObject.h>
#import <Foundation/NSString.h>

@class NSError, NSMutableArray, NSMutableDictionary, NSURL;

/* THE MANIFEST'S FILE NAME AND VERSION. The version is written so a reader can refuse a file it is too old for,
 * which is the one forward-compatibility rule this format has. */
extern NSString *const AGProjectManifestName;
extern NSString *const AGProjectErrorDomain;

/* THE BROWSER'S GROUPS, in the order Project Center lists them. `AGProjectCategoryOther` is the bucket every
 * extension this file does not recognise falls into — a category is a view, never a filter that drops a file. */
extern NSString *const AGProjectCategorySources;
extern NSString *const AGProjectCategoryHeaders;
extern NSString *const AGProjectCategoryResources;
extern NSString *const AGProjectCategoryOther;

/* WHAT THE PROJECT BUILDS. The four the reference project manager offers, with its meanings: an application is
 * an executable with a bundle, a tool is an executable without one, a library is a shared library, and a bundle
 * is a loadable resource (`NSBundle -load`). */
typedef enum {
	AGProjectTypeApplication = 0,
	AGProjectTypeTool,
	AGProjectTypeLibrary,
	AGProjectTypeBundle
} AGProjectType;

/* ONE FILE THE PROJECT NAMES. The path is RELATIVE to the project directory and is stored that way, so a project
 * that is moved or checked out into another directory keeps working — an absolute path in a manifest is a
 * manifest that only works on the machine that wrote it. */
@interface AGProjectFile : NSObject
{
	NSString *_relativePath;
}

+ (instancetype)fileWithRelativePath:(NSString *)relativePath;
- (instancetype)initWithRelativePath:(NSString *)relativePath;

- (NSString *)relativePath;
- (NSString *)displayName;
- (NSString *)category;

@end

@interface AGProject : NSObject
{
	NSURL *_URL;			/* RETAINED: the project DIRECTORY */
	NSString *_name;		/* RETAINED */
	AGProjectType _type;
	NSString *_buildDirectory;	/* RETAINED: relative to the project directory */
	NSMutableArray *_files;		/* RETAINED: AGProjectFile, in manifest order */
	NSString *_displayName;		/* RETAINED or nil: the manifest's answer, or nil for the project's name */
	NSString *_bundleIdentifier;	/* RETAINED or nil: reverse-DNS, or nil for the default */
	NSString *_bundleVersion;	/* RETAINED or nil: the manifest's answer, or nil for 0.1.0 */
	NSString *_iconPath;		/* RETAINED or nil: a file relative to the project */
	BOOL _dirty;
}

/* READING. `url` may be the project DIRECTORY or the manifest file inside it, because a person drags either. */
+ (instancetype)projectWithContentsOfURL:(NSURL *)url error:(NSError **)error;

/* MAKING ONE. The directory is created if it does not exist, with nothing in it but the manifest; a person's
 * first source file is added afterwards, by `-addFileAtAbsolutePath:error:` or by the editor's own save. */
+ (instancetype)newProjectAtDirectoryURL:(NSURL *)directoryURL
				    name:(NSString *)name
				    type:(AGProjectType)type
				   error:(NSError **)error;

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error;
- (NSURL *)manifestURL;

- (NSURL *)URL;
- (NSURL *)projectDirectoryURL;
- (NSString *)name;
- (AGProjectType)type;
- (NSString *)typeName;			/* the manifest's spelling: "application", "tool", … */
- (NSURL *)buildDirectoryURL;
- (BOOL)isDirty;
- (void)setName:(NSString *)name;

/* **THE BUNDLE'S METADATA, WHICH IS THE MANIFEST'S TO CARRY.** An application's `Info.plist` is not a build setting:
 * it is what the thing IS — its identifier, the name a person sees, its version, its icon. So those are keys in the
 * project file (and the interface that edits them edits the project), and the bundle is generated from them.
 *
 * Each answers a DEFAULT when the manifest is silent, so a project written before these keys existed still builds:
 * the display name is the project's name, the identifier is `io.github.agoradesktop.<target>`, and the version is
 * 0.1.0. The identifier is the one field with a shape (reverse-DNS, letters, digits, hyphens and dots), and a value
 * that is not one is refused at the door that sets it rather than silently written into a plist no launcher can use. */
- (NSString *)displayName;			/* CFBundleName, defaulting to the project's name */
- (NSString *)bundleIdentifier;			/* CFBundleIdentifier, defaulting to io.github.agoradesktop.<target> */
- (NSString *)bundleVersion;			/* CFBundleShortVersionString and CFBundleVersion, defaulting to 0.1.0 */
- (NSString *)iconPath;				/* RETAINED or nil: a file relative to the project, copied into Resources */

- (void)setDisplayName:(NSString *)name;
- (BOOL)setBundleIdentifier:(NSString *)identifier;	/* refused unless it is a reverse-DNS-shaped name */
- (void)setBundleVersion:(NSString *)version;
- (void)setIconPath:(NSString *)relativePath;

/* THE TWO THINGS THE BUNDLE NEEDS FROM THE MANIFEST, as text: the `Info.plist` a launcher reads, and the resource
 * copies it needs beside the executable. Both are generated from the keys above, so the plist and the interface
 * cannot disagree about what the application is called. */
- (NSString *)generatedInfoPlist;

/* The bundle's own URL — `<build>/<target>.app` — which is what a person opens, as distinct from `-productURL`,
 * which is the executable inside it. */
- (NSURL *)bundleURL;

/* THE FILES, in manifest order, and the same list grouped for a browser. A group with no files is absent, which
 * is what a browser wants and what a stored group could not promise. */
- (NSArray *)files;
- (NSArray *)categories;
- (NSArray *)filesInCategory:(NSString *)category;

/* ABSOLUTE AND RELATIVE, IN BOTH DIRECTIONS. `-absolutePathForFile:` is what the editor opens; a path outside the
 * project directory is refused by `-addFileAtAbsolutePath:error:` rather than stored with `..` in it, because the
 * generated build would then be one a checkout could not reproduce. */
- (NSString *)absolutePathForFile:(AGProjectFile *)file;
- (BOOL)addFileAtAbsolutePath:(NSString *)absolutePath error:(NSError **)error;
- (BOOL)removeFile:(AGProjectFile *)file error:(NSError **)error;

/* THE GENERATOR. One string, written to `<build>/CMakeLists.txt` by the builder; it is a method here because the
 * project is what knows its targets, sources and dependencies, and a generator that was also a writer would be
 * two ways to ask the same question. */
- (NSString *)generatedCMakeLists;

/* THE PRODUCT THE GENERATED BUILD MAKES: `<build>/<name>`, and `<build>/<name>.app/Contents/<platform>/<arch>/<name>`
 * for an application. `-productURL` answers the second when the type makes a bundle, the first otherwise. */
- (NSURL *)productURL;

@end

/* THE TYPE'S MANIFEST SPELLING, in both directions; the reader refuses an unknown word rather than defaulting. */
NSString *AGProjectTypeName(AGProjectType type);
BOOL AGProjectTypeFromName(NSString *name, AGProjectType *outType);

#endif /* AGPROJECT_H */
