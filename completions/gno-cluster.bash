# Tab-completion for `make <cmd> run=<folder>` in gno-cluster projects.
#
# Source this file in your current shell:
#     source /path/to/gno-cluster/completions/gno-cluster.bash
# No ~/.bashrc modification required (but you can add that source line there
# if you want it persistent across sessions).
#
# The completion only activates when the current working directory is inside a
# gno-cluster project (detected by walking up for internal/scripts/cluster.sh).
# Outside that, it delegates to bash-completion's default _make, so make keeps
# working normally in every other project.

_gno_cluster_make() {
    local cur root runs_dir
    cur="${COMP_WORDS[COMP_CWORD]}"

    # Walk up from PWD looking for a cluster.sh marker.
    root="$PWD"
    while [[ "$root" != "/" && ! -f "$root/internal/scripts/cluster.sh" ]]; do
        root="$(dirname "$root")"
    done

    if [[ -f "$root/internal/scripts/cluster.sh" ]]; then
        # Are we completing a value right after `run=`? COMP_WORDBREAKS includes
        # `=` by default, so `run=foo` is split into words "run", "=", "foo".
        if (( COMP_CWORD >= 2 )) \
                && [[ "${COMP_WORDS[COMP_CWORD-2]}" == "run" ]] \
                && [[ "${COMP_WORDS[COMP_CWORD-1]}" == "=" ]]; then
            # Only for run-aware commands (avoid suggesting run folders for,
            # say, `foo=bar` if the user ever types something similar).
            local w found=0
            for w in "${COMP_WORDS[@]:1}"; do
                case "$w" in
                    start|update|clone|infos|restart) found=1; break ;;
                esac
            done
            if (( found )); then
                runs_dir="$root/runs"
                if [[ -d "$runs_dir" ]]; then
                    local runs=() entry
                    for entry in "$runs_dir"/*; do
                        [[ -d "$entry" && ! -L "$entry" ]] || continue
                        runs+=("$(basename "$entry")")
                    done
                    COMPREPLY=($(compgen -W "${runs[*]}" -- "$cur"))
                    return 0
                fi
            fi
        fi
    fi

    # Delegate to the default make completion when available.
    if declare -F _make >/dev/null 2>&1; then
        _make
    fi
}

complete -F _gno_cluster_make make
