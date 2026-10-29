/*
 * AGProject.m — the manifest's reader, its writer, and the CMake it generates.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See AGProject.h for the model. Two things are worth saying here that the header does not.
 *
 * **A KEY THIS READER DOES NOT KNOW IS REFUSED, NOT IGNORED.** `NSNibSource.h` states the rule for the nib
 * compiler — "a compiler that silently drops a typo is a compiler that silently drops a design" — and a project
 * manifest has the same failure shape: a misspelled `AGProjectFilePaths` would open an empty project that looks
 * fine. So the reader walks the dictionary's keys, refuses the first one it does not name, and says which.
 *
 * **THE GENERATED BUILD IS RELATIVE TO THE BUILD DIRECTORY, AND SO ARE THE SOURCES.** The manifest names files
 * relative to the project directory; the generated `CMakeLists.txt` lives one level down, in `build/`, so every
 * source is prefixed with `../` at generation time. That is the whole transformation, and it is why the CMake
 * that is generated is the CMake a person would have written by hand in that directory.
 */
#import "AGProject.h"

#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSError.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSPropertyList.h>
#import <Foundation/NSPropertyListSerialization.h>
#import <Foundation/NSString.h>
#import <Foundation/NSURL.h>

NSString *const AGProjectManifestName = @"Project.agproj";
NSString *const AGProjectErrorDomain = @"AGProjectErrorDomain";

NSString *const AGProjectCategorySources = @"Sources";
NSString *const AGProjectCategoryHeaders = @"Headers";
NSString *const AGProjectCategoryResources = @"Resources";
NSString *const AGProjectCategoryOther = @"Other Sources";

/* THE KEYS THE MANIFEST MAY CARRY. Kept in one place because the reader's refusal walks this list. */
static NSString *const AGKeyFormatVersion = @"AGProjectFormatVersion";
static NSString *const AGKeyName = @"AGProjectName";
static NSString *const AGKeyType = @"AGProjectType";
static NSString *const AGKeyBuildDirectory = @"AGProjectBuildDirectory";
static NSString *const AGKeyFilePaths = @"AGProjectFilePaths";
/* THE BUNDLE'S METADATA. Optional, so a manifest written before they existed still opens — each has a default in
 * `-displayName` and its neighbours rather than a required key. */
static NSString *const AGKeyDisplayName = @"AGProjectDisplayName";
static NSString *const AGKeyIdentifier = @"AGProjectIdentifier";
static NSString *const AGKeyVersion = @"AGProjectVersion";
static NSString *const AGKeyIconPath = @"AGProjectIconPath";

static const NSInteger AGProjectFormatVersion = 1;

static NSError *AGProjectError(NSString *description)
{
	/* THE KEY IS THE TREE'S OWN CONSTANT: libagora-base spells it "NSLocalizedDescriptionKey", not Apple's
	 * "NSLocalizedDescription", and a literal here would be a message that never reaches -localizedDescription. */
	NSDictionary *info = [NSDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];

	return [NSError errorWithDomain:AGProjectErrorDomain code:1 userInfo:info];
}

NSString *AGProjectTypeName(AGProjectType type)
{
	switch (type) {
	case AGProjectTypeApplication:	return @"application";
	case AGProjectTypeTool:		return @"tool";
	case AGProjectTypeLibrary:	return @"library";
	case AGProjectTypeBundle:	return @"bundle";
	}
	return @"application";
}

BOOL AGProjectTypeFromName(NSString *name, AGProjectType *outType)
{
	if ([name isEqualToString:@"application"]) {
		if (outType != NULL) { *outType = AGProjectTypeApplication; }
		return YES;
	}
	if ([name isEqualToString:@"tool"]) {
		if (outType != NULL) { *outType = AGProjectTypeTool; }
		return YES;
	}
	if ([name isEqualToString:@"library"]) {
		if (outType != NULL) { *outType = AGProjectTypeLibrary; }
		return YES;
	}
	if ([name isEqualToString:@"bundle"]) {
		if (outType != NULL) { *outType = AGProjectTypeBundle; }
		return YES;
	}
	return NO;
}

/* THE CATEGORY OF ONE PATH, computed once and asked from one place. The extension is lowercased because a person
 * writing `.M` means the same language as `.m`. */
