vim9script
# proof.vim - Word-style grammar underlines for Vim 9, powered by `claude -p`.
#
# Needs: Vim 9 with +job +textprop +popupwin (standard builds have all three)
#        and a logged-in Claude Code (`claude`) on $PATH.
#
# Install:  git clone https://github.com/mtelvers/proof.vim ~/.vim/pack/plugins/start/proof.vim
#           or copy plugin/proof.vim into ~/.vim/plugin/
#
# Commands: :Proof        check the current buffer now
#           :ProofClear   remove the underlines
#           :ProofAuto    toggle automatic checking (on idle and on save)
#
# Keys (normal mode, in prose buffers - see g:proof_filetypes):
#           ]g / [g       jump to the next / previous suggestion
#           gh            show the reason and suggested fix under the cursor
#           gy            accept the suggested fix under the cursor
#
# Resting the cursor on an underline for 'updatetime' ms pops up the
# suggestion automatically, like hovering in Word.
#
# Settings (set in ~/.vimrc before the plugin loads):
#   g:proof_model      'sonnet' (default), 'haiku' or 'opus'
#   g:proof_effort     'low' (default)
#   g:proof_auto       true: check on idle and on save (default); false: only :Proof
#   g:proof_filetypes  list of filetypes to check
#   g:proof_max_bytes  refuse to check buffers larger than this
#   g:proof_no_maps    true: define no key mappings

if exists('g:loaded_proof')
  finish
endif
g:loaded_proof = 1

g:proof_model     = get(g:, 'proof_model', 'sonnet')
g:proof_effort    = get(g:, 'proof_effort', 'low')
g:proof_auto      = get(g:, 'proof_auto', true)
g:proof_filetypes = get(g:, 'proof_filetypes',
  ['markdown', 'text', 'tex', 'plaintex', 'mail', 'gitcommit', 'rst', 'asciidoc'])
g:proof_max_bytes = get(g:, 'proof_max_bytes', 40000)
g:proof_no_maps   = get(g:, 'proof_no_maps', false)

const PROMPT_LINES =<< trim END
  You are a copy editor reviewing a document written in Markdown.
  Find problems of spelling, grammar, punctuation, repeated words and awkward phrasing.
  Respond with ONLY a JSON array and nothing else: no prose, no code fence.
  Each element is an object with three string fields:
    "original":    the exact faulty text, copied verbatim from the document, character for character, kept within one line and short (the smallest span that contains the problem, usually 1 to 8 words)
    "replacement": the corrected text that should replace "original"
    "reason":      a short explanation, under 12 words
  Do not flag Markdown syntax, code, URLs, file names or proper nouns.
  Do not rewrite for style when the text is already correct.
  Return [] if there is nothing to fix.
END
const SYSTEM_PROMPT = join(PROMPT_LINES, "\n")

# Orange undercurl where the terminal supports it, plain underline elsewhere.
# Vim's own spell checker uses red, so grammar gets a different colour.
# To change it, set g:proof_highlight in ~/.vimrc to the arguments you would
# give :highlight, for example:
#   let g:proof_highlight = 'cterm=undercurl ctermul=Blue gui=undercurl guisp=Blue'
# It is reapplied whenever a colour scheme loads.
def SetHighlight()
  if exists('g:proof_highlight')
    execute 'highlight ProofError term=underline' g:proof_highlight
  else
    highlight default ProofError term=underline cterm=undercurl ctermul=214 gui=undercurl guisp=#ffaf00
  endif
enddef
SetHighlight()
augroup proof_highlight
  autocmd!
  autocmd ColorScheme * SetHighlight()
augroup END

if empty(prop_type_get('proof'))
  prop_type_add('proof', {highlight: 'ProofError', priority: 10, combine: true})
endif

def IsProse(): bool
  return index(g:proof_filetypes, &filetype) >= 0
enddef

def Message(msg: string, hl: string = 'None')
  execute 'echohl' hl
  echomsg 'proof: ' .. msg
  echohl None
enddef

# ---------------------------------------------------------------- running --

def Run()
  var buf = bufnr()
  if exists('b:proof_job') && job_status(b:proof_job) == 'run'
    Message('already checking')
    return
  endif
  var text = join(getline(1, '$'), "\n")
  if text =~ '^\s*$'
    return
  endif
  if len(text) > g:proof_max_bytes
    Message('buffer too large to check (' .. len(text) .. ' bytes, limit g:proof_max_bytes)', 'WarningMsg')
    return
  endif

  b:proof_tick = b:changedtick
  var outfile = tempname()
  var errfile = tempname()
  var cmd = ['claude', '-p', '--no-session-persistence', '--tools', '',
    '--model', g:proof_model, '--effort', g:proof_effort,
    '--output-format', 'text', '--system-prompt', SYSTEM_PROMPT]
  b:proof_job = job_start(cmd, {
    in_io: 'buffer', in_buf: buf,
    out_io: 'file', out_name: outfile,
    err_io: 'file', err_name: errfile,
    exit_cb: (job: job, status: number) => Done(buf, status, outfile, errfile),
  })
  if job_status(b:proof_job) != 'run'
    Message('could not start claude', 'ErrorMsg')
    return
  endif
  Message('checking...')
enddef

def ReadAndDelete(path: string): string
  var text = filereadable(path) ? join(readfile(path), "\n") : ''
  delete(path)
  return text
enddef

