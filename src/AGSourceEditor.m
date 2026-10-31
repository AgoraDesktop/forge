/*
 * AGSourceEditor.m — the glass, the ruler and the colour pass.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * See AGSourceEditor.h. The colour pass is deliberately one scanner over the string rather than a lexer with a
 * token stream: what a source view has to colour is four kinds of run (a comment, a string, a number, a keyword),
 * and a scanner that answers "where does this run end" for each is the whole requirement. A language with a
 * different comment syntax is a different scanner, and that is the honest shape of the problem.
 */
#import "AGSourceEditor.h"

#import <AppKit/NSAttributedString.h>
#import <AppKit/NSColor.h>
#import <AppKit/NSFont.h>
#import <AppKit/NSGraphics.h>
#import <AppKit/NSLayoutManager.h>
#import <AppKit/NSRulerView.h>
#import <AppKit/NSScrollView.h>
#import <AppKit/NSTextContainer.h>
#import <AppKit/NSTextStorage.h>
#import <AppKit/NSTextView.h>
#import <AppKit/NSWindow.h>
#import <AppKit/NSStringDrawing.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSEnumerator.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSString.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const CGFloat AGEditorPointSize = 12.0;
static const CGFloat AGRulerThickness = 48.0;

/* **THE WORDS THAT GET BOLDED, IN C, BECAUSE THE PASS RUNS ON EVERY EDIT AND A SET OF `NSString`s COSTS A STRING PER
 * WORD.** It used to build an `NSSet` of string literals and ask it about every identifier in the file — which means one
 * `-substringWithRange:` allocation AND one hash of a fresh string for every word: MEASURED, 15,000 words into a 1,600-line
 * file made one colour pass 500 ms, with only 877 runs actually coloured. The table below compares a run of characters
 * against the words of its own LENGTH, so an identifier costs a handful of byte comparisons and no object at all.
 *
 * The set's contents are unchanged — the same C and Objective-C words this project writes — and they are grouped by
 * length so the comparison for one word is against the two or three candidates it could be rather than against all
 * fifty. */
static const char *const AGKeywordTable[] = {
	"if", "do", "id", "NO", "YES", "for", "int", "nil", "long", "char", "else", "case", "enum", "goto",
	"void", "NULL", "self", "while", "break", "union", "short", "float", "const", "super", "sizeof",
	"struct", "static", "extern", "switch", "double", "return", "signed", "typedef", "continue", "volatile",
	"register", "unsigned", "instancetype", "@end", "@try", "@class", "@catch", "@throw", "@import",
	"@finally", "@selector", "@property", "@protocol", "@synthesize", "@interface", "@autoreleasepool",
	"@implementation",
	NULL
};

/* **AND WHETHER A RUN OF CHARACTERS IS ONE OF THEM**, compared against the candidates of the same length — the table is
 * short enough that a length check removes almost all of the work before a byte is compared. Non-ASCII text can never be
 * a keyword (every entry is ASCII), which is the one fact that lets a `unichar` be compared with a `char`. */
static BOOL AGWordIsKeyword(const unichar *word, NSUInteger length)
{
	NSUInteger i;

	if (length == 0) {
		return NO;
	}
	for (i = 0; AGKeywordTable[i] != NULL; i++) {
		const char *candidate = AGKeywordTable[i];
		NSUInteger j;

		if ((NSUInteger)strlen(candidate) != length) {
			continue;
		}
		for (j = 0; j < length; j++) {
			if (word[j] > 0x7Fu || (char)word[j] != candidate[j]) {
				break;
			}
		}
		if (j == length) {
			return YES;
		}
	}
	return NO;
}

/* **THE PREPROCESSOR'S OWN WORDS**, which are the ones a `#` introduces. They wear the keyword ink because that is what they
 * are — a keyword of the translation unit's first pass — and the LIST is what makes `#import` recognisable, because the
 * `import` on its own is not a keyword of anything else and used to be plain text. */
static BOOL AGWordIsDirective(const unichar *word, NSUInteger length)
{
	static const char *const directives[] = {
		"import", "include", "define", "undef", "if", "ifdef", "ifndef", "else", "elif", "endif", "error",
		"warning", "pragma", "line", NULL
	};
	NSUInteger i;

	for (i = 0; directives[i] != NULL; i++) {
		const char *candidate = directives[i];
		NSUInteger j;

		if ((NSUInteger)strlen(candidate) != length) {
			continue;
		}
		for (j = 0; j < length; j++) {
			if (word[j] > 0x7Fu || (char)word[j] != candidate[j]) {
				break;
			}
		}
		if (j == length) {
			return YES;
		}
	}
	return NO;
}

