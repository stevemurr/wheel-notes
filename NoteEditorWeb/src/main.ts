import './styles.css'

import { Editor, Extension, Node, mergeAttributes, type Range } from '@tiptap/core'
import Image from '@tiptap/extension-image'
import type { Node as ProseMirrorNode } from '@tiptap/pm/model'
import { TextSelection } from '@tiptap/pm/state'
import Placeholder from '@tiptap/extension-placeholder'
import Table from '@tiptap/extension-table'
import TableCell from '@tiptap/extension-table-cell'
import TableHeader from '@tiptap/extension-table-header'
import TableRow from '@tiptap/extension-table-row'
import TaskItem from '@tiptap/extension-task-item'
import TaskList from '@tiptap/extension-task-list'
import StarterKit from '@tiptap/starter-kit'
import Suggestion, { type SuggestionKeyDownProps, type SuggestionProps } from '@tiptap/suggestion'

type JSONObject = Record<string, unknown>

type BridgeMessage = {
  type: string
  payload?: JSONObject
}

type SourcePayload = {
  title: string
  url: string
  capturedAt?: string
}

type ImageInsertResult = {
  imageCount: number
  sources: string[]
  alts: string[]
}

type LinkCardPayload = {
  title: string
  url: string
}

type LinkCardInsertResult = {
  inserted: boolean
  title: string
  url: string
  linkCount: number
}

type SlashItem = {
  title: string
  description: string
  keywords: string[]
  command: (editor: Editor) => void
}

declare global {
  interface Window {
    NoteEditor: {
      receiveCommand: (command: string, payload: JSONObject) => void
      debugApplyMarkdown: (text: string) => JSONObject
      debugOpenSlashMenu: (query: string) => JSONObject
      debugInsertImage: (mimeType: string, fileName?: string) => Promise<ImageInsertResult>
      debugPasteLink: (plainText: string, html?: string, uriList?: string) => LinkCardInsertResult
    }
    webkit?: {
      messageHandlers?: {
        noteEditorBridge?: {
          postMessage: (message: BridgeMessage) => void
        }
      }
    }
  }
}

const editorElement = document.getElementById('editor')

if (!editorElement) {
  throw new Error('Wheel note editor failed to find its editor root element.')
}

let documentChangeTimer: number | undefined
const supportedImageExtensions = new Set([
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'svg',
  'bmp',
  'tif',
  'tiff',
  'heic',
  'heif',
  'avif',
  'ico',
])

const sendBridgeMessage = (type: string, payload: JSONObject = {}) => {
  window.webkit?.messageHandlers?.noteEditorBridge?.postMessage({ type, payload })
}

function isEmptyParagraphNode(node: ProseMirrorNode | null | undefined): boolean {
  return Boolean(node && node.type.name === 'paragraph' && node.childCount === 0)
}

function isEmptyEditor(editor: Editor): boolean {
  return editor.state.doc.childCount === 1 && isEmptyParagraphNode(editor.state.doc.firstChild)
}

function normalizeText(value: string): string {
  return value.replace(/\s+/g, ' ').trim()
}

function truncateText(value: string, maxLength: number): string {
  const normalized = normalizeText(value)
  if (normalized.length <= maxLength) {
    return normalized
  }

  return `${normalized.slice(0, Math.max(0, maxLength - 1)).trimEnd()}…`
}

function normalizeLinkURL(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed || /\s/.test(trimmed)) {
    return null
  }

  try {
    const parsed = new URL(trimmed)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
      return null
    }

    return parsed.toString()
  } catch {
    return null
  }
}

function formatLinkDisplayURL(value: string, maxLength = 58): string {
  try {
    const parsed = new URL(value)
    const hostname = parsed.hostname.replace(/^www\./i, '')
    const pathname = parsed.pathname === '/' ? '' : parsed.pathname.replace(/\/$/, '')
    const decodedPath = pathname
      ? (() => {
          try {
            return decodeURIComponent(pathname)
          } catch {
            return pathname
          }
        })()
      : ''
    const suffix = parsed.search || parsed.hash ? '…' : ''
    const display = `${hostname}${decodedPath}${suffix}` || hostname || value

    return truncateText(display, maxLength)
  } catch {
    return truncateText(value, maxLength)
  }
}

function deriveLinkTitle(url: string): string {
  return formatLinkDisplayURL(url, 92)
}