static NSString *AGCategoryForPath(NSString *path)
{
	NSString *extension = [[path pathExtension] lowercaseString];

	if ([extension isEqualToString:@"m"] || [extension isEqualToString:@"c"] ||
	    [extension isEqualToString:@"cc"] || [extension isEqualToString:@"cpp"] ||
	    [extension isEqualToString:@"cxx"] || [extension isEqualToString:@"mm"] ||
	    [extension isEqualToString:@"s"]) {
		return AGProjectCategorySources;
	}
	if ([extension isEqualToString:@"h"] || [extension isEqualToString:@"hh"] ||
	    [extension isEqualToString:@"hpp"] || [extension isEqualToString:@"hxx"]) {
		return AGProjectCategoryHeaders;
	}
	if ([extension isEqualToString:@"plist"] || [extension isEqualToString:@"strings"] ||
	    [extension isEqualToString:@"nib"] || [extension isEqualToString:@"agproj"] ||
	    [extension isEqualToString:@"png"] || [extension isEqualToString:@"tiff"] ||
	    [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"pdf"] ||
	    [extension isEqualToString:@"txt"] || [extension isEqualToString:@"rtf"]) {
		return AGProjectCategoryResources;
	}
	return AGProjectCategoryOther;
}

/* A NAME THAT IS SAFE TO PUT IN A CMAKE TARGET: letters, digits and underscores, and never a leading digit. A
 * project called "my app" is a project whose target is `my_app` rather than one whose generated build is a
 * syntax error, and the manifest keeps the name the person typed. */
static NSString *AGTargetNameFromProjectName(NSString *name)
{
	NSMutableString *target = [NSMutableString string];
	NSUInteger i, length = [name length];

	for (i = 0; i < length; i++) {
		unichar c = [name characterAtIndex:i];

		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			[target appendFormat:@"%C", c];
		} else {
			[target appendString:@"_"];
		}
	}
	if ([target length] == 0) {
		return @"project";
	}
	{
		unichar first = [target characterAtIndex:0];

		if (first >= '0' && first <= '9') {
			return [@"project_" stringByAppendingString:target];
		}
	}
	return target;
}

@implementation AGProjectFile

+ (instancetype)fileWithRelativePath:(NSString *)relativePath
{
	return [[[self alloc] initWithRelativePath:relativePath] autorelease];
}

- (instancetype)initWithRelativePath:(NSString *)relativePath
{
	self = [super init];
	if (self != nil) {
		_relativePath = [relativePath copy];
	}
	return self;
}

- (void)dealloc
{
	[_relativePath release];
	[super dealloc];
}

- (NSString *)relativePath
{
	return _relativePath;
}

- (NSString *)displayName
{
	return [_relativePath lastPathComponent];
}

- (NSString *)category
{
	return AGCategoryForPath(_relativePath);
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<AGProjectFile %@>", _relativePath];
}

@end

/* THE READER'S PRIVATE DOOR, declared before use so a caller above it compiles without a forward warning. */
@interface AGProject ()
- (BOOL)fn_loadDictionary:(NSDictionary *)plist projectPath:(NSString *)path error:(NSError **)error;
@end

@implementation AGProject

+ (instancetype)projectWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *path = [url path];
	BOOL isDirectory = NO;

	if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
		if (error != NULL) {
			*error = AGProjectError([NSString stringWithFormat:@"There is nothing at %@.", path]);
		}
		return nil;
	}
	if (!isDirectory) {
		/* A manifest chosen directly: the project is the directory that holds it. */
		path = [path stringByDeletingLastPathComponent];
	}
	{
		NSString *manifestPath = [path stringByAppendingPathComponent:AGProjectManifestName];
		NSData *data = [NSData dataWithContentsOfFile:manifestPath];
		id plist;
		NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
		AGProject *project;

		if (data == nil) {
			if (error != NULL) {
				*error = AGProjectError([NSString stringWithFormat:
					@"%@ has no %@ in it.", path, AGProjectManifestName]);
			}
			return nil;
		}
		plist = [NSPropertyListSerialization propertyListWithData:data
								 options:NSPropertyListImmutable
								  format:&format
								   error:error];
		if (plist == nil || ![plist isKindOfClass:[NSDictionary class]]) {
			if (error != NULL && *error == nil) {
				*error = AGProjectError(@"The project manifest is not a dictionary.");
			}
			return nil;
		}
		project = [[[self alloc] init] autorelease];
		if (![project fn_loadDictionary:plist projectPath:path error:error]) {
			return nil;
		}
		return project;
	}
}