/* **AND WHETHER A WORD IS A TYPE, WHICH IS THE ONE CONVENTION OBJECTIVE-C KEEPS ABSOLUTELY.** A class, a struct and every
 * `NS…`/`CF…` typedef begin with a capital; a local, a method and a variable begin with a lower-case letter or an
 * underscore. So a capitalised word that is not a keyword is a type name — `NSView`, `AGProject`, `CGFloat`, `BOOL`,
 * `NS_ASSUME_NONNULL_BEGIN` — and a word that is a keyword stays a keyword, because the table is asked first. This is a
 * heuristic, and it is the one every editor of this language uses, because the language has no other way to say it. */
static BOOL AGWordIsTypeName(const unichar *word, NSUInteger length)
{
	if (length == 0 || word[0] == '@') {
		return NO;		/* `@` words are keywords or selectors, and the table has them */
	}
	return (word[0] >= 'A' && word[0] <= 'Z') || (word[0] == '_');
}

static NSColor *AGCommentColor(void)
{
	static NSColor *color = nil;

	if (color == nil) {
		color = [[NSColor colorWithCalibratedRed:0.36 green:0.52 blue:0.34 alpha:1.0] retain];
	}
	return color;
}

static NSColor *AGStringColor(void)
{
	static NSColor *color = nil;

	if (color == nil) {
		color = [[NSColor colorWithCalibratedRed:0.70 green:0.28 blue:0.24 alpha:1.0] retain];
	}
	return color;
}

static NSColor *AGNumberColor(void)
{
	static NSColor *color = nil;

	if (color == nil) {
		color = [[NSColor colorWithCalibratedRed:0.35 green:0.30 blue:0.62 alpha:1.0] retain];
	}
	return color;
}

/* **A TYPE'S OWN INK, WHICH IS WHAT MAKES AN OBJECTIVE-C FILE READ AS ONE.** A class name — `NSView`, `AGProject` — is
 * capitalised by convention and is the word a reader's eye needs to find fastest in a line of C; giving it the keyword's
 * ink would fold it in with `if` and `return`. A TEAL, because the four existing inks already own green (comments), red
 * (strings), blue-violet (numbers) and purple (keywords), and a fifth hue is what keeps a declaration line legible. */
static NSColor *AGTypeColor(void)
{
	static NSColor *color = nil;

	if (color == nil) {
		color = [[NSColor colorWithCalibratedRed:0.13 green:0.42 blue:0.55 alpha:1.0] retain];
	}
	return color;
}

static NSColor *AGKeywordColor(void)
{
	static NSColor *color = nil;

	if (color == nil) {
		color = [[NSColor colorWithCalibratedRed:0.42 green:0.16 blue:0.42 alpha:1.0] retain];
	}
	return color;
}

static BOOL AGIsIdentifierStart(unichar c)
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '@';
}

static BOOL AGIsIdentifierBody(unichar c)
{
	return AGIsIdentifierStart(c) || (c >= '0' && c <= '9');
}

static BOOL AGIsDigit(unichar c)
{
	return c >= '0' && c <= '9';
}

/* ---------------------------------------------------------------------------------------------------
 * The ruler.
 * --------------------------------------------------------------------------------------------------- */

@implementation AGLineNumberRuler

/* **THE WALK, ONCE, IN DOCUMENT COORDINATES.** The scroll view keeps a vertical ruler's BOUNDS ORIGIN in step with the
 * clip view's, so the ruler's own coordinate space is the DOCUMENT's — `NSScrollView -reflectScrolledClipView:` says
 * so in one place, and it is why a mark drawn at document y=300 appears under the character at 300.
 *
 * THE FIRST VERSION OF THIS CLASS CONVERTED THROUGH THE CLIENT VIEW INSTEAD (`-convertPoint:toView:`), which applies
 * the scroll a second time: the numbers were right at the top of the file and drifted by exactly the scroll distance
 * afterwards, then stopped being drawn at all. MEASURED in the running session as line 22 sitting beside the text of
 * line 32. So: no conversion. The y of a fragment is the text view's own, and the text view is the document view, so
 * the only offset left is its container's inset. */
