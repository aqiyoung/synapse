# Changelog

## v1.1.0+11 (2026-05-28)

### Fixes
- Status bar: immersive on all pages (home, graph, lint, note detail)
- Graph: auto-resume animation 500ms after pinch/zoom/drag ends
- Graph: cancel resume timer when new gesture starts

## v1.0.9+10 (2026-05-28)

### Fixes
- Status bar: true immersive mode on note detail (edge-to-edge + transparent AppBar)
- Search: real-time search with 500ms debounce (no need to press submit)
- Search: added clear button to reset search
- Graph: node tap now works — was broken because `onScaleEnd` never fires for quick taps in Flutter's gesture system, switched to `onTap` callback

## v1.0.8+9 (2026-05-28)

### Changes
- Removed hardcoded default server URL (no more `wiki.threel.site` in source)
- App requires server configuration on first launch
- Search queries now properly URL-encoded (fixes Chinese character search)
- Added CHANGELOG.md

## v1.0.7+8 (2026-05-28)

### Fixes
- Graph: replaced AnimationController with Ticker for continuous physics simulation
- Graph: simplified tap detection (distance < 10px instead of complex state machine)
- Graph: animation no longer freezes after pinch-zoom gestures
- Graph: node tap navigation to note detail now works correctly

## v1.0.6+7 (2026-05-28)

### Fixes
- Graph: animation restart after gesture end
- Graph: ScaleEndDetails focalPoint error

## v1.0.5+6 (2026-05-28)

### Changes
- Graph: force-directed physics matching web version
- Graph: interactive zoom, pan, drag nodes
- Graph: tag-based coloring, degree-based sizing
- App icon: K monogram matching web logo
- Status bar: immersive only on note detail page
- Consistent APK signing across builds
- Server error handling with settings shortcut

## v1.0.4+5 (2026-05-27)

### Changes
- Initial graph visualization
- Note list, detail, tags, search
- Dark/light theme toggle
- Settings page with server configuration