+ (instancetype)newProjectAtDirectoryURL:(NSURL *)directoryURL
				    name:(NSString *)name
				    type:(AGProjectType)type
				   error:(NSError **)error
{
	NSFileManager *manager = [NSFileManager defaultManager];
	NSString *path = [directoryURL path];
	AGProject *project;

	if (![manager fileExistsAtPath:path]) {
		if (![manager createDirectoryAtPath:path
			withIntermediateDirectories:YES
					 attributes:nil
					      error:error]) {
			return nil;
		}
	}
	if ([manager fileExistsAtPath:[path stringByAppendingPathComponent:AGProjectManifestName]]) {
		if (error != NULL) {
			*error = AGProjectError([NSString stringWithFormat:
				@"%@ already holds a project.", path]);
		}
		return nil;
	}
	project = [[[self alloc] init] autorelease];
	project->_URL = [directoryURL retain];
	project->_name = [([name length] > 0 ? name : @"Untitled") copy];
	project->_type = type;
	project->_buildDirectory = [@"build" copy];
	project->_files = [[NSMutableArray alloc] init];
	project->_dirty = YES;
	if (![project writeToURL:directoryURL error:error]) {
		return nil;
	}
	return project;
}

- (instancetype)init
{
	self = [super init];
	if (self != nil) {
		_files = [[NSMutableArray alloc] init];
		_type = AGProjectTypeApplication;
		_buildDirectory = [@"build" copy];
	}
	return self;
}

- (void)dealloc
{
	[_URL release];
	[_name release];
	[_buildDirectory release];
	[_files release];
	[_displayName release];
	[_bundleIdentifier release];
	[_bundleVersion release];
	[_iconPath release];
	[super dealloc];
}

/* ---------------------------------------------------------------------------------------------------
 * READING, which is the refusal as much as the acceptance.
 * --------------------------------------------------------------------------------------------------- */

- (BOOL)fn_loadDictionary:(NSDictionary *)plist projectPath:(NSString *)path error:(NSError **)error
{
	NSArray *keys = [plist allKeys];
	NSUInteger i;
	NSArray *known = [NSArray arrayWithObjects:AGKeyFormatVersion, AGKeyName, AGKeyType,
				   AGKeyBuildDirectory, AGKeyFilePaths, AGKeyDisplayName, AGKeyIdentifier,
				   AGKeyVersion, AGKeyIconPath, nil];
	NSNumber *version;
	NSString *typeName;
	AGProjectType type = AGProjectTypeApplication;
	NSArray *paths;

	for (i = 0; i < [keys count]; i++) {
		NSString *key = [keys objectAtIndex:i];

		if (![known containsObject:key]) {
			if (error != NULL) {
				*error = AGProjectError([NSString stringWithFormat:
					@"The project manifest carries a key this reader does not know: %@.", key]);
			}
			return NO;
		}
	}
	version = [plist objectForKey:AGKeyFormatVersion];
	if (version == nil || [version integerValue] > AGProjectFormatVersion) {
		if (error != NULL) {
			*error = AGProjectError([NSString stringWithFormat:
				@"This project's format version (%@) is newer than this Forge reads (%ld).",
				version, (long)AGProjectFormatVersion]);
		}
		return NO;
	}
	_URL = [[NSURL alloc] initFileURLWithPath:path isDirectory:YES];
	_name = [([plist objectForKey:AGKeyName] ?: @"Untitled") copy];
	typeName = [plist objectForKey:AGKeyType];
	if (typeName != nil && !AGProjectTypeFromName(typeName, &type)) {
		if (error != NULL) {
			*error = AGProjectError([NSString stringWithFormat:
				@"The project manifest names an unknown project type: %@.", typeName]);
		}
		return NO;
	}
	_type = type;
	{
		NSString *buildDirectory = [plist objectForKey:AGKeyBuildDirectory];

		[_buildDirectory release];
		_buildDirectory = [(buildDirectory != nil ? buildDirectory : @"build") copy];
	}
	paths = [plist objectForKey:AGKeyFilePaths];
	if (paths != nil && ![paths isKindOfClass:[NSArray class]]) {
		if (error != NULL) {
			*error = AGProjectError(@"AGProjectFilePaths is not an array.");
		}
		return NO;
	}
	for (i = 0; i < [paths count]; i++) {
		id entry = [paths objectAtIndex:i];

		if (![entry isKindOfClass:[NSString class]]) {
			if (error != NULL) {
				*error = AGProjectError(@"AGProjectFilePaths holds something that is not a string.");
			}
			return NO;
		}
		[_files addObject:[AGProjectFile fileWithRelativePath:entry]];
	}
	/* THE METADATA, all optional: a key that is present must be a string, and one that is not is refused rather than
	 * coerced — a plist that says nothing and a plist that says the wrong thing are different files. */
	{
		NSArray *stringKeys = [NSArray arrayWithObjects:AGKeyDisplayName, AGKeyIdentifier, AGKeyVersion,
					AGKeyIconPath, nil];
		NSUInteger k;

		for (k = 0; k < [stringKeys count]; k++) {
			id value = [plist objectForKey:[stringKeys objectAtIndex:k]];

			if (value != nil && ![value isKindOfClass:[NSString class]]) {
				if (error != NULL) {
					*error = AGProjectError([NSString stringWithFormat:
						@"%@ is not a string.", [stringKeys objectAtIndex:k]]);
				}
				return NO;
			}
		}
	}
	_displayName = [[plist objectForKey:AGKeyDisplayName] copy];
	_bundleIdentifier = [[plist objectForKey:AGKeyIdentifier] copy];
	_bundleVersion = [[plist objectForKey:AGKeyVersion] copy];
	_iconPath = [[plist objectForKey:AGKeyIconPath] copy];
	_dirty = NO;
	return YES;
}