- (void)fn_enumerateVisibleLines:(void (^)(NSUInteger lineNumber, CGFloat top, CGFloat height))block
{
	NSTextView *client = [self clientViewOfTextViewClass];
	NSLayoutManager *layoutManager;
	NSRect visible;
	CGFloat containerTop;
	NSUInteger glyph, glyphCount, lineNumber = 1;

	if (client == nil || block == nil) {
		return;
	}
	layoutManager = [client layoutManager];
	visible = [self bounds];
	containerTop = [client textContainerOrigin].y;
	glyphCount = [layoutManager numberOfGlyphs];
	glyph = 0;
	while (glyph < glyphCount) {
		NSRange effective = NSMakeRange(0, 0);
		NSRect fragment = [layoutManager lineFragmentRectForGlyphAtIndex:glyph effectiveRange:&effective];
		CGFloat top = containerTop + fragment.origin.y;

		/* **A NUMBER IS PAINTED WHERE ITS LINE'S TOP IS, SO THAT IS THE TEST.** The window is the ruler's own bounds,
		 * which the scroll view keeps equal to the clip's. A line whose top is above the window has its label
		 * clipped away — the text's bottom sliver is there and the number is not, which is what a pixel scroll does
		 * and what this reports. Counting a label that is drawn outside the window is how the first version came to
		 * sit one line behind the text. */
		if (top >= NSMinY(visible) - 0.5 && top < NSMaxY(visible)) {
			block(lineNumber, top, fragment.size.height);
		}
		if (NSMaxRange(effective) <= glyph) {
			break;		/* a zero-length fragment would loop forever; the guard is the honest one */
		}
		glyph = NSMaxRange(effective);
		lineNumber++;
	}
}

- (NSTextView *)clientViewOfTextViewClass
{
	NSView *client = [self clientView];

	return [client isKindOfClass:[NSTextView class]] ? (NSTextView *)client : nil;
}

/* THE NUMBERS THIS RULER WOULD PAINT RIGHT NOW, in the order they appear top to bottom. A test door, and the same walk
 * the drawing does — so a test cannot pass while the drawing disagrees with it. */
- (NSArray *)cg_visibleLineNumbers
{
	NSMutableArray *numbers = [NSMutableArray array];

	[self fn_enumerateVisibleLines:^(NSUInteger lineNumber, CGFloat top, CGFloat height) {
		(void)top;
		(void)height;
		[numbers addObject:[NSNumber numberWithUnsignedInteger:lineNumber]];
	}];
	return numbers;
}

/* The number band's ink. Every pass asks the layout manager, so a resize, a scroll and an edit are one question with
 * one answer. */
- (void)drawHashMarksAndLabelsInRect:(NSRect)rect
{
	NSTextView *client = [self clientViewOfTextViewClass];
	NSFont *font;
	NSDictionary *attributes;
	CGFloat right = [self bounds].size.width - 6.0;

	(void)rect;
	/* **A DARKER BAND THAN THE PAGE, WHICH IS WHAT MAKES THE NUMBERS READ AS A MARGIN.** At 0.94 the strip was almost the
	 * editor's own white and the numbers floated in it; the rule at its right edge is what separates the two surfaces. */
	[[NSColor colorWithCalibratedWhite:0.87 alpha:1.0] set];
	NSRectFill([self bounds]);
	[[NSColor colorWithCalibratedWhite:0.72 alpha:1.0] set];
	NSRectFill(NSMakeRect([self bounds].size.width - 1.0, 0.0, 1.0, [self bounds].size.height));

	if (client == nil) {
		return;
	}
	font = [NSFont userFixedPitchFontOfSize:10.0];
	attributes = [NSDictionary dictionaryWithObjectsAndKeys:
		font, NSFontAttributeName,
		[NSColor colorWithCalibratedWhite:0.30 alpha:1.0], NSForegroundColorAttributeName,
		nil];

	[self fn_enumerateVisibleLines:^(NSUInteger lineNumber, CGFloat top, CGFloat height) {
		NSString *label = [NSString stringWithFormat:@"%lu", (unsigned long)lineNumber];
		NSSize size = [label sizeWithAttributes:attributes];
		CGFloat baseline = top + [font ascender];

		(void)height;
		[label drawAtPoint:NSMakePoint(right - size.width, baseline) withAttributes:attributes];
	}];
}

