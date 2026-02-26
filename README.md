# GOKZ Manual Recorder and Replay Viewer

A drag-and-drop SourceMod plugin for GOKZ that lets you manually record and watch `.replay` files without modifying core `gokz-hud` or `gokz-replays` files.

## Commands

- `sm_manualrecord` or `/manualrecord`  
  Toggle manual recording start/stop.

- `sm_manualreplay` or `/manualreplay`  
  Open the standalone replay menu for manual recordings.

## Features

- Standalone plugin workflow (no direct edits required to core GOKZ plugin files).
- Manual replay browser organized by mode.
- Replay entries shown with clean metadata (map/style/date).
- Saves replay files in a dedicated per-player folder.

## Replay File Location

Manual replays are saved to:

`addons/sourcemod/data/gokz-replays/_manual/<steamid>/`

Filename format:

`<mapname>_<timestamp>_<mode>_<style>.replay`

## Requirements

- GOKZ core plugins
- `gokz-replays` (required for replay playback natives)

## Notes

- This plugin is intended for community/non-profit use.
- You’re free to use and modify the source.
- Credit/shoutouts are appreciated.
