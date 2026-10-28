FILING A FOLLOW-UP — any issue you create in this session (a gap you defer, an edge case, a
pre-existing failure worth fixing) MUST be dispatchable, or it is stranded for good: create it WITH
the `{{LABEL_READY}}` label (`gh issue create … --label {{LABEL_READY}}`), and end its body with:

    ## Blocked by
    None

    ## Parent
    #<P>

where #<P> is the PRD that #{{ISSUE}} names in its own `## Parent` (or `Part of #N`) — or the literal
word `None` under `## Parent` when #{{ISSUE}} has no parent. An issue filed with no label is in no
lane's queue: its PRD signs off and closes over it, and nothing ever dispatches it.