@end

/* ---------------------------------------------------------------------------------------------------
 * The editor.
 * --------------------------------------------------------------------------------------------------- */

/* THE ONE PRIVATE DOOR: the announcement a tab and the window both act on, declared here because `-setSource:`
 * reaches it before its definition does. */
@interface AGSourceEditor ()
- (void)fn_announce;
@end

@implementation AGSourceEditor

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];
	if (self != nil) {
		NSTextView *textView;
		NSFont *font = [NSFont userFixedPitchFontOfSize:AGEditorPointSize];

		_scrollView = [[NSScrollView alloc] initWithFrame:[self bounds]];
		[_scrollView setHasVerticalScroller:YES];
		[_scrollView setBorderType:NSNoBorder];
		[_scrollView setAutoresizingMask:(NSViewWidthSizable | NSViewHeightSizable)];

		textView = [[NSTextView alloc] initWithFrame:[self bounds] textContainer:nil];
		[textView setRichText:NO];
		[textView setAllowsUndo:YES];
		[textView setVerticallyResizable:YES];
		[textView setHorizontallyResizable:NO];
		[textView setAutoresizingMask:NSViewWidthSizable];
		if (font != nil) {
			[textView setFont:font];
		}
		[textView setBackgroundColor:[NSColor colorWithCalibratedWhite:1.0 alpha:1.0]];
		[textView setTextColor:[NSColor colorWithCalibratedWhite:0.10 alpha:1.0]];
		[[textView textContainer] setWidthTracksTextView:YES];
		[[textView textContainer] setHeightTracksTextView:NO];
		_textView = [textView retain];
		[_scrollView setDocumentView:textView];
		[textView release];		/* the scroll view and this view each hold their own reference */

		_ruler = [[AGLineNumberRuler alloc] initWithScrollView:_scrollView orientation:NSVerticalRuler];
		[_ruler setClientView:textView];
		[_ruler setRuleThickness:AGRulerThickness];
		[_scrollView setVerticalRulerView:_ruler];
		[_scrollView setRulersVisible:YES];

		/* **THE EDITOR IS ITS TEXT VIEW'S DELEGATE, WHICH IS WHERE BOTH REPORTS COME FROM.** Every edit ends in
		 * `-textDidChange:` (the same announcement `NSText`'s own commands make), and that is the moment the colour pass
		 * re-runs and the buffer counts as unsaved — one hook, both facts. */
		[textView setDelegate:self];
		[self addSubview:_scrollView];
	}
	return self;
}

- (void)dealloc
{
	[_ruler release];
	[_textView release];
	[_scrollView release];
	[super dealloc];
}

- (NSTextView *)textView
{
	return _textView;
}

/* **THE SCROLL VIEW IS THE VIEW'S SIZE, ALWAYS.** This view is laid out by a split view's frames rather than by
 * autoresizing from a born size, so the scroll view it created in `-initWithFrame:` has to be placed again whenever
 * the editor is: without this the editor drew as the small box it was born as inside a pane that had grown. */
- (void)fn_placeScrollView
{
	NSRect bounds = [self bounds];

	[_scrollView setFrame:bounds];
	if (_textView == nil) {
		return;
	}
	/* **THE WIDTH TRACKS THE PANE AND THE HEIGHT IS THE TEXT SYSTEM'S ANSWER.** `-sizeToFit` asks the layout for the
	 * used rect PLUS the view's own `-textContainerInset` (NSTextView.m's `-cg_setHeightToLayout` says so in one
	 * place), which is the arithmetic a document view needs. The first version of this method computed the height
	 * itself from `-usedRectForTextContainer:` alone — short by twice the inset — so the last line of every file sat
	 * below the document's own bottom edge and could not be scrolled into view: MEASURED as the bottom row being cut
	 * in half in the editor and in the build log. */
	[_textView setFrameSize:NSMakeSize(bounds.size.width, [_textView frame].size.height)];
	if (_layoutDeferred) {
		return;		/* the wrap waits for the hand to stop; `-setLayoutDeferred:NO` comes back through here */
	}
	[_textView sizeToFit];
	if ([_textView frame].size.height < bounds.size.height) {
		/* **AND THE DOCUMENT FILLS ITS PANE WHEN THE TEXT IS SHORT**: a clip view whose document is shorter than
		 * itself draws the scroll view's background under the last line and loses clicks down there. */
		[_textView setFrameSize:NSMakeSize(bounds.size.width, bounds.size.height)];
	}
}

