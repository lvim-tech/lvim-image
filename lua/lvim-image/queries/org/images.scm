; Org links: [[target]] and [[target][description]].
;
; Org's grammar has NO node for a link — the whole thing is one `expr` whose children are the
; bracket tokens and the words between them, so there is nothing to capture as the path on its
; own. The `expr` is captured whole instead and `doc.resolve` unwraps it; the predicate is what
; keeps every OTHER expr in the paragraph out of the match.
;
; Not every such link is an image: `[[https://…][text]]` and `[[#anchor]]` match here too, and
; are dropped downstream by the scheme check and the extension test — one place decides what is
; displayable, for every format.
((expr) @image.src
  (#lua-match? @image.src "^%[%[.+%]%]$"))
