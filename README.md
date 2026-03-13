# WheelNotes

Standalone notes app for Wheel.

## Layout

- `Sources/WheelNotes`: SwiftUI macOS app shell
- `Sources/WheelNotesCore`: note domain, editor integration, Fabric provider
- `Sources/WheelSupport`: shared storage and WebKit helpers
- `NoteEditorWeb`: source for the bundled web note editor

## Development

```sh
make build
make test
make run
```