- (void)setFrame:(NSRect)frame
{
	[super setFrame:frame];
	[self fn_placeScrollView];
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self fn_placeScrollView];
}

- (void)setSource:(NSString *)source
{
	[_textView setString:(source != nil ? source : @"")];
	/* **A FILE'S OWN TEXT IS NOT AN EDIT.** Filling the buffer from disk — or from a new file's skeleton — is the one
	 * moment the text and the file agree, so the bullet goes and the tab stops saying "unsaved". */
	_dirty = NO;
	/* **THE INSERTION POINT GOES TO THE TOP, AND `-setString:` IS WHY IT HAS TO BE SAID.** That door places the
	 * insertion point at the END of the text, so a freshly opened file arrived scrolled to its last page — MEASURED
	 * in the first screenshot where the editor opened at line 8 of the end. */
	[_textView setSelectedRange:NSMakeRange(0, 0)];
	[self fn_placeScrollView];
	[_textView scrollRangeToVisible:NSMakeRange(0, 0)];
	/* **NO SECOND COLOUR PASS: `-setString:` ALREADY MADE ONE.** The view announces `NSTextDidChangeNotification` for
	 * every replacement, and this editor is its delegate — so the pass below ran twice for one open, and on a 1,600-line
	 * file the second one was half a second of the open. MEASURED: 1,283 ms for one open, of which 531 was the duplicate. */
	[self fn_announce];
}

- (NSString *)source
{
	/* **ASKING FOR THE TEXT IS NOT AN EDIT EITHER**, and `-string` does not announce one — this door is read by a save
	 * and by a build's diagnostics. */
	return [_textView string];
}

- (BOOL)isDirty
{
	return _dirty;
}

- (void)setDirty:(BOOL)flag
{
	_dirty = flag ? YES : NO;
	[self fn_announce];
}

- (void)setTarget:(id)target
{
	_target = target;	/* NOT RETAINED */
}

- (void)setAction:(SEL)action
{
	_action = action;
}

- (void)fn_announce
{
	if (_target != nil && _action != NULL && [_target respondsToSelector:_action]) {
		[_target performSelector:_action withObject:self];
	}
}

/* **EVERY EDIT, IN ONE PLACE: THE BUFFER IS UNSAVED, THE COLOUR PASS RUNS, AND THE STRIP IS TOLD.** The pass is over the
 * whole string, which is the design this file states at the top — a source file here is a few hundred lines, and the
 * alternative is a token stream that has to be kept in step with the text. */
- (void)textDidChange:(NSNotification *)notification
{
	(void)notification;
	_dirty = YES;
	[self highlight];
	[self fn_announce];
}

- (void)setLayoutDeferred:(BOOL)deferred
{
	if (_layoutDeferred == deferred) {
		return;
	}
	_layoutDeferred = deferred;
	if (!deferred) {
		[self fn_placeScrollView];	/* the one re-fit the drag put off */
	}
}

- (NSRulerView *)lineNumberRuler
{
	return _ruler;
}

- (NSScrollView *)scrollView
{
	return _scrollView;
}

- (NSString *)filePath
{
	return _filePath;
}

- (void)setFilePath:(NSString *)path
{
	NSString *copy = [path copy];

	[_filePath release];
	_filePath = copy;
}

- (void)goToLine:(NSInteger)line
{
	NSString *text = [_textView string];
	NSUInteger index = 0, currentLine = 1, length = [text length];

	if (line < 1) {
		line = 1;
	}
	while (index < length && currentLine < line) {
		unichar c = [text characterAtIndex:index];

		index++;
		if (c == '\n') {
			currentLine++;
		}
	}
	[_textView setSelectedRange:NSMakeRange(index, 0)];
	[_textView scrollRangeToVisible:NSMakeRange(index, 0)];
	[[_textView window] makeFirstResponder:_textView];
}

