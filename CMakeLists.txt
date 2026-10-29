# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later

#===----------------------------------------------------------------------===#
#
# Agora's build for Forge, the project manager and editor.
#
# **AN APPLICATION, NOT A LIBRARY.** It consumes the AppKit as a built package (`AgoraApp::App`), owns no headers
# anyone else links against, and installs its bundle the way `workspace` and `terminal` do. The three things in
# this repository are the project model (a manifest and the CMake it generates), the builder (the toolchain as a
# child process), and the window (a browser, an editor and a log). See README.md for the division.
#
#===----------------------------------------------------------------------===#

cmake_minimum_required(VERSION 3.24)

project(AgoraForge VERSION 0.1.0 LANGUAGES C OBJC)

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE YES)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

find_package(AgoraApp CONFIG REQUIRED)

# ---------------------------------------------------------------------------
# The toolbar's pictures: Tabler outlines rasterised into a C header at build time.
# ---------------------------------------------------------------------------
# **THE ART IS VENDORED AND THE PIXELS ARE COMPILED IN.** `assets/tabler-icons` holds five MIT-licensed outlines (see its
# PROVENANCE.md); `tools/embed-glyphs.py` rasterises each at 24 and 48 points and writes a header of RGBA bytes into the
# BUILD directory, so nothing is loaded from disk at run time and the vendored SVG is what the build starts from. A machine
# without `rsvg-convert` or ImageMagick's `convert` still builds: the header is simply not generated, `__has_include` fails,
# and `AGToolbarIcons.m` draws its own shapes instead.
find_program(AGORA_RSVG_CONVERT rsvg-convert)
find_program(AGORA_IMAGEMAGICK convert)
find_package(Python3 COMPONENTS Interpreter QUIET)

set(AGORA_TOOLBAR_GLYPH_DIR "${CMAKE_BINARY_DIR}/generated")
if(AGORA_RSVG_CONVERT AND AGORA_IMAGEMAGICK AND Python3_Interpreter_FOUND)
  set(AGORA_TOOLBAR_GLYPHS "${AGORA_TOOLBAR_GLYPH_DIR}/agora-toolbar-glyphs.h")
  add_custom_command(
      OUTPUT "${AGORA_TOOLBAR_GLYPHS}"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${AGORA_TOOLBAR_GLYPH_DIR}"
      COMMAND ${Python3_EXECUTABLE} "${CMAKE_CURRENT_SOURCE_DIR}/tools/embed-glyphs.py"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons" "${AGORA_TOOLBAR_GLYPHS}"
              "${AGORA_RSVG_CONVERT}"
      DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/tools/embed-glyphs.py"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons/hammer.svg"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons/player-play.svg"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons/trash.svg"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons/square.svg"
              "${CMAKE_CURRENT_SOURCE_DIR}/assets/tabler-icons/plus.svg"
      COMMENT "Embedding the Tabler toolbar glyphs"
      VERBATIM)
  add_custom_target(agora_toolbar_glyphs DEPENDS "${AGORA_TOOLBAR_GLYPHS}")
  set_source_files_properties("${AGORA_TOOLBAR_GLYPHS}" PROPERTIES GENERATED TRUE)
else()
  message(STATUS "Forge: rsvg-convert/ImageMagick/python3 not all present — the toolbar draws its own icons")
  set(AGORA_TOOLBAR_GLYPHS "")
endif()

set(FORGE_SOURCES
    src/main.m
    src/AGProject.m
    src/AGBuilder.m
    src/AGSourceEditor.m
    src/AGProjectInfoView.m
    src/AGToolbarIcons.m
    src/AGProjectWindowController.m)

add_executable(Forge ${FORGE_SOURCES})

target_include_directories(Forge PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
if(AGORA_TOOLBAR_GLYPHS)
  add_dependencies(Forge agora_toolbar_glyphs)
endif()
target_link_libraries(Forge PRIVATE AgoraApp::App)

# ---------------------------------------------------------------------------
# The bundle platform and architecture — libagora-core's vocabulary, not CMake's.
# ---------------------------------------------------------------------------
# The names are what `NSBundle -executablePath` resolves against, so they are computed here rather than in the
# application: a bundle laid out with CMake's `x86_64` is one this tree cannot launch.
if(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
  set(_bundle_platform "MacOS")
elseif(CMAKE_SYSTEM_NAME MATCHES "^(Linux|FreeBSD|NetBSD|OpenBSD|DragonFly)$")
  set(_bundle_platform "${CMAKE_SYSTEM_NAME}")
else()
  message(FATAL_ERROR "Forge: no bundle platform directory is named for ${CMAKE_SYSTEM_NAME}.")
endif()

if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64|AMD64)$")
  set(_bundle_arch "amd64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(aarch64|arm64|ARM64)$")
  set(_bundle_arch "arm64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^riscv64$")
  set(_bundle_arch "riscv64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(i[3-6]86|x86)$")
  set(_bundle_arch "i386")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "^(ppc64|ppc64le|powerpc64)$")
  set(_bundle_arch "ppc64")