function formatLinkTitle(value: string): string {
  return truncateText(value, 92)
}

function formatLinkSummary(value: string): string {
  return formatLinkDisplayURL(value, 58)
}

function formatLinkHost(value: string): string {
  try {
    return new URL(value).hostname.replace(/^www\./i, '') || value
  } catch {
    return value
  }
}

function extractSingleAnchorFromHTML(html: string): { href: string; text: string } | null {
  const trimmed = html.trim()
  if (!trimmed) {
    return null
  }

  const document = new DOMParser().parseFromString(trimmed, 'text/html')
  const anchors = Array.from(document.body.querySelectorAll('a[href]'))
  if (anchors.length !== 1) {
    return null
  }

  const [anchor] = anchors
  const bodyText = normalizeText(document.body.textContent ?? '')
  const anchorText = normalizeText(anchor.textContent ?? '')

  if (bodyText && anchorText && bodyText !== anchorText) {
    return null
  }

  return {
    href: anchor.href,
    text: anchorText,
  }
}

function firstURIListEntry(value: string): string {
  return value
    .split(/\r?\n/)
    .map((entry) => entry.trim())
    .find((entry) => entry.length > 0 && !entry.startsWith('#')) ?? ''
}

function extractLinkCardPayload(
  plainText: string,
  html = '',
  uriList = '',
): LinkCardPayload | null {
  const anchor = extractSingleAnchorFromHTML(html)
  const plainURL = normalizeLinkURL(normalizeText(plainText))
  const uriListURL = normalizeLinkURL(firstURIListEntry(uriList))
  const anchorURL = normalizeLinkURL(anchor?.href ?? '')
  const url = plainURL ?? anchorURL ?? uriListURL

  if (!url) {
    return null
  }

  if (anchorURL && plainURL && anchorURL !== plainURL) {
    return null
  }

  const anchorTitle = normalizeText(anchor?.text ?? '')
  const title = anchorTitle && anchorTitle !== url ? formatLinkTitle(anchorTitle) : deriveLinkTitle(url)

  return {
    title,
    url,
  }
}

function selectionCanInsertTopLevelBlock(editor: Editor): boolean {
  const { selection } = editor.state
  if (!selection.empty) {
    return false
  }

  const { $from } = selection
  return $from.depth === 1 && $from.parent.type.name === 'paragraph' && $from.parent.textContent.trim().length === 0
}

function currentTopLevelParagraphRange(editor: Editor): Range | null {
  if (!selectionCanInsertTopLevelBlock(editor)) {
    return null
  }

  const { $from } = editor.state.selection
  return {
    from: $from.before(),
    to: $from.after(),
  }
}

function isSupportedImageFile(file: File): boolean {
  const normalizedType = file.type.trim().toLowerCase()
  if (normalizedType.startsWith('image/')) {
    return true
  }

  const extensionMatch = file.name.toLowerCase().match(/\.([a-z0-9]+)$/)
  return Boolean(extensionMatch && supportedImageExtensions.has(extensionMatch[1]))
}

function readFileAsDataURL(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()

    reader.onerror = () => {
      reject(new Error(`Failed to read ${file.name || 'image file'}.`))
    }

    reader.onload = () => {
      if (typeof reader.result === 'string') {
        resolve(reader.result)
        return
      }

      reject(new Error(`Failed to decode ${file.name || 'image file'}.`))
    }

    reader.readAsDataURL(file)
  })
}

function buildImageContent(
  images: Array<{ src: string; alt: string }>,
): JSONObject[] {
  const content: JSONObject[] = []

  images.forEach((image) => {
    content.push({
      type: 'image',
      attrs: {
        src: image.src,
        alt: image.alt,
        title: image.alt,
      },
    })
    content.push({ type: 'paragraph' })
  })

  return content
}

function buildLinkCardContent(link: LinkCardPayload): JSONObject[] {
  return [
    {
      type: 'linkCard',
      attrs: {
        title: link.title,
        url: link.url,
      },
    },
    {
      type: 'paragraph',
    },
  ]
}