/* THE COLOUR PASS. Six questions in one loop, each answered by consuming its own run:
 *
 *   a comment      swallows to its end;
 *   a string       to its closing quote (or the end of the line, which is how C recovers from an unterminated one) —
 *                  and `@"like this"` is one string, `@` included;
 *   a number       to its last digit-or-dot, including a hex or a float suffix;
 *   a directive    a `#` and the word after it are the keyword ink, and an `#import`/`#include`'s `<…>` path is the
 *                  string ink, which is how a header reads as a name rather than as six operators;
 *   a keyword      a C or Objective-C word from the table — and after `@property`, the parenthesised list of attributes
 *                  that follows it, because `nonatomic` and `copy` are keywords in exactly one place and this is it;
 *   a type name    any other word that begins with a capital, which is the language's own convention for a class, a
 *                  struct or an `NS…`/`CF…` typedef.
 *
 * Nothing is written to the storage — every run is a temporary attribute, so the file's bytes and the view's ink stay
 * separate.
 *
 * **AND NOTHING HERE ALLOCATES PER WORD.** The scanner reads characters, compares runs against C tables, and applies
 * one temporary attribute per run; the version before this one built an `NSString` per identifier to ask an `NSSet` a
 * question, which cost 500 ms a pass. A pass over 1,600 lines is 5-7 ms, and every edit runs one. */