- (BOOL)writeToURL:(NSURL *)url error:(NSError **)error
{
	NSMutableArray *paths = [NSMutableArray array];
	NSMutableDictionary *plist = [NSMutableDictionary dictionary];
	NSData *data;
	NSUInteger i;
	/* **THE PATH IS COPIED BEFORE ANYTHING IS RELEASED, BECAUSE `url` MAY BE THIS PROJECT'S OWN URL.** This method
	 * re-points `_URL` at the directory it wrote to, and the obvious spelling of a save — `[project writeToURL:[project
	 * projectDirectoryURL] error:NULL]` — hands it `_URL` itself: releasing `_URL` then left the caller's argument
	 * dangling, `[url path]` answered nil, and the project was left with NO directory at all. Every later add then
	 * refused every file it was shown, as "outside the project directory". MEASURED in Forge: the first Add worked and
	 * every one after it did nothing. */
	NSString *path = [[url path] copy];
	NSURL *held;

	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		if (![[NSFileManager defaultManager] createDirectoryAtPath:path
					       withIntermediateDirectories:YES
								attributes:nil
								     error:error]) {
			return NO;
		}
	}
	for (i = 0; i < [_files count]; i++) {
		[paths addObject:[[_files objectAtIndex:i] relativePath]];
	}
	[plist setObject:[NSNumber numberWithInteger:AGProjectFormatVersion] forKey:AGKeyFormatVersion];
	[plist setObject:_name forKey:AGKeyName];
	[plist setObject:AGProjectTypeName(_type) forKey:AGKeyType];
	[plist setObject:_buildDirectory forKey:AGKeyBuildDirectory];
	[plist setObject:paths forKey:AGKeyFilePaths];
	/* **A DEFAULT IS NOT WRITTEN.** A key appears in the manifest only when a person (or the interface) set it, so the
	 * defaults in this class stay the one place they are defined and a project file says what its author decided. */
	if (_displayName != nil) {
		[plist setObject:_displayName forKey:AGKeyDisplayName];
	}
	if (_bundleIdentifier != nil) {
		[plist setObject:_bundleIdentifier forKey:AGKeyIdentifier];
	}
	if (_bundleVersion != nil) {
		[plist setObject:_bundleVersion forKey:AGKeyVersion];
	}
	if (_iconPath != nil) {
		[plist setObject:_iconPath forKey:AGKeyIconPath];
	}

	data = [NSPropertyListSerialization dataWithPropertyList:plist
							  format:NSPropertyListXMLFormat_v1_0
							 options:0
							   error:error];
	if (data == nil) {
		return NO;
	}
	if (![data writeToFile:[path stringByAppendingPathComponent:AGProjectManifestName] atomically:YES]) {
		if (error != NULL) {
			*error = AGProjectError(@"The project manifest could not be written.");
		}
		[path release];
		return NO;
	}
	held = [[NSURL alloc] initFileURLWithPath:path isDirectory:YES];

	[path release];
	[_URL release];
	_URL = held;
	/* THE METADATA, all optional: a key that is present must be a string, and one that is not is refused rather than
	 * coerced — a plist that says nothing and a plist that says the wrong thing are different files. */
	{
		NSArray *stringKeys = [NSArray arrayWithObjects:AGKeyDisplayName, AGKeyIdentifier, AGKeyVersion,
					AGKeyIconPath, nil];
		NSUInteger k;

		for (k = 0; k < [stringKeys count]; k++) {
			id value = [plist objectForKey:[stringKeys objectAtIndex:k]];

			if (value != nil && ![value isKindOfClass:[NSString class]]) {
				if (error != NULL) {
					*error = AGProjectError([NSString stringWithFormat:
						@"%@ is not a string.", [stringKeys objectAtIndex:k]]);
				}
				return NO;
			}
		}
	}
	_displayName = [[plist objectForKey:AGKeyDisplayName] copy];
	_bundleIdentifier = [[plist objectForKey:AGKeyIdentifier] copy];
	_bundleVersion = [[plist objectForKey:AGKeyVersion] copy];
	_iconPath = [[plist objectForKey:AGKeyIconPath] copy];
	_dirty = NO;
	return YES;
}