async function insertImageFiles(
  editor: Editor,
  files: File[],
  target?: number | Range,
): Promise<boolean> {
  const imageFiles = files.filter(isSupportedImageFile)
  if (imageFiles.length === 0) {
    return false
  }

  try {
    const images = await Promise.all(
      imageFiles.map(async (file) => ({
        src: await readFileAsDataURL(file),
        alt: file.name || 'Image',
      })),
    )
    const content = buildImageContent(images)

    if (isEmptyEditor(editor)) {
      editor.commands.setContent({ type: 'doc', content }, false)
      editor.commands.focus('end')
      return true
    }

    const insertionTarget = typeof target === 'number'
      ? { from: target, to: target }
      : target ?? { from: editor.state.selection.from, to: editor.state.selection.to }

    editor
      .chain()
      .focus()
      .insertContentAt(insertionTarget, content)
      .run()

    return true
  } catch (error) {
    sendBridgeMessage('editorError', {
      message: error instanceof Error ? error.message : 'Failed to insert dropped image.',
    })
    return false
  }
}

function makeDebugImageFile(mimeType: string, fileName?: string): File {
  const normalizedMimeType = mimeType.trim().toLowerCase()
  const fallbackName = normalizedMimeType === 'image/jpeg' ? 'debug-image.jpg' : 'debug-image.png'
  const bytes = normalizedMimeType === 'image/jpeg'
    ? new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
    : new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

  return new File([bytes], fileName || fallbackName, {
    type: normalizedMimeType || 'image/png',
  })
}

function insertLinkCard(editor: Editor, link: LinkCardPayload): boolean {
  if (!selectionCanInsertTopLevelBlock(editor)) {
    return false
  }

  const content = buildLinkCardContent(link)

  if (isEmptyEditor(editor)) {
    editor.commands.setContent({ type: 'doc', content }, false)
    editor.commands.focus('end')
    return true
  }

  const insertionTarget = currentTopLevelParagraphRange(editor)
  if (!insertionTarget) {
    return false
  }

  editor
    .chain()
    .focus()
    .insertContentAt(insertionTarget, content)
    .run()

  return true
}

function deleteAtomicBlock(
  editor: Editor,
  getPos: (() => number) | boolean,
  nodeTypeName: string,
): boolean {
  if (typeof getPos !== 'function') {
    return false
  }

  const position = getPos()
  const blockNode = editor.state.doc.nodeAt(position)

  if (!blockNode || blockNode.type.name !== nodeTypeName) {
    return false
  }

  let from = position
  let to = position + blockNode.nodeSize

  const before = editor.state.doc.resolve(position).nodeBefore
  if (isEmptyParagraphNode(before)) {
    from -= before.nodeSize
  }

  const after = editor.state.doc.resolve(position + blockNode.nodeSize).nodeAfter
  if (isEmptyParagraphNode(after)) {
    to += after.nodeSize
  }

  const paragraph = editor.state.schema.nodes.paragraph
  const transaction = editor.state.tr.delete(from, to)

  if (transaction.doc.childCount === 0 && paragraph) {
    transaction.insert(0, paragraph.create())
  }

  const selectionPosition = Math.min(from, transaction.doc.content.size)
  transaction.setSelection(TextSelection.near(transaction.doc.resolve(selectionPosition)))
  editor.view.dispatch(transaction.scrollIntoView())

  return true
}

function applyMarkdownShortcut(editor: Editor, rawTextBefore: string): boolean {
  const { selection } = editor.state

  if (!selection.empty) {
    return false
  }

  const { $from } = selection
  if ($from.parent.type.name !== 'paragraph') {
    return false
  }

  const textBefore = rawTextBefore.trimStart()
  if (!textBefore) {
    return false
  }

  const markerRange = {
    from: $from.start(),
    to: selection.from,
  }

  if (/^#{1,3}$/.test(textBefore)) {
    return editor
      .chain()
      .focus()
      .deleteRange(markerRange)
      .setNode('heading', { level: textBefore.length })
      .run()
  }

  if (/^[-+*]$/.test(textBefore)) {
    return editor.chain().focus().deleteRange(markerRange).toggleBulletList().run()
  }

  if (/^1[.)]$/.test(textBefore)) {
    return editor.chain().focus().deleteRange(markerRange).toggleOrderedList().run()
  }

  if (/^(?:\[\]|\[ \])$/.test(textBefore)) {
    return editor.chain().focus().deleteRange(markerRange).toggleTaskList().run()
  }

  if (textBefore === '>') {
    return editor.chain().focus().deleteRange(markerRange).toggleBlockquote().run()
  }

  if (textBefore === '```' || textBefore === '~~~') {
    return editor.chain().focus().deleteRange(markerRange).toggleCodeBlock().run()
  }

  return false
}

