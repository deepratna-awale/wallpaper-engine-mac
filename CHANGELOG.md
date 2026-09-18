# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added Steam Workshop browsing with tag filters, numbered pagination, cached metadata, author profiles, and downloaded-item filtering.
- Added SteamCMD download queueing, retryable failures, live percentage progress when available, and a dedicated Downloads tab.
- Added Workshop preview windows backed by a bounded cache, with set-wallpaper, playback, and volume controls.
- Added multi-selection, range selection, and confirmation-gated bulk Workshop downloads and Installed wallpaper deletion.
- Added persisted downloaded Workshop IDs and download timestamps, including `Date Downloaded` sorting.
- Added multi-desktop selection and an `All Desktops` control in Display Settings.
- Added wallpaper placement controls for Fill, Fit, Center, Stretch, and Zoom.
- Added audio/video speed linking controls for video wallpapers.
- Added configurable wallpaper storage with an option to move the existing library to the selected location.

### Changed

- Installed and Workshop grids now size their pages from the available viewport and current icon size.
- Installed tile selection now previews an item; applying a wallpaper is an explicit action from the sidebar or preview window.
- Cached Workshop previews are promoted to the permanent wallpaper library when applied, without a second download.
- Scene image layers use explicit SpriteKit depth ordering.
- Only one desktop video wallpaper outputs audio to avoid duplicate playback artifacts.
- Renamed the Installed sort label to `Date Downloaded` while preserving the existing saved preference value.

### Fixed

- Fixed SteamCMD downloads failing when the default Homebrew location is not writable by using a local forced install directory.
- Fixed stale Workshop previews replacing newer selections.
- Fixed cached Workshop download status not being reflected after app restart.
- Fixed Workshop Hide Downloaded pages leaving empty grid positions.
- Fixed SF Symbol warnings caused by empty symbol names.
- Fixed preview rendering requiring window movement before redraw.
- Fixed preview audio continuing after the preview window closes.
- Fixed author lookup when downloaded projects have an empty `workshopid` by falling back to the numeric wallpaper folder name.
- Fixed saved wallpaper assignments, recents, and the downloaded-ID index after moving the wallpaper library.
- Preserved compatibility with legacy Workshop metadata cache encodings.

### Removed

- Removed hover-triggered Workshop preview downloads.
- Removed the bottom download queue panel in favor of the Downloads tab.
