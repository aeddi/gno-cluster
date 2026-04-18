#compdef make
# Tab-completion for `make <cmd> run=<folder>` in gno-cluster projects.
#
# Source this file in your current shell:
#     source /path/to/gno-cluster/completions/gno-cluster.zsh
# No ~/.zshrc modification required (but you can add that source line there
# if you want it persistent across sessions).
#
# The completion only activates when the current working directory is inside a
# gno-cluster project (detected by walking up for internal/scripts/cluster.sh).
# Outside that, it delegates to the default _make, so make keeps working
# normally in every other project.

_gno_cluster_make() {
    local root

    # Walk up from PWD looking for a cluster.sh marker.
    root="$PWD"
    while [[ "$root" != "/" && ! -f "$root/internal/scripts/cluster.sh" ]]; do
        root="${root:h}"
    done

    if [[ -f "$root/internal/scripts/cluster.sh" ]]; then
        # Are we completing a value right after `run=`? With zsh's default
        # splitting, `run=foo` becomes words "run", "=", "foo".
        if (( CURRENT >= 3 )) \
                && [[ "${words[CURRENT-1]}" == "=" ]] \
                && [[ "${words[CURRENT-2]}" == "run" ]]; then
            # Only for run-aware commands.
            local w found=0
            for w in "${words[@]:2}"; do
                case "$w" in
                    start|update|clone|infos|restart) found=1; break ;;
                esac
            done
            if (( found )); then
                local -a runs
                local entry
                for entry in "$root/runs"/*(N); do
                    [[ -d "$entry" && ! -L "$entry" ]] && runs+=("${entry:t}")
                done
                if (( ${#runs[@]} > 0 )); then
                    _values 'run folder' "${runs[@]}"
                    return 0
                fi
            fi
        fi
    fi

    # Delegate to the default make completion.
    _make "$@"
}

compdef _gno_cluster_make make