const PageSource = Node.create({
  name: 'pageSource',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: false,

  addAttributes() {
    return {
      title: { default: '' },
      url: { default: '' },
      capturedAt: { default: '' },
    }
  },

  parseHTML() {
    return [{ tag: 'div[data-type="page-source"]' }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'page-source' })]
  },

  addNodeView() {
    return ({ editor, getPos, node }) => {
      const dom = document.createElement('div')
      dom.className = 'page-source'
      dom.dataset.type = 'page-source'

      const icon = document.createElement('div')
      icon.className = 'page-source__icon'
      icon.textContent = '↗'

      const meta = document.createElement('div')
      meta.className = 'page-source__meta'

      const link = document.createElement('a')
      link.className = 'page-source__title'
      link.href = String(node.attrs.url ?? '')
      link.target = '_blank'
      link.rel = 'noreferrer'
      link.textContent = String(node.attrs.title ?? node.attrs.url ?? 'Source')

      const url = document.createElement('span')
      url.className = 'page-source__url'
      url.textContent = String(node.attrs.url ?? '')

      const time = document.createElement('span')
      time.className = 'page-source__time'
      time.textContent = formatCapturedAt(String(node.attrs.capturedAt ?? ''))

      const actions = document.createElement('div')
      actions.className = 'page-source__actions'

      const remove = document.createElement('button')
      remove.type = 'button'
      remove.className = 'page-source__remove'
      remove.textContent = 'Remove'
      remove.setAttribute('aria-label', 'Remove source block')
      const handleRemove = (event: MouseEvent) => {
        event.preventDefault()
        event.stopPropagation()
        deleteAtomicBlock(editor, getPos, 'pageSource')
      }
      remove.onmousedown = handleRemove
      remove.onclick = handleRemove

      meta.append(link, url)
      actions.append(time, remove)
      dom.append(icon, meta, actions)

      return {
        dom,
        selectNode: () => dom.classList.add('is-selected'),
        deselectNode: () => dom.classList.remove('is-selected'),
      }
    }
  },
})

const LinkCard = Node.create({
  name: 'linkCard',
  group: 'block',
  atom: true,
  selectable: true,
  draggable: false,

  addAttributes() {
    return {
      title: { default: '' },
      url: { default: '' },
    }
  },

  parseHTML() {
    return [{ tag: 'div[data-type="link-card"]' }]
  },

  renderHTML({ HTMLAttributes }) {
    return ['div', mergeAttributes(HTMLAttributes, { 'data-type': 'link-card' })]
  },

  addNodeView() {
    return ({ editor, getPos, node }) => {
      const dom = document.createElement('div')
      dom.className = 'link-card'
      dom.dataset.type = 'link-card'

      const icon = document.createElement('div')
      icon.className = 'link-card__icon'
      icon.textContent = '↗'

      const meta = document.createElement('div')
      meta.className = 'link-card__meta'

      const link = document.createElement('a')
      link.className = 'link-card__title'
      link.href = String(node.attrs.url ?? '')
      link.target = '_blank'
      link.rel = 'noreferrer'
      link.textContent = String(node.attrs.title ?? node.attrs.url ?? 'Link')

      const url = document.createElement('span')
      url.className = 'link-card__url'
      url.textContent = formatLinkSummary(String(node.attrs.url ?? ''))

      const actions = document.createElement('div')
      actions.className = 'link-card__actions'

      const host = document.createElement('span')
      host.className = 'link-card__host'
      host.textContent = formatLinkHost(String(node.attrs.url ?? ''))

      const remove = document.createElement('button')
      remove.type = 'button'
      remove.className = 'link-card__remove'
      remove.textContent = 'Remove'
      remove.setAttribute('aria-label', 'Remove link block')
      const handleRemove = (event: MouseEvent) => {
        event.preventDefault()
        event.stopPropagation()
        deleteAtomicBlock(editor, getPos, 'linkCard')
      }
      remove.onmousedown = handleRemove
      remove.onclick = handleRemove

      meta.append(link, url)
      actions.append(host, remove)
      dom.append(icon, meta, actions)

      return {
        dom,
        selectNode: () => dom.classList.add('is-selected'),
        deselectNode: () => dom.classList.remove('is-selected'),
      }
    }
  },
})