- (NSURL *)manifestURL
{
	return [_URL URLByAppendingPathComponent:AGProjectManifestName];
}

- (NSURL *)URL
{
	return _URL;
}

- (NSURL *)projectDirectoryURL
{
	return _URL;
}

- (NSString *)name
{
	return _name;
}

- (void)setName:(NSString *)name
{
	NSString *copy = [name copy];

	[_name release];
	_name = copy;
	_dirty = YES;
}

- (AGProjectType)type
{
	return _type;
}

- (NSString *)typeName
{
	return AGProjectTypeName(_type);
}

- (NSURL *)buildDirectoryURL
{
	return [_URL URLByAppendingPathComponent:_buildDirectory];
}

- (BOOL)isDirty
{
	return _dirty;
}

- (NSArray *)files
{
	return _files;
}

- (NSArray *)categories
{
	NSMutableArray *categories = [NSMutableArray array];
	NSArray *order = [NSArray arrayWithObjects:AGProjectCategorySources, AGProjectCategoryHeaders,
				   AGProjectCategoryResources, AGProjectCategoryOther, nil];
	NSUInteger i;

	for (i = 0; i < [order count]; i++) {
		NSString *category = [order objectAtIndex:i];

		if ([[self filesInCategory:category] count] > 0) {
			[categories addObject:category];
		}
	}
	return categories;
}

- (NSArray *)filesInCategory:(NSString *)category
{
	NSMutableArray *matching = [NSMutableArray array];
	NSUInteger i;

	for (i = 0; i < [_files count]; i++) {
		AGProjectFile *file = [_files objectAtIndex:i];

		if ([[file category] isEqualToString:category]) {
			[matching addObject:file];
		}
	}
	return matching;
}

- (NSString *)absolutePathForFile:(AGProjectFile *)file
{
	return [[_URL path] stringByAppendingPathComponent:[file relativePath]];
}

- (BOOL)addFileAtAbsolutePath:(NSString *)absolutePath error:(NSError **)error
{
	NSString *base = [[_URL path] stringByStandardizingPath];
	NSString *standard = [absolutePath stringByStandardizingPath];
	NSString *prefix = [base stringByAppendingString:@"/"];
	NSString *relative;

	if (![standard hasPrefix:prefix]) {
		if (error != NULL) {
			*error = AGProjectError([NSString stringWithFormat:
				@"%@ is outside the project directory, so it cannot be part of this project.",
				absolutePath]);
		}
		return NO;
	}
	relative = [standard substringFromIndex:[prefix length]];
	{
		NSUInteger i;

		for (i = 0; i < [_files count]; i++) {
			if ([[[_files objectAtIndex:i] relativePath] isEqualToString:relative]) {
				return YES;	/* already a member; adding twice is not an error */
			}
		}
	}
	[_files addObject:[AGProjectFile fileWithRelativePath:relative]];
	_dirty = YES;
	return YES;
}

