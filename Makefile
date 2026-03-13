NOTE_EDITOR_DIR = NoteEditorWeb

.PHONY: build build-note-editor run test clean

build-note-editor:
	@if [ -d "$(NOTE_EDITOR_DIR)/node_modules" ]; then \
		npm --prefix "$(NOTE_EDITOR_DIR)" run build; \
	elif [ -f "Sources/WheelNotesCore/Resources/NoteEditor/index.html" ]; then \
		echo "Using existing NoteEditor bundle. Run 'npm --prefix $(NOTE_EDITOR_DIR) install && npm --prefix $(NOTE_EDITOR_DIR) run build' to refresh it."; \
	else \
		echo "NoteEditor bundle missing. Run 'npm --prefix $(NOTE_EDITOR_DIR) install && npm --prefix $(NOTE_EDITOR_DIR) run build' first."; \
		exit 1; \
	fi

build: build-note-editor
	swift build

run: build-note-editor
	swift run WheelNotes

test: build-note-editor
	swift test

clean:
	swift package clean
