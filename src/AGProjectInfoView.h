/*
 * AGProjectInfoView.h — the project's metadata, as a pane of the project window.
 *
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * **A PANE, NOT A WINDOW, BECAUSE THE THING IT EDITS IS BESIDE IT.** A bundle's name, identifier, version and icon are
 * the project's, and a person editing them wants the browser and the code a click away. This view is what the toolbar's
 * Code/Info switch swaps into the editor's place: the same window, the same project, no second surface to manage.
 *
 * It was a modal alert first and then a standalone panel. Both were the same mistake in different clothes — a separate
 * surface for something that belongs to the window — and the alert also nested a loop inside whatever opened it.
 *
 * `AGProject` owns the values and their defaults; this view holds no copy of them. Applying is one write and one
 * notification, and the project window (the delegate) is what re-reads the consequences: the browser's groups and the
 * window's title.
 */
#ifndef AGPROJECTINFOVIEW_H
#define AGPROJECTINFOVIEW_H

#import <AppKit/NSView.h>

@class AGProject, NSTextField, NSButton, AGIconWell;

@protocol AGProjectInfoViewDelegate <NSObject>
@optional
/* THE MANIFEST WAS WRITTEN: the delegate re-reads what depends on it (groups, title). */
- (void)projectInfoDidApply:(id)sender;
/* A LINE FOR THE PROJECT'S LOG, so a refusal is visible where the person is already looking. */
- (void)projectInfoDidLog:(NSString *)line;
/* A PICTURE WAS ADDED TO THE PROJECT, so the file list has a new member. */
- (void)projectInfoDidAddFile:(NSString *)relativePath;
@end

@interface AGProjectInfoView : NSView
{
	AGProject *_project;				/* RETAINED */
	id <AGProjectInfoViewDelegate> _delegate;	/* NOT retained */
	NSTextField *_nameField;			/* RETAINED by this view's subviews */
	NSTextField *_identifierField;
	NSTextField *_versionField;
	NSTextField *_iconLabel;			/* the icon's FILE NAME, beside the well */

	/* THE HEADER, THE SECTION CAPTIONS AND THE FOOTER: what turns a column of fields into a form. */
	NSTextField *_titleLabel;
	NSTextField *_subtitleLabel;			/* the project's type and directory */
	NSTextField *_identityCaption;
	NSTextField *_presentationCaption;
	NSTextField *_nameCaption;
	NSTextField *_identifierCaption;
	NSTextField *_versionCaption;
	NSTextField *_iconCaption;
	NSTextField *_identifierHint;			/* what reverse-DNS means, under the field that wants it */
	NSTextField *_statusLabel;			/* "Up to date" or "Unsaved changes" */
	NSButton *_applyButton;
	NSButton *_removeIconButton;
	AGIconWell *_iconWell;				/* RETAINED: the picture, or the empty slot for one */
	NSString *_baseline;				/* RETAINED: the field values as the project has them, for the state line */
}

- (instancetype)initWithFrame:(NSRect)frame project:(AGProject *)project;

- (void)setDelegate:(id <AGProjectInfoViewDelegate>)delegate;
- (id <AGProjectInfoViewDelegate>)delegate;

/* READ THE PROJECT BACK INTO THE FIELDS, and the door the window sends when the pane is shown again. */
- (void)reloadFields;

/* WRITE THE FIELDS ONTO THE PROJECT AND THE MANIFEST. An identifier the project refuses changes nothing and is
 * reported through the delegate, with the field put back to the value the project actually has. */
- (void)apply:(id)sender;
- (void)revert:(id)sender;
- (void)chooseIcon:(id)sender;
- (void)removeIcon:(id)sender;

/* TEST DOORS, named as such. */
- (NSTextField *)nameField;
- (NSTextField *)identifierField;
- (NSTextField *)versionField;
- (NSTextField *)iconLabel;
- (NSTextField *)statusLabel;
- (NSButton *)applyButton;
- (NSButton *)removeIconButton;

/* IS THERE ANYTHING TO APPLY? The footer's state line and the two verbs are driven from this answer. */
- (BOOL)isDirty;

@end

#endif /* AGPROJECTINFOVIEW_H */
