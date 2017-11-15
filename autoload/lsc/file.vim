if !exists('s:initialized')
  " file path -> file version
  let s:file_versions = {}
  " file path -> file content
  let s:file_content = {}
  " filetype -> boolean
  let s:allowed_incremental_sync = {}
endif

" Send a 'didOpen' message for all open files of type `filetype` if they aren't
" already tracked.
function! lsc#file#trackAll(filetype) abort
  for buffer in getbufinfo({'loaded': v:true})
    if getbufvar(buffer.bufnr, '&filetype') != a:filetype | continue | endif
    call s:FlushChanges(buffer.name, a:filetype)
  endfor
endfunction

" Run language servers for this filetype if they aren't already running and
" flush file changes.
function! lsc#file#onOpen() abort
  call lsc#server#start(&filetype)
  call lsc#config#mapKeys()
  call s:FlushChanges(expand('%:p'), &filetype)
endfunction

" Flushes changes for the current buffer.
function! lsc#file#flushChanges() abort
  call s:FlushIfChanged(expand('%:p'), &filetype)
endfunction

" Send the 'didOpen' message for a file.
function! s:DidOpen(file_path) abort
  let bufnr = bufnr(a:file_path)
  if !bufloaded(bufnr) | return | endif
  let buffer_content = join(getbufline(bufnr, 1, '$'), "\n")
  let filetype = getbufvar(bufnr, '&filetype')
  let params = {'textDocument':
      \   {'uri': lsc#uri#documentUri(a:file_path),
      \    'languageId': filetype,
      \    'version': 1,
      \    'text': buffer_content
      \   }
      \ }
  if lsc#server#call(filetype, 'textDocument/didOpen', params)
    let s:file_versions[a:file_path] = 1
    let s:file_content[a:file_path] = buffer_content
    if s:AllowIncrementalSync(filetype)
      let s:file_content[a:file_path] = buffer_content
    endif
  endif
endfunction

" Mark all files of type `filetype` as untracked.
function! lsc#file#clean(filetype) abort
  for buffer in getbufinfo({'loaded': v:true})
    if getbufvar(buffer.bufnr, '&filetype') != a:filetype | continue | endif
    if has_key(s:file_versions, buffer.name)
      unlet s:file_versions[buffer.name]
      unlet s:file_content[buffer.name]
    endif
  endfor
endfunction

function! lsc#file#onChange() abort
  if exists('b:lsc_flush_timer')
    call timer_stop(b:lsc_flush_timer)
  endif
  let b:lsc_flush_timer =
      \ timer_start(500,
      \   {_->s:FlushIfChanged(expand('%:p'), &filetype)},
      \   {'repeat': 1})
endfunction

" Flushes only if `onChange` had previously been called for the file and the
" changes aren't yet flusehd.
function! s:FlushIfChanged(file_path, filetype) abort
  if exists('b:lsc_flush_timer')
    call s:FlushChanges(a:file_path, a:filetype)
  endif
endfunction

" Changes are flushed after 500ms of inactivity or before leaving the buffer.
function! s:FlushChanges(file_path, filetype) abort
  if !has_key(s:file_versions, a:file_path)
    call s:DidOpen(a:file_path)
    return
  endif
  let s:file_versions[a:file_path] += 1
  if exists('b:lsc_flush_timer')
    call timer_stop(b:lsc_flush_timer)
    unlet b:lsc_flush_timer
  endif
  let buffer_content = join(getline(1, '$'), "\n")
  let allow_incremental = s:AllowIncrementalSync(a:filetype)
  if allow_incremental
    let change = lsc#diff#compute(s:file_content[a:file_path], buffer_content)
  else
    let change = {'text': buffer_content}
  endif
  let params = {'textDocument':
      \   {'uri': lsc#uri#documentUri(),
      \    'version': s:file_versions[a:file_path],
      \   },
      \ 'contentChanges': [change],
      \ }
  call lsc#server#call(a:filetype, 'textDocument/didChange', params)
  if allow_incremental
    let s:file_content[a:file_path] = buffer_content
  endif
endfunction

function! lsc#file#version() abort
  return get(s:file_versions, expand('%:p'), '')
endfunction

function! lsc#file#enableIncrementalSync(filetype) abort
  let s:allowed_incremental_sync[a:filetype] = v:true
endfunction

function! s:AllowIncrementalSync(filetype) abort
  return exists('g:lsc_enable_incremental_sync')
      \ && g:lsc_enable_incremental_sync
      \ && get(s:allowed_incremental_sync, a:filetype, v:false)
endfunction