const slashItems: SlashItem[] = [
  {
    title: 'Text',
    description: 'Switch back to normal text',
    keywords: ['paragraph', 'text', 'body'],
    command: (editor) => editor.chain().focus().setParagraph().run(),
  },
  {
    title: 'Heading 1',
    description: 'Large section heading',
    keywords: ['heading', 'title', 'h1'],
    command: (editor) => editor.chain().focus().toggleHeading({ level: 1 }).run(),
  },
  {
    title: 'Heading 2',
    description: 'Secondary section heading',
    keywords: ['heading', 'subtitle', 'h2'],
    command: (editor) => editor.chain().focus().toggleHeading({ level: 2 }).run(),
  },
  {
    title: 'Heading 3',
    description: 'Compact section heading',
    keywords: ['heading', 'subheading', 'h3'],
    command: (editor) => editor.chain().focus().toggleHeading({ level: 3 }).run(),
  },
  {
    title: 'Bullet List',
    description: 'Create a bulleted list',
    keywords: ['list', 'bullets', 'unordered'],
    command: (editor) => editor.chain().focus().toggleBulletList().run(),
  },
  {
    title: 'Checklist',
    description: 'Track tasks with checkboxes',
    keywords: ['tasks', 'todo', 'checklist'],
    command: (editor) => editor.chain().focus().toggleTaskList().run(),
  },
  {
    title: 'Numbered List',
    description: 'Create an ordered list',
    keywords: ['list', 'ordered', 'numbers'],
    command: (editor) => editor.chain().focus().toggleOrderedList().run(),
  },
  {
    title: 'Quote',
    description: 'Insert a blockquote',
    keywords: ['blockquote', 'quote', 'citation'],
    command: (editor) => editor.chain().focus().toggleBlockquote().run(),
  },
  {
    title: 'Code Block',
    description: 'Insert a code block',
    keywords: ['code', 'snippet', 'monospace'],
    command: (editor) => editor.chain().focus().toggleCodeBlock().run(),
  },
  {
    title: 'Table',
    description: 'Insert a 3x3 table',
    keywords: ['table', 'grid', 'rows'],
    command: (editor) => editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run(),
  },
]

const createSlashMenu = () => {
  let element: HTMLDivElement | null = null
  let propsRef: SuggestionProps<SlashItem> | null = null
  let selectedIndex = 0

  const remove = () => {
    element?.remove()
    element = null
    propsRef = null
    selectedIndex = 0
  }

  const updatePosition = () => {
    if (!element || !propsRef?.clientRect) {
      return
    }

    const rect = propsRef.clientRect()
    if (!rect) {
      return
    }

    const menuWidth = element.offsetWidth || 240
    const menuHeight = element.offsetHeight || 280
    const left = Math.max(12, Math.min(rect.left, window.innerWidth - menuWidth - 12))
    const preferredTop = rect.bottom + 10
    const top = preferredTop + menuHeight <= window.innerHeight - 12
      ? preferredTop
      : Math.max(12, rect.top - menuHeight - 10)

    element.style.left = `${left}px`
    element.style.top = `${top}px`
  }

  const selectItem = (index: number) => {
    if (!propsRef) {
      return
    }

    const item = propsRef.items[index]
    if (!item) {
      return
    }

    propsRef.command(item)
  }

  const renderItems = () => {
    if (!element || !propsRef) {
      return
    }

    element.innerHTML = ''
    if (propsRef.items.length === 0) {
      const emptyState = document.createElement('div')
      emptyState.className = 'slash-menu__empty'
      emptyState.textContent = 'No matching blocks'
      element.appendChild(emptyState)
      return
    }

    propsRef.items.forEach((item, index) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.className = `slash-menu__item${index === selectedIndex ? ' is-selected' : ''}`
      button.innerHTML = `<strong>${item.title}</strong><span>${item.description}</span>`
      button.onmousedown = (event) => {
        event.preventDefault()
        selectItem(index)
      }
      element?.appendChild(button)
    })
  }

  return {
    onStart: (props: SuggestionProps<SlashItem>) => {
      propsRef = props
      selectedIndex = 0
      element = document.createElement('div')
      element.className = 'slash-menu'
      document.body.appendChild(element)
      renderItems()
      updatePosition()
    },
    onUpdate: (props: SuggestionProps<SlashItem>) => {
      propsRef = props
      selectedIndex = Math.min(selectedIndex, Math.max(props.items.length - 1, 0))
      renderItems()
      updatePosition()
    },
    onKeyDown: ({ event }: SuggestionKeyDownProps) => {
      if (!propsRef) {
        return false
      }

      if (propsRef.items.length === 0) {
        if (event.key === 'Escape') {
          remove()
          return true
        }

        return false
      }

      if (event.key === 'ArrowDown') {
        selectedIndex = (selectedIndex + 1) % propsRef.items.length
        renderItems()
        return true
      }

      if (event.key === 'ArrowUp') {
        selectedIndex = (selectedIndex + propsRef.items.length - 1) % propsRef.items.length
        renderItems()
        return true
      }

      if (event.key === 'Enter') {
        selectItem(selectedIndex)
        return true
      }

      if (event.key === 'Tab') {
        event.preventDefault()
        selectItem(selectedIndex)
        return true
      }

      if (event.key === 'Escape') {
        remove()
        return true
      }

      return false
    },
    onExit: remove,
  }
}

