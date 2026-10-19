# proof.vim

Word-style grammar underlines for Vim 9, powered by Claude Code.

proof.vim sends the buffer you are writing to `claude -p` in the background,
asks for a list of spelling, grammar and phrasing problems, and underlines
each one in the buffer. Rest the cursor on an underline to see the reason and
the suggested fix, and press a key to accept it. It is the half of Grammarly
that rule-based checkers miss, inside the editor you already use.

It needs no plugin manager, no language server and no API key. It runs on a
Claude Pro or Max subscription through the `claude` command-line tool.

## Requirements

- Vim 9 built with `+job`, `+textprop` and `+popupwin`. Standard distribution
  builds have all three. Check with `:version`.
- [Claude Code](https://claude.com/claude-code) installed and logged in, so
  that `claude -p` works from a shell.

Neovim is not supported. It has no `prop_add()` or `popup_atcursor()`; a port
would use `vim.diagnostic` instead.

## Install

Vim's built-in package support:

```sh
git clone https://github.com/mtelvers/proof.vim ~/.vim/pack/plugins/start/proof.vim
```

Or copy `plugin/proof.vim` into `~/.vim/plugin/`. Any plugin manager that
takes a GitHub path works too.

## Use

Open a Markdown file and write. When you pause for `'updatetime'`
milliseconds (4 seconds by default), or when you save, the buffer is checked
and problems are underlined in orange. You can keep editing while the check
runs; it takes a few seconds.

| Key | Action |
|-----|--------|
| `]g` / `[g` | jump to the next / previous suggestion |
| `gh` | show the reason and suggested fix for the suggestion under the cursor |
| `gy` | accept the suggested fix under the cursor |

Resting the cursor on an underline pops the suggestion up automatically.

| Command | Action |
|---------|--------|
| `:Proof` | check the current buffer now |
| `:ProofClear` | remove the underlines |
| `:ProofAuto` | toggle automatic checking on idle and on save |

## Configuration

Set these in `~/.vimrc`. The values shown are the defaults.

```vim
let g:proof_model = 'sonnet'      " 'haiku' is faster, 'opus' more thorough
let g:proof_effort = 'low'
let g:proof_auto = v:true         " v:false: check only with :Proof
let g:proof_filetypes = ['markdown', 'text', 'tex', 'plaintex', 'mail',
                       \ 'gitcommit', 'rst', 'asciidoc']
let g:proof_max_bytes = 40000     " refuse to check buffers larger than this
let g:proof_no_maps = v:false     " v:true: define no key mappings
```

The underline is the `ProofError` highlight group. To change its colour, give
the arguments you would pass to `:highlight`:

```vim
let g:proof_highlight = 'cterm=undercurl ctermul=Blue gui=undercurl guisp=Blue'
```

Each automatic check is one call to Claude, so one call per pause after
editing. If you would rather control when that happens, set `g:proof_auto`
to `v:false` and run `:Proof` yourself.

## Pairing with Vim's spell checker

proof.vim is for grammar and phrasing. For instant spelling on every
keystroke, use Vim's built-in checker alongside it:

```vim
set spell spelllang=en_gb
```

Vim's default spell highlighting uses solid background colours in a terminal.
To get coloured underlines that match proof.vim, redefine the four spell
groups:

```vim
highlight SpellBad   cterm=undercurl ctermbg=NONE ctermul=Red     gui=undercurl guibg=NONE guisp=Red
highlight SpellCap   cterm=undercurl ctermbg=NONE ctermul=Blue    gui=undercurl guibg=NONE guisp=Blue
highlight SpellRare  cterm=undercurl ctermbg=NONE ctermul=Magenta gui=undercurl guibg=NONE guisp=Magenta
highlight SpellLocal cterm=undercurl ctermbg=NONE ctermul=Cyan    gui=undercurl guibg=NONE guisp=Cyan
```

## Curly underlines in a terminal

Undercurl needs three things to line up: the terminal emulator must support
it (kitty, WezTerm, Alacritty, foot, iTerm2 and recent GNOME Terminal do;
macOS Terminal.app does not), Vim must know the escape codes, and anything in
between, such as tmux, must pass them through. Where any of these is missing
you get a plain straight underline instead, which still works.

Inside tmux, the `tmux-256color` terminfo entry has no undercurl capability,
so give Vim the codes directly:

```vim
if &term =~# '^\%(tmux\|screen\|xterm\)'
  let &t_Cs = "\e[4:3m"               " start undercurl
  let &t_Ce = "\e[4:0m"               " stop undercurl
  let &t_AU = "\e[58;5;%dm"           " underline colour, 256-colour index
  let &t_8u = "\e[58;2;%lu;%lu;%lum"  " underline colour, RGB
endif
```

and tell tmux (3.2 or later) that the outer terminal supports underline
styles, in `~/.tmux.conf`:

```
set -as terminal-features ",xterm-256color:usstyle"
```

Detach and reattach for that to take effect.

## How it works

The buffer is piped to `claude -p` with a system prompt that asks for a JSON
array of `{original, replacement, reason}` objects, where `original` is a
short span copied verbatim from the document. Each span is located in the
buffer with a plain substring search and marked with a text property. There
is no line-number arithmetic for the model to get wrong. Accepting a fix
replaces only that span and shifts the other underlines on the line.

## Licence

MIT. See [LICENSE](LICENSE).