- (BOOL)removeFile:(AGProjectFile *)file error:(NSError **)error
{
	(void)error;
	[_files removeObjectIdenticalTo:file];
	_dirty = YES;
	return YES;
}

/* ---------------------------------------------------------------------------------------------------
 * THE GENERATOR.
 * --------------------------------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------------------------------
 * THE BUNDLE'S METADATA.
 * --------------------------------------------------------------------------------------------------- */

- (NSString *)displayName
{
	return (_displayName != nil && [_displayName length] > 0) ? _displayName : _name;
}

- (NSString *)bundleIdentifier
{
	if (_bundleIdentifier != nil && [_bundleIdentifier length] > 0) {
		return _bundleIdentifier;
	}
	return [NSString stringWithFormat:@"io.github.agoradesktop.%@",
		[AGTargetNameFromProjectName(_name) lowercaseString]];
}

/* **THE SHAPE IS CHECKED, BECAUSE A LAUNCHER READS THIS STRING.** Reverse-DNS is what every platform's registry and
 * every other bundle on this desktop is keyed by: letters, digits, dots and hyphens, at least one dot, and no empty
 * component. A caller that sets something else is answered NO and the manifest keeps what it had. */
BOOL AGBundleIdentifierIsValid(NSString *identifier)
{
	NSUInteger i, length = [identifier length];
	NSUInteger components = 1;

	if (length == 0) {
		return NO;
	}
	for (i = 0; i < length; i++) {
		unichar c = [identifier characterAtIndex:i];

		if (c == '.') {
			if (i == 0 || i + 1 == length || [identifier characterAtIndex:i - 1] == '.') {
				return NO;	/* an empty component: ".a", "a." or "a..b" */
			}
			components++;
			continue;
		}
		if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-')) {
			return NO;
		}
	}
	return components >= 2;
}

- (NSString *)bundleVersion
{
	return (_bundleVersion != nil && [_bundleVersion length] > 0) ? _bundleVersion : @"0.1.0";
}

- (NSString *)iconPath
{
	return _iconPath;
}

- (void)setDisplayName:(NSString *)name
{
	NSString *copy = ([name length] > 0) ? [name copy] : nil;

	[_displayName release];
	_displayName = copy;
	_dirty = YES;
}

- (BOOL)setBundleIdentifier:(NSString *)identifier
{
	NSString *copy;

	if (!AGBundleIdentifierIsValid(identifier)) {
		return NO;
	}
	copy = [identifier copy];
	[_bundleIdentifier release];
	_bundleIdentifier = copy;
	_dirty = YES;
	return YES;
}

- (void)setBundleVersion:(NSString *)version
{
	NSString *copy = ([version length] > 0) ? [version copy] : nil;

	[_bundleVersion release];
	_bundleVersion = copy;
	_dirty = YES;
}

- (void)setIconPath:(NSString *)relativePath
{
	NSString *copy = ([relativePath length] > 0) ? [relativePath copy] : nil;

	[_iconPath release];
	_iconPath = copy;
	_dirty = YES;
}

- (NSURL *)bundleURL
{
	NSString *target = AGTargetNameFromProjectName(_name);
	NSString *suffix = (_type == AGProjectTypeBundle) ? @".bundle" : @".app";

	return [[self buildDirectoryURL] URLByAppendingPathComponent:[target stringByAppendingString:suffix]];
}

/* **THE PLIST A LAUNCHER READS, GENERATED FROM THE MANIFEST.** Written as XML by hand rather than through
 * `NSPropertyListSerialization`: the file is four or five keys of text that a person may want to read in a build
 * directory, and a serialiser would make the generator depend on a data path for a file whose whole content is
 * known here. `CFBundleExecutable` names the target, because that is the file the generator puts in `Contents/MacOS`.
 * The icon is named by its FILE, which is how a bundle without an asset catalogue carries one. */
