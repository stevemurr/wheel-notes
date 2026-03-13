import { build } from 'esbuild'
import { cp, mkdir } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const outdir = path.resolve(root, '../Sources/WheelNotesCore/Resources/NoteEditor')

await mkdir(outdir, { recursive: true })

await build({
  entryPoints: [path.join(root, 'src/main.ts')],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020', 'safari16'],
  outfile: path.join(outdir, 'note-editor.js'),
  loader: {
    '.css': 'css',
  },
  sourcemap: false,
  logLevel: 'info',
})

await cp(path.join(root, 'src/index.html'), path.join(outdir, 'index.html'))