def Done(buf: number, status: number, outfile: string, errfile: string)
  var out = ReadAndDelete(outfile)
  var err = ReadAndDelete(errfile)
  if !bufexists(buf)
    return
  endif
  if status != 0
    Message('claude failed: ' .. (empty(err) ? out : err)[: 200], 'ErrorMsg')
    return
  endif
  # Be tolerant of a code fence or a sentence around the array.
  var json = matchstr(out, '\[\_.*\]')
  var findings: any
  try
    findings = json_decode(json)
  catch
    Message('unparseable reply: ' .. out[: 120], 'ErrorMsg')
    return
  endtry
  if type(findings) != v:t_list
    Message('unexpected reply: ' .. out[: 120], 'ErrorMsg')
    return
  endif
  Mark(buf, findings)
  setbufvar(buf, 'proof_done', 1)
enddef

# ---------------------------------------------------------------- marking --

def Str(d: dict<any>, key: string): string
  var v = get(d, key, '')
  return type(v) == v:t_string ? v : string(v)
enddef

def Mark(buf: number, findings: list<any>)
  prop_remove({type: 'proof', bufnr: buf, all: true})
  var store: dict<dict<string>> = {}
  var lines = getbufline(buf, 1, '$')
  var id = 0
  for f in findings
    if type(f) != v:t_dict
      continue
    endif
    var original = Str(f, 'original')
    if original == '' || original =~ "\n"
      continue
    endif
    var lnum = 0
    for line in lines
      lnum += 1
      var col = stridx(line, original)
      if col >= 0
        id += 1
        prop_add(lnum, col + 1,
          {type: 'proof', length: len(original), id: id, bufnr: buf})
        store[string(id)] = {
          original: original,
          replacement: Str(f, 'replacement'),
          reason: Str(f, 'reason'),
        }
        break
      endif
    endfor
  endfor
  setbufvar(buf, 'proof_findings', store)
  Message(id == 0 ? 'nothing to fix' : id .. ' suggestion' .. (id == 1 ? '' : 's') .. '  (]g to review)')
enddef

def Clear()
  prop_remove({type: 'proof', bufnr: bufnr(), all: true})
  b:proof_findings = {}
enddef

# ------------------------------------------------------------- reviewing --

# The finding under the cursor, with its position, or {} if none.
def AtCursor(): dict<any>
  var col = col('.')
  for p in prop_list(line('.'), {types: ['proof']})
    if col >= p.col && col < p.col + p.length
      var f = copy(get(get(b:, 'proof_findings', {}), string(p.id), {}))
      if !empty(f)
        f.lnum = line('.')
        f.col = p.col
        f.length = p.length
        f.id = p.id
      endif
      return f
    endif
  endfor
  return {}
enddef

def Show()
  var f = AtCursor()
  if empty(f)
    return
  endif
  popup_atcursor([f.reason, 'Fix: ' .. f.replacement, '(gy to accept)'], {
    border: [], padding: [0, 1, 0, 1], moved: 'any',
    highlight: 'Pmenu', borderhighlight: ['PmenuSel'],
  })
enddef

def Fix()
  var f = AtCursor()
  if empty(f)
    Message('no suggestion under the cursor')
    return
  endif
  var buf = bufnr()
  var line = getline(f.lnum)
  var before = strpart(line, 0, f.col - 1)
  var after = strpart(line, f.col - 1 + f.length)
  var delta = len(f.replacement) - f.length

  # Remember the other suggestions on this line, since replacing the line
  # drops its text properties.
  var others = prop_list(f.lnum, {types: ['proof']})
    ->filter((_, p) => p.id != f.id)
  setline(f.lnum, before .. f.replacement .. after)
  prop_remove({type: 'proof', bufnr: buf}, f.lnum)
  for p in others
    var col = p.col > f.col ? p.col + delta : p.col
    prop_add(f.lnum, col, {type: 'proof', length: p.length, id: p.id, bufnr: buf})
  endfor
  remove(b:proof_findings, string(f.id))
  # Our own edit should not trigger another check.
  b:proof_tick = b:changedtick
enddef

def Jump(dir: string)
  var p = prop_find({type: 'proof', skipstart: true}, dir)
  if empty(p)
    Message('no ' .. (dir == 'f' ? 'further' : 'earlier') .. ' suggestions')
    return
  endif
  cursor(p.lnum, p.col)
enddef

# ------------------------------------------------------------- automatic --

def Auto()
  if !g:proof_auto || !IsProse() || !&modifiable
    return
  endif
  if get(b:, 'proof_tick', -1) == b:changedtick
    return
  endif
  Run()
enddef

def Hover()
  if IsProse() && !empty(get(b:, 'proof_findings', {}))
    Show()
  endif
enddef

def ToggleAuto()
  g:proof_auto = !g:proof_auto
  Message('automatic checking ' .. (g:proof_auto ? 'on' : 'off'))
enddef

def SetupBuffer()
  if g:proof_no_maps
    return
  endif
  nnoremap <buffer> <silent> ]g <ScriptCmd>Jump('f')<CR>
  nnoremap <buffer> <silent> [g <ScriptCmd>Jump('b')<CR>
  nnoremap <buffer> <silent> gh <ScriptCmd>Show()<CR>
  nnoremap <buffer> <silent> gy <ScriptCmd>Fix()<CR>
enddef

command! Proof Run()
command! ProofClear Clear()
command! ProofAuto ToggleAuto()

augroup proof
  autocmd!
  autocmd FileType * if index(g:proof_filetypes, expand('<amatch>')) >= 0 | SetupBuffer() | endif
  autocmd CursorHold,BufWritePost * Auto()
  autocmd CursorHold * Hover()
augroup END

# For headless testing: block until the current check has finished.
def g:ProofWait(timeout_ms: number = 60000): bool
  var waited = 0
  while !exists('b:proof_done') && waited < timeout_ms
    sleep 100m
    waited += 100
  endwhile
  return exists('b:proof_done')
enddef
