FILING A FOLLOW-UP — an issue you create must be dispatchable, or its PRD signs off and closes over
it and nothing ever runs it: `gh issue create … --label {{LABEL_READY}}`, its body ENDING with the
lines below, #<P> = the PRD that #{{ISSUE}} names in its own `## Parent` / `Part of` (`None` if none):
    ## Blocked by
    None
    ## Parent
    #<P>