const SlashCommand = Extension.create({
  name: 'slashCommand',

  addProseMirrorPlugins() {
    return [
      Suggestion<SlashItem>({
        editor: this.editor,
        char: '/',
        startOfLine: true,
        allowedPrefixes: null,
        items: ({ query }) => {
          const normalized = query.trim().toLowerCase()
          if (!normalized) {
            return slashItems
          }
          return slashItems.filter((item) => {
            return (
              item.title.toLowerCase().includes(normalized) ||
              item.description.toLowerCase().includes(normalized) ||
              item.keywords.some((keyword) => keyword.includes(normalized))
            )
          })
        },
        command: ({ editor, range, props }) => {
          editor.chain().focus().deleteRange(range as Range).run()
          props.command(editor)
        },
        render: createSlashMenu,
      }),
    ]
  },
})

const MarkdownShortcuts = Extension.create({
  name: 'markdownShortcuts',

  addKeyboardShortcuts() {
    return {
      Space: () => {
        const { selection } = this.editor.state
        const { $from } = selection
        const textBefore = $from.parent.textBetween(0, $from.parentOffset, undefined, '\ufffc')
        return applyMarkdownShortcut(this.editor, textBefore)
      },
    }
  },
})

const editor = new Editor({
  element: editorElement,
  extensions: [
    StarterKit.configure({
      history: true,
      heading: { levels: [1, 2, 3] },
    }),
    TaskList,
    TaskItem.configure({ nested: true }),
    Table.configure({ resizable: true }),
    TableRow,
    TableHeader,
    TableCell,
    Image.configure({
      allowBase64: true,
      inline: false,
      HTMLAttributes: {
        loading: 'lazy',
      },
    }),
    Placeholder.configure({
      placeholder: 'First line becomes the title. Type / for blocks, use markdown like #, -, [], >, and ```, or drop images here.',
    }),
    PageSource,
    LinkCard,
    MarkdownShortcuts,
    SlashCommand,
  ],
  editorProps: {
    attributes: {
      class: 'wheel-note-editor',
      spellcheck: 'true',
    },
    handleDrop: (_view, event) => {
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length === 0 || files.every((file) => !isSupportedImageFile(file))) {
        return false
      }

      event.preventDefault()
      const position = editor.view.posAtCoords({
        left: event.clientX,
        top: event.clientY,
      })?.pos
      void insertImageFiles(editor, files, position)
      return true
    },
    handlePaste: (_view, event) => {
      const files = Array.from(event.clipboardData?.files ?? [])
      if (files.length > 0 && files.some(isSupportedImageFile)) {
        event.preventDefault()
        void insertImageFiles(editor, files)
        return true
      }

      const link = extractLinkCardPayload(
        event.clipboardData?.getData('text/plain') ?? '',
        event.clipboardData?.getData('text/html') ?? '',
        event.clipboardData?.getData('text/uri-list') ?? '',
      )
      if (!link || !selectionCanInsertTopLevelBlock(editor)) {
        return false
      }

      event.preventDefault()
      return insertLinkCard(editor, link)
    },
  },
  content: {
    type: 'doc',
    content: [{ type: 'paragraph' }],
  },
  onUpdate: ({ editor }) => {
    window.clearTimeout(documentChangeTimer)
    documentChangeTimer = window.setTimeout(() => {
      sendBridgeMessage('documentChanged', { document: editor.getJSON() as JSONObject })
    }, 120)
  },
  onCreate: () => {
    sendBridgeMessage('ready')
  },
})