else()
  message(FATAL_ERROR "Forge: no bundle architecture directory is named for ${CMAKE_SYSTEM_PROCESSOR}.")
endif()

target_compile_definitions(Forge PRIVATE
    AG_BUNDLE_PLATFORM="${_bundle_platform}"
    AG_BUNDLE_ARCH="${_bundle_arch}")

set(_bundle "${CMAKE_BINARY_DIR}/Forge.app")
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in" "${_bundle}/Contents/Info.plist" @ONLY)
add_custom_command(TARGET Forge POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
        "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:Forge>"
        "${_bundle}/Contents/${_bundle_platform}/${_bundle_arch}/Forge")

# ---------------------------------------------------------------------------
# The headless probes: the manifest, the generator and the diagnostic parse, with no window anywhere.
# ---------------------------------------------------------------------------
include(CTest)

if(BUILD_TESTING)
  enable_testing()

  add_executable(forge_project_model
      tests/project_model.m
      src/AGProject.m)
  target_include_directories(forge_project_model PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(forge_project_model PRIVATE AgoraApp::App)
  target_compile_definitions(forge_project_model PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-project-model COMMAND forge_project_model)

  add_executable(forge_diagnostics
      tests/diagnostics.m
      src/AGBuilder.m
      src/AGProject.m)
  target_include_directories(forge_diagnostics PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(forge_diagnostics PRIVATE AgoraApp::App)
  target_compile_definitions(forge_diagnostics PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-diagnostics COMMAND forge_diagnostics)

  # THE WHOLE CHAIN, MEASURED: manifest -> generated CMake -> toolchain -> a product on disk. It needs the SDK
  # prefix by ABSOLUTE path because the generated build resolves `AgoraApp` with find_package() from the project
  # directory, which is a temporary one.
  add_executable(forge_end_to_end
      tests/end_to_end.m
      src/AGBuilder.m
      src/AGProject.m)
  target_include_directories(forge_end_to_end PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(forge_end_to_end PRIVATE AgoraApp::App)
  target_compile_definitions(forge_end_to_end PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-end-to-end COMMAND forge_end_to_end)

  get_filename_component(_forge_sdk_prefix_unused "${CMAKE_PREFIX_PATH}" REALPATH
      BASE_DIR "${CMAKE_SOURCE_DIR}")
  # A RELATIVE `CMAKE_PREFIX_PATH` IS RELATIVE TO THE SOURCE DIRECTORY (that is how this project was configured),
  # so it is resolved against the source directory here too — resolving it against the build directory produced a
  # prefix that does not exist, and the test then failed on a `find_package` the rest of the tree passes.
  # **BUILD, CLEAN, BUILD — IN ONE PROCESS.** The verbs a shell runs as three processes are one project window's
  # session, and the state between them (the flight flag, the poll timer, the generated build on disk) is exactly
  # what "it works the first time and fails after cleaning" was about.
  add_executable(forge_build_sequence
      tests/build_sequence.m
      src/AGBuilder.m
      src/AGProject.m
      src/AGSourceEditor.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_build_sequence PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_build_sequence agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_build_sequence PRIVATE AgoraApp::App)
  target_compile_definitions(forge_build_sequence PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-build-sequence COMMAND forge_build_sequence)

  # **A VERB PRESSED WHILE ANOTHER IS RUNNING.** The reported symptom — "building works the first time, then fails
  # after cleaning" — is what a Build or Clean that clears the log and then quietly does nothing looks like from the
  # outside. This drives the window controller's own actions, in one process, and reads the log text a person sees.
  add_executable(forge_verb_conflicts
      tests/verb_conflicts.m
      src/AGBuilder.m
      src/AGProject.m
      src/AGSourceEditor.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_verb_conflicts PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_verb_conflicts agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_verb_conflicts PRIVATE AgoraApp::App)
  target_compile_definitions(forge_verb_conflicts PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-verb-conflicts COMMAND forge_verb_conflicts)

  # **THE LAST ROW IS ON THE SCREEN.** Both panes once computed their document height themselves: the editor dropped
  # the text view's own inset, and the log never asked for a height at all because a caller that edits the storage
  # directly is not an edit the view takes. This measures the last line's rectangle, not the intention.
  add_executable(forge_text_layout
      tests/text_layout.m
      src/AGBuilder.m
      src/AGProject.m
      src/AGSourceEditor.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_text_layout PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_text_layout agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_text_layout PRIVATE AgoraApp::App)
  target_compile_definitions(forge_text_layout PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-text-layout COMMAND forge_text_layout)

  # **THE NUMBERS SIT BESIDE THE LINES THEY NUMBER.** A vertical ruler's space is the DOCUMENT's (its bounds origin
  # tracks the clip view), and the first version of Forge's ruler also converted through the client — so every number
  # was drawn a scroll-distance away from its line. This scrolls by N line heights and reads the ruler's own walk back.
  add_executable(forge_line_numbers
      tests/line_numbers.m
      src/AGSourceEditor.m)
  target_include_directories(forge_line_numbers PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
  target_link_libraries(forge_line_numbers PRIVATE AgoraApp::App)
  add_test(NAME forge-line-numbers COMMAND forge_line_numbers)

  # **THE METADATA PANEL, DRIVEN END TO END.** It is a window rather than an alert, so a probe can fill its fields,
  # press Apply and read the manifest back — and can assert that showing it enters NO modal session, which is the whole
  # of what the change from an alert bought.
  add_executable(forge_project_info
      tests/project_info_view.m
      src/AGProject.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGBuilder.m
      src/AGSourceEditor.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_project_info PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_project_info agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_project_info PRIVATE AgoraApp::App)
  target_compile_definitions(forge_project_info PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-project-info COMMAND forge_project_info)

  # **A VERB'S BUTTON SAYS WHETHER IT CAN DO ANYTHING.** Run needs a product and nothing running, Clean needs something to
  # clean, Stop needs something to stop. The probe drives the real window through build → run → stop → clean and reads
  # each item's `-isEnabled` after the validation pass.
  add_executable(forge_toolbar_state
      tests/toolbar_state.m
      src/AGProject.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGBuilder.m
      src/AGSourceEditor.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_toolbar_state PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_toolbar_state agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_toolbar_state PRIVATE AgoraApp::App)
  target_compile_definitions(forge_toolbar_state PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-toolbar-state COMMAND forge_toolbar_state)

  # **THE ICONS, MEASURED: an image of the right size, with ink in it, and five DIFFERENT pictures.** A factory that
  # forgot a `break` would return one shape five times — right in size, wrong in meaning, and invisible to a compile.
  add_executable(forge_toolbar_icons
      tests/toolbar_icons.m
      src/AGToolbarIcons.m)
  target_include_directories(forge_toolbar_icons PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_toolbar_icons agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_toolbar_icons PRIVATE AgoraApp::App)
  add_test(NAME forge-toolbar-icons COMMAND forge_toolbar_icons)

  # **THE DIVIDERS DRAG, AND THE NUMBERS ARE REMEMBERED.** Two synthetic drags on the real window, the defaults read back
  # from a scratch store (`FNX_CONFIG_ROOT`), and then a SECOND window that must already be the right size.
  add_executable(forge_pane_sizes
      tests/pane_sizes.m
      src/AGProject.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGBuilder.m
      src/AGSourceEditor.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_pane_sizes PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_pane_sizes agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_pane_sizes PRIVATE AgoraApp::App)
  target_compile_definitions(forge_pane_sizes PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-pane-sizes COMMAND forge_pane_sizes)

  # **THE LOG'S FIRST CHARACTER SITS AT ITS PANE'S LEFT EDGE.** Three origins decide where it lands (the view's frame,
  # the clip's bounds, the container's inset); the probe renders the window at 1:1 in points and measures the ink.
  add_executable(forge_log_alignment
      tests/log_alignment.m
      src/AGProject.m
      src/AGProjectInfoView.m
      src/AGToolbarIcons.m
      src/AGBuilder.m
      src/AGSourceEditor.m
      src/AGProjectWindowController.m)
  target_include_directories(forge_log_alignment PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
  if(AGORA_TOOLBAR_GLYPHS)
    add_dependencies(forge_log_alignment agora_toolbar_glyphs)
  endif()
  target_link_libraries(forge_log_alignment PRIVATE AgoraApp::App)
  target_compile_definitions(forge_log_alignment PRIVATE
      AG_BUNDLE_PLATFORM="${_bundle_platform}"
      AG_BUNDLE_ARCH="${_bundle_arch}")
  add_test(NAME forge-log-alignment COMMAND forge_log_alignment)
  set_tests_properties(forge-log-alignment PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-pane-sizes PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-toolbar-icons PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-toolbar-state PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-project-info PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-line-numbers PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-text-layout PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-verb-conflicts PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
  set_tests_properties(forge-build-sequence PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")

  get_filename_component(_forge_sdk_prefix "${CMAKE_PREFIX_PATH}" REALPATH
      BASE_DIR "${CMAKE_SOURCE_DIR}")

  # **THE DEFAULTS STORE NEEDS A ROOT THIS ACCOUNT CAN WRITE, AND THE PANES NOW SAVE AS THE WINDOW IS BUILT.** The split
  # views remember their divider positions (`AgoraSplitView <name>`), so a test that opens a window writes to the store —
  # and the default scope, `<FNX_CONFIG_ROOT>/Users/<user>/Configuration`, is unwritable when the variable is unset. One
  # scratch root per build tree, for every test in this component.
  file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/test-config/Users")
  set(_forge_tests
      forge-project-model forge-diagnostics forge-end-to-end forge-build-sequence forge-verb-conflicts
      forge-text-layout forge-line-numbers forge-project-info forge-toolbar-state forge-toolbar-icons
      forge-pane-sizes forge-log-alignment)
  foreach(_forge_test IN LISTS _forge_tests)
    set_tests_properties(${_forge_test} PROPERTIES ENVIRONMENT
        "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib;FNX_CONFIG_ROOT=${CMAKE_CURRENT_BINARY_DIR}/test-config")
  endforeach()
  # **`CMAKE_PREFIX_PATH` IS DELIBERATELY NOT SET HERE.** The builder has to find the SDK the way the application
  # does — from `FORGE_SDK_PREFIX`/`AGORA_PREFIX`, or from its own binary's ancestors — and a test that hands it the
  # answer cannot tell whether a person pressing Build will get one.
  set_tests_properties(forge-end-to-end PROPERTIES
      ENVIRONMENT "LD_LIBRARY_PATH=${_forge_sdk_prefix}/lib")
endif()

# ---------------------------------------------------------------------------
# Install: the bundle, with an INSTALL_RPATH so it starts with no environment
# ---------------------------------------------------------------------------
set(_bundle_install "${CMAKE_INSTALL_LIBEXECDIR}/Forge.app")

get_property(_forge_rpath_is_set CACHE CMAKE_INSTALL_RPATH PROPERTY TYPE SET)
if(NOT _forge_rpath_is_set)
  set_target_properties(Forge PROPERTIES
      INSTALL_RPATH "${CMAKE_INSTALL_FULL_LIBDIR}")
endif()

install(TARGETS Forge
    RUNTIME DESTINATION "${_bundle_install}/Contents/${_bundle_platform}/${_bundle_arch}")
install(FILES "${_bundle}/Contents/Info.plist" DESTINATION "${_bundle_install}/Contents")

# A MEASUREMENT, NOT A TEST: what one drag step costs. Built always, run by hand.
add_executable(forge_drag_cost
    tests/_drag_cost.m
    src/AGProject.m
    src/AGProjectInfoView.m
    src/AGToolbarIcons.m
    src/AGBuilder.m
    src/AGSourceEditor.m
    src/AGProjectWindowController.m)
target_include_directories(forge_drag_cost PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src" "${AGORA_TOOLBAR_GLYPH_DIR}")
target_link_libraries(forge_drag_cost PRIVATE AgoraApp::App)
target_compile_definitions(forge_drag_cost PRIVATE
    AG_BUNDLE_PLATFORM="${_bundle_platform}"
    AG_BUNDLE_ARCH="${_bundle_arch}")
if(AGORA_TOOLBAR_GLYPHS)
  add_dependencies(forge_drag_cost agora_toolbar_glyphs)
endif()