- (NSString *)generatedInfoPlist
{
	NSString *target = AGTargetNameFromProjectName(_name);
	NSMutableString *text = [NSMutableString string];
	NSString *escapedName = [self fn_escapeXML:[self displayName]];
	NSString *escapedIdentifier = [self fn_escapeXML:[self bundleIdentifier]];
	NSString *escapedVersion = [self fn_escapeXML:[self bundleVersion]];

	[text appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
	[text appendString:@"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
		"\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"];
	[text appendString:@"<!-- GENERATED BY FORGE FROM Project.agproj. The manifest is what is edited. -->\n"];
	[text appendString:@"<plist version=\"1.0\">\n<dict>\n"];
	[text appendFormat:@"\t<key>CFBundleIdentifier</key>\n\t<string>%@</string>\n", escapedIdentifier];
	[text appendFormat:@"\t<key>CFBundleName</key>\n\t<string>%@</string>\n", escapedName];
	[text appendFormat:@"\t<key>CFBundleExecutable</key>\n\t<string>%@</string>\n", target];
	[text appendFormat:@"\t<key>CFBundlePackageType</key>\n\t<string>%@</string>\n",
		(_type == AGProjectTypeApplication) ? @"APPL" : @"BNDL"];
	[text appendFormat:@"\t<key>CFBundleShortVersionString</key>\n\t<string>%@</string>\n", escapedVersion];
	[text appendFormat:@"\t<key>CFBundleVersion</key>\n\t<string>%@</string>\n", escapedVersion];
	[text appendString:@"\t<key>CFBundleInfoDictionaryVersion</key>\n\t<string>6.0</string>\n"];
	[text appendString:@"\t<key>NSPrincipalClass</key>\n\t<string>NSApplication</string>\n"];
	[text appendString:@"\t<key>NSHighResolutionCapable</key>\n\t<true/>\n"];
	[text appendString:@"\t<key>LSMinimumSystemVersion</key>\n\t<string>10.6</string>\n"];
	if (_iconPath != nil && [_iconPath length] > 0) {
		[text appendFormat:@"\t<key>CFBundleIconFile</key>\n\t<string>%@</string>\n",
			[self fn_escapeXML:[_iconPath lastPathComponent]]];
	}
	[text appendString:@"</dict>\n</plist>\n"];
	return text;
}

/* THE FOUR CHARACTERS A PLIST'S TEXT CANNOT CARRY, escaped the way XML says. A name with an ampersand in it is a name
 * a person may type into the interface, and it must not produce a plist no reader can parse. */
- (NSString *)fn_escapeXML:(NSString *)text
{
	NSMutableString *escaped = [NSMutableString stringWithString:(text != nil ? text : @"")];

	[escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0
				   range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0
				   range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0
				   range:NSMakeRange(0, [escaped length])];
	[escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0
				   range:NSMakeRange(0, [escaped length])];
	return escaped;
}

- (NSURL *)productURL
{
	NSString *target = AGTargetNameFromProjectName(_name);

	if (_type == AGProjectTypeApplication) {
		return [[[self buildDirectoryURL] URLByAppendingPathComponent:
			[target stringByAppendingString:@".app"]] URLByAppendingPathComponent:
			[NSString stringWithFormat:@"Contents/%@/%@/%@",
				@AG_BUNDLE_PLATFORM, @AG_BUNDLE_ARCH, target]];
	}
	if (_type == AGProjectTypeLibrary) {
		return [[self buildDirectoryURL] URLByAppendingPathComponent:
			[NSString stringWithFormat:@"lib%@.so", target]];
	}
	if (_type == AGProjectTypeBundle) {
		return [[[self buildDirectoryURL] URLByAppendingPathComponent:
			[target stringByAppendingString:@".bundle"]] URLByAppendingPathComponent:
			[NSString stringWithFormat:@"Contents/%@/%@/%@",
				@AG_BUNDLE_PLATFORM, @AG_BUNDLE_ARCH, target]];
	}
	return [[self buildDirectoryURL] URLByAppendingPathComponent:target];
}

- (NSString *)generatedCMakeLists
{
	NSString *target = AGTargetNameFromProjectName(_name);
	NSMutableString *text = [NSMutableString string];
	NSArray *sources = [self filesInCategory:AGProjectCategorySources];
	NSArray *resources = [self filesInCategory:AGProjectCategoryResources];
	NSUInteger i;

	[text appendString:@"# GENERATED BY FORGE FROM Project.agproj - DO NOT EDIT.\n"];
	[text appendString:@"# The manifest is the project; this file is its build, and the next build rewrites it.\n"];
	[text appendString:@"cmake_minimum_required(VERSION 3.24)\n"];
	[text appendFormat:@"project(%@ VERSION 0.1.0 LANGUAGES C OBJC)\n\n", target];
	[text appendString:@"set(CMAKE_POSITION_INDEPENDENT_CODE YES)\n\n"];

	if (_type == AGProjectTypeLibrary) {
		[text appendString:@"add_library("];
		[text appendFormat:@"%@ SHARED\n", target];
	} else if (_type == AGProjectTypeBundle) {
		[text appendString:@"add_library("];
		[text appendFormat:@"%@ MODULE\n", target];
	} else {
		[text appendString:@"add_executable("];
		[text appendFormat:@"%@\n", target];
	}
	for (i = 0; i < [sources count]; i++) {
		[text appendFormat:@"    ../%@\n", [[sources objectAtIndex:i] relativePath]];
	}
	[text appendString:@")\n\n"];

	if (_type != AGProjectTypeLibrary && _type != AGProjectTypeBundle) {
		[text appendString:@"# THE SDK: the installed AppKit, through its CMake package.\n"];
		[text appendString:@"find_package(AgoraApp CONFIG REQUIRED)\n"];
		[text appendFormat:@"target_link_libraries(%@ PRIVATE AgoraApp::App)\n\n", target];
		[text appendFormat:@"set_target_properties(%@ PROPERTIES\n", target];
		[text appendString:@"    INSTALL_RPATH \"${CMAKE_INSTALL_FULL_LIBDIR}\")\n"];
	}

	/* **AN APPLICATION'S PRODUCT IS A BUNDLE, AND THE GENERATED BUILD MAKES ONE.** `-productURL` answers the path
	 * inside `<target>.app/Contents/<platform>/<arch>/`, which is the layout libagora-core's resolver reads — so the
	 * generator has to put the executable there or Run has nothing to launch. The platform and architecture are this
	 * tool's own compile-time names, which keeps one spelling of them in the tree. */
	if (_type == AGProjectTypeApplication || _type == AGProjectTypeBundle) {
		NSString *suffix = (_type == AGProjectTypeApplication) ? @".app" : @".bundle";

		/* **THE EXECUTABLE GOES WHERE BOTH READERS LOOK.** `NSBundle -executablePath` answers
		 * `Contents/MacOS/<CFBundleExecutable>` — Apple's rule, and the one a launcher uses — while this tree's
		 * installed bundles put the binary in `Contents/<platform>/<arch>/`. One copy and one symlink serves both, and
		 * the second is a LINK rather than a second copy so a bundle can never hold two different builds. */
		[text appendString:@"\n# THE BUNDLE: Contents/MacOS for NSBundle, Contents/<platform>/<arch> for this tree.\n"];
		[text appendFormat:@"set(_bundle \"${CMAKE_BINARY_DIR}/%@%@\")\n", target, suffix];
		[text appendString:@"set(_macos \"${_bundle}/Contents/MacOS\")\n"];
		[text appendFormat:@"set(_platform \"${_bundle}/Contents/%@/%@\")\n",
			@AG_BUNDLE_PLATFORM, @AG_BUNDLE_ARCH];
		[text appendFormat:@"add_custom_command(TARGET %@ POST_BUILD\n", target];
		[text appendString:@"    COMMAND ${CMAKE_COMMAND} -E make_directory \"${_macos}\"\n"];
		[text appendFormat:@"    COMMAND ${CMAKE_COMMAND} -E copy \"$<TARGET_FILE:%@>\" \"${_macos}/%@\"\n",
			target, target];
		[text appendString:@"    COMMAND ${CMAKE_COMMAND} -E make_directory \"${_platform}\"\n"];
		[text appendFormat:@"    COMMAND ${CMAKE_COMMAND} -E create_symlink \"../../MacOS/%@\" "
			"\"${_platform}/%@\")\n", target, target];
	}

	if ([resources count] > 0) {
		[text appendFormat:@"# RESOURCES, kept beside the product the way NSBundle reads them.\n"];
		for (i = 0; i < [resources count]; i++) {
			[text appendFormat:@"#   %@\n", [[resources objectAtIndex:i] relativePath]];
		}
	}
	if ([sources count] == 0) {
		[text appendString:@"\n# THIS PROJECT HAS NO SOURCES YET. Add one in the browser and build again;\n"];
		[text appendString:@"# CMake refuses a target with an empty source list, and that is the honest answer.\n"];
	}
	return text;
}

@end