- (void)highlight
{
	NSString *text = [_textView string];
	NSLayoutManager *layoutManager = [_textView layoutManager];
	NSUInteger length = [text length];
	NSUInteger i = 0;
	NSRange all = NSMakeRange(0, length);

	if (layoutManager == nil) {
		return;
	}
	[layoutManager removeTemporaryAttribute:NSForegroundColorAttributeName forCharacterRange:all];

	while (i < length) {
		unichar c = [text characterAtIndex:i];

		if (c == '/' && i + 1 < length) {
			unichar next = [text characterAtIndex:i + 1];

			if (next == '/') {
				NSUInteger start = i, end = i;

				while (end < length && [text characterAtIndex:end] != '\n') {
					end++;
				}
				[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
							       value:AGCommentColor()
						   forCharacterRange:NSMakeRange(start, end - start)];
				i = end;
				continue;
			}
			if (next == '*') {
				NSUInteger start = i, end = i + 2;

				while (end + 1 < length) {
					if ([text characterAtIndex:end] == '*' &&
					    [text characterAtIndex:end + 1] == '/') {
						end += 2;
						break;
					}
					end++;
				}
				if (end > length) {
					end = length;
				}
				[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
							       value:AGCommentColor()
						   forCharacterRange:NSMakeRange(start, end - start)];
				i = end;
				continue;
			}
		}
		/* **AND AN `@` BEFORE THE QUOTE IS PART OF THE STRING**, which is how Objective-C writes one. It used to be scanned
		 * as a word of its own — a `@` with no ink — and left as plain text in front of a coloured run. */
		if (c == '@' && i + 1 < length && [text characterAtIndex:i + 1] == '"') {
			unichar quote = '"';
			NSUInteger start = i, end = i + 2;

			while (end < length) {
				unichar inner = [text characterAtIndex:end];

				if (inner == '\\' && end + 1 < length) {
					end += 2;
					continue;
				}
				end++;
				if (inner == quote || inner == '\n') {
					break;
				}
			}
			[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
						       value:AGStringColor()
					   forCharacterRange:NSMakeRange(start, end - start)];
			i = end;
			continue;
		}
		if (c == '"' || c == '\'') {
			unichar quote = c;
			NSUInteger start = i, end = i + 1;

			while (end < length) {
				unichar inner = [text characterAtIndex:end];

				if (inner == '\\' && end + 1 < length) {
					end += 2;
					continue;
				}
				end++;
				if (inner == quote || inner == '\n') {
					break;
				}
			}
			[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
						       value:AGStringColor()
					   forCharacterRange:NSMakeRange(start, end - start)];
			i = end;
			continue;
		}
		if (AGIsDigit(c)) {
			NSUInteger start = i;

			while (i < length) {
				unichar digit = [text characterAtIndex:i];

				if (AGIsDigit(digit) || digit == '.' ||
				    (digit >= 'a' && digit <= 'f') || (digit >= 'A' && digit <= 'F') ||
				    digit == 'x' || digit == 'X' || digit == 'u' || digit == 'U' || digit == 'l' || digit == 'L') {
					i++;
					continue;
				}
				break;
			}
			[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
						       value:AGNumberColor()
					   forCharacterRange:NSMakeRange(start, i - start)];
			continue;
		}
		/* **A `#` AND THE WORD IT INTRODUCES ARE A PREPROCESSOR DIRECTIVE**, and an import's header path is a name rather
		 * than a row of `<`, `/` and `.` operators. Both are the same two inks the rest of the file uses, so a
		 * preprocessor line reads as part of the file rather than as a foreign strip at the top of it. */
		if (c == '#') {
			NSUInteger hash = i, wordStart, wordEnd;
			unichar word[24];
			NSUInteger wordLength;

			i++;
			while (i < length && [text characterAtIndex:i] == ' ') {
				i++;
			}
			wordStart = i;
			while (i < length && AGIsIdentifierBody([text characterAtIndex:i])) {
				if (i - wordStart < sizeof(word) / sizeof(word[0])) {
					word[i - wordStart] = [text characterAtIndex:i];
				}
				i++;
			}
			wordEnd = i;
			wordLength = wordEnd - wordStart;
			[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
						       value:AGKeywordColor()
					   forCharacterRange:NSMakeRange(hash, wordEnd - hash)];
			if (wordLength <= sizeof(word) / sizeof(word[0]) && AGWordIsDirective(word, wordLength)
			    && (wordLength == 6 || wordLength == 7)) {	/* "import", "include" */
				NSUInteger pathStart = wordEnd;

				while (pathStart < length && [text characterAtIndex:pathStart] == ' ') {
					pathStart++;
				}
				if (pathStart < length && [text characterAtIndex:pathStart] == '<') {
					NSUInteger pathEnd = pathStart + 1;

					while (pathEnd < length && [text characterAtIndex:pathEnd] != '>'
					       && [text characterAtIndex:pathEnd] != '\n') {
						pathEnd++;
					}
					if (pathEnd < length && [text characterAtIndex:pathEnd] == '>') {
						pathEnd++;
					}
					[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
								       value:AGStringColor()
							   forCharacterRange:NSMakeRange(pathStart, pathEnd - pathStart)];
				}
			}
			continue;
		}
		if (AGIsIdentifierStart(c)) {
			NSUInteger start = i;
			unichar word[24];		/* the longest keyword and then some; a longer run is not one */
			BOOL fits;

			while (i < length && AGIsIdentifierBody([text characterAtIndex:i])) {
				unichar body = [text characterAtIndex:i];

				if (i - start < sizeof(word) / sizeof(word[0])) {
					word[i - start] = body;
				}
				i++;
			}
			fits = (i - start <= sizeof(word) / sizeof(word[0]));
			if (fits && AGWordIsKeyword(word, i - start)) {
				[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
							       value:AGKeywordColor()
						   forCharacterRange:NSMakeRange(start, i - start)];
				/* **AND `@property` OWNS THE LIST THAT FOLLOWS IT.** `nonatomic`, `copy`, `strong`, `readonly` and
				 * their neighbours are keywords in exactly one place — between the parentheses after `@property` —
				 * and nowhere else, which is why they are not in the table: a local called `copy` must stay plain.
				 * The list is coloured here, at the one site that can know what it is. */
				if (i - start == 9 && word[0] == '@') {
					NSUInteger paren = i;

					while (paren < length && ([text characterAtIndex:paren] == ' '
								  || [text characterAtIndex:paren] == '\t')) {
						paren++;
					}
					if (paren < length && [text characterAtIndex:paren] == '(') {
						NSUInteger close = paren + 1;

						while (close < length && [text characterAtIndex:close] != ')'
						       && [text characterAtIndex:close] != '\n') {
							close++;
						}
						if (close < length && [text characterAtIndex:close] == ')') {
							[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
										       value:AGKeywordColor()
									   forCharacterRange:NSMakeRange(paren, close + 1 - paren)];
						}
					}
				}
			} else if (fits && AGWordIsTypeName(word, i - start)) {
				[layoutManager addTemporaryAttribute:NSForegroundColorAttributeName
							       value:AGTypeColor()
						   forCharacterRange:NSMakeRange(start, i - start)];
			}
			continue;
		}
		i++;
	}
}

@end
