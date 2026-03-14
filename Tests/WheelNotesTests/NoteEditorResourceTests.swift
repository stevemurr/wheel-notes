import Foundation
import Testing
import WebKit
@testable import WheelNotesCore

@Suite("Note editor resources", .serialized)
@MainActor
struct NoteEditorResourceTests {
    @Test("Bundled editor HTML is present and bootstraps the runtime")
    func loadsEditorBundle() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.evaluateJavaScript("typeof window.NoteEditor.receiveCommand === 'function'")
        let hasBridge = try #require(result as? Bool)
        #expect(hasBridge)
    }

    @Test("Bundled editor exposes an explicit remove control for page source cards")
    func pageSourceCardsCanBeRemoved() async throws {
        let webView = try await makeLoadedWebView()

        let sourceCountBefore = try await webView.evaluateJavaScript(
            """
            (() => {
              window.NoteEditor.receiveCommand('loadDocument', {
                document: {
                  type: 'doc',
                  content: [
                    {
                      type: 'pageSource',
                      attrs: {
                        title: 'Wheel Docs',
                        url: 'https://example.com/docs',
                        capturedAt: '2026-03-08T00:00:00Z'
                      }
                    },
                    { type: 'paragraph' }
                  ]
                }
              });

              return document.querySelectorAll('.page-source__remove').length;
            })()
            """
        )
        #expect((sourceCountBefore as? NSNumber)?.intValue == 1)

        let sourceCountAfter = try await webView.evaluateJavaScript(
            """
            (() => {
              const button = document.querySelector('.page-source__remove');
              button?.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true }));
              return document.querySelectorAll('.page-source').length;
            })()
            """
        )
        #expect((sourceCountAfter as? NSNumber)?.intValue == 0)
    }

    @Test("Bundled editor applies markdown heading shortcuts")
    func markdownShortcutsTransformContent() async throws {
        let webView = try await makeLoadedWebView()

        let applied = try await webView.evaluateJavaScript(
            "window.NoteEditor.debugApplyMarkdown('# ').applied"
        )
        let nodeType = try await webView.evaluateJavaScript(
            "window.NoteEditor.debugApplyMarkdown('# ').type"
        )
        let headingLevel = try await webView.evaluateJavaScript(
            "window.NoteEditor.debugApplyMarkdown('# ').level"
        )

        #expect(applied as? Bool == true)
        #expect(nodeType as? String == "heading")
        #expect((headingLevel as? NSNumber)?.intValue == 1)
    }

    @Test("Bundled editor opens the slash command menu at the start of a line")
    func slashCommandMenuAppears() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.callAsyncJavaScript(
            """
            window.NoteEditor.debugOpenSlashMenu('');
            await Promise.resolve();
            return {
              visible: Boolean(document.querySelector('.slash-menu')),
              itemCount: document.querySelectorAll('.slash-menu__item').length,
              firstItem: document.querySelector('.slash-menu__item strong')?.textContent ?? '',
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let payload = try #require(result as? [String: Any])

        #expect(payload["visible"] as? Bool == true)
        #expect((payload["itemCount"] as? NSNumber)?.intValue ?? 0 > 0)
        #expect(payload["firstItem"] as? String == "Text")
    }

    @Test("Bundled editor renders markdown todo shortcuts as styled task rows")
    func taskShortcutCreatesStyledTaskList() async throws {
        let webView = try await makeLoadedWebView()

        let applied = try await webView.evaluateJavaScript(
            "window.NoteEditor.debugApplyMarkdown('[] ').applied"
        )
        let nodeType = try await webView.evaluateJavaScript(
            "window.NoteEditor.debugApplyMarkdown('[] ').type"
        )
        let result = try await webView.callAsyncJavaScript(
            """
            window.NoteEditor.debugApplyMarkdown('[] ');
            await new Promise((resolve) => setTimeout(resolve, 0));
            const list = document.querySelector('ul[data-type="taskList"]');
            const item = document.querySelector('ul[data-type="taskList"] li');
            return {
              listStyle: list ? getComputedStyle(list).listStyleType : '',
              itemDisplay: item ? getComputedStyle(item).display : '',
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let payload = try #require(result as? [String: Any])

        #expect(applied as? Bool == true)
        #expect(nodeType as? String == "taskList")
        #expect(payload["listStyle"] as? String == "none")
        #expect(payload["itemDisplay"] as? String == "flex")
    }

    @Test("Bundled editor inserts dropped image files as note images")
    func droppedImagesInsertIntoDocument() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.callAsyncJavaScript(
            """
            const png = await window.NoteEditor.debugInsertImage('image/png', 'diagram.png');
            const jpeg = await window.NoteEditor.debugInsertImage('image/jpeg', 'photo.jpg');
            return { png, jpeg };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let payload = try #require(result as? [String: Any])
        let png = try #require(payload["png"] as? [String: Any])
        let jpeg = try #require(payload["jpeg"] as? [String: Any])
        let pngSources = try #require(png["sources"] as? [String])
        let jpegSources = try #require(jpeg["sources"] as? [String])
        let pngAlts = try #require(png["alts"] as? [String])
        let jpegAlts = try #require(jpeg["alts"] as? [String])

        #expect((png["imageCount"] as? NSNumber)?.intValue == 1)
        #expect(pngSources.first?.hasPrefix("data:image/png;base64,") == true)
        #expect(pngAlts.first == "diagram.png")
        #expect((jpeg["imageCount"] as? NSNumber)?.intValue == 1)
        #expect(jpegSources.first?.hasPrefix("data:image/jpeg;base64,") == true)
        #expect(jpegAlts.first == "photo.jpg")
    }

    @Test("Bundled editor turns pasted links into removable link cards")
    func pastedLinksInsertAsLinkCards() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.callAsyncJavaScript(
            """
            const inserted = window.NoteEditor.debugPasteLink(
              'https://www.example.com/product/notes?view=full#section',
              '<a href="https://www.example.com/product/notes?view=full#section">Product Notes</a>'
            );
            return {
              inserted: inserted.inserted,
              linkCount: inserted.linkCount,
              title: document.querySelector('.link-card__title')?.textContent ?? '',
              url: document.querySelector('.link-card__url')?.textContent ?? '',
              host: document.querySelector('.link-card__host')?.textContent ?? '',
              removeCount: document.querySelectorAll('.link-card__remove').length,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let payload = try #require(result as? [String: Any])

        #expect(payload["inserted"] as? Bool == true)
        #expect((payload["linkCount"] as? NSNumber)?.intValue == 1)
        #expect(payload["title"] as? String == "Product Notes")
        #expect(payload["url"] as? String == "example.com/product/notes…")
        #expect(payload["host"] as? String == "example.com")
        #expect((payload["removeCount"] as? NSNumber)?.intValue == 1)
    }

    @Test("Bundled editor omits formatting toolbar buttons")
    func toolbarOmitsFormattingButtons() async throws {
        let webView = try await makeLoadedWebView()

        let buttonCount = try await webView.evaluateJavaScript(
            """
            document.querySelectorAll('#toolbar button').length
            """
        )

        #expect((buttonCount as? NSNumber)?.intValue == 0)
    }

    @Test("Switching notes focuses the editor at the top of the document")
    func switchingNotesResetsViewportToTop() async throws {
        let webView = try await makeLoadedWebView()

        let result = try await webView.callAsyncJavaScript(
            """
            const makeDocument = (prefix) => ({
              type: 'doc',
              content: Array.from({ length: 80 }, (_, index) => ({
                type: 'paragraph',
                content: [{ type: 'text', text: `${prefix} line ${index + 1}` }],
              })),
            });

            const editor = document.querySelector('.editor');
            if (!editor) {
              return null;
            }

            window.NoteEditor.receiveCommand('loadDocument', { document: makeDocument('First') });
            editor.scrollTop = editor.scrollHeight;

            window.NoteEditor.receiveCommand('loadDocument', { document: makeDocument('Second') });
            window.NoteEditor.receiveCommand('focusEditor', {});

            await new Promise((resolve) => setTimeout(resolve, 25));

            return {
              scrollTop: editor.scrollTop,
              scrollHeight: editor.scrollHeight,
              clientHeight: editor.clientHeight,
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let payload = try #require(result as? [String: Any])

        #expect((payload["scrollHeight"] as? NSNumber)?.doubleValue ?? 0 > (payload["clientHeight"] as? NSNumber)?.doubleValue ?? 0)
        #expect((payload["scrollTop"] as? NSNumber)?.doubleValue == 0)
    }

    private func makeLoadedWebView() async throws -> WKWebView {
        let htmlURL = try #require(NoteEditorResources.editorHTMLURL())
        let directoryURL = try #require(NoteEditorResources.editorDirectoryURL())
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            configuration: WKWebViewConfiguration()
        )

        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        webView.loadFileURL(htmlURL, allowingReadAccessTo: directoryURL)
        try await delegate.waitUntilLoaded()
        return webView
    }
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func waitUntilLoaded() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
