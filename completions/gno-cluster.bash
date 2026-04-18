# Tab-completion for `make <cmd> run=<folder>` in gno-cluster projects.
#
# Source this file in your current shell:
#     source /path/to/gno-cluster/completions/gno-cluster.bash
# Nothing is installed outside the project directory.
#
# Only activates when PWD is inside a gno-cluster checkout (detected by
# walking up for internal/scripts/cluster.sh). Outside that, it delegates to
# the default _make so regular make completion is unaffected.

_gno_cluster_make() {
    local root cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]:-}"

    # Walk up from PWD looking for a cluster.sh marker.
    root="$PWD"
    while [[ "$root" != "/" && ! -f "$root/internal/scripts/cluster.sh" ]]; do
        root="$(dirname "$root")"
    done

    if [[ -f "$root/internal/scripts/cluster.sh" ]]; then
        # Detect "completing a run= value". Handle both cases:
        #   (a) = is in COMP_WORDBREAKS (default):  words end in ... "run" "="
        #   (b) = removed from COMP_WORDBREAKS:     current word is "run=<partial>"
        local partial="" match=0
        if (( COMP_CWORD >= 2 )) \
                && [[ "${COMP_WORDS[COMP_CWORD-2]}" == "run" ]] \
                && [[ "$prev" == "=" ]]; then
            partial="$cur"
            match=1
        elif [[ "$cur" == run=* ]]; then
            partial="${cur#run=}"
            match=2
        fi

        if (( match )); then
            # Ensure a run-aware command is somewhere on the line.
            local w cmd_found=0
            for w in "${COMP_WORDS[@]:1}"; do
                case "$w" in
                    start|update|clone|infos|restart) cmd_found=1; break ;;
                esac
            done
            if (( cmd_found )); then
                local runs=() entry
                if [[ -d "$root/runs" ]]; then
                    for entry in "$root/runs"/*; do
                        [[ -d "$entry" && ! -L "$entry" ]] || continue
                        runs+=("$(basename "$entry")")
                    done
                fi
                COMPREPLY=($(compgen -W "${runs[*]}" -- "$partial"))
                # In case (b) we ate the "run=" prefix; put it back so the
                # shell replaces the whole word correctly.
                if (( match == 2 )); then
                    COMPREPLY=("${COMPREPLY[@]/#/run=}")
                fi
                return 0
            fi
        fi
    fi

    # Fall back to the default make completion. Trigger bash-completion's lazy
    # loader first if it exists, so _make is defined even on the first tab.
    if ! declare -F _make >/dev/null 2>&1; then
        if declare -F _comp_load >/dev/null 2>&1; then
            _comp_load make 2>/dev/null || true
        elif declare -F _completion_loader >/dev/null 2>&1; then
            _completion_loader make 2>/dev/null || true
        fi
    fi
    if declare -F _make >/dev/null 2>&1; then
        _make
    fi
}

complete -F _gno_cluster_make make