function setDocument(document: JSONObject | undefined) {
  editor.commands.setContent(
    document ?? {
      type: 'doc',
      content: [{ type: 'paragraph' }],
    },
    false
  )
}

function focusEditorAtStart() {
  editorElement.scrollTop = 0
  editor.commands.focus('start', { scrollIntoView: false })
}

function insertSourceBlock(source: SourcePayload | undefined) {
  if (!source) {
    return
  }

  editor
    .chain()
    .focus()
    .insertContent([
      {
        type: 'pageSource',
        attrs: {
          title: source.title,
          url: source.url,
          capturedAt: source.capturedAt ?? new Date().toISOString(),
        },
      },
      {
        type: 'paragraph',
      },
    ])
    .run()
}

window.NoteEditor = {
  receiveCommand(command: string, payload: JSONObject) {
    try {
      switch (command) {
        case 'loadDocument':
          setDocument(payload.document as JSONObject | undefined)
          break
        case 'focusEditor':
          focusEditorAtStart()
          break
        case 'insertSourceBlock':
          insertSourceBlock(payload.source as SourcePayload | undefined)
          break
        default:
          break
      }
    } catch (error) {
      sendBridgeMessage('editorError', {
        message: error instanceof Error ? error.message : 'Unknown note editor failure',
      })
    }
  },
  debugApplyMarkdown(text: string) {
    const triggerText = text.endsWith(' ') ? text.slice(0, -1) : text

    setDocument({
      type: 'doc',
      content: [
        {
          type: 'paragraph',
          content: triggerText
            ? [
                {
                  type: 'text',
                  text: triggerText,
                },
              ]
            : [],
        },
      ],
    })
    editor.commands.focus('start')
    editor.commands.focus('end')
    const applied = applyMarkdownShortcut(editor, triggerText)
    const document = editor.getJSON() as {
      content?: Array<Record<string, unknown>>
    }
    const firstNode = document.content?.[0] ?? {}
    const attrs = (firstNode.attrs as Record<string, unknown> | undefined) ?? {}

    return {
      applied,
      type: firstNode.type ?? '',
      level: attrs.level ?? 0,
    }
  },
  debugOpenSlashMenu(query: string) {
    setDocument({
      type: 'doc',
      content: [{ type: 'paragraph' }],
    })
    editor.commands.focus('start')
    editor.commands.focus('end')
    if (query.length > 0) {
      editor.commands.insertContent(`/${query}`)
    } else {
      editor.commands.insertContent('/')
    }

    const items = Array.from(document.querySelectorAll('.slash-menu__item strong')).map((element) => {
      return element.textContent ?? ''
    })

    return {
      visible: Boolean(document.querySelector('.slash-menu')),
      itemCount: items.length,
      items,
    }
  },
  async debugInsertImage(mimeType: string, fileName?: string) {
    setDocument({
      type: 'doc',
      content: [{ type: 'paragraph' }],
    })
    editor.commands.focus('end')
    await insertImageFiles(editor, [makeDebugImageFile(mimeType, fileName)])

    const images = Array.from(document.querySelectorAll('.ProseMirror img'))
    return {
      imageCount: images.length,
      sources: images.map((image) => image.getAttribute('src') ?? ''),
      alts: images.map((image) => image.getAttribute('alt') ?? ''),
    }
  },
  debugPasteLink(plainText: string, html = '', uriList = '') {
    setDocument({
      type: 'doc',
      content: [{ type: 'paragraph' }],
    })
    editor.commands.focus('end')

    const link = extractLinkCardPayload(plainText, html, uriList)
    const inserted = link ? insertLinkCard(editor, link) : false
    const links = Array.from(document.querySelectorAll('.link-card'))

    return {
      inserted,
      title: document.querySelector('.link-card__title')?.textContent ?? '',
      url: document.querySelector('.link-card__url')?.textContent ?? '',
      linkCount: links.length,
    }
  },
}

function formatCapturedAt(value: string): string {
  if (!value) {
    return 'Source'
  }

  const date = new Date(value)
  if (Number.isNaN(date.getTime())) {
    return 'Source'
  }

  return date.toLocaleDateString(undefined, {
    month: 'short',
    day: 'numeric',
  })
}
